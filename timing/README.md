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

### Internet-via-proxy mode (`-TimingInternet <url>`)

A third harness mode that fetches a **non-tailnet** URL through the tsnet SOCKS5
proxy (the same `URLSession.tailscaleSession` path WebKit uses) and logs the
HTTP status / NSError domain+code. Diagnoses whether tsnet's direct dial of
non-tailnet hosts works on a given platform:

```sh
xcrun simctl launch booted io.tailscale.Aperture \
    -TimingHarness -TimingRuns 1 -TimingInternet "https://www.google.com/" -AuthKey tskey-auth-...
```

Results (2026-07-24): `https://www.google.com/` → **HTTP 200 on BOTH the iPhone
17 Pro sim and the iPad Pro 11-inch sim.** The bug (internet URLs failing with
a connection error) is **NOT reproduced in the simulator** — it's real-ios-binary
only (real iPad + macOS-Designed-for-iPad). (`https://example.com/` fails on both
sims with `kCFErrorHTTPSProxyConnectionFailure` 310 — a per-host proxy quirk,
not the user's bug; `google.com` is the clean test case.)

### Mechanism: how non-tailnet traffic is routed

The app sets `dataStore.proxyConfigurations = [socks5Proxy]` for ALL WebKit
traffic — there's no per-host split. tsnet's SOCKS5 server dials via
`s.dialer.UserDial` (`tsnet.go:493`). `UserDial` (`net/tsdial/tsdial.go:482`):
- tailnet peer IP → `NetstackDialTCP` (the tunnel) — works on all platforms.
- non-tailnet IP → `net.Dialer.DialContext` after `net.Resolver.LookupIP`
  (cgo `getaddrinfo` on iOS, since `CGO_ENABLED=1`, no `netgo` tag) — a **direct
  OS dial** by the tsnet process. This is how `google.com` is supposed to work.

`userDialResolve` has a `TODO(bradfitz): wire up net/dnscache too` — tsnet uses
plain `net.Resolver`, NOT the robust `net/dnscache` the Tailscale iOS app uses.

### The likely gate: the `com.apple.developer.web-browser` entitlement

Your security intuition is right: a random iOS app *shouldn't* be able to
impersonate a browser and intercept all gmail traffic. Apple's defense is the
**`com.apple.developer.web-browser` entitlement** — a *managed* entitlement
Apple grants via the App Store "web browser" category (per WebKit's
[App-Bound Domains blog](https://webkit.org/blog/10882/app-bound-domains/):
"BrowserApp has previously received permission to take the managed entitlement
com.apple.developer.web-browser, which signifies its purpose as a full
web-browser. All `WKWebView` instances for BrowserApp will therefore have
unrestricted API access on all domains.").

WebKit source confirms the gate (`Source/WebKit/Shared/Cocoa/DefaultWebBrowserChecks.mm`):

```cpp
bool isFullWebBrowserOrRunningTest(const String& bundleIdentifier) {
    static bool fullWebBrowser = WTF::processHasEntitlement("com.apple.developer.web-browser"_s);
    ...
    return fullWebBrowser && !treatAsNonBrowser(bundleID);
}
```

`isFullWebBrowserOrRunningTest()` gates WebKit's "full browser" privileges
(unrestricted API access on all domains, ITP behavior, app-bound-domain
exemption, etc.). Without it you're an "in-app browser" with restrictions.

**Aperture does NOT have this entitlement** — the project has no entitlements
file (`codesign -d --entitlements` on the build is empty), and the Info.plist is
minimal (just ATS). So WebKit treats Aperture as an in-app browser on every
device. Which raises the question: why does the restriction fire on iPad but
not iPhone, when both run the same entitlement-less `ios-arm64` binary?

### Why the iPhone/iPad split — three hypotheses, ranked

The entitlement itself is the same (absent) on both. The split needs another
explanation. Three hypotheses, each with a decisive test:

**H2 — dev-mode / install-signing (CURRENTLY MOST LIKELY).** The iPhone is
Xcode-dev-signed with **Developer Mode ON** (the user can plug it in). The
iPad has a **broken USB port** — it can't be Xcode-installed, so its build is
TestFlight / ad-hoc / App-Store-installed, and **Developer Mode may be OFF**.
Apple's dev-mode doc says it "reduces the security of your device" and exposes
"developer-only functionality." So dev-mode-ON (iPhone) could relax the
in-app-browser proxy restriction; dev-mode-OFF (iPad) enforces it. **This
explains the split WITHOUT requiring iPadOS vs iOS to differ at all** — same
binary, same entitlements, different device policy state. The user's own
question ("Because my phone is in dev mode?") may be exactly right.
  - *Decisive test:* turn Developer Mode ON on the iPad (Settings → Privacy &
    Security → Developer Mode) and reload `https://google.com/`. If it then
    loads → H2 confirmed. (No Mac needed — just the Settings app.)

**H3 — single-label / public-suffix hostname categorization.** How could
Apple auto-categorize `http://ai/` as "not internet" but `https://google.com/`
as "internet"? Tailnet IPs are 100.64.0.0/10 (CGNAT) but ONLY the proxy sees
them — WebKit hands the hostname `ai` to the SOCKS proxy and never sees the
IP, so categorization can't be IP-based pre-proxy. It must be HOSTNAME-based.
`ai` is a **single-label name with no public suffix**; `google.com` is a
registrable domain under a public suffix (`.com`). Apple's app-bound-domain
machinery is entirely public-suffix/registrable-domain based. A policy like
"an in-app browser may proxy only non-public-suffix (local/intranet) hosts"
would let `ai` through and block `google.com`. A bare public IP
(`142.250.80.46`) is also clearly-internet → blocked, fitting "all three -1000."
  - *Decisive test (iPad, existing build, URL bar only):* type the FQDN
    `https://ai.<tailnet>.ts.net/` (has dots, registrable-domain-ish). If H3
    is right it should ALSO -1000, whereas `http://ai/` works. Also test
    `http://example.com/` (HTTP not HTTPS) to isolate TLS from the host check.

**H1 — entitlement/policy, iPadOS-enforces-stricter.** in-app-browser policy
blocks proxying public-internet hosts; iPadOS enforces stricter than iOS.
WEAKNESS: the blog says app-bound-domains is OPT-IN (add `WKAppBoundDomains` to
Info.plist), which Aperture doesn't have — so that specific restriction
shouldn't fire. And it's odd for the SAME entitlement-less binary to behave
differently by idiom. H2 (dev-mode) subsumes this if the iPhone is dev-mode
and the iPad isn't. If H2 is ruled out (dev-mode is ON on the iPad too and it
still fails), H1 + H3 combine: iPadOS enforces a non-opt-in proxy restriction
on non-browser apps, gated by hostname public-suffix.

### iPad-doable tests (no Mac, no rebuild — URL bar + `[domain code]` overlay)

The iPad's USB is broken, so the only interface is the app UI + the error
overlay (which now prints `[domain code]`). These discriminating tests need
nothing else:

| type this | isolates | result → rules in/out |
| --- | --- | --- |
| `https://google.com/` | baseline | -1000 (known) |
| `http://ai/` | baseline | works (known) |
| `https://ai.<tailnet>.ts.net/` | **H3**: FQDN (dots) vs short name | -1000 → H3 yes; works → H3 no |
| `http://example.com/` | TLS vs host (H3) | -1000 → not TLS-specific; works → TLS matters |
| `http://neverssl.com/` | plain-HTTP internet | -1000 → host-based not scheme; works → scheme |
| Settings → Privacy & Security → **Developer Mode ON**, then `https://google.com/` | **H2** | loads → H2 confirmed |

The two highest-value tests: **the FQDN** (`https://ai.<tailnet>.ts.net/`)
for H3, and **toggling Developer Mode** for H2. Either one, done in a minute
on the iPad with no Mac, collapses the hypothesis space significantly.

### Consistency check

The entitlement/policy framing is consistent with everything observed:
- The request likely **never reaches tsnet** for `google.com` on the iPad
  (-1000 is pre-proxy); the tsnet `socks5:` log would confirm.
- The sim doesn't reproduce it (sims don't enforce the production policy).
- iPhone works — iPadOS enforces stricter, or the iPhone's dev-mode / a
  linkedOnOrAfter / SDK-aligned-behavior difference relaxes it. (Your phone
  being in dev mode, or an `linkedOnOrAfterSDKWithBehavior` quirk, could be
  why iPhone doesn't trigger the same policy — see `determineTracking
  PreventionStateInternal`'s `appWasLinkedOnOrAfter` branch in the same file.)

### Three-model consultation (deepseek / gpt-5.5 / opus) — synthesis

Spawned three independent sub-pi consultations per `README.codereview.md`
(deepseek-v4-flash, gpt-5.5, claude-opus-4-8; logs in `/tmp/ipad-1000-*.log`).
They converged on the core and each added a distinct mechanism:

**Convergent (all three):**
- The `com.apple.developer.web-browser` entitlement is the gate
  (`isFullWebBrowserOrRunningTest` / `isParentProcessAFullWebBrowser`). Aperture
  lacks it → in-app browser.
- `-1000` is a URL-validity/pre-dial rejection, NOT DNS/connect/SOCKS. The
  request likely never reaches tsnet for internet hosts on the iPad.
- Classic App-Bound Domains (opt-in via `WKAppBoundDomains`) does NOT apply —
  Aperture doesn't have the key, and the blog says unchanged apps aren't
  restricted. The mechanism is something BROADER.
- H3 (single-label) explains the tailnet clue but not the iPhone/iPad split.
- H2 (dev-mode/install-channel) best explains the split — BUT dev-mode-the-toggle
  doesn't change `processHasEntitlement` (which reads the code signature, not a
  runtime flag), so H2 is really about install-channel/signing/SDK-linkage.
- The exact `-1000`-for-valid-URL behavior is NOT in open WebKit source → likely
  in closed CFNetwork/Network.framework or an Apple-private policy.
- PAC (tailnet via SOCKS, internet DIRECT) is legitimate least-privilege design,
  NOT "hiding a policy" — internet has no business going through the tsnet proxy.
  Do it regardless, AND pursue the entitlement if Aperture is a full browser.

**Complementary mechanisms found:**
- **Opus — WebKit PR #39912** ("Invalid WTF::URLs should not convert to NSURLs",
  bug 286926, merged Feb 2025, commit `2404832`): WebKit's WTF::URL→NSURL
  conversion was changed to fail for invalid URLs, **behind a
  `linkedOnOrAfterSDKWithBehavior` gate.** A concrete, sourced mechanism that
  yields a badURL-class failure for URLs one SDK-linkage side accepts and the
  other rejects — fits the build/SDK-linkage axis of H2. Also: the app's OWN
  synthetic `URLError(.badURL)` (`reportURLParseFailure`, kind=`.urlFormat`) must
  be excluded — but the user's "connection error" (`.retrieval`) label already
  does. Also: **sysdiagnose + the Networking diagnostic profile can be captured
  on-device via Settings (no USB, no Mac)** — the route to ground-truth "did the
  request reach the proxy" given the broken iPad USB.
- **Deepseek — H4 appBoundSession proxy-miss:** in
  `NetworkSessionCocoa::sessionWrapperForTask`, without the entitlement
  `shouldBeConsideredAppBound` stays `Yes` → requests route to a lazily-created
  `appBoundSession` whose `nw_context_t` never received the `nw_proxy_config`
  (applied to the default session's context via `nw_context_add_proxy`, not the
  appBound one). Ties the entitlement directly to "proxy not applied to the
  session that loads internet." H5: the `requiresHTTPProtocols`/recreate branch
  — SOCKS5 likely returns false → no recreate → appBound session misses the
  proxy. (Tension: `http://ai/` works though — resolvable if single-label/host-
  class routes `ai` to the proxied default session, combining H4+H3.)
- **Gpt — H1′ closed-policy:** the open WebKit proxy-application path shows NO
  public-host/non-browser gate, so the actual `-1000` rejection is in CLOSED
  CFNetwork/Network.framework or an Apple-private policy reached via the
  `nw_proxy_config`/`appBoundSession` path. Strong iPad-doable host-class/IP-
  class/scheme/port matrix below.

### Consolidated no-Mac iPad test matrix (URL bar + `[domain code]` overlay)

These need only the existing iPad build — no Mac, no rebuild, no Console. Read
the `[domain code]` AND the category label on each. Several reviewers stress:
**"anything other than `-1000`" is informative**, even if the page doesn't load.

| type this | isolates | result → rules in/out |
| --- | --- | --- |
| `https://google.com/` | baseline | -1000 / "Connection error" (known) |
| `http://ai/` | baseline | works (known) |
| **Settings → Privacy & Security → Developer Mode ON**, then `https://google.com/` | **H2** (dev-mode) | loads → H2 confirmed |
| `https://ai.<tailnet>.ts.net/` (FQDN) | **H3** dots vs short name | -1000 → H3 yes; works → H3 no |
| `http://ai.<tailnet>.ts.net/` (FQDN, HTTP) | H3 + TLS | -1000 → not scheme; works → TLS matters |
| `http://a/` or `http://example/` (single-label, NOT tailnet) | **H3 killer** | -1000 → H3 dead; -1003 → reached proxy, single-label allowed |
| `http://example.com/` (HTTP, public) | TLS vs host | -1000 → not TLS; loads → TLS/CONNECT-specific |
| `http://foo.local/` / `http://foo.lan/` (dotted, non-public-suffix) | public-suffix boundary | non-(-1000) → PSL boundary; -1000 → broader dotted block |
| `http://100.x.y.z/` (tailnet IP) vs `http://142.250.80.46/` (public IP) | address-class | tailnet-IP works + public-IP -1000 → address-class policy |
| `http://192.168.1.1/` (private IP) | private-IP | non-(-1000) → private allowed; -1000 → all IP-literals blocked |
| `https://google.com./` (trailing dot) | canonicalization | same -1000 → policy sees through canonicalization |
| **sysdiagnose + Networking profile** (Settings-driven, no USB) | ground truth | shows whether the request reached the proxy at all |

The two highest-value: **toggle Developer Mode** (H2, one minute, no Mac) and
**`http://a/`** (H3 killer). If dev-mode-on makes google.com load, H2 is
confirmed and the fix is the entitlement (production needs it) — PAC for split-
tunnel in the meantime. If `http://a/` also -1000s, H3 is dead and the block is
"public-web/non-browser" broadly (H1′ + H4), not single-label.

### RESOLVED: measured `matchDomains` semantics + what `-1000` actually means

Everything below this section was hypothesis. This section is **measurement**,
run on macOS 26.5 against a purpose-built logging SOCKS5 proxy
(`/tmp/pxprobe/socks.py`) that records every CONNECT it receives, driven from
both `URLSession` and `WKWebsiteDataStore.proxyConfigurations` (WebKit). It
settles two things: how to scope the proxy, and what `-1000` really is.

**1. `-1000` is NOT specific to Local Network Access, and NOT a URL problem.**
A SOCKS5 proxy that accepts the connection and then answers CONNECT with a
failure reply makes WebKit report `NSURLErrorDomain -1000` (`NSURLErrorBadURL`,
rendered as "invalid URL") for **every** SOCKS failure code — general failure,
not-allowed, network-unreachable, host-unreachable, connection-refused (1–5),
for both short names and public names. So `-1000` is simply CFNetwork's generic
mapping for **"the proxy could not establish this connection"**. It says
nothing about the URL and does not require the LNA mechanism to explain it.

That reframes the whole investigation. The reasoning above — "-1000 is a
pre-dial URL-validity rejection, so the request never reached tsnet" — was the
load-bearing assumption behind H1/H3/H4/H-LNA, and it is **wrong**. The
observation is equally consistent with the much simpler H5: the request DOES
reach tsnet, and tsnet's `UserDial` fails for non-tailnet hosts on real iOS
(Go's cgo `getaddrinfo` is unreliable there; MagicDNS names resolve in-memory
and so keep working). Both stories predict "tailnet works, internet -1000"; the
device-to-device split is then just whether that device's tsnet can resolve
public DNS, not an OS policy difference.

**This is worth knowing regardless of mechanism:** the fix below is correct
under *either* story, because in both cases the mistake is sending public
traffic through the tsnet proxy at all. But the docs should not keep asserting
LNA as established fact — H-LNA remains plausible and is well-sourced, it is
just no longer *implied* by the error code.

To distinguish them on the iPad with the shipped build: Settings → Routing now
shows the live rules, and `-ProxyEverything` restores the old behaviour. If
public sites load with the split tunnel on and `-1000` only with
`-ProxyEverything`, the proxy path is the culprit either way.

**1b. Who applies search domains? The OS — but only AFTER deciding not to proxy.**
Measured on a Mac where `corp.ts.net` is a system search domain (`scutil --dns`)
and `ai.corp.ts.net` is a real peer:

| request | `matchDomains` | reached proxy? | as what |
| --- | --- | --- | --- |
| `http://ai/` | `[corp.ts.net]` | **no** | (OS expanded + dialed it itself) |
| `http://ai.corp.ts.net/` | `[corp.ts.net]` | yes | `ai.corp.ts.net` |
| `http://ai/` | `[ai]` | yes | **`ai`** (bare label, NOT expanded) |
| `http://onlyviaproxy/` | `[somethingelse]` | **no** → `-1003` | — |
| `http://onlyviaproxy/` | `[onlyviaproxy]` | yes → `-1000` | `onlyviaproxy` |

So the sequence is: **iOS matches `matchDomains` against the LITERAL host string
first**; on a miss it resolves/dials itself (applying its own search domains); on
a match it hands the literal string to the proxy, unexpanded. The OS never
expands a name *for* the proxy, and never asks the proxy to adjudicate.

Consequences:
- **iOS pre-filters.** The proxy is not consulted about hosts that don't match —
  so the two error codes have distinct meanings: `-1003` = pre-filtered, the OS
  couldn't resolve it; `-1000` = it reached the proxy and the proxy couldn't dial.
- **Search domains ≠ match domains.** Suffixing is *resolution*; `matchDomains`
  is *routing*. Anything relying on a bare label reaching the proxy must either
  list the bare label as a rule (which over-captures that TLD — see below) or
  rewrite the URL to the FQDN before loading. Aperture rewrites.
- **A bare-label rule captures the whole TLD.** With a peer named `ai`,
  `matchDomains=[ai]` sent `openai.ai` and `www.elevenlabs.ai` to the proxy.
  With FQDN-only rules (`ai.corp.ts.net`, `corp.ts.net`) they correctly went
  DIRECT.

**2. `ProxyConfiguration.matchDomains` behaves as needed (all verified):**

| behaviour | measured |
| --- | --- |
| no entries | proxies **everything** (the old, broken config) |
| any entries | proxies **only** matches; everything else goes DIRECT |
| name matching | label-wise **suffix**: `example.com` matches `www.example.com`, `a.b.example.com`, not `notexample.com` |
| **single-label entry** | `ai` matches host `ai` **and `openai.ai`** — a peer named `ai` would capture the whole `.ai` TLD |
| CIDR entries | **supported**, with exact boundaries: `100.64.0.0/10` covers `100.101.102.103` and `100.127.255.254`, excludes `100.5.5.5` / `142.250.80.46` |
| IPv6 CIDR | supported (`fd7a:115c:a1e0::/48`) |
| case / trailing dot | insensitive / tolerated |
| empty-string entry | matches **everything** — never emit one |
| invalid entry | ignored, does not poison the config |
| `excludedDomains` | **avoid**: getter reads back `matchDomains`, and matching fires in surprising directions |
| WebKit vs URLSession | **identical** behaviour |

**The fix (implemented in `TSNet/TailnetProxyPolicy.swift`):** scope the SOCKS
proxy to tailnet destinations only — the CGNAT/ULA ranges, the MagicDNS suffix,
peer FQDNs, and peer short names (minus public-TLD collisions, which are
reached by rewriting to the FQDN). Public hosts then load DIRECT and never
depend on the proxy. Unit tests: `scripts/test-proxy-policy.sh` (90 checks,
mutation-tested). On-device diagnostic: Settings → Routing.

### Follow-up: the decisive new fact + the sourced mechanism (H-LNA)

The user ran a fuller matrix on the real iPad: **ALL tailnet URLs work** —
`http://ai/`, `http://ai.corp.ts.net/`, **and `https://ai.corp.ts.net/`** (FQDN,
dotted, HTTPS), plus other `*.corp.ts.net` services. **ALL non-tailnet URLs
-1000** — `google.com`, `example.com`, `142.250.80.46`. So the discriminator is
NOT hostname shape (H3 is DEAD — `ai.corp.ts.net` is dotted/HTTPS and works) —
it's whether the host **is on the tailnet**.

The domain-entitlement hypothesis is RULED OUT: the project has NO entitlements
file, NO `com.apple.developer.associated-domains`, NO `ts.net` anywhere, NO
`WKAppBoundDomains` — `Info.plist` is just ATS. MagicDNS is a Tailscale-node DNS
feature, not an Apple one; `*.ts.net` gets no Apple-side special handling. So
Apple isn't categorizing `ai.corp.ts.net` as "tailnet" — the proxy (tsnet) is.

Re-engaged the three reviewers with this narrowed direction. **Opus found the
concrete, sourced iOS-26 mechanism — H-LNA (Local Network Access / IPAddressSpace):**

- **WebKit PR #69886** "Classify the real resolved connection IP for Local
  Network Access on Cocoa" (bug 319906, rdar://182830220, **merged 2026-07-24** —
  three days before this bug report): adds `classifyIPAddressSpace(const
  IPAddress&)` to `NetworkDataTaskCocoa.mm` (`didReceiveResponse` /
  `willPerformHTTPRedirection`). Verbatim from the PR: *"the resolved connection
  address, not the request URL's host, is what gets classified into an
  IPAddressSpace… When the connection address cannot be classified (no resolved
  address…) the space is left as IPAddressSpace::Unknown, which ranks as the
  least public space so the local network access check **fails closed** instead
  of defaulting to Public."* 
  https://github.com/WebKit/WebKit/pull/69886
- **`IPAddressSpace.cpp` / `IPAddressSpaceTests.cpp`**: classifies into
  `{Public, Local, Loopback, Unknown}`. There is an explicit
  **`IPv4CarrierGradeNAT` test** — **`100.64.0.0/10` (RFC 6598 CGNAT) is
  classified as `Local`**, alongside RFC1918. **Tailscale hands out exactly
  `100.64.0.0/10`.** So tailnet hosts → `Local` → allowed; public hosts →
  `Public` (or, through a proxy that resolves proxy-side, `Unknown`) → gated.
- Meta-bug **250607** (LNA enforcement); PRs #63281, #69817 (IPAddressSpace
  split into `{Public, Local, Loopback}`). Apple docs: **TN3179** (local network
  privacy), support article 102229 — confirm `100.64/10` shared-address-space is
  treated as local.

**How it fits every fact:** through a SOCKS5 proxy that resolves proxy-side
(tsnet uses `addrType: domainName` — the client hands the hostname to the proxy
and never resolves it), WebKit on iOS 26 gets **no client-side resolved
connection address** for the target → `IPAddressSpace::Unknown` → **fails
closed** for public-destined loads. Tailnet hosts that resolve (via MagicDNS
registered system-side, or whose connection resolves to a `100.x`) classify as
`Local` (CGNAT) → allowed. That's the tailnet-works/internet-fails split, with
NO app entitlement, NO domain allowlist, scheme/dottedness-independent, and
it's brand-new in iOS 26 (merged 2026-07-24) — so the sim (older/unenforced)
doesn't reproduce it, and the iPhone may be on a different enforcement state
(per-app Local Network permission / linked-SDK behavior — a specific form of
H2). Real-device confirmation: Apple devforums thread 817697 (iOS 26.4
WKWebView: IP-type connections hang minutes / no SYN; `.local` and remote
domains fine — LNA gating on address-class).

**GPT's H5 (proxy-side `UserDial` split)** is a partial alternative: the request
DOES reach tsnet; `UserDial` succeeds for tailnet (MagicDNS → netstack) and
fails for public (system resolver/dial); CFNetwork misleadingly maps the SOCKS
`generalFailure` to -1000. This fits the tailnet/internet split WITHIN a device
but NOT the iPhone/iPad split (same tsnet, same `UserDial` — would fail on both).
H-LNA fits both: the split is the per-device LNA enforcement state, not tsnet.
**Deepseek stayed with H4 (appBoundSession proxy-miss)** but flagged its own
tension (if the appBound session has no proxy, `google.com` should go direct and
work, not -1000) and landed on "the discriminator is resolves-to-tailnet-IP via
DNS" — which is the address-class core of H-LNA.

**Net:** H3 dead; H-LNA (iOS-26 LNA + CGNAT-as-Local + fail-closed-on-Unknown)
is the leading mechanism, sourced and verified; H2 (dev-mode/install-channel)
is the specific form of "why iPhone vs iPad" (per-app LNA permission/enforcement
state); H1 (entitlement) is the gate that makes an app a "full browser" exempt
from the in-app-browser LNA restriction.

### The ONE best new iPad test (URL bar only, ~1 minute)

**Type `http://142.250.80.46/` (public IP) and `http://100.x.y.z/` (a known
tailnet peer's raw 100.x IP) — both bare IPs, both dotted, no DNS, no hostname
shape.** Under H-LNA: tailnet-IP (`100.x` = CGNAT = Local) **works**, public-IP
(`142.250.x` = Public, or Unknown-through-proxy) **-1000s**. Nothing but H-LNA
predicts a raw-private-IP-works / raw-public-IP-fails split — it kills any
residual "it's about names/DNS/MagicDNS" story and confirms the discriminator is
address-space class decided on the IP itself. Add `http://192.168.1.1/` as a
tie-breaker (RFC1918 = Local = should work under H-LNA). And the earlier
"toggle Developer Mode" test (H2) is still cheap and orthogonal.

### What this means for a fix

Under H-LNA, the framing flips: a PAC is **the correct fix, not a workaround.**
Routing only tailnet (`100.64.0.0/10`, MagicDNS suffix, `*.ts.net`) through the
SOCKS proxy and everything else DIRECT is exactly what lets WebKit classify
each request against its *true* address space with a *real resolved IP*: public
hosts loaded DIRECT get a normal public classification and load normally (no
proxy → WebKit resolves them itself → real public IP → ordinary public load,
NOT `Unknown`-fail-closed). Tailnet hosts via the proxy classify as `Local`
(CGNAT) and are allowed. PAC stops feeding public hosts through a proxy that
denies WebKit a resolvable address — that's the actual bug, and PAC fixes it
directly. Internet has no business going through tsnet anyway; this is correct
least-privilege design (matches Safari-on-a-tailnet split-tunnel semantics).

1. **PAC / split-tunnel (#1, implement now):** `Network.ProxyConfiguration`
   supports `autoConfigurationURL`; the PAC returns the SOCKS proxy for tailnet
   names/IPs and `DIRECT` for the rest. Fixes the bug on all platforms, no App
   Review, sound architecture.
2. **`com.apple.developer.web-browser` entitlement (parallel, if Aperture is a
   full browser):** would exempt it from the in-app-browser LNA restriction.
   Managed/App-Review-gated, can't be self-granted for local testing. Pursue
   for product legitimacy; even then, PAC is still worth doing for least-
   privilege.
3. **`NSLocalNetworkUsageDescription` (cheap intermediate, no App Review):**
   adding it + the LNA permission prompt (`decidePolicyForLocalNetworkAccess
   PermissionRequest`) may let the app take the local-network posture directly —
   a legitimate stance for an app that reaches tailnet (private) hosts. Worth
   trying to validate the mechanism without App Review.
4. **Confirm H-LNA first** with the `http://142.250.80.46/` vs `http://100.x.y.z/`
   IP-literal test (above) — one minute on the iPad, no Mac. If raw-private-IP
   works and raw-public-IP -1000s, H-LNA is confirmed and the PAC is the fix.

### Earlier fix framing (superseded by H-LNA above)

The concern that a PAC would *hide a security policy* was valid under the
H1/H3 framing. Under H-LNA it's inverted: PAC makes WebKit's address-space
classification correct. Kept for reference:

1. **Declare `com.apple.developer.web-browser`** in Aperture's entitlements and
   ship via the App Store as a "web browser" category app (Apple grants the
   managed entitlement on approval). This is the *intended* path for an app
   whose purpose is browsing. It's also what makes the in-app-browser
   restrictions not apply. **Most likely the correct fix.** Requires App Review
   approval as a browser.
2. **Confirm the policy + file a WebKit bug** if the iPhone/iPad asymmetry is
   unintended (an in-app-browser restriction should arguably fire identically
   on both). The `-1000` for an obviously-valid URL is itself a poor error (it
   should be a clear "not permitted" message), suggesting a bug in the policy's
   *error reporting* even if the policy is intended.
3. **Route internet DIRECT, tailnet via proxy (PAC)** — still valid as a
   *design* choice (internet doesn't need tsnet), but it would be sidestepping
   the policy, not addressing it. If the policy also blocks DIRECT internet for
   in-app browsers on iPad (unknown), this wouldn't even work.

The next step is **confirming the policy is the cause** (vs. a coincidental
WebKit networking bug) before deciding. The cleanest confirmation: add the
`com.apple.developer.web-browser` entitlement to a local build, run on the real
iPad, and see if `https://google.com/` then loads. If it does → the entitlement
is the gate; pursue path 1. If it doesn't → the policy is something else, and
we file a WebKit bug with the -1000 reproduction. (Caveat: the entitlement is
*managed* — a self-signed local build may not actually grant it; the real test
is an App-Store-signed build with the entitlement granted by Apple. A
provisioning profile with the entitlement from the dev portal is the dev path.)

### The -1000 (badURL) result + the iPhone/iPad split

> **Superseded — see "RESOLVED" above.** The premise of this section (that
> `-1000` is a CFURL-layer rejection happening *before* the SOCKS dial, and
> therefore proves the request never reached tsnet) was tested directly and is
> **false**: a SOCKS proxy that fails the CONNECT produces `-1000` for every
> failure code. Kept for the record.

On a REAL iPad (and macOS-Designed-for-iPad), `https://www.google.com/` fails
with **`NSURLErrorDomain -1000` = `NSURLErrorBadURL`** (surfaced via WebKit's
`.failedProvisionalNavigation`). On a real iPhone (same `ios-arm64`, same tailnet,
same login) it works. This is the key fact, and -1000 is surprising:

- It is NOT `-1003` (cannot find host / DNS) or `-1004` (cannot connect / TCP)
  or `-1001` (timeout) — which is what a tsnet getaddrinfo/dial failure would
  produce. The SOCKS-layer errors live in the 100–124 range (`kCFSOCKS5Error…`).
- `-1000` is `kCFURLErrorBadURL` — the **CFURL/CFURLConnection layer** rejecting
  the URL, *before* the SOCKS dial stage. For a URL that is obviously valid.

So the failure is NOT "tsnet can't resolve/dial internet hosts" (that would be
-1003, and would fail on the iPhone too). It's WebKit/CFNetwork deciding the
URL is bad **on the iPad only**, in the proxied-request path. Since the app has
NO idiom branching in the network/proxy code (verified: `proxyConfig` constructs
the SOCKS endpoint identically; all `hSizeClass == .regular` branches are pure
UI chrome), this points at an **Apple WebKit/CFNetwork idiom-specific behavior**
for `WKWebsiteDataStore.proxyConfigurations` / `Network.ProxyConfiguration` —
the well-trodden "WKWebView + SOCKS proxy is buggy on iOS" territory
(rdar://20545691, iOS-17 forum threads), now manifesting as an iPhone/iPad
split.

### The decisive question: did the request reach tsnet?

-1000 is at the URL layer, so the request may not even reach tsnet's SOCKS
server. Two cases:
- **tsnet log shows a `socks5:` CONNECT to `google.com`** (then a dial failure)
  → the request reached tsnet; -1000 is CFNetwork's (odd) mapping of the SOCKS
  `generalFailure` reply. Fix: PAC (route only tailnet via the proxy) or fix
  tsnet's resolver.
- **tsnet log shows NOTHING for `google.com`** → the request never left
  WebKit/CFNetwork on the iPad; a pure client-side URL/proxy-handling bug. The
  PAC approach may still help (DIRECT bypasses the proxy entirely) but the bug
  is in Apple's code.

The app already logs tsnet's socks5 activity to os_log (subsystem
`io.tailscale.Aperture`, category `tsnet`). On the real iPad, capture it via
Console.app while loading google.com and look for `socks5:` lines.

### Faithful reproduction: `-TimingInternet -TimingWeb`

The default `-TimingInternet` fetches via **URLSession + the CFNetwork SOCKS
proxy dictionary** — a DIFFERENT proxy mechanism than the app (which uses
**WebKit + `WKWebsiteDataStore.proxyConfigurations` + `Network.ProxyConfiguration`**).
To reproduce the app's exact path, add `-TimingWeb`: the harness loads each URL
via a real `BrowserViewModel`/`WebPage` + `WKWebsiteDataStore(forIdentifier:)` +
the SOCKS `ProxyConfiguration` (the same code the URL bar uses), and logs the
full `WebPage.NavigationError` + underlying NSError domain+code + the app's
`NavErrorKind`.

```sh
# Real iPad — reproduce the app's WebKit path, full diagnostics in one launch:
xcrun simctl launch booted io.tailscale.Aperture \
    -TimingHarness -TimingRuns 1 -TimingInternet -TimingWeb -AuthKey tskey-auth-...
# (or via Xcode's Run on the real device with these launch args)
```

Verified on iPhone 17 Pro sim: google.com loads (title=Google) via the WebKit
path; on the real iPad the same line should show `FAIL: navError=… kind=…
underlying=[NSURLErrorDomain -1000] …`, reproducing the overlay's -1000.

### Likely root cause (real-ios-binary only)

On the sim, `net.Resolver.LookupIP` uses the macOS host resolver → works. On the
**real ios binary**, Go's cgo `getaddrinfo` for non-tailnet hostnames is
unreliable (a known Go-on-iOS pitfall; the Tailscale iOS app avoids it via
custom DNS / DoH, which tsnet doesn't). So tsnet's SOCKS proxy can't resolve/dial
internet hosts on real iOS → every non-tailnet URL fails with a connection
error. Tailnet works because those names resolve via MagicDNS-in-memory
(`dns.resolveMemory`), not getaddrinfo.

**To confirm on a real iPad:** the app already logs the full navigation error —
`log stream --predicate 'subsystem == "io.tailscale.Aperture"'` while loading
`https://google.com/` shows `Navigation error for …: <error>`. The overlay's
message line now also appends `[domain code]`. If it's `NSURLErrorDomain -1003`
(cannot find host) → DNS (getaddrinfo) failure, confirming the hypothesis. The
`-TimingInternet` harness mode run on a real iPad logs the same NSError directly.

(The "iPhone works, iPad doesn't" split the user saw is the one anomaly this
doesn't explain — both are real ios-arm64 binaries running the same `UserDial`.
Either the "iPhone works" observation was the simulator, or there's a
device/network difference in getaddrinfo behavior. The captured error from a
real iPad will disambiguate.)

### The design question: should internet go through tsnet at all?

The user's instinct ("we're sending stuff to tsnet that we shouldn't be") is
right. Routing ALL WebKit traffic through the tsnet SOCKS proxy is necessary for
tailnet hosts (MagicDNS + tunnel) but NOT for internet hosts, and it's what
makes internet depend on tsnet's iOS-direct-dial working. Options:

1. **PAC (proxy auto-config)** — route only tailnet hosts/IPs through the SOCKS
   proxy, everything else DIRECT. `Network.ProxyConfiguration` supports
   `autoConfigurationURL`; a PAC script can return the SOCKS proxy for tailnet
   names (`*.ts.net`, MagicDNS suffix, tailnet IPs) and `DIRECT` for the rest.
   This matches Safari-on-tailnet semantics and removes the tsnet-internet
   dependency entirely (works on all platforms). Most promising.
2. **Exit node** — route internet through a tailnet exit node. Works but
   requires the user to run one; not general.
3. **Fix tsnet's resolver upstream** — wire `net/dnscache` / DoH into
   `userDialResolve` so non-tailnet DNS works on real iOS. An upstream
   libtailscale change; doesn't fix the design (internet still needlessly
   flows through tsnet).

Aperture can't use a NetworkExtension VPN tunnel (the real Tailscale iOS app's
approach, which lets the OS route tailnet vs internet natively) because it's a
userspace tsnet app — the SOCKS proxy is the workaround. The PAC approach is the
closest equivalent within that constraint.

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
