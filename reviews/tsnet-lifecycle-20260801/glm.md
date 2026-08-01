I've confirmed the "tabs sent home" bug. The key sequence: `unloadWebView()` sets `pendingLoadURL = url` (committed URL) and `didLoadInitial = false`. Then `makeWebView()` loads `pendingLoadURL` via `loadResolved` but does NOT set `didLoadInitial = true`. Subsequently, `applyProxy` or `applyConnectionState(true)` calls `loadInitial()` which calls `load(url: initialURL)` → since `webView != nil`, `loadResolved(initialURL)` loads the home page, overwriting the restored URL. Even worse, if `webView` is nil (hidden tab), `load()` sets `pendingLoadURL = initialURL` (home page), overwriting the committed URL that `unloadWebView` saved.

I now have all the information I need. Let me write the comprehensive review.

---

# Deep Adversarial Review: tsnet / Proxy / WebKit / iOS Lifecycle

## Executive Assessment

The recent lifecycle work (commits 5071bac–5536989) is a substantial and mostly well-reasoned effort to keep tsnet and WebKit sessions alive across iOS suspend/resume. The split-tunnel policy, SOCKS logging relay, generation-tagged observers, and the foreground "repair transports then recover observers" split are all defensible designs. However, the review uncovered one **HIGH-severity "tabs sent home" bug** that is almost certainly the user-visible regression behind "tabs return home" reports: `unloadWebView` resets `didLoadInitial = false`, and the subsequent `applyProxy`/`applyConnectionState(true)` (fired by the synthetic `.Running` set during foreground recovery, or by any proxy policy republish) calls `loadInitial()`, which overwrites the restored `pendingLoadURL` with the home-page URL — for both visible and **hidden** tabs. Separately, the unconditional `model.state = .Running` synthesis in `willEnterForeground` is wrong for a node that was `NeedsLogin` before background, briefly opens the SOCKS gate to a non-Running proxy, and the fallback node rebuild leaves a stale `proxyConfiguration` pointing at a stopped/closed loopback. Observer/SOCKS/message-queue lifecycles are otherwise sound; the test suite has several false-positive risks and lacks deterministic fault injection for the exact failure modes that matter. Findings below.

---

## Findings

### HIGH-1: Hidden tabs are sent to the home page on every reconnect/state-bounce (`unloadWebView` + `loadInitial` race)

**File:** `App/Browser/BrowserViewModel.swift` — `unloadWebView()` (L118–132), `makeWebView()` (L103–112), `applyProxy()` (L166–168), `applyConnectionState(_:)` (L171–179), `loadInitial()` (L182–190), `load(url:)` (L192–199).

**Trigger sequence (concrete):**
1. User has ≥2 tabs. Tab A is on a conversation page (`http://ai/chat/abc`); `didLoadInitial == true`, `pendingLoadURL == nil`.
2. User switches to Tab B. `TabManager.unloadHiddenTabs()` → Tab A's `unloadWebView()`:
   - `pendingLoadURL = url` (the committed conversation URL),
   - `self.webView = nil`,
   - `didLoadInitial = false`.
3. App is backgrounded. `TSNetManager.willEnterBackground()` sets `model.state = .Starting`. (For every tab, `applyConnectionState(false)` fires; `isConnected` becomes false; `loadInitial()` is skipped because `isConnected == false`.)
4. App is foregrounded. `willEnterForeground()` runs `node.debugResetConnections()` then sets `self.model.state = .Running`.
5. `model.$state` publishes `.Running`. `.removeDuplicates()` sees a change (`.Starting`→`.Running`), so `applyConnectionState(true)` fires on **every** `BrowserViewModel` — including hidden Tab A.
6. For Tab A: `isConnected = true`; `if !didLoadInitial { loadInitial() }` — `didLoadInitial` is `false`, so `loadInitial()` runs.
7. `loadInitial()`: `guard !didLoadInitial, isConnected` passes; `didLoadInitial = true`; `load(url: initialURL)` (the **home page** `http://ai/chat`).
8. `load(url:)`: `guard webView != nil else { pendingLoadURL = target; return }`. Tab A's `webView` is `nil` (unloaded). So `pendingLoadURL` is **overwritten** with the home-page URL, destroying the conversation URL that step 2 saved.
9. User switches back to Tab A. `makeWebView()` sees `pendingLoadURL` = home page → loads the home page. **Tab sent home.**

The same overwrite happens from `applyProxy` (fired by `refreshProxyPolicyIfNeeded` when a peer joins/leaves during the restoration window) and on the simpler tab-switch path without any backgrounding, if a proxy policy republish or a state bounce happens between `makeWebView` loading `pendingLoadURL` and the page committing — because `makeWebView`→`loadResolved` never sets `didLoadInitial = true`.

**Impact:** The single most plausible root cause of "tabs return home." Reproducible with: open two tabs, navigate tab 2 away from home, switch to tab 1, background+foreground, switch back to tab 2 → home page. Also reproducible without backgrounding if a peer-set change republishes `proxyConfiguration` while a restored tab's load is in flight.

**Why tests miss it:** `testBackgroundResumeReconnectsWithoutReloadingPage` and `testExternalProcessSuspendRecoversWithoutReloadingPage` keep the **selected** tab loaded (its `webView` is never nil, so `load()` takes the `loadResolved` branch and reloads in place — which happens to be the home page anyway, so the URL-pill assertion `== address` passes trivially). No test exercises a **hidden** tab surviving a reconnect and then being re-selected, which is the exact path that fails. The URL-pill assertion `app.buttons["url-pill"].label == address` only proves the *visible* tab didn't reload; it says nothing about hidden tabs.

**Fix:** In `load(url:)`, do not overwrite an already-pending restored URL:
```swift
guard webView != nil else {
    if pendingLoadURL == nil { pendingLoadURL = target }
    return
}
```
and in `makeWebView`, when restoring from `pendingLoadURL`, set `didLoadInitial = true` (the page was already loaded; we are restoring, not doing the initial load):
```swift
if let pendingLoadURL {
    self.pendingLoadURL = nil
    didLoadInitial = true        // <-- restored page counts as loaded
    loadResolved(pendingLoadURL)
} else {
    loadInitial()
}
```
This prevents both `applyProxy` and `applyConnectionState(true)` from re-triggering `loadInitial()` over a restored page.

---

### HIGH-2: `willEnterForeground` synthesizes `model.state = .Running` unconditionally, including for a `NeedsLogin` node

**File:** `TSNet/TSNetManager.swift` — `willEnterForeground()` (L655–688), `recoverLocalAPIObserversAfterResume` (L690–735).

**Trigger sequence:**
1. Node is at `NeedsLogin` (user logged out, or never logged in but the app was backgrounded after a prior session's logout persisted state).
2. `willEnterBackground()` sets `model.state = .Starting` (discarding the real `NeedsLogin`).
3. `willEnterForeground()` runs `node.debugResetConnections()` — this is a magicsock rebind + DERP break, which succeeds regardless of login state (it just rebinds UDP sockets).
4. `self.model.state = .Running` is set. The SOCKS gate opens (via `proxyAvailabilityWatcher`), and `applyConnectionState(true)` fires on all tabs (feeding HIGH-1).
5. WebKit loads through the proxy to a node that is **not** Running → tsnet's SOCKS5 fails the CONNECT (can't dial peers, no netmap) → WebKit reports `-1000` ("invalid URL").
6. The synthetic `.Running` is corrected only when `recoverLocalAPIObserversAfterResume` gets a fresh bus/status response showing `NeedsLogin` — up to ~4s (the validation deadline) × 3 attempts later.

**Impact:** A logged-out user returning from background sees "connected" UI and experiences `-1000` popups for several seconds; the ReconnectingBanner never shows (because `isConnected == true`). Combined with HIGH-1, all hidden tabs get sent home during this window.

**Why tests miss it:** Every lifecycle test launches with an auth key (`launchConnected`), so the node is always Running before background. No test covers backgrounding a `NeedsLogin` node (the interactive-login test never backgrounds mid-session).

**Fix:** Do not synthesize `.Running` blindly. Either (a) read the pre-background state in `willEnterBackground` (store `lastKnownState`) and only set `.Running` on foreground if it was `.Running`; or (b) issue a quick `backendStatus()` poll *before* setting state and mirror the real `BackendState`. At minimum, set `.Starting` (not `.Running`) and let the prompt observer recovery drive the real state, accepting a brief ReconnectingBanner — the banner is the correct UX for a node whose state is genuinely unknown.

---

### MEDIUM-1: Fallback node rebuild (`rebuildNodeAfterFailedResume`) leaves a stale `proxyConfiguration` pointing at a stopped relay / closed loopback

**File:** `TSNet/TSNetManager.swift` — `rebuildNodeAfterFailedResume` (L737–759).

**Trigger sequence:**
1. Three foreground-recovery attempts fail to get a fresh LocalAPI response.
2. `rebuildNodeAfterFailedResume` runs: `socksLogProxy?.stop()` (cancels the relay listener and waiting clients), `self.node = nil`, `startInFlight = false`, `try await node.close()` (closes tsnet's loopback listener), `startTailscaleIfNeeded()`.
3. `model.proxyConfiguration` is **not cleared** and still references the old relay port (`127.0.0.1:<oldRelayPort>`, now stopped) or tsnet's old loopback (now closed). `model.state` is still `.Running` (set earlier in foreground recovery) and is **not reset** to `.Starting`.
4. WebKit retains the old `ProxyConfiguration`. New SOCKS CONNECTs to the stopped relay get `ECONNREFUSED` → CFNetwork reports `-1000` ("invalid URL"). Because `model.state == .Running`, the ReconnectingBanner does not show, so the failure surfaces as "invalid URL" with no proxy context.
5. Only when `startTailscaleIfNeeded()` → `startTailscale()` → `tailscaleUp()` publishes a new `proxyConfig(loopback)` is the stale config replaced (seconds later, cold-start latency).

**Impact:** During the cold-start of the replacement node, users see spurious "invalid URL" errors on a node that the UI claims is connected. The SOCKS gate is open (`model.state == .Running`) but the proxy is dead.

**Fix:** In `rebuildNodeAfterFailedResume`, before closing the node:
```swift
model.state = .Starting
socksLogProxy?.setUpstreamAvailable(false)
```
and keep `model.proxyConfiguration` in place but gated (the `SocksLogProxy` gate, now closed, holds new SOCKS clients without returning a failure). If the relay was stopped, either restart it on the retained port or clear `model.proxyConfiguration` so WebKit falls back to DIRECT (public hosts work; tailnet hosts fail, which is honest).

---

### MEDIUM-2: `SocksLogProxy` established relays can stall indefinitely on a dead upstream (no half-close / no idle timeout)

**File:** `TSNet/SocksLogProxy.swift` — `pump(from:to:id:observe:)` (L201–221).

**Trigger sequence:**
1. A relay is established (client ↔ tsnet). The `pump(client→upstream)` is blocked in `upstream.receive(...)` waiting for response bytes.
2. tsnet's loopback is rebuilt (HIGH-2 fallback) or the underlying netstack session silently dies (iOS killed the socket during suspend but the Go side didn't notice). The upstream `NWConnection` may not deliver an error or `isComplete` promptly — TCP keepalive timeouts on loopback can be very long (or effectively infinite for a half-open socketpair in Go's netstack).
3. `pump` never receives a callback, so it never cancels either side. The `Session` parse state stays mid-handshake, and the WebKit request hangs until the user navigates away.

**Impact:** "Spinning forever" on a tailnet page after a reconnect/rebuild, with no log line (the relay never logs an outcome because it never sees end-of-stream). Hard to distinguish from the HIGH-2 stale-proxy case without an idle timeout.

**Why tests miss it:** The proxy-bounce harness (`ProxyBounceTestHarness`) only tests a fetch *started before* a bounce completing; it does not model an established stream that goes silent mid-transfer.

**Fix:** Add an idle timeout to `pump` (cancel both connections if no bytes flow for N seconds), and/or have `rebuildNodeAfterFailedResume` cancel the `SocksLogProxy`'s in-flight relays (currently `stop()` only cancels `waitingClients`, not established relays — see `stop()` L184–191). At minimum, `stop()` should cancel established relays too when the node is being torn down (vs. a transient gate close, which must preserve them).

---

### MEDIUM-3: `refreshProxyPolicyIfNeeded` republishes `proxyConfiguration`, reassigning `dataStore.proxyConfigurations` and tearing down WebKit connection pools under live loads

**File:** `TSNet/TSNetManager.swift` — `refreshProxyPolicyIfNeeded()` (L430–449); `App/Browser/BrowserViewModel.swift` — `applyProxy()` (L166–168).

**Trigger sequence:**
1. A page is loaded and has an active WebSocket / streaming fetch / long-poll.
2. A peer joins or leaves the tailnet. The 5s `backendStatus` poll updates `model.localStatus`.
3. `refreshProxyPolicyIfNeeded` computes a new policy (`matchDomains` changed), mutates `model.proxyConfiguration.matchDomains`, and republishes `model.proxyConfiguration`.
4. `BrowserViewModel.applyProxy` fires: `dataStore.proxyConfigurations = [proxy]`. Reassigning this array tears down WebKit's SOCKS connection pool, dropping the WebSocket / breaking the stream. The page may need to reconnect (and if it's a bare-name URL, it may briefly fail per the split-tunnel notes).

**Impact:** Intermittent connection drops when the tailnet peer set changes during active streaming. Not a crash, but a real correctness/UX issue for long-lived connections.

**Why tests miss it:** No test holds a WebSocket/streaming connection open across a peer-set change. The connection-bounce harness uses a one-shot `fetch`.

**Fix:** Separate *policy* changes from *proxy-identity* changes. `matchDomains` mutations on an already-installed `ProxyConfiguration` should be applied in place without reassigning the array (verify whether WebKit observes `matchDomains` mutations — if not, only republish when the proxy *endpoint* changes, and fold domain updates into the next natural republish). Alternatively, debounce peer-set republishes (the status poll fires every 5s; coalesce rule changes to once per 15–30s unless a tailnet-structural change occurs).

---

### MEDIUM-4: `MessageReader.receiveData` will trap on an empty `Data` if URLSession ever delivers one

**File:** `ThirdParty/libtailscale/swift/TailscaleKit/LocalAPI/MessageReader.swift` — `receiveData(_:)` (L139–152).

`buffer.append(data)` followed by `if buffer[buffer.count - 1] == kJsonNewline` — if `data` is empty *and* `buffer` was empty, `buffer.count - 1` is `-1` and the `Data` subscript traps (precondition failure / abort). Apple documents `urlSession(_:dataTask:didReceive:)` is called with non-empty data, so this is latent, but the crash would be indistinguishable from the Go-runtime fatals the app goes to great lengths to capture (`CrashCapture`), polluting the "stderr.log non-empty = Go crash" heuristic. Guard `guard !data.isEmpty` before appending, or check `buffer.isEmpty` before indexing.

---

### LOW-1: `SocksLogProxy.handle(client:)` reads `nextID` off the serial `queue` but `nextID` is instance state — correct only because all access is via `queue`

**File:** `TSNet/SocksLogProxy.swift` — `handle(client:)` (L160–178).

`handle` is the `NWListener.newConnectionHandler` callback, which Network.framework delivers on `queue`. `nextID` and `waitingClients` are mutated only there, so this is correct. But the class is `@unchecked Sendable` and the invariant is undocumented at the mutation sites — a future caller that touches `waitingClients` off-`queue` would race silently. Consider making the invariant explicit (a doc comment on each mutated property, or an `os_unfair_lock`/actor) to prevent regressions.

---

### LOW-2: `MessageProcessor.deinit` calls `cancel()` then `reader.stop()`, but `reader.stop()` enqueues on `workQueue` which may be gone

**File:** `ThirdParty/libtailscale/swift/TailscaleKit/LocalAPI/MessageProcessor.swift` — `deinit` (L37–41), `MessageReader.stop()` (L50–62).

`deinit` runs on whatever thread releases the last reference. `reader.stop()` does `workQueue.addOperation { ... }`. `OperationQueue` retains itself while operations are running, so the queued block will execute even after `deinit` returns, but it captures `[weak self]` on `MessageReader` — if the `MessageReader` is being deallocated concurrently (it's owned by `MessageProcessor`, so `deinit` drops it too), the `weak self` could be nil and the block no-ops. This is safe but fragile; the queued work (invalidating the URLSession) could be lost if the queue is torn down. In practice `URLSession` is also deallocated by `MessageReader`'s `deinit` (implicit), which cancels tasks. Low risk; worth a comment.

---

## "Tabs sent home" — Causal Analysis

The reported "tabs return home" symptom has exactly one causal chain in the current code, and it is HIGH-1:

**Root cause:** `unloadWebView()` saves the committed URL into `pendingLoadURL` and clears `didLoadInitial = false`, but **no code path ever sets `didLoadInitial = true` when restoring from `pendingLoadURL`**. `makeWebView()` calls `loadResolved(pendingLoadURL)` (which does not touch `didLoadInitial`), leaving `didLoadInitial == false`. Any subsequent fire of `applyProxy` (proxy republish) or `applyConnectionState(true)` (state→Running) calls `loadInitial()`, which:
- For a **visible** tab (`webView != nil`): calls `load(url: initialURL)` → `loadResolved(initialURL)` → navigates the live WebView to the home page, interrupting the restored load.
- For a **hidden** tab (`webView == nil`): calls `load(url: initialURL)` → `pendingLoadURL = initialURL`, **overwriting** the committed URL saved by `unloadWebView`.

The foreground recovery path is the most reliable trigger because `willEnterBackground` sets `model.state = .Starting` and `willEnterForeground` sets `model.state = .Running` (HIGH-2), guaranteeing a `.removeDuplicates()`-passing state transition that fires `applyConnectionState(true)` on *every* tab simultaneously — so **all** hidden tabs get their `pendingLoadURL` overwritten with the home page at once, not just the visible one.

Secondary contributors that make the window wider:
- `refreshProxyPolicyIfNeeded` republishes `proxyConfiguration` on peer-set changes (MEDIUM-3), firing `applyProxy`→`loadInitial()` on hidden tabs even without a state bounce.
- The synthetic `.Running` (HIGH-2) opens the gate and sets `isConnected = true`, satisfying `loadInitial()`'s guard.

**Why it wasn't caught:** Every reconnect/no-reload UI test keeps the *selected* tab's WebView alive (never `unloadWebView`'d), so `loadInitial()`'s overwrite either (a) doesn't fire (state was stably Running, no duplicate), or (b) reloads the visible tab to the home page — which is also its `initialURL`, so the URL-pill assertion passes trivially. No test restores a *hidden* tab after a reconnect and asserts its non-home URL survived. This is a textbook false-positive test gap: the assertion `url-pill.label == address` is true even when the tab was sent home, because `address` *is* the home page.

**The fix** (from HIGH-1) breaks the chain at two points: `makeWebView` sets `didLoadInitial = true` on restore, and `load(url:)` refuses to overwrite a non-nil `pendingLoadURL`. Together these make `loadInitial()` a no-op for restored tabs.

---

## Logging / Observability Audit

**What's good:**
- Every `logger.log` funnels through `LogRing` (in-memory) + `os_log` (unified) + `print` (stdout), so on-device (Settings → Logs), Console.app, and `xcodebuild test` all get the same lines. The `io.tailscale.Aperture` subsystem + `tsnet`/`crash` categories are filterable.
- `SocksLogProxy` logs every CONNECT with host/port, reply code, and latency (`socks[id] OK/FAILED target (Nms)`), which is the single best on-device signal for "did the request reach the proxy and what did tsnet say."
- `CrashCapture` cleanly separates Go-runtime fatals (stderr.log) from tsnet logs (tsnet.log), making "non-empty stderr.log + crash signature" a reliable crash indicator.
- Lifecycle transitions are logged at key points: `Background: preserving tsnet/proxy sessions`, `Foreground: rebinding tsnet transports`, `Foreground: tsnet transport rebind complete/failed`, `Foreground recovery: observers started; awaiting fresh response (attempt N)`, `Foreground recovery: fresh LocalAPI response received`, `Foreground recovery: three attempts produced no fresh data; rebuilding tsnet node`.

**Gaps:**

1. **No correlation between SOCKS ids, IPN events, and lifecycle generations.** A `socks[42] FAILED ai:80` line has no link to which observer generation or foreground-recovery attempt was active. Add a generation/id prefix to SOCKS log lines (or a concurrent "node generation" field) so a failed CONNECT can be correlated to the node that was live when it was attempted. Currently you can only time-correlate, which is fragile across the 5s poll cadence.

2. **`freshLocalAPIResponseGeneration` increments are logged only implicitly.** The `Foreground recovery: fresh LocalAPI response received` line proves *a* response arrived, but it does not log *what* the response said (the `BackendState`). If the response reveals `NeedsLogin` (HIGH-2), there is no log line saying "fresh response was NeedsLogin — synthetic Running was wrong." Add a log of the resolved `BackendState`/`State` at that point.

3. **No log for `unloadWebView`/`makeWebView`/`loadInitial`/`pendingLoadURL` overwrite (the HIGH-1 path).** The "tabs sent home" bug is completely invisible in the logs — there is no line when a tab's `pendingLoadURL` is overwritten with the home page, and `loadInitial` logs nothing on the overwrite path. Add: `log("tab restored from pendingURL: \(url)")` in `makeWebView`, and `log("loadInitial overwriting pendingLoadURL with home: \(initialURL)")` when `load()` takes the `webView == nil` branch with a non-nil existing `pendingLoadURL`. Without this, the bug is undiagnosable from logs alone.

4. **No log when `applyProxy`/`applyConnectionState` *actually* call `loadInitial()`.** They log only on the "no reload" happy path (`Tailnet reconnected — page and proxy kept`). The destructive path (`if !didLoadInitial { loadInitial() }`) is silent. Add a log when `loadInitial()` fires from these paths, including whether `webView` was nil (hidden tab).

5. **`refreshProxyPolicyIfNeeded` logs the rule change but not *which* proxy identity is affected** (the relay port / tsnet loopback). When the node is rebuilt (MEDIUM-1), the log shows "policy updated" but not "proxy now points at dead port N." Add the proxy endpoint to the log.

6. **Sensitive-data risk: `BrowseToURL` (the full Tailscale auth URL, which contains a node key fragment) is logged in plaintext** (`TSNetConsumer.notify`: `logger.log("Authenticate at: \(b)")`). This is intentional for debugging but ends up in `LogRing` (in-memory, viewable in Settings → Logs on a device that could be handed to someone). Consider redacting the query fragment in the in-memory/on-device copy while keeping the full URL in `os_log` (which requires Console.app / `log show` access).

7. **SOCKS credentials pass through the relay and are never logged** — correct, but worth an explicit assertion/test that the relay's `inspectClientBytes` never logs the auth payload (it currently parses and discards it, which is right).

---

## Prioritized Test Matrix

### Simulator (deterministic, no auth key needed for the fault paths)

| Test | Fault injected | Asserts |
|---|---|---|
| **Hidden tab survives reconnect** (NEW — covers HIGH-1) | Open 2 tabs, navigate tab 2 off-home, switch to tab 1, drive `model.state` `.Starting`→`.Running` via `-UITestLifecycleRecoveryRace` or a bus-restart, switch back to tab 2 | Tab 2's URL-pill != home page; `socks[]` shows no new CONNECT to home |
| **Hidden tab survives proxy policy republish** (NEW) | As above, but trigger `refreshProxyPolicyIfNeeded` by injecting a synthetic peer-set change | Tab 2's URL unchanged |
| **`NeedsLogin` node backgrounded+foregrounded** (NEW — covers HIGH-2) | Launch without auth key (gate), background, foreground | UI shows NeedsLogin (not Running) within 2s; no `-1000` errors; SOCKS gate stays closed |
| **Fallback node rebuild restores proxy** (NEW — covers MEDIUM-1) | Force 3 failed observer attempts (e.g., kill the loopback mid-recovery via a launch arg), assert rebuild path | `lifecycle-recovery-test-status == fallback-node-rebuild`; subsequent loads succeed (new SOCKS CONNECT OK); no `-1000` window |
| **Established relay idle timeout** (NEW — covers MEDIUM-2) | Start a streaming fetch, kill the upstream tsnet socket (host-side via the relay's test hook) | Relay logs a timeout/cancel within Ns, not a silent hang |
| Existing: `testConnectionBounceDoesNotReloadPageOrLoseFetch` | Harness bounce | Keep — but extend to assert hidden tabs too |
| Existing: `testBackgroundResumeReconnectsWithoutReloadingPage` | `XCUIDevice.home` + activate | **Tighten:** assert the URL-pill is a *non-home* URL (navigate away first) so the assertion is non-trivial |

### Host-induced faults (real process suspension)

| Test | Fault | Asserts |
|---|---|---|
| `scripts/test-lock-resume.sh` (existing) | `SIGSTOP` the sim app for 7s during background | ReconnectingBanner clears ≤7s; URL-pill unchanged. **Extend:** navigate off-home first; assert the *off-home* URL survives, not just "some URL" |
| **Repeated scene churn** (NEW) | `SIGSTOP`/`SIGCONT` 5× rapidly during a single background window | No overlapping nodes (verify via `pgrep`/Go server count log); no duplicate `Brought Tailscale up`; banner clears |
| **Startup-during-background** (NEW) | Launch the app, immediately `SIGSTOP` before `tailscaleUp` completes, `SIGCONT` | Startup observers are not orphaned; foreground recovery owns them; state reaches Running |
| **Repair failure/timeout** (NEW) | Make `debugResetConnections` return -1 (e.g., kill the loopback before foreground) | Foreground logs "rebind failed; continuing"; observer recovery proceeds; no permanent Starting |
| **Network path change during suspension** (NEW) | Toggle the sim's network (offline/online) while SIGSTOPped | After resume, a fresh netmap is fetched; connection-type indicators update |

### Physical device (the only place real iOS suspend/socket-death occurs)

| Test | Fault | Asserts |
|---|---|---|
| **Real lock/unlock with active streaming tab** | Lock screen 30s, unlock, with a WebSocket page open | Stream reconnects; no "invalid URL"; no tab sent home |
| **Real lock/unlock with multiple tabs** | Lock/unlock with 2+ tabs, one off-home, one a streaming page | Both survive; off-home tab not sent home (HIGH-1 regression guard) |
| **Logged-out background** | Log out, background 30s, foreground | UI shows NeedsLogin (not Running); no `-1000` (HIGH-2 regression guard) |
| **Airplane-mode toggle mid-load** | Toggle airplane mode during a page load | SOCKS relay holds/releases correctly; page loads on restore |
| **Exit-node toggle during streaming** | Toggle exit node with a streaming connection | Connection survives or fails cleanly (MEDIUM-3) |

### Upstream Go/Swift unit tests (no iOS needed)

| Test | What it verifies |
|---|---|
| `TsnetDebugResetConnections` preserves live netstack TCP sessions | Open a tsnet dial, call reset, assert the session still transfers bytes (validates the "existing sessions remain alive" claim in tailscale.go) |
| `TsnetClose` cancels an in-progress `Up` | Call `Up` on a no-key node, then `Close`; assert `Close` returns (not deadlocked) — the TODO in tailscale.go (`// TODO: cancel Up`) suggests this is unverified |
| `LocalClient` works after `Start` without `Up` | Assert `DebugAction("rebind")` succeeds on a `NeedsLogin` node (validates that HIGH-2's transport repair doesn't depend on Running) |

---

## Things checked that are NOT bugs

1. **The `TSNetConsumer` generation check** (`model.activeObservationGeneration == observationGeneration`) correctly discards stale IPN events from cancelled URLSession watchers. The `Task { @MainActor in ... }` hop is safe because the generation read is on the main actor and the discard happens before any model mutation.

2. **`MessageReader.stop()` not calling `cancelAllOperations`** is correct and intentional (the inline comment explains why): cancelling operations could discard a subsequently-queued `start()` and invert lifecycle order. Keeping the serial queue's FIFO guarantees stop-then-start ordering.

3. **`MessageReader`/`MessageProcessor` queue ordering and the edge-triggered `messagesAvailable` drain** are sound: the `drainScheduled`/`drainRequested` flag dance correctly coalesces bursts and closes the arrival race without polling. The `kMaxQueueSize` backpressure + `congested` flag correctly signals `MessageQueueError.queueCongested` to trigger an `.initialState` restart.

4. **`scheduleBusRestart` owning its retry in `busRestartTask`** correctly prevents the unowned-Task-survives-background race that b4da483 fixed. Cancelling the prior task before scheduling a new one prevents concurrent restarts. The `consumer.error = nil` reset prevents re-triggering.

5. **`SocksLogProxy` holding waiting clients via TCP backpressure** (not returning a SOCKS failure) is the correct design for a transient gate: WebKit's request stays pending without surfacing a `-1000`, and is released when `Running` returns. Established relays are correctly never touched by a gate close.

6. **`TailnetProxyPolicy`'s sorting + dedup** correctly prevents `refreshProxyPolicyIfNeeded` from republishing on every 5s poll when the peer set is unchanged — the `Equatable` comparison is stable. (MEDIUM-3 is about the *changed*-peer-set case, not the unchanged case.)

7. **The decision not to call `node.up()`** is correct and well-documented: `Up(context.Background())` is non-cancellable and would deadlock the `TailscaleNode` actor for a `NeedsLogin` node (and deadlock `close()` behind it). `Start()` + bus watching is the right pattern. The timing harness validates `Start→Running ≈ Up→Running`.

8. **`CrashCapture`'s stderr/tsnet log separation** is correct: `log.SetOutput(f)` in `TsnetSetLogFD` routes Go's stdlib `log` package to tsnet.log, leaving stderr.log for raw Go-runtime panic/fatal output only. The crash-signature heuristic (`panic:`/`fatal error:`/`goroutine `/`runtime: out of memory`) is robust, and skipping past os_log debugger noise to the real crash line is the right call.

9. **`ApertureApp`'s `.inactive` → no-op** is correct: tearing down the node on Control Center / app-switcher peek / notification banner would be both expensive and dangerous mid-login (the stale-URL bug). Only `.background` disconnects.

10. **`BrowserViewModel.acceptSameDocumentURL`'s same-origin check** correctly prevents cross-origin provisional URLs from spoofing the address bar before commit, while allowing `history.pushState`/fragment updates. This is defense-in-depth on top of WebKit's own enforcement.

11. **`ConnectionTypeResolver`'s conservative `.derped` fallback** for short names withheld as public TLDs (e.g. `ai`) is correct: it avoids mislabeling the home-page peer as "Internet" while the FQDN expansion handles routing.

12. **The `MessageProcessor.processMessage` split-on-newline handling** correctly deals with multiple newline-delimited messages arriving in one chunk (it splits and decodes each), and the partial-then-complete accumulation across chunks is correct for newline-delimited JSON streaming.
