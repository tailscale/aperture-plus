// Command timing-go measures the cold latency of the core tsnet lifecycle
// operations against the real Tailscale control plane, using the SAME
// tailscale.com version the Aperture app embeds (pinned in go.mod):
//
//  1. Up() with NO auth key  → first login URL (BrowseToURL)
//  2. tear down + restart    → Up() with an auth key begins
//  3. Up() with auth key     → Running (truly connected), while recording
//     raw-IPN-bus ordering for LoginFinished, NetMap, Starting, and Running
//  4. Logout                 → idle (NeedsLogin / Stopped / NoState)
//  5. second Up() with key   → Running (a fresh node, mirroring an app
//     relaunch-on-the-same-workspace with a key)
//
// Each iteration uses a FRESH state dir per server so every measurement is a
// cold start (mirrors the UI tests' `-UITestResetLogin`). Keyed nodes are
// ephemeral so they auto-cleanup on Close. Run several times to see variance:
//
//	go run . -runs 5
//
// Auth key resolution: -authkey flag > APERTURE_TEST_AUTHKEY env >
// ~/.aperture-ios-authkey file (same order as the UI tests).
//
// # Peer path-upgrade mode (-peer <host>)
//
// When -peer is set, the lifecycle test is skipped and instead each run starts
// a keyed node, sends a little HTTP traffic to http://<host>/ (the same thing
// the app does when you browse to a tailnet peer), and watches the peer's
// CurAddr/Relay in the local-API /status response at high frequency. This
// reproduces exactly what the app's ConnectionType resolver keys off of
// (direct iff peer.CurAddr != ""), so a path that flips direct→DERP quickly
// here would explain the URL bar showing "mostly one green dot, briefly two":
//
//	go run . -peer ai -runs 3
//	go run . -peer ai -peer-watch 30s -peer-traffic 12s
//
// -peer-watch   : total time to watch the peer path (default 30s).
// -peer-traffic : how long to send 1 GET/s before going idle (default 12s);
//
//	the remaining watch window is idle, to test whether a direct
//	path survives ~10s+ of no traffic (normal tailscale keeps it
//	for minutes).
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"tailscale.com/derp/derphttp"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/net/netmon"
	"tailscale.com/tsnet"
	"tailscale.com/types/key"
)

const defaultControlURL = "https://controlplane.tailscale.com"

func main() {
	runs := flag.Int("runs", 5, "number of iterations to run")
	authKeyFlag := flag.String("authkey", "", "auth key (overrides env/file)")
	verbose := flag.Bool("v", false, "print tsnet log lines to stderr")

	// Peer path-upgrade mode.
	peerHost := flag.String("peer", "", "enable peer-upgrade test mode against this host (e.g. 'ai'); skips the lifecycle test")
	peerWatch := flag.Duration("peer-watch", 30*time.Second, "peer mode: total time to watch the peer path")
	peerTraffic := flag.Duration("peer-traffic", 12*time.Second, "peer mode: how long to send 1 GET/s before going idle")

	// Interactive completion mode. This intentionally has no auth key: it
	// measures the real LoginFinished event, which keyed login does not emit.
	interactive := flag.Bool("interactive", false, "measure a real interactive login; prints a URL to open and skips lifecycle/peer modes")
	interactiveTimeout := flag.Duration("interactive-timeout", 5*time.Minute, "interactive mode: deadline for completing browser auth")
	authURLOnly := flag.Bool("auth-url-only", false, "measure cold no-key startup through first BrowseToURL, then exit; does not require an auth key")
	derpURL := flag.String("derp-spike", "", "connect directly to a DERP URL repeatedly (for example https://derp16b.tailscale.com/derp)")
	derpRuns := flag.Int("derp-runs", 5, "DERP spike: number of fresh connections")

	flag.Parse()

	if *authURLOnly {
		runAuthURLMode(*runs, *interactiveTimeout, *verbose)
		return
	}

	if *derpURL != "" {
		if err := runDERPSpike(*derpURL, *derpRuns); err != nil {
			fmt.Fprintln(os.Stderr, "DERP spike FAILED:", err)
			os.Exit(1)
		}
		return
	}

	if *interactive {
		if err := runInteractiveLogin(*interactiveTimeout, *verbose); err != nil {
			fmt.Fprintln(os.Stderr, "interactive login FAILED:", err)
			os.Exit(1)
		}
		return
	}

	key := *authKeyFlag
	if key == "" {
		key = os.Getenv("APERTURE_TEST_AUTHKEY")
	}
	if key == "" {
		if b, err := os.ReadFile(os.Getenv("HOME") + "/.aperture-ios-authkey"); err == nil {
			key = strings.TrimSpace(string(b)) // file has a trailing newline; control plane rejects "key\n"
		}
	}
	if key == "" {
		fmt.Fprintln(os.Stderr, "no auth key found (-authkey / APERTURE_TEST_AUTHKEY / ~/.aperture-ios-authkey)")
		os.Exit(1)
	}

	if *peerHost != "" {
		runPeerMode(*runs, *peerHost, *peerWatch, *peerTraffic, key, *verbose)
		return
	}

	fmt.Printf("timing-go: %d runs, control=%s, key=%s…\n\n", *runs, defaultControlURL, key[:14])
	fmt.Println("run | 1:Up→URL | 2:URL→KeyUp | 3:KeyUp→Running | 4:Logout→idle | 5:KeyUp2→Running")

	var results []lifecycleTiming

	for i := 1; i <= *runs; i++ {
		rs, err := runOnce(i, key, *verbose)
		if err != nil {
			fmt.Fprintf(os.Stderr, "run %d FAILED: %v\n", i, err)
			// keep any partial timings already measured; unmeasured phases stay 0 ("-")
		}
		results = append(results, rs)
		fmt.Printf("%3d | %8s | %9s | %12s | %11s | %12s\n",
			i, durStr(rs.t1), durStr(rs.t2), durStr(rs.t3), durStr(rs.t4), durStr(rs.t5))
	}

	// Summary (avg / min / max), ignoring failed runs (-1).
	fmt.Println("\nsummary (successful runs only):")
	for _, label := range []struct {
		name string
		get  func(lifecycleTiming) time.Duration
	}{
		{"1:Up→URL       ", func(x lifecycleTiming) time.Duration { return x.t1 }},
		{"2:URL→KeyUp    ", func(x lifecycleTiming) time.Duration { return x.t2 }},
		{"3:KeyUp→Running", func(x lifecycleTiming) time.Duration { return x.t3 }},
		{"4:Logout→idle  ", func(x lifecycleTiming) time.Duration { return x.t4 }},
		{"5:KeyUp2→Run   ", func(x lifecycleTiming) time.Duration { return x.t5 }},
	} {
		var sum, n int
		var mn, mx time.Duration
		first := true
		for _, x := range results {
			v := label.get(x)
			if v <= 0 {
				continue
			}
			sum += int(v)
			n++
			if first || v < mn {
				mn = v
			}
			if first || v > mx {
				mx = v
			}
			first = false
		}
		if n == 0 {
			fmt.Printf("  %s  n=0 (all failed)\n", label.name)
			continue
		}
		avg := time.Duration(sum / n)
		fmt.Printf("  %s  n=%d  avg=%s  min=%s  max=%s\n", label.name, n, avg, mn, mx)
	}
}

type lifecycleTiming struct {
	t1, t2, t3, t4, t5 time.Duration
}

// loginCompletionTiming records notification receipt times from the raw Go IPN
// bus. firstNetmapFromLogin is signed: a negative value means the first netmap
// arrived before LoginFinished. loginToNetmapAfter is always the first netmap
// observed after LoginFinished, which is the latency requested by this harness.
// Booleans distinguish a real zero-ish duration from an event that never came.
type loginCompletionTiming struct {
	needsLoginAt         time.Time
	loginFinishedAt      time.Time
	firstNetmapAt        time.Time
	firstNetmapAfterAt   time.Time
	startingAt           time.Time
	runningAt            time.Time
	firstNetmapFromLogin time.Duration
	loginToNetmapAfter   time.Duration
	loginToStarting      time.Duration
	loginToRunning       time.Duration
	needsLoginToRunning  time.Duration
}

func (t *loginCompletionTiming) observe(n *ipn.Notify, now time.Time) {
	if n.NetMap != nil && t.firstNetmapAt.IsZero() {
		t.firstNetmapAt = now
	}
	if n.LoginFinished != nil && t.loginFinishedAt.IsZero() {
		t.loginFinishedAt = now
		if !t.firstNetmapAt.IsZero() {
			t.firstNetmapFromLogin = t.firstNetmapAt.Sub(now)
		}
	}
	if n.NetMap != nil && !t.loginFinishedAt.IsZero() && t.firstNetmapAfterAt.IsZero() {
		t.firstNetmapAfterAt = now
		t.loginToNetmapAfter = now.Sub(t.loginFinishedAt)
	}
	if n.State != nil {
		switch *n.State {
		case ipn.NeedsLogin:
			if t.needsLoginAt.IsZero() {
				t.needsLoginAt = now
			}
		case ipn.Starting:
			if t.startingAt.IsZero() {
				t.startingAt = now
			}
		case ipn.Running:
			if t.runningAt.IsZero() {
				t.runningAt = now
			}
		}
	}
	if !t.loginFinishedAt.IsZero() {
		if !t.firstNetmapAt.IsZero() && t.firstNetmapFromLogin == 0 && t.firstNetmapAt != t.loginFinishedAt {
			t.firstNetmapFromLogin = t.firstNetmapAt.Sub(t.loginFinishedAt)
		}
		if !t.startingAt.IsZero() {
			t.loginToStarting = t.startingAt.Sub(t.loginFinishedAt)
		}
		if !t.runningAt.IsZero() {
			t.loginToRunning = t.runningAt.Sub(t.loginFinishedAt)
		}
	}
	if !t.needsLoginAt.IsZero() && !t.runningAt.IsZero() {
		t.needsLoginToRunning = t.runningAt.Sub(t.needsLoginAt)
	}
}

func signedDurStr(d time.Duration, present bool) string {
	if !present {
		return "-"
	}
	if d < 0 {
		return "-" + durStr(-d)
	}
	if d == 0 {
		return "<1ms"
	}
	return "+" + durStr(d)
}

type authURLTiming struct {
	startToNeedsLogin time.Duration
	needsLoginToURL   time.Duration
	startToURL        time.Duration
}

func runAuthURLMode(runs int, timeout time.Duration, verbose bool) {
	fmt.Printf("timing-go auth URL: %d cold runs, control=%s, timeout=%s\n", runs, defaultControlURL, timeout)
	fmt.Println("run | Start→NeedsLogin | NeedsLogin→URL | Start→URL")
	results := make([]authURLTiming, 0, runs)
	for i := 1; i <= runs; i++ {
		r, err := measureAuthURL(i, timeout, verbose)
		if err != nil {
			fmt.Fprintf(os.Stderr, "run %d FAILED: %v\n", i, err)
		}
		results = append(results, r)
		fmt.Printf("%3d | %16s | %14s | %9s\n", i, durStr(r.startToNeedsLogin), durStr(r.needsLoginToURL), durStr(r.startToURL))
	}
	fmt.Println("summary:")
	printAuthURLSummary("  Start→NeedsLogin", results, func(r authURLTiming) time.Duration { return r.startToNeedsLogin })
	printAuthURLSummary("  NeedsLogin→URL ", results, func(r authURLTiming) time.Duration { return r.needsLoginToURL })
	printAuthURLSummary("  Start→URL      ", results, func(r authURLTiming) time.Duration { return r.startToURL })
}

func measureAuthURL(run int, timeout time.Duration, verbose bool) (authURLTiming, error) {
	var result authURLTiming
	base, err := os.MkdirTemp("", fmt.Sprintf("timing-go-auth-url-%d-", run))
	if err != nil {
		return result, err
	}
	defer os.RemoveAll(base)
	logf := func(format string, a ...any) {
		if verbose {
			fmt.Fprintf(os.Stderr, "[tsnet auth-url r%d] "+format+"\n", append([]any{run}, a...)...)
		}
	}
	srv := &tsnet.Server{Hostname: fmt.Sprintf("timing-auth-url-%d", run), Dir: base, ControlURL: defaultControlURL, Logf: logf}
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	start := time.Now()
	if err := srv.Start(); err != nil {
		return result, err
	}
	lc, err := srv.LocalClient()
	if err != nil {
		return result, err
	}
	watcher, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
	if err != nil {
		return result, err
	}
	defer watcher.Close()
	var needsLoginAt time.Time
	for {
		n, err := watcher.Next()
		if err != nil {
			return result, err
		}
		now := time.Now()
		if n.State != nil && *n.State == ipn.NeedsLogin && needsLoginAt.IsZero() {
			needsLoginAt = now
			result.startToNeedsLogin = now.Sub(start)
		}
		if n.BrowseToURL != nil && *n.BrowseToURL != "" {
			result.startToURL = now.Sub(start)
			if !needsLoginAt.IsZero() {
				result.needsLoginToURL = now.Sub(needsLoginAt)
			}
			return result, nil
		}
	}
}

func printAuthURLSummary(name string, results []authURLTiming, get func(authURLTiming) time.Duration) {
	var values []time.Duration
	for _, r := range results {
		if v := get(r); v > 0 {
			values = append(values, v)
		}
	}
	if len(values) == 0 {
		fmt.Printf("%s n=0\n", name)
		return
	}
	slices.Sort(values)
	var total time.Duration
	for _, v := range values {
		total += v
	}
	p50 := values[(len(values)-1)/2]
	p90 := values[(len(values)-1)*9/10]
	fmt.Printf("%s n=%d avg=%s p50=%s p90=%s min=%s max=%s\n", name, len(values), durStr(total/time.Duration(len(values))), durStr(p50), durStr(p90), durStr(values[0]), durStr(values[len(values)-1]))
}

func runDERPSpike(serverURL string, runs int) error {
	fmt.Printf("timing-go DERP spike: url=%s runs=%d\n", serverURL, runs)
	fmt.Println("run | full DERP Connect | TLS resumed | TLS version")
	for i := 1; i <= runs; i++ {
		client, err := derphttp.NewClient(key.NewNode(), serverURL, func(string, ...any) {}, netmon.NewStatic())
		if err != nil {
			return err
		}
		start := time.Now()
		err = client.Connect(context.Background())
		elapsed := time.Since(start)
		if err != nil {
			client.Close()
			return fmt.Errorf("run %d: %w", i, err)
		}
		state, _ := client.TLSConnectionState()
		resumed, version := false, "none"
		if state != nil {
			resumed = state.DidResume
			version = tlsVersionName(state.Version)
		}
		fmt.Printf("%3d | %17s | %11v | %s\n", i, durStr(elapsed), resumed, version)
		client.Close()
	}
	return nil
}

func tlsVersionName(v uint16) string {
	switch v {
	case tls.VersionTLS13:
		return "TLS1.3"
	case tls.VersionTLS12:
		return "TLS1.2"
	default:
		return fmt.Sprintf("0x%04x", v)
	}
}

func runInteractiveLogin(timeout time.Duration, verbose bool) error {
	base, err := os.MkdirTemp("", "timing-go-interactive-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(base)

	logf := func(format string, a ...any) {
		if verbose {
			fmt.Fprintf(os.Stderr, "[tsnet interactive] "+format+"\n", a...)
		}
	}
	srv := &tsnet.Server{
		Hostname:   "timing-go-interactive",
		Dir:        base,
		ControlURL: defaultControlURL,
		Ephemeral:  true,
		Logf:       logf,
	}
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	go func() { _, _ = srv.Up(ctx) }()
	lc, err := srv.LocalClient()
	if err != nil {
		return fmt.Errorf("LocalClient: %w", err)
	}
	watcher, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState|ipn.NotifyInitialNetMap|ipn.NotifyWatchEngineUpdates)
	if err != nil {
		return fmt.Errorf("WatchIPNBus: %w", err)
	}
	defer watcher.Close()

	var timing loginCompletionTiming
	var printedURL bool
	fmt.Printf("timing-go interactive: waiting up to %s; open the URL below and authorize this node\n", timeout)
	for {
		n, err := watcher.Next()
		if err != nil {
			return fmt.Errorf("watcher: %w", err)
		}
		now := time.Now()
		timing.observe(&n, now)
		if n.BrowseToURL != nil && *n.BrowseToURL != "" && !printedURL {
			printedURL = true
			fmt.Printf("LOGIN URL: %s\n", *n.BrowseToURL)
		}
		fields := notifyFieldNames(&n)
		if fields != "" {
			fmt.Printf("  +%s  %s", durStr(now.Sub(firstNonZero(timing.needsLoginAt, now))), fields)
			if n.State != nil {
				fmt.Printf("=%s", *n.State)
			}
			if n.Engine != nil {
				fmt.Printf("(NumLive=%d LiveDERPs=%d)", n.Engine.NumLive, n.Engine.LiveDERPs)
			}
			fmt.Println()
		}
		if !timing.loginFinishedAt.IsZero() && !timing.runningAt.IsZero() {
			fmt.Println("interactive completion:")
			fmt.Printf("  first NetMap − LoginFinished:       %s (signed; negative means netmap came first)\n", signedDurStr(timing.firstNetmapFromLogin, !timing.firstNetmapAt.IsZero()))
			fmt.Printf("  LoginFinished → first NetMap after: %s\n", durStr(timing.loginToNetmapAfter))
			fmt.Printf("  LoginFinished → Starting:           %s\n", durStr(timing.loginToStarting))
			fmt.Printf("  LoginFinished → Running:            %s\n", durStr(timing.loginToRunning))
			fmt.Printf("  NeedsLogin → Running:                %s\n", durStr(timing.needsLoginToRunning))
			return nil
		}
	}
}

func notifyFieldNames(n *ipn.Notify) string {
	var f []string
	if n.LoginFinished != nil {
		f = append(f, "LoginFinished")
	}
	if n.NetMap != nil {
		f = append(f, "NetMap")
	}
	if n.State != nil {
		f = append(f, "State")
	}
	if n.BrowseToURL != nil {
		f = append(f, "BrowseToURL")
	}
	if n.Engine != nil {
		f = append(f, "Engine")
	}
	return strings.Join(f, ",")
}

func firstNonZero(t, fallback time.Time) time.Time {
	if t.IsZero() {
		return fallback
	}
	return t
}

func durStr(d time.Duration) string {
	if d <= 0 {
		return "-"
	}
	if d < 100*time.Millisecond {
		return d.Round(time.Millisecond).String() // show ms for the fast phases
	}
	return d.Round(10 * time.Millisecond).String()
}

func runOnce(run int, authKey string, verbose bool) (rs lifecycleTiming, err error) {
	base := filepath.Join(os.TempDir(), fmt.Sprintf("timing-go-run%d", run))
	logf := func(format string, a ...any) {
		if verbose {
			fmt.Fprintf(os.Stderr, "[tsnet r%d] "+format+"\n", append([]any{run}, a...)...)
		}
	}
	_ = os.RemoveAll(base)

	// --- Phase 1: Up() with NO auth key → first login URL ---
	srv1 := &tsnet.Server{
		Hostname:   fmt.Sprintf("timing-go-%d", run),
		Dir:        filepath.Join(base, "nokey"),
		ControlURL: defaultControlURL,
		Ephemeral:  false, // no key → not registering; ephemeral is irrelevant
		Logf:       logf,
	}
	tUpStart := time.Now()
	// Up() blocks until Running; with no key it never reaches Running, so run
	// it in a goroutine and observe the login URL on a SEPARATE bus watcher.
	// (NotifyInitialState replays the current State+BrowseToURL in the first
	// message, so we never miss the URL even if we attach after it was emitted.)
	upCtx1, cancelUp1 := context.WithCancel(context.Background())
	go func() { _, _ = srv1.Up(upCtx1) }()

	lc1, err := srv1.LocalClient()
	if err != nil {
		cancelUp1()
		_ = srv1.Close()
		return rs, fmt.Errorf("p1 LocalClient: %w", err)
	}
	w1, err := lc1.WatchIPNBus(context.Background(), ipn.NotifyInitialState)
	if err != nil {
		cancelUp1()
		_ = srv1.Close()
		return rs, fmt.Errorf("p1 WatchIPNBus: %w", err)
	}
	gotURL := false
	for !gotURL {
		n, e := w1.Next()
		if e != nil {
			w1.Close()
			cancelUp1()
			_ = srv1.Close()
			return rs, fmt.Errorf("p1 watcher: %w", e)
		}
		if n.ErrMessage != nil {
			w1.Close()
			cancelUp1()
			_ = srv1.Close()
			return rs, fmt.Errorf("p1 backend: %s", *n.ErrMessage)
		}
		if n.BrowseToURL != nil && *n.BrowseToURL != "" {
			rs.t1 = time.Since(tUpStart)
			gotURL = true
		}
	}
	_ = w1.Close()
	tURL := time.Now()

	// --- Phase 2: tear down + restart with an auth key (measured from tURL) ---
	cancelUp1()
	_ = srv1.Close() // Close latency is part of t2 (the restart overhead).

	srv2 := &tsnet.Server{
		Hostname:   fmt.Sprintf("timing-go-%d-key", run),
		Dir:        filepath.Join(base, "key1"),
		AuthKey:    authKey,
		ControlURL: defaultControlURL,
		Ephemeral:  true,
		Logf:       logf,
	}
	tKeyUpStart := time.Now()
	rs.t2 = tKeyUpStart.Sub(tURL)

	// --- Phase 3: Up() with auth key → Running ---
	st, err := srv2.Up(context.Background())
	if err != nil {
		_ = srv2.Close()
		return rs, fmt.Errorf("p3 Up: %w", err)
	}
	rs.t3 = time.Since(tKeyUpStart)
	if st.BackendState != "Running" {
		_ = srv2.Close()
		return rs, fmt.Errorf("p3 not Running: %s", st.BackendState)
	}

	// --- Phase 4: Logout → idle (the app's exact path: currentProfile +
	//     deleteProfile, NOT lc.Logout — the Swift wrapper doesn't expose the
	//     latter publicly, and deleteProfile is what the app's Logout button calls) ---
	lc2, err := srv2.LocalClient()
	if err != nil {
		_ = srv2.Close()
		return rs, fmt.Errorf("p4 LocalClient: %w", err)
	}
	w2, err := lc2.WatchIPNBus(context.Background(), ipn.NotifyInitialState)
	if err != nil {
		_ = srv2.Close()
		return rs, fmt.Errorf("p4 WatchIPNBus: %w", err)
	}
	tLogoutStart := time.Now()
	cur, _, err := lc2.ProfileStatus(context.Background())
	if err != nil {
		w2.Close()
		_ = srv2.Close()
		return rs, fmt.Errorf("p4 ProfileStatus: %w", err)
	}
	if err := lc2.DeleteProfile(context.Background(), cur.ID); err != nil {
		w2.Close()
		_ = srv2.Close()
		return rs, fmt.Errorf("p4 DeleteProfile: %w", err)
	}
	// Watch until the backend settles into a non-running, non-starting state.
	idle := false
	for !idle {
		n, e := w2.Next()
		if e != nil {
			w2.Close()
			_ = srv2.Close()
			return rs, fmt.Errorf("p4 watcher: %w", e)
		}
		if n.State != nil {
			switch *n.State {
			case ipn.NeedsLogin, ipn.Stopped, ipn.NoState:
				rs.t4 = time.Since(tLogoutStart)
				idle = true
			}
		}
	}
	_ = w2.Close()
	_ = srv2.Close()

	// --- Phase 5: second Up() with auth key → Running (fresh node) ---
	srv3 := &tsnet.Server{
		Hostname:   fmt.Sprintf("timing-go-%d-key2", run),
		Dir:        filepath.Join(base, "key2"),
		AuthKey:    authKey,
		ControlURL: defaultControlURL,
		Ephemeral:  true,
		Logf:       logf,
	}
	tKeyUp2Start := time.Now()
	st2, err := srv3.Up(context.Background())
	if err != nil {
		_ = srv3.Close()
		return rs, fmt.Errorf("p5 Up: %w", err)
	}
	rs.t5 = time.Since(tKeyUp2Start)
	if st2.BackendState != "Running" {
		_ = srv3.Close()
		return rs, fmt.Errorf("p5 not Running: %s", st2.BackendState)
	}
	_ = srv3.Close()
	return rs, nil
}

// ============================================================================
// Peer path-upgrade mode (-peer)
// ============================================================================

// peerReport is the result of a single peer-upgrade run.
type peerReport struct {
	upSeconds      time.Duration // time to reach Running
	peerFound      bool          // did the host match a peer in /status?
	timeToDirect   time.Duration // 0 if it never went direct
	directFlips    int           // direct→derped transitions observed
	totalDirect    time.Duration // cumulative time spent direct
	longestDirect  time.Duration // longest single direct stretch
	stayedDirect10 bool          // longestDirect >= 10s
	directAtEnd    bool          // still direct at last sample
	trafficGets    int           // GET attempts
	trafficOK      int           // GETs that returned a response
	trafficErr     error         // first traffic error (non-fatal; refusals still send SYMs)
}

func runPeerMode(runs int, peerHost string, watch, traffic time.Duration, authKey string, verbose bool) {
	fmt.Printf("timing-go peer: %d runs, peer=%q, watch=%s, traffic=%s, key=%s…\n\n",
		runs, peerHost, watch, traffic, authKey[:14])
	fmt.Printf("run |   up | toDirect | flips | totalDirect | longestDirect | >=10s | direct@end | gets/ok | found\n")

	var reps []peerReport
	for i := 1; i <= runs; i++ {
		r, err := runPeerOnce(i, peerHost, watch, traffic, authKey, verbose)
		if err != nil {
			fmt.Fprintf(os.Stderr, "run %d FAILED: %v\n", i, err)
		}
		reps = append(reps, r)
		found := "no"
		if r.peerFound {
			found = "yes"
		}
		fmt.Printf("%3d | %4s | %8s | %5d | %11s | %13s | %5v | %10v | %7s | %s\n",
			i,
			durStr(r.upSeconds),
			durStr(r.timeToDirect),
			r.directFlips,
			durStr(r.totalDirect),
			durStr(r.longestDirect),
			r.stayedDirect10,
			r.directAtEnd,
			fmt.Sprintf("%d/%d", r.trafficOK, r.trafficGets),
			found)
		if r.trafficErr != nil {
			fmt.Printf("    traffic err (non-fatal): %v\n", r.trafficErr)
		}
	}

	// Summary over the runs that found the peer.
	var n int
	var sumToDirect time.Duration
	var directCount, stayed10, directAtEndCount int
	for _, r := range reps {
		if !r.peerFound {
			continue
		}
		n++
		if r.timeToDirect > 0 {
			sumToDirect += r.timeToDirect
			directCount++
		}
		if r.stayedDirect10 {
			stayed10++
		}
		if r.directAtEnd {
			directAtEndCount++
		}
	}
	fmt.Println("\nsummary (runs that found the peer):")
	if n == 0 {
		fmt.Printf("  n=0 — peer %q never matched in /status. See the peer dump above.\n", peerHost)
		fmt.Println("  (This itself is a clue: the app's host→peer matching may be the bug.)")
		return
	}
	if directCount > 0 {
		fmt.Printf("  reached direct:    %d/%d   avg time-to-direct=%s\n", directCount, n, durStr(sumToDirect/time.Duration(directCount)))
	} else {
		fmt.Printf("  reached direct:    0/%d   (never went direct)\n", n)
	}
	fmt.Printf("  stayed direct ≥10s: %d/%d\n", stayed10, n)
	fmt.Printf("  direct at end:      %d/%d\n", directAtEndCount, n)
}

// runPeerOnce starts a keyed ephemeral node, sends 1 GET/s to http://<peerHost>/
// for `traffic`, then goes idle, watching the peer's CurAddr/Relay via the
// local-API /status endpoint at 200ms intervals for `watch`. It classifies the
// path exactly as the app does (direct iff CurAddr != "") and records every
// direct↔derped transition with a timestamp.
func runPeerOnce(run int, peerHost string, watch, traffic time.Duration, authKey string, verbose bool) (rep peerReport, err error) {
	base := filepath.Join(os.TempDir(), fmt.Sprintf("timing-go-peer%d", run))
	logf := func(format string, a ...any) {
		if verbose {
			fmt.Fprintf(os.Stderr, "[tsnet r%d] "+format+"\n", append([]any{run}, a...)...)
		}
	}
	_ = os.RemoveAll(base)

	srv := &tsnet.Server{
		Hostname:   fmt.Sprintf("timing-go-peer-%d", run),
		Dir:        base,
		AuthKey:    authKey,
		ControlURL: defaultControlURL,
		Ephemeral:  true,
		Logf:       logf,
	}
	tStart := time.Now()
	st, err := srv.Up(context.Background())
	if err != nil {
		_ = srv.Close()
		return rep, fmt.Errorf("Up: %w", err)
	}
	if st.BackendState != "Running" {
		_ = srv.Close()
		return rep, fmt.Errorf("not Running: %s", st.BackendState)
	}
	rep.upSeconds = time.Since(tStart)
	fmt.Printf("  [r%d] up → Running in %s; starting traffic + path watch\n", run, durStr(rep.upSeconds))

	lc, err := srv.LocalClient()
	if err != nil {
		_ = srv.Close()
		return rep, fmt.Errorf("LocalClient: %w", err)
	}

	// Traffic generator: 1 GET/s to http://<peerHost>/ via the tailnet dialer,
	// for `traffic`, then stop (idle for the rest of `watch`). Even a refused
	// connection sends a SYN through the tailnet, which is enough to trigger
	// endpoint discovery / a direct-path upgrade.
	httpClient := srv.HTTPClient()
	httpClient.Timeout = 8 * time.Second
	trafficCtx, cancelTraffic := context.WithCancel(context.Background())
	go func() {
		ticker := time.NewTicker(1 * time.Second)
		defer ticker.Stop()
		// note: no initial sleep — fire a GET immediately so traffic starts at t=0
		first := true
		for {
			if !first {
				select {
				case <-trafficCtx.Done():
					return
				case <-ticker.C:
				}
			}
			first = false
			if trafficCtx.Err() != nil {
				return
			}
			rep.trafficGets++
			resp, gerr := httpClient.Get("http://" + peerHost + "/")
			if gerr == nil {
				rep.trafficOK++
				_, _ = io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
			} else if rep.trafficErr == nil {
				rep.trafficErr = gerr
			}
			if time.Since(tStart) >= traffic {
				cancelTraffic()
				return
			}
		}
	}()
	defer cancelTraffic()
	defer func() { _ = srv.Close() }()

	// Path watcher: poll /status every 200ms (the app polls every 5s; we poll
	// fast to catch quick direct→DERP flips the app's coarse poll would miss).
	const pollInterval = 200 * time.Millisecond
	deadline := tStart.Add(watch)

	var prevClass string // "", "direct", "derped"
	var directSince time.Time
	var firstDirectAt time.Time
	var dumpedPeers, dumpedDetail bool

	// Local-API HTTP endpoint (the path the Swift app's LocalAPIClient uses
	// to read /status). We fetch it each poll and compare the peer's CurAddr
	// against the in-process lc.Status() — a mismatch would mean the
	// local-API-over-loopback path returns stale status (an app-side bug).
	localAPIURL := ""
	localAPICred := ""
	if lbAddr, _, lbCred, lerr := srv.Loopback(); lerr == nil {
		localAPIURL = "http://" + lbAddr + "/localapi/v0/status"
		localAPICred = lbCred
	}

	for {
		now := time.Now()
		if now.After(deadline) {
			break
		}
		sts, serr := lc.Status(context.Background())
		if serr != nil {
			time.Sleep(pollInterval)
			continue
		}
		peer := findPeer(peerHost, sts)
		if peer == nil {
			if !dumpedPeers {
				// First time we couldn't find the peer, dump the peer list so
				// we can see why the app's matching might also be failing.
				dumpedPeers = true
				fmt.Printf("  [r%d] peer %q not found in /status; known peers:\n", run, peerHost)
				if sts.Self != nil {
					fmt.Printf("        self: HostName=%q DNSName=%q IPs=%v\n", sts.Self.HostName, sts.Self.DNSName, ipsStr(sts.Self.TailscaleIPs))
				}
				for _, p := range sts.Peer {
					fmt.Printf("        peer: HostName=%q DNSName=%q IPs=%v\n", p.HostName, p.DNSName, ipsStr(p.TailscaleIPs))
				}
			}
			time.Sleep(pollInterval)
			continue
		}
		rep.peerFound = true

		if !dumpedDetail {
			dumpedDetail = true
			selfAddrs := []string{}
			if sts.Self != nil {
				selfAddrs = sts.Self.Addrs
			}
			fmt.Printf("  [r%d] detail: self.Addrs=%v\n", run, selfAddrs)
			fmt.Printf("  [r%d] detail: peer.Addrs=%v peer.Online=%v\n", run, peer.Addrs, peer.Online)
		}

		// Compare in-process CurAddr with the local-API HTTP /status CurAddr.
		if localAPIURL != "" {
			if req, rerr := http.NewRequest("GET", localAPIURL, nil); rerr == nil {
				req.SetBasicAuth("tsnet", localAPICred)
				req.Header.Set("Sec-Tailscale", "localapi")
				if resp, herr := http.DefaultClient.Do(req); herr == nil {
					body, _ := io.ReadAll(resp.Body)
					resp.Body.Close()
					var ls ipnstate.Status
					if jerr := json.Unmarshal(body, &ls); jerr == nil {
						if lp := findPeer(peerHost, &ls); lp != nil {
							if lp.CurAddr != peer.CurAddr {
								fmt.Printf("  [r%d] MISMATCH: in-process CurAddr=%q vs localapi CurAddr=%q\n", run, peer.CurAddr, lp.CurAddr)
							}
						}
					}
				}
			}
		}

		class := "derped"
		curAddr := peer.CurAddr
		relay := peer.Relay
		if curAddr != "" {
			class = "direct"
		}

		if class != prevClass {
			t := time.Since(tStart)
			relStr := relay
			if relStr == "" {
				relStr = "-"
			}
			fmt.Printf("  [r%d] %8.2fs  → %-7s  (CurAddr=%q Relay=%q)\n", run, t.Seconds(), class, curAddr, relStr)
			if class == "direct" {
				if firstDirectAt.IsZero() {
					firstDirectAt = now
					rep.timeToDirect = t
				}
				directSince = now
			} else { // derped
				if !directSince.IsZero() {
					d := now.Sub(directSince)
					rep.totalDirect += d
					if d > rep.longestDirect {
						rep.longestDirect = d
					}
					rep.directFlips++
				}
				directSince = time.Time{}
			}
			prevClass = class
		}
		time.Sleep(pollInterval)
	}

	// Close out any direct stretch still open at the end of the window.
	if !directSince.IsZero() {
		d := time.Since(directSince)
		rep.totalDirect += d
		if d > rep.longestDirect {
			rep.longestDirect = d
		}
		rep.directAtEnd = true
	} else if prevClass == "derped" {
		rep.directAtEnd = false
	}
	rep.stayedDirect10 = rep.longestDirect >= 10*time.Second
	return rep, nil
}

// findPeer mirrors App/Browser/ConnectionType.swift's peerStatus(forHost:in:):
// match by HostName, DNSName (trailing-dot trimmed), first label of DNSName
// (the MagicDNS short name), or any TailscaleIP. Considers Self too.
func findPeer(host string, st *ipnstate.Status) *ipnstate.PeerStatus {
	lower := strings.ToLower(host)
	if st.Self != nil && matchPeer(st.Self, lower) {
		return st.Self
	}
	for _, p := range st.Peer {
		if matchPeer(p, lower) {
			return p
		}
	}
	return nil
}

func matchPeer(p *ipnstate.PeerStatus, lower string) bool {
	if strings.ToLower(p.HostName) == lower {
		return true
	}
	dns := strings.Trim(strings.ToLower(p.DNSName), ".")
	if dns == lower {
		return true
	}
	if label := strings.SplitN(dns, ".", 2)[0]; label == lower {
		return true
	}
	for _, ip := range p.TailscaleIPs {
		if strings.ToLower(ip.String()) == lower {
			return true
		}
	}
	return false
}

func ipsStr(ips []netip.Addr) string {
	if len(ips) == 0 {
		return "[]"
	}
	var b strings.Builder
	b.WriteByte('[')
	for i, ip := range ips {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(ip.String())
	}
	b.WriteByte(']')
	return b.String()
}
