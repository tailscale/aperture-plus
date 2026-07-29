// Command register is a deliberately tiny extraction of tsnet's interactive
// auth-URL path. It constructs only a controlclient.Direct and calls TryLogin;
// there is no LocalBackend, wgengine, netstack, magicsock, LocalAPI, IPN bus,
// status machine, disk state, or Swift code.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"slices"
	"time"

	"tailscale.com/control/controlclient"
	"tailscale.com/health"
	"tailscale.com/net/netmon"
	"tailscale.com/net/tsdial"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"tailscale.com/util/eventbus"
)

const controlURL = "https://controlplane.tailscale.com"

type result struct {
	total  time.Duration
	gotURL bool
}

func main() {
	runs := flag.Int("runs", 10, "number of fresh register requests")
	timeout := flag.Duration("timeout", 90*time.Second, "per-request timeout")
	verbose := flag.Bool("v", false, "print controlclient logs")
	flag.Parse()

	fmt.Printf("bare-register: %d runs, control=%s\n", *runs, controlURL)
	fmt.Println("run | Direct.TryLogin→AuthURL")
	results := make([]result, 0, *runs)
	for i := 1; i <= *runs; i++ {
		r, err := runOnce(i, *timeout, *verbose)
		if err != nil {
			log.Printf("run %d FAILED: %v", i, err)
		}
		results = append(results, r)
		fmt.Printf("%3d | %s\n", i, format(r.total))
	}
	values := make([]time.Duration, 0, len(results))
	for _, r := range results {
		if r.gotURL {
			values = append(values, r.total)
		}
	}
	if len(values) == 0 {
		return
	}
	slices.Sort(values)
	var sum time.Duration
	for _, v := range values {
		sum += v
	}
	fmt.Printf("summary: n=%d avg=%s p50=%s p90=%s min=%s max=%s\n",
		len(values), format(sum/time.Duration(len(values))),
		format(values[(len(values)-1)/2]), format(values[(len(values)-1)*9/10]),
		format(values[0]), format(values[len(values)-1]))
}

func runOnce(run int, timeout time.Duration, verbose bool) (result, error) {
	bus := eventbus.New()
	defer bus.Close()
	mon := netmon.NewStatic()
	dialer := tsdial.NewDialer(mon)
	dialer.SetBus(bus)
	machineKey := key.NewMachine()
	logf := func(format string, args ...any) {
		if verbose {
			log.Printf("[r%d] "+format, append([]any{run}, args...)...)
		}
	}
	direct, err := controlclient.NewDirect(controlclient.Options{
		ServerURL:            controlURL,
		GetMachinePrivateKey: func() (key.MachinePrivate, error) { return machineKey, nil },
		Hostinfo: &tailcfg.Hostinfo{
			BackendLogID: fmt.Sprintf("bare-register-%d", run),
			Hostname:     fmt.Sprintf("bare-register-%d", run),
			Package:      "bare-register-benchmark",
		},
		Logf:              logf,
		Dialer:            dialer,
		Bus:               bus,
		HealthTracker:     health.NewTracker(bus),
		SkipStartForTests: true,
	})
	if err != nil {
		return result{}, err
	}
	defer direct.Close()

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	start := time.Now()
	url, err := direct.TryLogin(ctx, controlclient.LoginInteractive)
	elapsed := time.Since(start)
	if err != nil {
		return result{total: elapsed}, err
	}
	if url == "" {
		return result{total: elapsed}, fmt.Errorf("empty AuthURL")
	}
	return result{total: elapsed, gotURL: true}, nil
}

func format(d time.Duration) string {
	if d < time.Second {
		return d.Round(time.Millisecond).String()
	}
	return fmt.Sprintf("%.2fs", d.Seconds())
}
