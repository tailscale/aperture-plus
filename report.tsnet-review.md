# Deep review: tsnet, proxy, WebKit, and iOS lifecycle

**Reviewed:** current `main` at `5536989`, including recent lifecycle commits `5071bac` through `b4da483`, the app's Swift code, UI tests and host scripts, the pinned `ThirdParty/libtailscale` Swift/C/Go code, and the pinned `tailscale.com` module.

**Independent reviewers:** GLM 5.2 produced a complete review in `reviews/tsnet-lifecycle-20260801/glm.md`. DeepSeek and Kimi performed long repository reviews but returned no final text through `pi --print`; their saved reasoning was recovered into `deepseek-raw-analysis.md` and `kimi-raw-analysis.md`. All three independently converged on the hidden-tab/home-page bug; Kimi also identified the auth-session cancellation, stale recovery write, stale proxy window, and main-thread semaphore wait.

**Tests run:**

- `make test-policy`: **102/102 passed**.
- `cd ThirdParty/libtailscale/swift && make test`: **all TailscaleKit tests passed**, each in a fresh process.

## Executive assessment

The recent work fixed several real problems: avoiding the indefinitely blocking `Up`, separating disposable LocalAPI observers from the retained tsnet server, adding generation checks, preserving the WKWebView during ordinary state bounces, and adding the SOCKS relay are all directionally sound.

There is nevertheless one confirmed high-severity application bug that explains tabs returning to their home/initial page. There are also important resume-state correctness problems: the app claims `Running` merely because the debug rebind calls returned, can reopen the proxy while it is backgrounded due to a stale task, cancels interactive login on background, and leaves WebKit pointed at a dead relay during fallback node rebuild.

The current repair hook is also incomplete as a network-reconfiguration repair: upstream explicitly documents that magicsock `Rebind()` **should be followed by `ReSTUN()`**, but Aperture performs rebind plus DERP break only. It is also too optimistic to equate successful debug-action dispatch with end-to-end proxy usability.

The logs are helpful for app-level sequencing and individual SOCKS handshakes, but not sufficient for diagnosing the suspected deadlocks/crashes on a device. In particular, Go/tsnet's detailed logs go to persistent `tsnet.log`, not to `LogRing` or unified logging, and the app has no node/workspace/lifecycle correlation IDs.

---

## Ranked findings

### HIGH 1 — Confirmed: an unloaded/restored tab is later navigated back to its initial URL

**Locations:**

- `App/Browser/BrowserViewModel.swift:97-111` (`makeWebView`)
- `App/Browser/BrowserViewModel.swift:118-132` (`unloadWebView`)
- `App/Browser/BrowserViewModel.swift:165-179` (`applyProxy`, `applyConnectionState`)
- `App/Browser/BrowserViewModel.swift:181-199` (`loadInitial`, `load`)

**Concrete sequence:**

1. A tab starts at its `initialURL` (normally the home page) and navigates to a conversation URL B.
2. Selecting another tab calls `unloadWebView()`. It saves B in `pendingLoadURL`, destroys the WKWebView, and sets `didLoadInitial = false`.
3. Selecting the tab again makes a new WKWebView and loads B from `pendingLoadURL`, but `makeWebView()` does **not** restore `didLoadInitial = true`.
4. A later `Starting -> Running` transition calls `applyConnectionState(true)`, or a proxy-policy publication calls `applyProxy`.
5. Both see `didLoadInitial == false` and call `loadInitial()`, which loads `initialURL`, replacing B with the tab's home/initial page.

There is an even more direct hidden-tab variant. If the tab remains hidden when the state returns to `Running`, `loadInitial()` calls `load(initialURL)` while there is no WKWebView, and `load` overwrites the saved `pendingLoadURL` B with `initialURL`. When the user later selects the tab, it opens at home.

This matches the reported symptom extremely well. Foreground recovery reliably generates the false-to-true state transition for **every tab**, so it can reset every unloaded tab together. A changed proxy policy can trigger it without any lifecycle event.

**Why tests miss it:** all no-reload lifecycle tests inspect the currently selected tab. That tab retains its WKWebView. They also normally begin and remain at the home page, so even a destructive reload to the same URL is not observable. `testWorkspaceTabsSurviveSwitching` checks tab count, not a non-home committed URL across switch + reconnect.

**Recommended fix:** distinguish “never loaded” from “temporarily unloaded.” When restoring `pendingLoadURL`, mark the tab initialized before issuing the request. Never let an automatic initial load overwrite an existing pending restore URL. Better still, replace the two loosely coupled fields with an explicit state:

```swift
enum PageResidency {
    case neverLoaded
    case loaded
    case unloaded(committedURL: URL)
}
```

Add a deterministic regression test with two tabs, a non-home URL, an unload/reselect, then both a state bounce and proxy-policy publication.

### HIGH 2 — Foreground repair publishes `Running` without proving the backend or proxy is Running

**Location:** `TSNet/TSNetManager.swift:646-665`.

After `debugResetConnections()` returns, the manager sets `model.state = .Running`. That call proves only that two in-process LocalAPI debug actions completed:

- `rebind` called `MagicConn().Rebind()`;
- `break-derp-conns` closed active DERP connections and started the home-DERP reconnect.

It does **not** prove that:

- the node was authenticated before background;
- DERP has reconnected;
- a direct path works;
- a SOCKS CONNECT can reach a peer;
- the previous backend state was actually `Running`.

A node that was `NeedsLogin`, `Stopped`, or `Starting` before background is therefore temporarily announced as `Running`. This opens the SOCKS gate and tells every BrowserViewModel it is connected. Failures during that window are then surfaced as navigation failures rather than held as reconnecting work.

This also feeds HIGH 1 by forcing `loadInitial()` on restored tabs.

**Recommended fix:** keep separate concepts:

- `backendState`: only bus/status evidence may set this;
- `transportRepairState`: idle/repairing/failed/verified;
- `proxyReady`: proven by a current-generation health check.

Do not write synthetic `Running`. At minimum retain the pre-background state and only optimistically reopen if it was `Running`, but a stronger solution is an actual SOCKS/LocalAPI readiness probe after repair.

### HIGH 3 — A cancelled, stale foreground task can set `Running` and reopen the SOCKS gate after the app backgrounds again

**Locations:** `TSNet/TSNetManager.swift:601-629`, `646-666`.

**Sequence:**

1. Foreground recovery enters the synchronous C/Go `debugResetConnections()` call.
2. The app backgrounds again. `willEnterBackground()` increments the generation, cancels `foregroundRecoveryTask`, sets `.Starting`, and closes the SOCKS admission gate.
3. Swift cancellation cannot interrupt the C/Go call.
4. The old call returns successfully.
5. The task writes `model.state = .Running` **before** checking cancellation/generation.
6. `proxyAvailabilityWatcher` reopens the gate while the app is backgrounded.

The subsequent guard prevents observer recovery, but it is too late to prevent the stale state mutation.

**Recommended fix:** immediately after every non-cancellable foreign call, check `Task.isCancelled`, `didEnterBackground`, and the lifecycle generation **before any state mutation or logging that claims success**. Pass a unique recovery ID through the operation and test rapid background/foreground/background churn while forcing the Go call to take several seconds.

### HIGH 4 — Backgrounding during interactive login cancels the auth session

**Locations:**

- `TSNet/TSNetManager.swift:601-629`
- `App/Tailnet Status/StatusViewModel.swift:52-91`
- `TSNet/AuthManager.swift:64-72`

`willEnterBackground()` unconditionally sets `model.state = .Starting`. `StatusViewModel` treats every non-`NeedsLogin` state as a reason to call `authManager.cancel`. Thus switching away during an `ASWebAuthenticationSession`—for example to a password manager—or locking the phone aborts login.

The `.inactive` handling correctly avoids disrupting login, but the `.background` path still does so through synthetic state mutation. The underlying tsnet node is intentionally preserved, so there is no need for the UI to pretend its authentication state changed.

**Recommended fix:** do not use backend state as the lifecycle/reconnect indicator. Keep the genuine `NeedsLogin` state while separately marking transport observers suspended/recovering. Add an XCUITest that starts interactive login, presses Home, returns, and verifies that either the same auth session remains valid or the app explicitly and safely restarts login.

### HIGH 5 — Fallback node rebuild leaves WebKit configured for a stopped relay/closed loopback while UI state remains `Running`

**Location:** `TSNet/TSNetManager.swift:749-771`.

The fallback path stops `SocksLogProxy`, clears its port, closes the old node, and starts a new node, but it does not first replace or invalidate `model.proxyConfiguration`. The WKWebsiteDataStore continues pointing at the old relay port. Because foreground repair previously set `.Running`, the BrowserViewModel accepts navigation errors instead of treating them as reconnect noise.

During cold startup of the replacement node, new tailnet requests receive connection-refused / `-1000`; waiting clients were cancelled by `stop()`.

**Recommended fix:** introduce an endpoint generation and a deliberate “proxy unavailable/rebuilding” state. Before stopping the relay, close admission and mark the backend non-ready. Either:

1. keep a stable relay listener for the entire manager lifetime and swap its upstream when a node is replaced (preferred), or
2. atomically publish a replacement relay endpoint only after it is ready.

Do not leave a published endpoint whose listener has been cancelled.

### HIGH 6 — Recovery startup errors deliberately crash the app

**Location:** `TSNet/TSNetManager.swift:158-188`.

Any thrown setup error—node creation, LocalAPI watcher setup, or loopback configuration—ends in `fatalError`. This includes last-resort resume recovery. A temporary state-store, loopback, or startup problem therefore turns a degraded networking state into an application crash.

This is especially risky because fallback rebuild is entered precisely when the networking substrate is unhealthy. The likely crash report will implicate Swift `fatalError`, not explain the underlying tsnet condition.

**Recommended fix:** keep a recoverable manager state with bounded retry/backoff and an explicit user-visible failure. Reserve process termination for invariant violations proven to be unrecoverable. Log the complete error chain and node/recovery generation.

### MEDIUM 1 — Repair omits the upstream-required ReSTUN step

**Locations:**

- `ThirdParty/libtailscale/tailscale.go:608-627`
- pinned `tailscale.com/.../wgengine/magicsock/magicsock.go:3838-3840`

The upstream source says:

> Rebind closes and re-binds the UDP sockets and resets the DERP connection. It should be followed by a call to ReSTUN.

Aperture invokes `rebind`, then `break-derp-conns`, but not `restun`. On a real path change (new Wi-Fi, Wi-Fi to cellular, changed NAT mapping), rebinding sockets alone may leave endpoint discovery stale and delay direct connectivity until another subsystem eventually triggers STUN.

`break-derp-conns` repairs the relay path, but it is not a replacement for endpoint rediscovery.

**Recommended fix:** make the Go resume operation a first-class libtailscale API rather than stitching debug endpoints together. It should perform rebind, ReSTUN, and DERP validation/reconnect under a bounded context, with structured result fields and tests. If sequential debug actions remain, use per-action deadlines rather than one context whose remaining budget may be exhausted by rebind.

### MEDIUM 2 — Unconditional rebind + DERP break damages healthy transports on every resume

**Locations:** `TSNet/TSNetManager.swift:632-670`, `ThirdParty/libtailscale/tailscale.go:601-627`.

Every real background/foreground cycle closes/reopens magicsock UDP and forcibly breaks every DERP connection, even if the app was backgrounded very briefly and no socket was defuncted. On DERP-only paths this guarantees a traffic interruption; existing netstack TCP sessions survive only if retransmission outlasts the outage.

This may be an acceptable conservative policy, but it should not be described as proving the retained proxy usable. The tests establish that one page survives one short controlled event, not that streaming/WebSocket/large-response sessions survive repeated resets.

**Recommended approach:** initially retain the conservative reset, but instrument its cost and validate a real SOCKS connection afterward. Long term, let libtailscale own platform resume repair based on its netmon/magicsock state rather than exposing production behavior through `DebugAction` strings.

### MEDIUM 3 — Fallback close can overlap a new node on the same state directory during lifecycle churn

**Location:** `TSNet/TSNetManager.swift:749-771`.

`rebuildNodeAfterFailedResume` sets `self.node = nil` and `startInFlight = false` before awaiting old-node `close()`. If the app backgrounds and foregrounds while close is blocked, `willEnterForeground` sees `node == nil` and can start a replacement before close finishes. Two tsnet servers may briefly use the same state directory and identity.

**Recommended fix:** model lifecycle explicitly (`starting`, `running`, `closing`, `rebuilding`) and retain the old node reference in manager state until close completes. Starting a node must be impossible while state is `closing`. One serialized supervisor task/actor should own all node transitions.

### MEDIUM 4 — Recovery attempts reuse one observer generation, weakening stale-callback protection

**Location:** `TSNet/TSNetManager.swift:677-746`.

All three observer attempts use the same lifecycle `generation`. A late queued event from attempt 1 can pass the generation check while attempt 2 is waiting and increment `freshLocalAPIResponseGeneration`, causing attempt 2 to claim fresh evidence without proving its own bus/poller works.

The window is narrow because old processors are cancelled, but the design is needlessly weaker than the comments claim.

**Recommended fix:** use two dimensions: node/lifecycle generation and observer-attempt ID. Only evidence tagged with the exact current attempt can satisfy that attempt's readiness wait.

### MEDIUM 5 — SOCKS relay does not own/close established sessions, mishandles TCP half-close, and has no useful timeout diagnostics

**Locations:** `TSNet/SocksLogProxy.swift:126-221`.

Problems:

- `stop()` cancels the listener and waiting clients, but established relay pairs are not tracked or cancelled. They can remain hung against a dead upstream after node rebuild.
- On EOF in either direction, `pump` cancels both connections immediately. That does not preserve TCP half-close semantics and can discard response bytes still flowing in the other direction.
- A client held behind the gate has no application timeout or age log. It may remain indefinitely if state never becomes `Running`.
- Send completion errors are ignored, so logs often contain neither an outcome nor a terminal reason.

**Recommended fix:** introduce a `RelaySession` object that owns both connections, tracks state and last activity, preserves half-close, reports terminal cause/duration/bytes, and can be closed by relay generation on a real node rebuild. Continue preserving established sessions across a transient gate close, but explicitly terminate them when their upstream node is destroyed.

### MEDIUM 6 — Proxy-policy changes republish the WKWebsiteDataStore proxy under live loads

**Locations:**

- `TSNet/TSNetManager.swift:511-532`
- `App/Browser/BrowserViewModel.swift:165-168`

When peer-derived match domains change, the manager republishes `proxyConfiguration`; every tab assigns `dataStore.proxyConfigurations = [proxy]`. This may reset WebKit connection pools or disrupt live streams. It also activates the HIGH 1 bug for restored tabs.

The sorted policy prevents needless publications when rules are equal, which is good, but changed peer sets are still normal operational events.

**Recommended fix:** empirically test live WebSocket/streaming behavior across a policy publication. If WebKit requires replacement assignment to apply `matchDomains`, debounce/coalesce it and make the disruption explicit. Do not let configuration publication imply page initialization/reload.

### MEDIUM 7 — `SocksLogProxy.start()` can block the MainActor for three seconds

**Locations:** `TSNet/TSNetManager.swift:471-491`, `TSNet/SocksLogProxy.swift:82-119`.

`proxyConfig` runs on the MainActor and calls `relay.start()`, which waits on a semaphore for up to three seconds. The listener callback runs on another queue, so this is not a strict deadlock, but it is a launch/recovery UI freeze and a watchdog risk under resource pressure.

**Recommended fix:** make listener startup async and publish the proxy configuration only after readiness. Never block MainActor waiting on networking callbacks.

### LOW 1 — Startup and status failures are underreported

The status poll uses `try? await client.backendStatus()`. A hung/failed poll is operationally important during resume but produces no per-attempt timeout/error log. Conversely, routine `Requesting status via ...` messages can be noisy. Log failures with a rate limit and duration, plus a success transition after failures.

### LOW 2 — Auth URLs and browsing destinations are logged as public text

`Authenticate at: <full URL>`, SOCKS destination names, and navigation URLs enter unified logging and the in-app ring. The auth URL is especially sensitive. Redact tokens and offer an explicit “include destinations” diagnostic mode rather than always logging them.

---

## Lifecycle/API semantics review

### `Start` versus `Up`

The decision not to call `TailscaleNode.up()` is correct for the present wrapper. Go's `TsnetUp` calls:

```go
s.s.Up(context.Background())
```

and the C/Go call synchronously occupies the Swift `TailscaleNode` actor until Running. At `NeedsLogin`, LocalAPI operations that first cross that actor to obtain loopback configuration can queue behind it. `Start()` plus IPN observation is the right shape.

However, the wrapper's documentation says close cancels an in-progress `Up`, while `tailscale.go` still has `// TODO: cancel Up`. That inconsistency should be fixed upstream even if Aperture no longer calls `Up`.

### Loopback and LocalAPI

`Loopback()` is cached in `TailscaleNode`, and LocalAPI requests build a new URLSession configuration around that stable loopback address. Preserving the node does preserve the local listener *if iOS does not defunct it*. Apple's guidance specifically says loopback listeners can be defuncted during suspension, so only repairing magicsock/DERP may be insufficient if the tsnet loopback listener itself suffers the reported iOS behavior.

The current debug reset test exercises magicsock and DERP, not destruction of the loopback listener. A separate fault hook is needed to invalidate/recreate the loopback serving socket while retaining or replacing the node.

### Close/deinit

`TailscaleNode.close()` does not mark the Swift handle closed, and `deinit` calls `tailscale_close` again. The second call returns `EBADF` after Go has removed the handle, which is ignored. That is not currently a crash, but explicit idempotent close state in the Swift actor would be cleaner and would make lifecycle assertions possible.

### Live TCP sessions

A proxied TCP flow is a netstack TCP session carried over WireGuard packets. Rebinding UDP and reconnecting DERP need not destroy netstack TCP state, so short outages can survive through retransmission. This is not a guarantee that every live HTTP stream or WebSocket survives: breaking DERP deliberately interrupts the packet carrier, and long recovery can exceed peer/application timeouts. Tests should assert survival and clean failure separately.

---

## iOS-specific conclusions from Apple guidance

Apple DTS guidance is unusually direct:

- An ordinary iOS app cannot rely on maintaining low-level TCP while suspended.
- The important distinction is **running versus suspended**, not merely foreground versus background.
- A debugger prevents suspension, so debugger-based tests are misleading.
- Listening sockets, including `NWListener`, should generally be closed before eligibility for suspension and reopened afterward.
- If a data connection is left open, its on-wire behavior while suspended/defuncted is unspecified; it may go deaf or close.
- A localhost TCP listener has specifically been observed returning `ECONNABORTED` while clients get `ECONNREFUSED` after inactivity; Apple attributes this to resource reclamation/defuncting.
- Network.framework does not exempt an app from these lifecycle rules.

Sources:

- Apple DTS, “Maintaining a TCP Connection in the Background”: <https://developer.apple.com/forums/thread/97824>
- Apple DTS, “TCP server socket for localhost gets broken…”: <https://developer.apple.com/forums/thread/85038>
- Apple DTS, “Network framework and background tasks”: <https://developer.apple.com/forums/thread/757385>
- Apple DTS, “Network.framework for peer to peer connection in background mode”: <https://developer.apple.com/forums/thread/715118>

This is important for Aperture: preserving the loopback listener is an optimization, not a valid invariant. The recovery design needs to tolerate both cases:

1. listener and sessions survived — preserve them;
2. loopback listener or transports were defuncted — atomically replace them without sending tabs home.

---

## Logging and observability audit

### What current logs can answer

From unified logging or Settings → Logs, one can usually determine:

- app background/foreground callbacks;
- whether transport repair returned success/failure;
- observer recovery attempts and fallback node rebuild;
- high-level IPN state/prefs/netmap notifications;
- whether a WebKit request reached the relay;
- SOCKS target, reply code, and handshake latency;
- browser navigation errors;
- deliberate Go panic capture on the next launch.

That is useful. In particular, the per-connection `socks[n]` records are a strong diagnostic improvement over tsnet's failure-only SOCKS logging.

### Critical gap: Go/tsnet logs are not actually in LogRing or unified logging

`Logger.log` writes Swift/app messages to print, OSLog, and LogRing. But Go's `s.s.Logf` is configured by `tailscale_set_logfd` and writes directly to `Logs/tsnet.log`. Those lines do **not** pass through `Logger.log`.

Therefore Settings → Logs and the documented unified-log predicate do not include the most useful internals:

- magicsock rebind details;
- DERP close/reconnect/ping results;
- control-client state;
- netmon changes;
- tsnet loopback listener failures;
- many Go-side deadlock/crash precursors.

`tsnet.log` is rotated and persisted but is not exposed by `LogViewer`. The README's implication that every libtailscale message reaches the in-app ring is inaccurate.

**Recommendation:** add a safe tail/export view for `tsnet.log` and `tsnet.log.old`, or bridge the Go log stream into OSLog/LogRing with bounded buffering. Keep panic stderr separate. A diagnostic export bundle should include app ring, Go log, prior Go log, crash capture, workspace/node metadata, and timestamps.

### Missing correlation

With multiple live workspaces, lines are interleaved and often impossible to assign to a node. Add to every app lifecycle line:

- workspace short ID and hostname;
- node generation / Go handle (non-secret stable diagnostic ID);
- lifecycle generation;
- observer attempt ID;
- proxy endpoint generation;
- SOCKS relay/session ID.

Log start and finish with elapsed durations, not just prose.

### Missing terminal events

Add logs for:

- WKWebView create/unload/restore with tab ID and committed/pending/initial URL (redacted host/path policy as appropriate);
- reason `loadInitial()` ran;
- proxy configuration endpoint replacement;
- held SOCKS client released, timed out, or cancelled;
- established relay termination and both NWConnection terminal states;
- status-poll failure/timeout and recovery;
- backend state returned by the fresh response that satisfied recovery;
- fallback close duration and whether a new start overlapped;
- process memory/session counts if chasing overnight crashes.

### If handed current logs, could they diagnose the reported issues?

- **Tabs sent home:** no. The destructive `loadInitial` path is silent.
- **Stuck reconnect banner:** partially. Observer attempts are visible, but not exact attempt ownership or backend response content.
- **SOCKS failure:** often yes if the request reaches the relay and receives a reply; no if an established relay hangs or the dead relay port refuses before acceptance.
- **DERP/magicsock recovery:** not from Settings → Logs; requires retrieving `tsnet.log`.
- **Crash/deadlock:** panic capture helps Go panics, but a hang has no watchdog/task snapshot and Swift `fatalError` obscures the prior setup error unless it was logged first.

---

## Test strategy

### 1. Deterministic in-process tests

Add narrow tests before more end-to-end tests:

1. **Tab residency state machine**
   - Load initial A, commit B, unload, recreate, state bounce, assert B.
   - Same but policy republish instead of state bounce.
   - Keep tab hidden during bounce, then select, assert B.

2. **Lifecycle supervisor races**
   - Suspend inside a controllably delayed repair call.
   - Trigger background/foreground/background.
   - Assert stale operation cannot publish state or open gate.
   - Trigger fallback close and foreground during close; assert no second node starts.

3. **Backend-state preservation**
   - Repeat lifecycle from `NeedsLogin`, `Stopped`, `Starting`, and `Running`.
   - Assert repair never invents a backend state.

4. **SOCKS relay protocol tests**
   - fragmented greeting/auth/request/reply;
   - client and server half-close;
   - send errors;
   - held-client timeout/cancellation;
   - stop with established sessions;
   - upstream replacement by generation.

5. **Message observer attempts**
   - deliver a late event from attempt N after N+1 starts;
   - assert it cannot satisfy N+1 readiness.

### 2. Simulator + host fault injection

The existing `SIGSTOP`/`SIGCONT` harness is valuable because it freezes Swift, URLSession, Network.framework, and Go together while retaining real scene transitions. Extend it to:

- use a non-home committed URL and multiple tabs;
- repeat suspend/resume 20–100 times;
- vary suspension from subsecond to minutes;
- suspend during startup, auth, policy publication, repair, and fallback close;
- issue traffic continuously and assert bytes/session identity, not just URL text;
- capture both unified log **and `tsnet.log`**.

For path/network faults:

- `simctl status_bar --wifiMode failed` is cosmetic; it does not reconfigure networking.
- There is no documented `simctl` command that provides a faithful per-simulator airplane-mode/path handoff.
- Network Link Conditioner can provide latency/loss/100% loss. On macOS it generally affects the host and therefore the simulator; third-party tools may scope shaping to the simulator, but this tests packet conditions, not necessarily interface identity changes. Background reading: <https://www.avanderlee.com/debugging/network-link-conditioner-utility/>.
- Use a local controllable proxy/server (toxiproxy-style) to cut/reset control, DERP, and peer TCP independently.
- Use host `pf`/route rules or a disposable VM/network namespace to blackhole specific control/DERP endpoints. Be careful not to lose the SSH/control channel.
- Add libtailscale test hooks for the conditions actually needed: close loopback listener, invalidate magicsock UDP sockets, break DERP, force STUN, pause LocalAPI responses, fail node close, and delay each operation.

A packet-loss profile is not a substitute for a network reconfiguration. Test both.

### 3. Upstream libtailscale tests

Add tests in the submodule for:

- a production `RepairAfterResume` operation that performs rebind + ReSTUN + DERP recovery;
- live TCP-over-netstack transfer across repair;
- DERP-only flow across forced DERP reconnect;
- LocalAPI and loopback listener recreation;
- `Close` during `Up`, resolving the API/docs inconsistency;
- close idempotency;
- multiple servers and protection against identical state directories;
- repeated IPN watcher start/stop/race with goroutine/session counts.

### 4. Physical-device matrix

Apple explicitly recommends a real device launched from the Home screen with no debugger. At minimum test:

- short Home/background and long lock/suspension;
- Wi-Fi unchanged;
- Wi-Fi AP change;
- Wi-Fi off/on;
- Wi-Fi ↔ cellular;
- airplane mode on/off;
- NAT/public-address change;
- DERP-only and direct peer paths;
- active WebSocket/streaming/large response;
- multiple tabs with non-home URLs;
- interactive login backgrounded mid-flow;
- repeated overnight cycles under memory pressure.

Success criteria should include proxy functionality, preserved committed URLs, observer freshness, no duplicate node, bounded recovery latency, and no process crash—not merely disappearance of the banner.

---

## Recommended architecture direction

The core problem is that one `Ipn.State` property currently carries three meanings:

1. real backend/auth state;
2. app lifecycle recovery state;
3. proxy admission readiness.

Split them. A small per-workspace supervisor should be the sole owner of node transitions:

```text
node lifecycle: absent -> starting -> live -> closing -> rebuilding -> failed
backend state:  NeedsLogin / Starting / Running / ...  (observed only)
transport:      unknown / repairing / healthy / degraded
observers:      stopped / starting(attempt) / proven / retrying
proxy endpoint: stable relay generation + upstream generation
```

Keep one stable local SOCKS listener per workspace if possible. WebKit points to it once. The supervisor swaps or gates its tsnet upstream atomically. This avoids repeatedly mutating `WKWebsiteDataStore.proxyConfigurations`, avoids dead ports during rebuild, and provides a natural place to hold/reject requests with bounded behavior.

Node start/close/rebuild should be serialized through that supervisor, and every foreign C/Go call should be followed by generation/cancellation validation before state publication.

---

## Things checked that appear sound

- Avoiding `TailscaleNode.up()` is correct given its blocking `context.Background()` implementation.
- Generation checks in `TSNetConsumer` correctly discard callbacks from a prior lifecycle generation.
- Explicit ownership/cancellation of `busRestartTask` is a real improvement over fire-and-forget retry tasks.
- `MessageReader.stop()` serializes URLSession lifecycle on its operation queue; the fresh-process race test passed.
- The edge-triggered `MessageProcessor` drain coalescing is reasonable and preserves FIFO processing.
- `TailnetProxyPolicy` sorting/dedup prevents needless policy publication on unchanged status; all 102 policy checks passed.
- Holding new SOCKS clients rather than returning a failure during a short reconnect is a sensible strategy, provided it gains bounds and terminal diagnostics.
- Not tearing down on `.inactive` is correct and avoids disrupting auth for transient interruptions.
- Keeping committed address-bar state separate from provisional WKWebView URL is good browser-security behavior.
- The current code does not intentionally unload WKWebViews merely because the app backgrounds; the home reset comes from the separate `didLoadInitial`/restore bug described above.

---

## Priority order

1. Fix and test the restored-tab `didLoadInitial` bug.
2. Stop synthesizing backend `Running`; separate lifecycle/transport/proxy readiness.
3. Guard the post-C/Go return against stale generations before all mutations.
4. Preserve interactive auth state across background.
5. Make the proxy endpoint stable/atomic across node rebuild.
6. Add ReSTUN and an actual readiness probe to resume repair.
7. Replace `fatalError` recovery with a bounded failed/retry state.
8. Expose/correlate `tsnet.log` and add tab/proxy/session terminal logging.
9. Expand SIGSTOP tests and add physical-device path-change testing.
