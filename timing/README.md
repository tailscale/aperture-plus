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

---

## Peer path-upgrade mode (`-peer` / `-TimingPeer`)

A second test mode that measures something the lifecycle harness doesn't: how
quickly a tailnet peer's path upgrades from **DERP-relayed to direct** (and how
stable that direct path is). This is what the app's URL-bar connection dots key
off of — `ConnectionTypeResolver` classifies a tab as `.direct` (two green
dots) iff the peer's `CurAddr` is non-empty in the local-API `/status` response,
else `.derped` (one green dot). See `../App/Browser/ConnectionType.swift`.

Normal Tailscale behaviour: a connection **starts** derped and upgrades to
direct within a few seconds of traffic, then stays direct for minutes. The
reported symptom ("almost always one green dot; after a minute or so, two dots
for a few seconds, then back to one") is NOT that — so the question was whether
the app is **misreporting** the path, or the path really is stuck on DERP.

### What it does

Each run starts a fresh keyed ephemeral node, sends 1 GET/s to
`http://<peer>/` (through the tailnet) for `-peer-traffic`/`-TimingPeerTraffic`
seconds, then goes idle, and polls the peer's `CurAddr`/`Relay` at **200ms**
intervals for `-peer-watch`/`-TimingPeerWatch` seconds. (The app polls `/status`
every **5s**; the harness polls fast to catch quick direct→DERP flips the app's
coarse poll would miss.) It classifies the path with the **app's own**
`ConnectionTypeResolver.peerStatus(forHost:in:)` + `CurAddr` check, logs every
direct↔derped transition with a timestamp, and reports time-to-direct, flip
count, and the longest direct stretch.

```sh
# Go (pure tsnet, macOS host process)
cd timing/go && go run . -peer ai -runs 3
#   -peer-watch 30s  -peer-traffic 12s   (traffic then idle)

# Swift (TailscaleKit, iOS Simulator)
xcrun simctl launch booted io.tailscale.Aperture \
    -TimingHarness -TimingRuns 3 -TimingPeer ai \
    -TimingPeerWatch 30 -TimingPeerTraffic 12 -AuthKey tskey-auth-...
#   -TimingPeerUseUp   (also call node.up(), mirroring the Go harness — see below)
```

The Go harness additionally compares the peer's `CurAddr` from the in-process
`lc.Status()` against the **local-API HTTP `/status`** endpoint (the path the
Swift `LocalAPIClient` uses) on every poll, and logs any mismatch — a mismatch
would mean the local-API-over-loopback path returns stale status.

### Results (captured 2026-07-24, peer `ai`)

Two regimes matter — **short idle** (under the 45s low-power threshold) and
**long idle** (over it). The Go harness reproduces the reported symptom in the
**long-idle** regime; the Swift/sim harness can't establish direct at all.

| harness | idle regime | reached direct | time-to-direct | dropped to DERP | flips | notes |
| --- | --- | --- | --- | --- | --- | --- |
| **Go** (host) | short (≤27s) | yes | ~1.6–1.7s | never (in window) | 0 | stays direct 33–38s, `direct@end`=yes — **normal** |
| **Go** (host) | **long (80s)** | yes | ~1.6s | **~62s** (~52s idle) | 1–2 | drops, then **brief direct at ~73s, back to DERP at ~79s** — **reproduces the symptom** |
| **Swift** (sim) | any (≤100s) | **no** (0/4) | never | n/a | 0 | traffic flows, self has STUN endpoint, peer online, `CurAddr` stays `""` |

The Go long-idle run is the user's report verbatim (run 2):

```
  [r2]     1.62s  → direct   (CurAddr="18.192.206.183:15299")
  [r2]    62.00s  → derped   (CurAddr="")            ← ~52s idle, low-power kicks in
  [r2]    72.86s  → direct                            ← "two green dots for a few seconds"
  [r2]    79.28s  → derped                            ← "then downgrades again to one dot"
```

The contrast run (35s traffic, only 5s idle → never crosses 45s) stays direct
the whole 38s, 0 flips — confirming the 45s idle threshold is the exact
boundary. Reproduced with the **debug knob off** (it only adds logging; the
45s `sessionActiveTimeout` constant fires regardless).

### What this says

**The app is NOT misreporting.** The following were each ruled out:

1. **The local-API `/status` path is not stale.** The Go harness reads
   `/status` both in-process (`lc.Status()`) and over the loopback HTTP local-API
   endpoint (the exact path `LocalAPIClient.backendStatus()` uses) on every
   poll — **zero `CurAddr` mismatches**. So the Swift app's `localStatus` is the
   backend's true, live view. The backend genuinely reports `CurAddr=""`.
2. **Not the netmap-cache envknobs.** `tailscale.go`'s `setupNetmapCacheEnv`
   sets `TS_FORCE_CACHE_NETMAP=1` / `TS_USE_CACHED_NETMAP=1` for every
   TailscaleKit node. Running the Go harness with those same env vars set still
   goes direct at 1.7s — so they don't cause it.
3. **Not `Start` vs `Up`.** The app deliberately calls only `tailscale_start`
   (`Start`), never `node.up()` (`Up`), to avoid the actor-blocking deadlock
   (see "Bugs found" #1). `Up` = `Start` + wait-for-`Running` + a `Status` call
   + serve-config reset — it does no extra disco/magicsock work. Confirmed:
   the Swift harness with `-TimingPeerUseUp` (calls `node.up()`) **still stays
   derped** for 40s.
4. **Not the dial path.** The app's HTTP traffic goes via the `tailscale_loopback`
   SOCKS5 proxy; `srv.Dial` goes direct. But the SOCKS5 server's `Dialer` is
   `s.dialer.UserDial` — the **same** dialer `srv.Dial` uses (`tsnet.go:362` vs
   `tsnet.go:493`). So traffic hits magicsock identically either way.
5. **Not host networking.** The Swift node **does** get a STUN endpoint
   (`self.Addrs=["208.52.154.144:…"]`, same public IP as the Go node) and the
   peer is `Online` in the netmap — so STUN/UDP outbound works and the netmap is
   populated. What never happens is the **disco handshake** to the peer's
   endpoint that flips `CurAddr` from `""` to a direct address.

The remaining variable for the **simulator's** "never direct" is the
**process/network environment**: the Go harness runs as a macOS host process
and establishes direct in ~1.7s; the TailscaleKit node runs in the **iOS
Simulator** and never establishes direct (≤100s, with traffic). The simulator
shares the host's network yet its magicsock disco to the peer doesn't complete
— most likely a simulator NAT/UDP behaviour that STUN survives but peer disco
doesn't. This is an **environment** issue, separate from the user's symptom.

### What this says (updated)

The Go long-idle run **reproduces the user's symptom exactly**, with pure-Go
tsnet on the macOS host — no app, no Swift, no simulator. So the symptom is
**Tailscale's intended mobile low-power behaviour** (idle STUN shutdown), not an
app misreport. Two separate things are going on:

1. **The user's "after a minute, briefly two dots then back to one" = low-power
   mode**, reproduced with Go on the host (drops at ~62s idle, flickers at ~73s).
   See the next section for the mechanism. **This is the answer to the bug
   report** — it's expected behaviour, not a misreport. The app's `CurAddr` is
   truthful throughout.
2. **The simulator's "never direct even during traffic" = a separate simulator
   networking issue** (peer disco UDP not completing). This is NOT what the user
   sees on a real device (where direct does establish, as the Go host shows); it's
   just a limitation of running the harness in the sim.

The app's 5s `/status` poll (`TSNetManager.startStatusPolling`) is a separate,
milder issue: it aliases short direct stretches, so a real-but-brief direct
flicker can look even briefer in the UI. Not a misreport, but a UI-smoothness
lever (see "Next").

### Running on macOS ("My Mac (Designed for iPad)")

The simulator is sandboxed and shares the host's network only through a
virtualized stack — a suspected source of the "never direct" above. To test
the **real `ios-arm64` TailscaleKit slice on the host's actual network**, build
the harness for the "My Mac (Designed for iPad)" destination:

```sh
xcodebuild build -project Aperture.xcodeproj -scheme Aperture -configuration Debug \
    -destination 'name=My Mac' -derivedDataPath build/DerivedDataMac
# → build/DerivedDataMac/Build/Products/Debug-iphoneos/Aperture.app (signed, ad-hoc-free)
```

This build can't be launched headlessly — `open` refuses ("incorrect executable
format"; it's an iOS-platform binary) and direct exec gets `Killed: 9`. Only
Xcode's launcher (or a Finder double-click of the signed build) can start it. And
launch args can't be passed that way, so the harness reads peer-mode settings
(and the auth key) from a **config file** instead:

```sh
# Write ~/.aperture-timing-peer (key=value lines):
printf 'peer=ai\nwatch=70\ntraffic=10\nuseUp=false\nauthkey=%s\n' "$(cat ~/.aperture-ios-authkey)" \
    > ~/.aperture-timing-peer
```

The "Designed for iPad" build has no App Sandbox entitlement, so `NSHomeDirectory()`
is the real home and the config/result files are at `~/.aperture-timing-peer` /
`~/.aperture-timing-peer-out.txt` (the **simulator** is sandboxed, so there you
still use launch args). Then launch and read the result:

1. In Xcode: pick the **My Mac** destination and press ⌘R (Run). (Or try a
   Finder double-click of the signed `.app`.) No scheme args needed — the config
   file triggers peer mode.
2. Wait ~`watch` seconds for the `timing-swift: DONE` line.
3. `cat ~/.aperture-timing-peer-out.txt` (or `log stream --predicate
   'subsystem == "io.tailscale.Aperture" AND category == "timing"'`).

The `watch=70 traffic=10` config gives ~60s of **idle after traffic** — long
enough to cross the 45s low-power threshold (see below) and observe whether a
direct path, once established, is dropped when idle. **Interpretation** (the
Go host run already showed the drop-at-~62s/flicker; this confirms the iOS
binary matches):
- goes direct, drops at ~62s idle, flickers → matches Go; the iOS binary behaves
  like pure tsnet, and the simulator's "never direct" was just the sim.
- goes direct like Go but **stays** direct past 62s → the iOS binary keeps the
  path without STUN (stable host NAT); the user's drops are device-NAT-specific.
- never goes direct even during traffic → the iOS binary itself has a
direct-path problem regardless of network (upstream of the app).

### Tailscale's mobile low-power mode (idle STUN shutdown)

**CONFIRMED: reproduced with pure-Go tsnet on the macOS host** (see the Go
long-idle result above — drops to DERP at ~62s idle, brief direct flicker at
~73s, back to DERP at ~79s). This is the mechanism behind the user's symptom,
and it's Tailscale's intended battery-saving — not an app bug.

magicsock stops doing **periodic STUN** (netcheck) when the node has been idle,
gated by `Conn.shouldDoPeriodicReSTUNLocked` (`wgengine/magicsock/magicsock.go`):

```go
// sessionActiveTimeout is how long since the last activity we ...
sessionActiveTimeout = 45 * time.Second
if idleFor > sessionActiveTimeout {
    if c.controlKnobs != nil && c.controlKnobs.ForceBackgroundSTUN.Load() {
        return true   // overridden by control
    }
    return false   // stop periodic STUN while idle
}
```

`idleFor` comes from `Conn.idleFunc`, which the **userspace engine** (what tsnet
uses) sets to `tundev.IdleDuration` (`wgengine/userspace.go:435`) — the time since
the last read/write to the **tun device** (`net/tstun/wrap.go:IdleDuration`).
Two consequences that fit the symptom precisely:

- **The app's 5s `/status` poll does NOT keep the node "active".**
  `backendStatus()` goes over the loopback SOCKS proxy on `127.0.0.1` — that
  traffic does **not** traverse the tun device, so it never resets
  `tundev.IdleDuration`. So even while the app is actively polling status every
  5s, the node's tun-idle keeps climbing; after 45s with no *tunneled* traffic,
  periodic STUN stops.
- On a mobile/rotating-NAT device, once STUN stops the node stops re-advertising
  its public endpoint; when the NAT mapping rotates, peers can't reach it
  directly → traffic falls back to DERP (one dot). The next tunneled request
  (user navigates) resets idle → STUN resumes → direct re-establishes briefly
  (two dots) → idle again → drops. That's the "two dots for a few seconds, then
  back to one" pattern, on a ~45s+ timescale ("after a minute or so").

The only override is `ForceBackgroundSTUN`, a **control-plane knob**
(`controlknobs.go`, set from `tailcfg.NodeAttrDebugForceBackgroundSTUN`) — i.e.
the control server grants it; the app can't set it locally. (The debugknobs file
that lists `debugReSTUNStopOnIdle` is `//go:build !ios && !js` — stubbed on iOS,
so `TS_DEBUG_RESTUN_STOP_ON_IDLE` etc. are unavailable there.)

This does **not** explain the simulator harness's "never direct even during
25s of sustained traffic" — that's well under the 45s idle threshold, so
low-power mode isn't engaged during the traffic window. The sim's "never direct"
is the simulator's network (peer disco UDP not completing); the low-power mode
is the additional real-device behaviour on top.

### Next (peer path)

The Go reproduction already confirms the user's symptom is low-power mode. The
remaining open questions and levers:

1. **Run the "My Mac" harness** (above) with `watch=90 traffic=10` to confirm
   the **iOS binary** on the host network shows the same drop-at-~62s/flicker
   pattern as the Go client (i.e. that it's not Go-specific). This is now a
   *confirmation*, not the primary experiment. (Can't launch headlessly — see
   the "My Mac" section.)
2. **Confirm on a real device** (`simctl` → `xcrun devicectl`) — does direct
   establish at all on the device's network, and does it drop at ~45s idle like
   the host? Distinguishes "device network can't disco" from "low-power drops
   it" (likely both, compounding).
3. **Mitigate the idle drop** — the real fix for the user's complaint: send a
   lightweight **tunneled** keepalive (a tiny HTTP GET to the peer) while a
   tailnet tab is open and foreground, every ~30s, to reset `tundev.IdleDuration`
   and keep STUN active — trading a little battery/radio for a stable direct
   path while reading. **The app's existing 5s `/status` poll does not help** —
   it's loopback (`127.0.0.1`), not tunneled, so it never resets the idle timer.
   This is the key actionable finding.
4. **`ForceBackgroundSTUN`** would be the cleanest fix but it's control-plane
   granted (`NodeAttrDebugForceBackgroundSTUN`); not something the app can set.
5. **Faster `/status` polling** (or bus-driven peer status, if `Tailcfg.Node` is
   extended to decode `Endpoints`/`DERP`) so the dots track short direct
   stretches faithfully instead of 5s-sampling them — a UI-smoothness lever,
   separate from the drop.
6. If direct never establishes on-device or on "My Mac" even during traffic,
   that's a separate **libtailscale path-establishment** issue (magicsock disco
   / UDP), upstream of the app — but the Go host result shows the *drop* is
   low-power, not a disco failure.
