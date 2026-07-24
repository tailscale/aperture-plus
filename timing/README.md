# tsnet lifecycle timing harnesses

Two text-mode harnesses that measure the cold-start latency of the core tsnet
lifecycle operations, so we can tell whether slowness is in **libtailscale /
tsnet** or in the **Swift app layer** on top. They follow the same 5-phase
cold-start cycle (fresh state dir per server, ephemeral keyed nodes) so their
numbers are directly comparable.

## The two harnesses

| harness | what it exercises | location |
| --- | --- | --- |
| **`go/`** | pure `tailscale.com/tsnet` + `local.Client` — the exact version pinned in `ThirdParty/libtailscale/go.mod`. Baseline: the library with nothing else. | `go/main.go` |
| **Swift** | the `TailscaleKit` wrapper the app actually uses (`TailscaleNode` + `LocalAPIClient` + `TSNetModel`/`TSNetConsumer` over the IPN bus), embedded in the app and gated by `-TimingHarness`. | `TimingHarness.swift` → `../App/TimingHarness.swift` |

### The 5 phases (each a cold start)

1. **Up/Start with NO auth key → first login URL** (`BrowseToURL`)
2. **tear down + restart → key Up/Start begins** (restart overhead incl. `Close()`)
3. **key Up/Start → `Running`** (truly connected)
4. **Logout → idle** (`NeedsLogin`/`Stopped`/`NoState`) — using the **app's real
   logout path**: `currentProfile` + `deleteProfile` (what the Settings Logout
   button actually calls), *not* `lc.Logout`
5. **second key Up/Start → `Running`** (a fresh node, mirroring an app relaunch
   on the same workspace with a key)

> Why the Swift harness calls `Start` (via `TailscaleNode.init`) and watches the
> bus instead of `node.up()`: `up()` calls Go's `Up(context.Background())`,
> which is **non-cancellable** and blocks the `TailscaleNode` actor until
> `Running`; `close()` is on the same actor and would queue behind it forever
> for a no-key node stuck at `NeedsLogin` (a real deadlock — see "Bugs found"
> below). `Start()`'s `doInit` already sets `WantRunning` + calls
> `StartLoginInteractive`, so the bus emits `NeedsLogin` + `BrowseToURL` (and
> later `Running` for a keyed node) on its own; `Up`'s only extra work is a
> redundant wait-for-`Running` bus watcher. So `Start→URL` ≈ `Up→URL`.

## Running

```sh
# Go (pure tsnet) — needs Go 1.26.3 and the libtailscale submodule initialized
# (go.sum is a symlink to ThirdParty/libtailscale/go.sum, so it tracks the
# app's pinned tailscale version automatically).
cd timing/go && go run . -runs 5
#   -authkey <key> | APERTURE_TEST_AUTHKEY env | ~/.aperture-ios-authkey

# Swift (TailscaleKit wrapper) — build the app for the sim, then launch it in
# harness mode; output goes to OSLog (subsystem io.tailscale.Aperture,
# category "timing"), captured by `log stream`.
xcodebuild build -project Aperture.xcodeproj -scheme Aperture \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/Aperture.app
xcrun simctl spawn booted log stream --predicate 'subsystem == "io.tailscale.Aperture"' &
xcrun simctl launch booted io.tailscale.Aperture -TimingHarness -TimingRuns 5 -AuthKey tskey-auth-...
# wait for the "timing-swift: DONE" line
```

## Results (5 runs each, captured 2026-07-24)

| phase | Go (pure tsnet) | Swift (TailscaleKit) | Swift overhead |
| --- | --- | --- | --- |
| **1: Up→login URL** | avg 3.88s (0.69–6.84s) | avg 6.54s (5.40–7.54s) | +~2.7s (bus bridging) |
| **2: URL→key Up begins** (restart) | avg 1ms | avg 32ms (29–39ms) | +31ms |
| **3: key Up→Running** | avg 1.25s (1.23–1.27s) | avg 1.42s (1.42–1.42s) | +170ms (~14%) |
| **4: Logout→idle** (`deleteProfile`) | avg 171ms (170–173ms) | avg 300ms (0.30–0.31s) | +130ms (~75%) |
| **5: 2nd key Up→Running** | avg 1.23s (1.15–1.26s) | avg 1.44s (1.42–1.52s) | +210ms (~17%) |

### What this says

**Nothing here takes "minutes."** Every core libtailscale operation — through
the Swift wrapper the app uses — completes in seconds or sub-seconds. The
wrapper adds a modest, consistent overhead (≈+130–210ms for the keyed phases,
+31ms for restart) but nothing close to minutes. **The slowness users see in
the app's login/logout is not in tsnet or the wrapper's up/logout path — it's
in the app-layer plumbing on top** (bus-watcher lifecycle, `StatusViewModel` /
`AuthManager` state handling, the `ASWebAuthenticationSession` round-trip).

The Swift harness's phase-1 floor of ~5.4s vs the Go harness's sub-1s best is
the bus-bridging lag: the OOP `ASWebAuthenticationSession`/accessibility layer
and the `@Published` model polling add latency the raw Go bus watcher doesn't.
That's UI-observation latency, not backend latency.

## Bugs found while building the harnesses

1. **`TailscaleNode.up()` blocks the actor → `close()` deadlocks.** `up()`
   calls Go's `Up(context.Background())` (non-cancellable) and blocks the
   `TailscaleNode` actor until `Running`. `close()` is on the same actor, so
   it queues behind `up()` and can never run. Closing a node that hasn't
   reached `Running` (e.g. backgrounding a fresh sim sitting at
   `NeedsLogin`) hangs forever. The app mostly dodges this because `up()`
   usually returns at `Running` before `close()` is needed — but it's a
   latent hang worth fixing (e.g. make `TsnetUp` take a cancellable context,
   or close via a non-actor path).

2. **The 60s `watch-ipn-bus` inactivity timeout.** The bus watcher's
   long-poll `URLSession` request times out (`NSURLErrorDomain -1001`) after
   ~60s of no data. `TSNetManager` restarts it on error, but each cycle is a
   ~60s window where state changes aren't observed. **This is the most
   likely source of the reported "minutes" of unresponsiveness:** if the UI
   is waiting on a bus-driven state flip (Login button enabling,
   logout→`NeedsLogin`), it can appear frozen for up to 60s per cycle, and
   "sometimes minutes" = a couple of cycles. The Go harness never sees this
   because its bus watcher is a raw HTTP stream with no inactivity timeout.

## Next

The library is exonerated — instrument the **app layer**: the
`watch-ipn-bus` timeout/restart behavior in `TSNetManager`, and the
`StatusViewModel`/`AuthManager` path around `showAuth`. See
`../TSNet/TSNetManager.swift` and `../App/Tailnet Status/StatusViewModel.swift`.
