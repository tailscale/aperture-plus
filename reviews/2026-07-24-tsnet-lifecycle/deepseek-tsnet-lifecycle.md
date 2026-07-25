I now have a thorough understanding of all the code paths. Here is the full adversarial review.

---

# Adversarial review: tsnet lifecycle at the Aperture app layer

## Summary

**The app-layer lifecycle has two fatal concurrency bugs and one systemic observation-gap bug.** The "minutes" of hang is most likely a confluence of (1) the `TailscaleNode.up()`-blocks-actor → `close()`-deadlocks bug (the README already flags it) hitting every time the app is backgrounded before a login completes or during a slow reconnect, plus (2) the 60‑second `watch-ipn-bus` inactivity timeout creating multi-cycle silent windows where state changes are invisible. Both are real, reproducible, and together explain "sometimes minutes" of unresponsiveness. The surrounding error‑swallowing in logout, a missing cancellation in the bus‑error restart loop, and a `combineLatest` + `removeDuplicates` race add further fragility but are secondary.

---

## Findings

### FATAL-1: `TailscaleNode.up()` block → `close()` deadlock on every background before login

**Location:** `TailscaleNode.up()` (TailscaleNode.swift:156) + `TSNetManager.willEnterBackground()` (TSNetManager.swift:245)

**What's wrong:** `TailscaleNode.up()` is actor‑isolated and calls Go's `TsnetUp`, which passes `context.Background()` (non‑cancellable) to `s.s.Up()`. `up()` returns only when the node reaches `Running`. For a **no-auth-key workspace** (every real user), the node sits at `NeedsLogin` forever — `up()` blocks the actor indefinitely. `close()` is on the same actor and queues behind it, so it **never runs**. The Go `TsnetClose` has a `// TODO: cancel Up` comment confirming the gap is known but unfixed.

**How to trigger it (concrete sequence):**
1. User opens app for the first time (no auth key). `tailscaleUp()` calls `node?.up()`.
2. Node goes to `NeedsLogin`. `up()` blocks the actor forever.
3. Before the user completes login, they press Home to switch apps.
4. `ApertureApp.onChange(.background)` → `workspaceManager.willEnterBackground()` → `TSNetManager.willEnterBackground()` → `Task { try await nodeTmp?.close() }`.
5. `close()` queues behind `up()` on the TailscaleNode actor → **deadlock**. The Task never completes.
6. User returns to foreground: `willEnterForeground()` → `startTailscaleIfNeeded()` → `setupNode()` creates a **second** `TailscaleNode` with the **same state directory** (the old one was never fully closed). Now two tsnet servers share one dir.
7. The second node may or may not work correctly. If it does, login might eventually succeed; if it doesn't, the user sees "Connecting…" indefinitely.

**Why `nodeTmp?.close()` doesn't help:** `nodeTmp` captures the `TailscaleNode` actor reference, which is non-nil. The `try await` crosses the actor boundary — it doesn't bypass serialization. `close()` is stuck.

**Suggested fix (two‑part):**
- **Short‑term:** Replace `node?.up()` with an alternative that doesn't block: after `TailscaleNode.init` (which calls `tailscale_start`, whose `doInit` already sets `WantRunning` + `StartLoginInteractive`), watch the bus for `Running` instead of calling `up()`. This is exactly what the Swift harness already does. The `up()` call is redundant for state observation (the bus emits `Running` when the node connects).
- **Long‑term:** Fix the Go side: make `TsnetUp` accept a cancellable context (or pass a context that Close() can cancel).

**Test/log:**
- Add a log line in `willEnterBackground` **before** and **after** the `close()` Task, and emit a timestamped warning if `close()` hasn't returned within 10 seconds:
  ```swift
  let deadline = Date().addingTimeInterval(10)
  Task {
      try await nodeTmp?.close()
      if Date() > deadline { logger.log("WARNING: close() took >10s (deadlock?)") }
  }
  ```
- UI test: launch without auth key, wait for `NeedsLogin`, background the app, wait 5s, foreground it, assert the login gate still responds within 5s.

---

### FATAL-2: 60‑second `watch-ipn-bus` inactivity timeout — no keep‑alive, invisible restarts

**Location:** `watchIPNBus` (LocalAPIClient.swift:103), `MessageReader.start()` (MessageReader.swift), `TSNetManager.startEventBus()` bus‑error observer (TSNetManager.swift:186)

**What's wrong:** The bus watcher uses `URLSessionConfiguration.default`, whose `timeoutIntervalForRequest` defaults to **60 seconds**. The `watch-ipn-bus` long‑poll is silent when no state changes occur — the Go backend sends no keep‑alive. After 60s of inactivity, the URLSession fires `NSURLErrorDomain -1001` (`timedOut`). This calls `TSNetConsumer.error()`, which triggers `startEventBus()` to restart the watcher. **Each cycle creates a ~60s window where the UI sees no state updates.** Since `startStatusPolling` (5s poll) only sets `model.localStatus` (not `model.state`), the UI's gate/browser switch is purely bus‑driven — it's blind during every timeout cycle.

**How to trigger it:**
1. Node is connected and idle (e.g., user reading a page, no tailnet changes).
2. After 60s, the bus watcher times out. `TSNetConsumer.error` fires.
3. `busErrorWatcher` fires, clears the error, calls `startEventBus()`.
4. New bus watcher starts, gets initial state (reports `Running` again). GPIO latency: ~1 round‑trip.
5. If the user logs out DURING one of these 60s windows, the node transitions to `NeedsLogin` + emits `BrowseToURL` — but nobody is watching. The user sees the browser still showing "Connected" for up to 60s.
6. When the timeout fires and the bus restarts, the initial state dump picks up `NeedsLogin`. The UI finally shows the LoginBanner.
7. If the user had already tapped Login (before the transition was observed), the sheet opens with the wrong/stale URL, or `showAuth` falls through to `startLoginInteractive()` — but by now the new bus watcher is attached, so the fresh URL arrives. Total delay: 60–120s, which matches "sometimes minutes."

**Suggested fix:**
- Disable the request‑level timeout for the bus watcher by setting a very long `timeoutIntervalForRequest` on the bus session config (e.g., `604800` = 7 days), and let the restart be driven by actual errors (connection drops, not silence). Or implement an app‑level keep‑alive: every 30s of silence, send a dummy localAPI request that causes a state echo.
- At minimum, set `request.timeoutInterval = 86400` in `watchIPNBus` and add a comment.

**Test/log:**
- Add a log line on every bus error with the elapsed time since the last successful message:
  ```swift
  logger.log("Bus watcher error after \(seconds) idle; restarting")
  ```
- Unit test: create a bus watcher, assert that 70s of silence does NOT cause a timeout (set a custom long timeout). Hard to do in a unit test without mocking, but the timing harness could measure the gap.

---

### HIGH-1: `busErrorWatcher` from old watcher NOT cancelled — cascading restart loop

**Location:** `TSNetManager.startEventBus()` (TSNetManager.swift:186), `TSNetManager.setProcessor()` (TSNetManager.swift:233)

**What's wrong:** `startEventBus()` creates a new `busObserver` (a Combine sink on `consumer.$error`) and stores it in `busErrorWatcher`, replacing the old one. But the **old `MessageProcessor`** is only cancelled via `setProcessor()` (line 234). The error‑restart Task inside the sink re‑enters `startEventBus` **before** `setProcessor()` is called for the new processor. The chain:

1. Bus error fires → `sink` closure creates `Task`.
2. That Task calls `await MainActor.run { consumer.error = nil }` then `try await startEventBus(...)`.
3. Inside the recursive `startEventBus`, a **new** bus observer is created and assigned to `busErrorWatcher`.
4. The recursive `startEventBus` returns the new processor.
5. The Task calls `await MainActor.run { self.setProcessor(processor) }`, which cancels the **old** processor.

**But:** between steps 2 and 3, if another bus error fires (e.g., from the old processor's URLSession before it's cancelled), `consumer.error` is set again. The **old** `busErrorWatcher` sink is still live at this point (it hasn't been replaced yet — `busErrorWatcher = busObserver` runs inside step 3's `MainActor.run`). So the old sink fires again, creating a second Task, which re‑enters `startEventBus` again. This can produce a cascade of `k` concurrent restarts.

In practice, this is rare because the old processor's URLSession was already invalidated. But the race window exists.

**Suggested fix:**
- Cancel the old `busErrorWatcher` before creating a new one. In `startEventBus`, do:
  ```swift
  await MainActor.run {
      self.busErrorWatcher?.cancel()
      self.busErrorWatcher = nil
  }
  // then create the new watcher
  ```
- Or, better: use a `Set<AnyCancellable>` with a flag to suppress re‑entrant restarts.

**Test/log:**
- Log `busErrorWatcher` count:
  ```swift
  logger.log("Restarting bus watcher (active observers: \(observers.count))")
  ```

---

### HIGH-2: `willEnterBackground` / `willEnterForeground` — orphaned close()+duplicate node creation

**Location:** `TSNetManager.willEnterBackground()` + `willEnterForeground()` (TSNetManager.swift:245, 265)

**What's wrong:** In `willEnterBackground`, `self.node` is set to `nil` and a detached `Task` calls `close()` on the old reference. `willEnterForeground` calls `startTailscaleIfNeeded()` which passes the `startInFlight` guard (reset to `false` in background) and creates a **new** node. If `close()` is deadlocked (FATAL‑1), or even just slow (e.g., a keyed node that takes 1.5s to close), the old node is still alive when the new node starts. Both point at the same `config.path` directory. The Go `tsnet.Server` has no file‑level locking on its state directory — two servers handling the same `Dir` can corrupt each other's bolt database.

**How to trigger it:** Cycle background/foreground rapidly (e.g., swipe up, tap the app icon again within 2 seconds). Each cycle creates a new orphan node.

**Suggested fix:**
- Do NOT nil `self.node` synchronously in `willEnterBackground`. Instead, store a cancellation flag and let `setupNode()` check for a pending close:
  ```swift
  func willEnterBackground() {
      logger.log("Background: Disconnecting...")
      startInFlight = false
      stopStatusPolling()
      busErrorWatcher?.cancel()
      pendingClose = self.node
      self.node = nil
      model.proxyConfiguration = nil
      Task {
          try? await pendingClose?.close()
          pendingClose = nil
      }
  }
  ```
  Then in `setupNode()`, `await` the `pendingClose` to complete before creating a new node (or at least check it). But this is hard because `setupNode` is not async and there's no easy way to await. A simpler approach: don't nil the node; instead, start the close and poll for it, or restructure to use a proper state machine.

**Test/log:**
- Log `willEnterBackground` with the current node pointer + the close Task handle. Log `willEnterForeground` with whether the previous close completed.

---

### HIGH-3: Logout silently fails — no feedback, stuck state

**Location:** `StatusViewModel.logout()` (StatusViewModel.swift:123), `Workspace.logout()` (Workspace.swift:146)

**What's wrong:** Both call `deleteProfile` with `try?` — every error is swallowed. If `deleteProfile` fails (network error, `localAPIClient` is nil, node not running), the user sees no feedback: the Logout button appears to do nothing, `hasConnected` is still `true` (sticky), and the `LoginBanner` never appears. The user can keep tapping Logout with no effect.

**How to trigger it:**
1. User is connected and browsing.
2. Network drops or node is slow to respond.
3. User taps Settings → Tailnet Status → Logout.
4. `currentProfile()` or `deleteProfile()` fails (e.g., 408 timeout from localAPI after 60s).
5. `try?` swallows the error. The logout Task returns silently.
6. UI stays on the browser (`hasConnected` is sticky). No `LoginBanner`. User is stuck.

**Suggested fix:**
- At minimum, log the error:
  ```swift
  func logout() {
      Task {
          do {
              guard let profile = try await manager.localAPIClient?.currentProfile() else { return }
              try await manager.localAPIClient?.deleteProfile(profileID: profile.id)
          } catch {
              logger.log("Logout failed: \(error)")
          }
      }
  }
  ```
- Better: surface the error to the user (e.g., an alert or status text).

**Test/log:**
- Add a log line: `"Logout: deleteProfile succeeded/failed: \(error)"`
- Unit test: mock `LocalAPIClient` to throw on `deleteProfile`, assert the UI does NOT stay in the post‑logout state.

---

### MEDIUM-1: `combineLatest(state, browseToURL)` + `removeDuplicates` — initial state miss + bus restart blind window

**Location:** `StatusViewModel.observeAuthURL()` (StatusViewModel.swift:31)

**What's wrong:** `combineLatest` requires **both** publishers to emit at least once before it fires. Combined with `removeDuplicates()` on `state`, the following sequence can cause a miss:

1. Bus watcher starts (fresh or after restart). First notify sets `state = NeedsLogin` and `browseToURL = "url"` in two separate `Task { @MainActor in … }` blocks. The order is **non‑deterministic**.
2. If `browseToURL` fires first: `combineLatest(nil, "url")` fires with `state=nil`. The `state == .NeedsLogin` check is false. Nothing happens — the URL is **ignored**.
3. Then `state = NeedsLogin` fires: `combineLatest(NeedsLogin, "url")` fires, and the URL is picked up. **This works 99% of the time** because both values are set within the same actor quantum.
4. But if in step 2, `state` was **already** `.NeedsLogin` (from a prior bus notify that was `removeDuplicates()`'d), the second `.NeedsLogin` is dropped. Then `combineLatest` never fires again for that state+URL pair. The URL is **silently lost**.

**Real trigger:** After a bus‑error restart (FATAL‑2), the new bus watcher's initial dump re‑emits `NeedsLogin` + `BrowseToURL`. If `state` is already `.NeedsLogin` (unchanged from the pre‑restart state), `removeDuplicates()` filters it — and `combineLatest` never sees the new URL. The user taps Login, `authURL` has the stale URL (or nil if it was cleared by the non‑NeedsLogin branch), and login hangs.

**Suggested fix:**
- Remove `removeDuplicates()` from the state publisher. The dedup isn't needed here because `combineLatest` already handles repeat emissions correctly, and `needsAuth` is set idempotently.
- Or: don't use `combineLatest`. Subscribe to `browseToURL` directly (it's the actual event of interest) and derive state from it.

**Test/log:**
- Log each `combineLatest` emission:
  ```swift
  logger.log("observeAuthURL: state=\(state?.rawValue ?? "nil"), url=\(browseToURL ?? "nil")")
  ```

---

### MEDIUM-2: `showAuth` before `localAPIClient` is set — silent no‑op

**Location:** `StatusViewModel.showAuth()` (StatusViewModel.swift:109)

**What's wrong:** In the `else` branch (`authURL` is nil), `showAuth` sets `requestedInteractiveLogin = true` and calls `try await manager.localAPIClient?.startLoginInteractive()`. If `localAPIClient` is nil (because `setLocalAPIClient` hasn't been called yet — it's called **after** `setupNode()` but the bus may emit `NeedsLogin` + `BrowseToURL` before `tailscaleUp` reaches `setLocalAPIClient`), the `?.` makes the call a silent no‑op. `requestedInteractiveLogin` stays `true` forever, but nothing happens. When `localAPIClient` is eventually set and a `BrowseToURL` arrives, the sheet opens — potentially minutes later.

**Suggested fix:**
- Instead of a boolean flag, store a pending‑login closure or use a continuation:
  ```swift
  func showAuth() {
      if let authURL { authManager.showAuth(authURL: authURL); return }
      guard let client = manager.localAPIClient else {
          // Retry after a short delay or observe localAPIClient being set
          requestedInteractiveLogin = true
          return
      }
      Task { try await client.startLoginInteractive() }
  }
  ```
  Then in `setLocalAPIClient`, check `requestedInteractiveLogin` and call `startLoginInteractive` if set.

---

### MEDIUM-3: `AuthManager.presentationAnchor` force‑unwrap crash

**Location:** `AuthManager.presentationAnchor(for:)` (AuthManager.swift:39)

**What's wrong:** The fallback expression `ASPresentationAnchor(windowScene: UIApplication.shared.connectedScenes.first as! UIWindowScene)` force‑casts and force‑unwraps. If `connectedScenes` is empty (e.g., `showAuth` is called before the app's window scene is set up, or after all scenes are disconnected), this crashes with a fatal error. This is a crash, not a hang, but it makes the app non‑responsive (it terminates).

**Suggested fix:**
- Use a safe fallback:
  ```swift
  guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
      logger.log("CRITICAL: no window scene for auth session — cannot present")
      return
  }
  return ASPresentationAnchor(windowScene: scene)
  ```

---

### MEDIUM-4: `startStatusPolling` doesn't drive `model.state` — no fallback during bus outage

**Location:** `TSNetManager.startStatusPolling()` (TSNetManager.swift:218) + `TSNetModel.localStatus` (TSNetModel.swift:20)

**What's wrong:** The 5‑second `backendStatus()` poll sets `model.localStatus` (an `IpnState.Status`), but **no code reads `localStatus` to update `model.state`**. The `state` field is only set by bus notifies. During the 60‑second bus‑timeout window (FATAL‑2), the 5‑second poll is running but its results are completely ignored by the gate‑browser switch and the LoginBanner. This is a wasted opportunity.

**Suggested fix:**
- In `startStatusPolling`, extract `state` from `backendStatus()` and update `model.state` if it's non‑nil and the bus hasn't updated it recently. This gives the UI a recovery path when the bus is between restarts.

---

### LOW-1: `TailscaleNode.down()` calls `tailscale_up` instead of `tailscale_down`

**Location:** `TailscaleNode.down()` (TailscaleNode.swift:175)

**What's wrong:** Line 175 reads `let res = tailscale_up(tailscale)`. This should be `tailscale_down`. The `down()` function is never called by the app (the app uses `close()`, not `down()`), so this is harmless in production, but it's a code‑level bug.

**Suggested fix:** Change to `tailscale_down`.

---

### LOW-2: `observeAuthURL` clears `browseToURL` on every non‑NeedsLogin state, not just after logout

**Location:** `StatusViewModel.observeAuthURL()` (StatusViewModel.swift:74)

**What's wrong:** The recent fix clears `model.browseToURL` in the `else` branch (state != `.NeedsLogin`). This runs on **every** transient state — `Starting`, `Stopped`, `NoState`, etc. — not just when leaving `NeedsLogin` after a logout. While the fix correctly prevents stale‑URL poisoning, it also **unnecessarily clears `browseToURL` during normal transient state transitions** (e.g., reconnecting after background). If the node emits `NeedsLogin` → `Starting` → `Running` and the `browseToURL` is set during `NeedsLogin` then cleared during `Starting`, the user returning from background might briefly see the LoginBanner flicker. This is cosmetic but worth noting.

**Suggested fix:**
- Track a `wasLoggedIn` flag that is set when state transitions from `.Running` → anything else, and only clear `browseToURL` when that flag is set.

---

### NIT-1: `TailscaleNode.deinit` calls synchronous `tailscale_close` — thread safety

**Location:** `TailscaleNode.deinit` (TailscaleNode.swift:93)

`deinit` calls `tailscale_close` synchronously (not `await close()`). If the Go server's `Close()` makes blocking syscalls, this blocks the deallocation thread (typically the MainActor or an actor's executor thread). Since `deinit` runs on whatever thread last held the actor's strong reference, this could block the Swift concurrency cooperative thread pool. Mitigated by the fact that `close()` is otherwise always called explicitly before deinit, but it's a latent thread‑pool starvation risk.

---

## Are any of the hypothesised "safe" paths actually safe?

**The `startInFlight` guard:** Yes, it's atomic (`@MainActor`). The `init()`-triggered start and the `scenePhase == .active` notification can't race through it because both are on the MainActor. The guard is sound.

**The `hasConnected` sticky flag:** Yes, it does what it says — once `true`, the gate never reappears. Combined with the `LoginBanner`, this is correct: a logout transitions through needsAuth without kicking the user back to the gate. The `LoginBanner` drives the re‑login flow.

**The `observeAuthURL` fix (clearing `browseToURL` in the non-NeedsLogin branch):** The fix is correct for its intended purpose (preventing stale‑URL poisoning after logout). It works because after `deleteProfile`, the node transitions through intermediate states (Stopped/NoState) before reaching NeedsLogin, and `browseToURL` is cleared during those intermediates. The only risk is unnecessary clears during normal reconnection as noted in LOW-2.

---

## Conclusion

The two fatal bugs — `up()` deadlocking `close()`, and the 60s bus‑timeout window — are the real cause of the "minutes" of hang. They interact: a background‑foreground cycle during login (FATAL‑1) creates an orphan node that corrupts state, and the bus‑timeout cycle (FATAL‑2) delays observation of the fallout by 60+ seconds. The `try?`‑swallowed logout (HIGH‑3) then makes recovery impossible without force‑killing the app. Fix FATAL‑1 by avoiding `up()` entirely (the bus already carries the signal), and fix FATAL‑2 by setting a very long timeout on the bus watcher's URLSession.
