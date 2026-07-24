// Command timing-go measures the cold latency of the core tsnet lifecycle
// operations against the real Tailscale control plane, using the SAME
// tailscale.com version the Aperture app embeds (pinned in go.mod):
//
//   1. Up() with NO auth key  → first login URL (BrowseToURL)
//   2. tear down + restart    → Up() with an auth key begins
//   3. Up() with auth key     → Running (truly connected)
//   4. Logout                 → idle (NeedsLogin / Stopped / NoState)
//   5. second Up() with key   → Running (a fresh node, mirroring an app
//                                 relaunch-on-the-same-workspace with a key)
//
// Each iteration uses a FRESH state dir per server so every measurement is a
// cold start (mirrors the UI tests' `-UITestResetLogin`). Keyed nodes are
// ephemeral so they auto-cleanup on Close. Run several times to see variance:
//
//	go run . -runs 5
//
// Auth key resolution: -authkey flag > APERTURE_TEST_AUTHKEY env >
// ~/.aperture-ios-authkey file (same order as the UI tests).
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

const defaultControlURL = "https://controlplane.tailscale.com"

func main() {
	runs := flag.Int("runs", 5, "number of iterations to run")
	authKeyFlag := flag.String("authkey", "", "auth key (overrides env/file)")
	verbose := flag.Bool("v", false, "print tsnet log lines to stderr")
	flag.Parse()

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

	fmt.Printf("timing-go: %d runs, control=%s, key=%s…\n\n", *runs, defaultControlURL, key[:14])
	fmt.Println("run | 1:Up→URL | 2:URL→KeyUp | 3:KeyUp→Running | 4:Logout→idle | 5:KeyUp2→Running")

	type r struct{ t1, t2, t3, t4, t5 time.Duration }
	var results []r

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
	for _, label := range []struct{ name string; get func(r) time.Duration }{
		{"1:Up→URL       ", func(x r) time.Duration { return x.t1 }},
		{"2:URL→KeyUp    ", func(x r) time.Duration { return x.t2 }},
		{"3:KeyUp→Running", func(x r) time.Duration { return x.t3 }},
		{"4:Logout→idle  ", func(x r) time.Duration { return x.t4 }},
		{"5:KeyUp2→Run   ", func(x r) time.Duration { return x.t5 }},
	} {
		var sum, n int; var mn, mx time.Duration; first := true
		for _, x := range results {
			v := label.get(x)
			if v <= 0 { continue }
			sum += int(v); n++
			if first || v < mn { mn = v }
			if first || v > mx { mx = v }
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

func durStr(d time.Duration) string {
	if d <= 0 {
		return "-"
	}
	if d < 100*time.Millisecond {
		return d.Round(time.Millisecond).String() // show ms for the fast phases
	}
	return d.Round(10 * time.Millisecond).String()
}

func runOnce(run int, authKey string, verbose bool) (rs struct{ t1, t2, t3, t4, t5 time.Duration }, err error) {
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
		cancelUp1(); _ = srv1.Close()
		return rs, fmt.Errorf("p1 LocalClient: %w", err)
	}
	w1, err := lc1.WatchIPNBus(context.Background(), ipn.NotifyInitialState)
	if err != nil {
		cancelUp1(); _ = srv1.Close()
		return rs, fmt.Errorf("p1 WatchIPNBus: %w", err)
	}
	gotURL := false
	for !gotURL {
		n, e := w1.Next()
		if e != nil {
			w1.Close(); cancelUp1(); _ = srv1.Close()
			return rs, fmt.Errorf("p1 watcher: %w", e)
		}
		if n.ErrMessage != nil {
			w1.Close(); cancelUp1(); _ = srv1.Close()
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
		w2.Close(); _ = srv2.Close()
		return rs, fmt.Errorf("p4 ProfileStatus: %w", err)
	}
	if err := lc2.DeleteProfile(context.Background(), cur.ID); err != nil {
		w2.Close(); _ = srv2.Close()
		return rs, fmt.Errorf("p4 DeleteProfile: %w", err)
	}
	// Watch until the backend settles into a non-running, non-starting state.
	idle := false
	for !idle {
		n, e := w2.Next()
		if e != nil {
			w2.Close(); _ = srv2.Close()
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
