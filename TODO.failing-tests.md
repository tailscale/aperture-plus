# TODO — currently failing UI tests

Snapshot of the UI-test suites' current state (2026-08-14), after the
fixes that landed in this session:

- `ApertureMacApp` now opens a workspace window on non-frontmost launches
  (`5ee5298e1 Open the workspace window on non-frontmost Mac launches`).
- `socks5` dial timeout raised 5s → 30s and dial failures are now classified
  + logged (`0b4cc7234 SOCKS5: raise dial timeout to 30s; classify + log dial
  failures`, in the `libtailscale`/`tailscale-patched` submodules).
- The staged `~/.aperture-ios-authkey` is a real `tskey-auth-…` ephemeral key
  (was accidentally a PEM private key).
- The simulator's software keyboard is enabled.

Run with `make test-ios-ui` / `make test-mac-ui`. As of the last full runs:

| Suite | Pass / Total |
|---|---|
| iOS (`ApertureUITests`) | 23 / 29 |
| macOS (`ApertureMacUITests`) | 2 / 3 |

The remaining failures split into three independent buckets, described
below. None is a regression from the work above; the SOCKS-layer flake those
fixes targeted is now solid (sim `ai` CONNECTs: **78 OK / 0 FAILED** with the
patched framework, vs 10 failures at exactly ~5s before).

---

## Bucket 1 — the `http://ai/chat` page-load flake (5 iOS tests)

All fail at ~66-68s (the tests' 60s page-load timeout). **The SOCKS CONNECT
now succeeds** (78/0) — the failure is one layer up, in the app's
initial-load gating, not the proxy.

Failing tests:

- `testHomePageLoadsWhenConnected` (`UITests/ApertureUITests.swift:991`) —
  "Home page (http://ai/chat) URL was not reached within 60s."
- `testHomePageInputKeyboardNoOverlap` (`:1199`) — "Chat home page did not
  load; can't exercise the home-input focus." (Depends on the home page
  loading.)
- `testChatInputKeyboardLayoutRepro` (`:1042`) — "Chat home page did not
  load; can't repro keyboard layout." (Same dependency.)
- `testConnectionTypeIndicatorNotInternet` (`:1581`) — "Home page should
  load before checking its connection type." (Same dependency.)
- `testExternalProcessSuspendRecoversWithoutReloadingPage` (`:758`) —
  generic `XCTAssertTrue failed`; same root cause.

### Symptom & evidence

The app logs, on every connected launch:

```
loadInitial: holding http://ai/chat until tailnet peer data arrives
Expanded known tailnet short name http://ai/chat -> http://ai.bopp-minor.ts.net/chat
```

The initial navigation is **held** until "tailnet peer data arrives"
(the netmap includes the `ai` peer, so the bare name can be rewritten to
its FQDN). That data is delivered by the LocalAPI `watch-ipn-bus`
stream. When the bus watcher is slow / drops, the hold eats the 60s
budget and the page never finishes loading — even though the SOCKS dial
is instant the moment it's actually attempted (the 78 OK CONNECTs are
fast: 14-61ms).

The bus watcher shows recurring loopback timeouts:

```
Bus watcher error: Error Domain=NSURLErrorDomain Code=-1001 "The request
timed out." .../watch-ipn-bus?mask=2; retrying after 0.5 seconds
```

`testBackgroundResumeReconnectsWithoutReloadingPage` (which loads the
**same** `http://ai/chat`) **passes** (~14-16s) because its node is
already warm — the hold resolves immediately. So this is a **cold-node
/ cold-netmap** failure path.

### Lead

`BrowserViewModel`'s `loadInitial: holding … until tailnet peer data
arrives` logic + `TSNetManager`'s `watch-ipn-bus` reliability. The hold
should fall back to the `/status` poll (which already runs every few
seconds) instead of waiting indefinitely on the bus, and/or the page
load should not be gated on netmap arrival at all for a peer whose FQDN
is already known from the persisted workspace. See
`TSNet/TSNetManager.swift` (`scheduleBusRestart`, the
`LocalAPI loopback failure; replacing loopback generation` recovery
path) and the `loadInitial` hold in the browser view model.

---

## Bucket 2 — exit-node env dependency (1 iOS test)

- `testExitNodeChangesEgressIP` (`UITests/ApertureUITests.swift:340`) —
  `XCTAssertNotEqual failed: ("24.202.72.5") is equal to ("24.202.72.5") —
  Egress IP should change when toggling the exit node on`.

This needs a **working exit-node peer** on the tailnet. With no exit node
configured/available, toggling it changes nothing, so the egress IP stays
the same and the assertion fails. This is an environment requirement,
not an app bug — see `README.ui-automation.md` ("At least one working
exit-node peer for the exit-node test"). Fix: stage an exit-node peer in
the tailnet (or accept this test as env-gated).

---

## Bucket 3 — macOS interactive login (1 Mac test)

- `testInteractiveLoginLogoutRelogin` (`MacUITests/ApertureMacUITests.swift:54`)
  — "Initial native Mac interactive login should complete" (fails at
  `completeNullIdLogin`).

This is the **documented macOS `ASWebAuthenticationSession` limitation**
(see `README.ui-automation.md` → "macOS difference"): on macOS,
`ASWebAuthenticationSession` opens the user's **default browser (Safari)
as a separate process**, so the test's `app.webViews.textFields` (which
queries Aperture's own process) can never see the login form. The iOS
`app.webViews.textFields` approach is therefore not portable to macOS as
written. The test now gets **past** the window/login-button gates (the
`ApertureMacApp` window fix landed this session) and fails only at the
nullid web flow itself.

Fixing this requires driving Safari via a separate
`XCUIApplication(bundleIdentifier: "com.apple.Safari")` (fragile), or a
non-web-auth path on macOS. The README calls this "fragile" and leaves it
open. The other two Mac tests
(`testCommandNOpensSeparateWorkspaceWindow`, `testAuthKeyLoginAndLogout`)
**pass**.

---

## Reproducing / gathering more evidence

```bash
# iOS (full suite; logs to build/uitest-logs/<ts>/)
make test-ios-ui

# Stream the sim's libtailscale + app logs during a run:
xcrun simctl spawn booted log stream \
  --predicate 'subsystem == "io.tailscale.Aperture"' --level debug

# macOS (full suite)
make test-mac-ui

# Single test, fast iteration:
xcodebuild test -project Aperture.xcodeproj -scheme Aperture \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData \
  -only-testing:'ApertureUITests/ApertureUITests/testHomePageLoadsWhenConnected' \
  -allowProvisioningUpdates
```

The SOCKS relay (`TSNet/SocksLogProxy.swift`) logs every CONNECT and its
outcome (`socks[N] OK/FAILED <host>:<port> (…ms)`); the new socks5 patch
also logs `dial tcp <host> failed: <err>` via tsnet's `socks5:`-prefixed
logger (visible on macOS stdout; **not** surfaced to iOS `os_log` —
tsnet's socks5 logs go to stdout, which XCUITest doesn't capture, so on
iOS the relay's reply-code line is the only SOCKS diagnostic).
