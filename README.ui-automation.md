# UI automation & agent tooling

How to build, run, see, poke, and read logs from Aperture — with an emphasis
on what works **autonomously** (no GUI clicks, no permission prompts) versus
what needs a human in the loop.

This file is the deep dive. `README.md` and `CLAUDE.md` keep only short pointers
to it so the always-in-context docs stay small.

## TL;DR

The top-level **Makefile** wraps the common flow:

```bash
make                         # build iOS simulator app
make test                    # complete required iOS + native Mac suite
make test AUTHKEY=tskey-...  # same, with an explicit ephemeral-compatible key
make test-ios-ui             # required iOS UI leg only
make test-mac                # native Mac entitlement + launch smoke check
make test-mac-ui             # all required native Mac UI tests
make look Q="describe the UI" # screenshot sim + vision-describe it
scripts/check-mac-automation.sh   # preflight: verify macOS perms + prereqs
```

The iOS simulator build/run/screenshot loop works headlessly with no permission
grants. The complete `make test` suite does **not**: native Mac XCUITest requires
a logged-in GUI session and macOS Automation/Accessibility approval, and the
interactive login tests require external network services.

**Build both schemes (iOS + macOS) from the Xcode GUI at least once first** — it
resolves the one-time headless-signing (`errSecInternalComponent`) and
Accessibility-prompt walls that otherwise block the CLI; see *One-time native
Mac permission setup*.

Or the raw commands (what `make` runs under the hood):

```bash
# 1. Build for the simulator
xcodebuild build -project Aperture.xcodeproj -scheme Aperture \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData

# 2. Run the app
xcrun simctl boot 'iPhone 17' 2>/dev/null || true
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/Aperture.app
xcrun simctl launch booted io.tailscale.Aperture

# 3. See it (screenshot + vision description)
scripts/look.sh "describe the UI and the status text"

# 4. Poke it (XCUITest)
scripts/run-uitests.sh

# 5. Read the libtailscale logs
xcrun simctl spawn booted log stream \
  --predicate 'subsystem == "io.tailscale.Aperture"' --level debug
```

Or just `scripts/run-uitests.sh`, which does 1, 4, and 5 together and writes
everything to `build/uitest-logs/<timestamp>/`.

---

## Native Mac UI test target (`ApertureMacUITests`)

The native `ApertureMac` scheme includes three macOS UI tests in `MacUITests/`:

- `testCommandNOpensSeparateWorkspaceWindow` — Command-N creates a second
  persisted workspace window and closing it leaves the other window running.
- `testInteractiveLoginLogoutRelogin` — drives native AuthenticationServices
  through Tailscale login, `testuser@nullid.fly.dev`, device authorization,
  Settings logout, and a second full interactive login.
- `testAuthKeyLoginAndLogout` — uses the staged auth key for deterministic
  connected login, drives Settings logout, and verifies that the replacement
  workspace reconnects with the inherited launch key.

Run all of them with `make test-mac-ui` (or as part of the complete required
`make test` suite). `make build-mac-uitests` only compiles them. Run
`scripts/check-mac-automation.sh` first to confirm the macOS permissions are
granted (see *One-time native Mac permission setup* below). Missing auth keys
or failures in the external nullid/control-plane flow fail the suite; no Mac
test skips.

## Required-test policy

Every test in both schemes is required. The suite has no `XCTSkip` paths and no
"print SKIP then return" paths. Missing auth keys, exit-node peers, software
keyboard setup, accessibility elements, or external login availability are
failures. `make test` runs policy tests, all iOS UI tests, the native Mac smoke
check, and all native Mac UI tests.

This means the required environment must provide:

- `~/.aperture-ios-authkey` (or `AUTHKEY=...`), compatible with ephemeral nodes.
- If the tailnet advertises an exit-node peer, it must provide working egress;
  without one the test instead verifies that the unsafe toggle is disabled.
- Network access to Tailscale's control plane, `login.tailscale.com`,
  `nullid.fly.dev`, and the pages used by browser tests.
- The simulator software keyboard configuration expected by keyboard tests.
- A logged-in macOS GUI session and Automation/Accessibility permission for
  Xcode/test runners to control the native app.

### One-time native Mac permission setup

The native Mac leg needs several things granted to the process that runs the
automation (Xcode for interactive runs; the **SSH/Terminal responsible process**
for headless/agent runs). A single self-test checks them all:

```bash
scripts/check-mac-automation.sh          # verify; prints ✅/❌ per check
scripts/check-mac-automation.sh --fix    # also clear stale window-restoration state
```

If anything fails, here is the full checklist:

0. **Build both schemes from the Xcode GUI at least once before relying on the
   CLI.** Open `Aperture.xcodeproj` in Xcode 26.x and Build (⌘B) — ideally also
   run one UI test from the Test navigator — for **both** the `Aperture` scheme
   (iOS Simulator) and the `ApertureMac` scheme (My Mac). Approve every prompt
   that appears (keychain access, Accessibility, signing-identity requests).
   This is the one-time escape hatch for the headless-signing wall: the first
   CLI `xcodebuild build-for-testing`/`test` for `ApertureMac` fails at
   `CodeSign …/TailscaleKit.framework` with `errSecInternalComponent`
   ("User interaction is not allowed") because the keychain won't release the
   "Mac Development" private key to a non-interactive `codesign`. A single GUI
   build makes Xcode approve key access; afterward the CLI signs cleanly for
   the session. The keychain re-locks on reboot, so re-do the GUI build (or run
   `scripts/unlock-keychain.sh`) once per SSH session afterwards. The iOS build
   doesn't strictly need this — the simulator signs ad-hoc — but building it
   from the GUI first surfaces first-run Xcode/Simulator provisioning and the
   Accessibility prompts in a context where you can click them.

1. **Frameworks.** `make mac-framework` (macOS `TailscaleKit.framework`) and
   `make ios-fat` (iOS `TailscaleKit.xcframework`) must have run once. The
   self-test checks both exist. If they're missing, they're built from the
   `libtailscale` git submodule, whose remote is `url = .` (the subtrac pattern
   — see `CLAUDE.md`), so on a fresh machine you must first enable the local
   file transport that `url = .` relies on: `git config --global
   protocol.file.allow always` (the CVE-2022-39253 default blocks it), then
   `git submodule update --init --recursive` (needs `m1/main.trac` to be
   fetchable), then `make framework && make mac-framework`. Needs Go 1.26.x on
   `PATH`; the first build is slow.
2. **Auth key.** Stage `~/.aperture-ios-authkey` (or pass `AUTHKEY=…`). The file
   must contain a **single-line `tskey-auth-…` key** (~40–60 chars) that is
   **ephemeral-compatible** (the tests set `APERTURE_EPHEMERAL=1`; create the
   key with the Ephemeral toggle on the admin keys page). Verify it's not
   accidentally a PEM/SSH private key or other credential — a PEM blob staged
   here fails *silently*: the node never reaches `State: Running` and the
   auth-key tests time out with no obvious error. Quick check:
   `head -c1 ~/.aperture-ios-authkey` should print `t` (for `tskey-…`), not
   `-` (for `-----BEGIN …`).
3. **Screen Recording** — System Settings → Privacy & Security → Screen
   Recording → `+` → press ⌘⇧G and enter the responsible-process path (for
   SSH: `/usr/libexec/sshd-keygen-wrapper`; for Terminal: add
   `com.apple.Terminal`) → toggle ON. Needed for `screencapture` /
   `scripts/look.sh --mac`.
4. **Accessibility** — same System Settings panel, add the same responsible
   process, toggle ON. Needed for System Events `click`/`AXPress` and for
   XCUITest to see the app. (For interactive Xcode runs, Xcode itself is the
   responsible process — run one `ApertureMacUITests` test from Xcode's Test
   navigator and approve the prompt.)
5. **Make Automation Mode authorization persistent on a dedicated test Mac.**
   By default, macOS may repeatedly ask an administrator to authorize XCTest UI
   automation, and unattended runs can fail with `Timed out while enabling
   automation mode`. Apple's built-in tool can remove that recurring prompt:
   ```bash
   sudo /usr/bin/automationmodetool enable-automationmode-without-authentication
   /usr/bin/automationmodetool   # verify enabled + authentication not required
   ```
   Log out and back in, or reboot, after changing it. This deliberately lowers
   a macOS UI-automation security barrier, so use it on a dedicated development,
   CI, or lab Mac rather than a general-purpose machine. To restore the default:
   ```bash
   sudo /usr/bin/automationmodetool disable-automationmode-without-authentication
   ```
6. **Clear stale window-restoration state.** A prior crash or an abrupt
   UI-test terminate can leave talagent's per-app `restorecount.plist` non-zero,
   which makes the next native launch block on a "Reopen windows?" modal — and
   under XCUITest that modal is suppressed, so the app comes up with **no
   window** and every test times out at its first `app.windows` wait.
   `scripts/check-mac-automation.sh --fix` clears it. (The app also sets
   `.restorationBehavior(.disabled)`, but a marker left by an older build or a
   real crash still blocks until cleared.) `--fix` clears talagent's
   `restorecount.plist` (in `~/Library/Daemon Containers`) and the app's
   `Saved Application State`, but it does **not** clear AppKit's window-frame
   auto-save in `defaults` — `defaults read io.tailscale.Aperture` may still
   show `NSWindow Frame workspace-AppWindow-1`. That leftover can keep
   `.defaultLaunchBehavior(.presented)` from auto-presenting (it only presents
   "when there is no saved state to restore"); if a launch still shows no
   window after `--fix`, also run
   `defaults delete io.tailscale.Aperture 'NSWindow Frame workspace-AppWindow-1'`.
7. **Stop stale suspended `ApertureMacUITests-Runner` processes** before
   retrying a test aborted from the debugger: `pkill -9 -f ApertureMacUITests-Runner`.
   Stale `Aperture` app processes (same bundle id `io.tailscale.Aperture`) from
   prior runs can also confuse `XCUIApplication().launch()` into attaching to
   the orphan instead of launching fresh; clear them with
   `pkill -9 -f 'Aperture.app/Aperture'` before retrying.

The Mac runner stages the key at `/tmp/aperture-test-authkey`, just like the iOS
runner. `make test-mac-ui AUTHKEY=...` passes a key explicitly; otherwise it
requires `~/.aperture-ios-authkey`.

### Test credentials and normal app isolation

UI tests use a separate persistent state namespace from the normal app. The
same `io.tailscale.Aperture` bundle is used for the native Mac UI tests, so
bundle ID separation alone is not enough: macOS would otherwise let the test
process open and delete the real app's Tailscale state. On iOS, the simulator
app and its UI-test launches likewise share the app container.

`WorkspaceStore` selects these roots when a test launch argument or XCTest
launch environment is present:

- normal iOS: `Application Support/Aperture`
- iOS UI tests: `Application Support/Aperture-UI-Test-iOS`
- normal macOS: `Application Support/Aperture`
- macOS UI tests: `Application Support/Aperture-UI-Test-macOS`

The test roots contain the workspace definitions, Tailscale state files,
bookmarks, tabs, and WebKit data-store identifiers. The reset/logout tests can
therefore delete credentials in the test namespace without logging out the
normal running instance. The namespaces are also platform-specific, so an iOS
simulator test cannot touch native Mac test state.

The embedded tsnet build used here stores its node credentials in the supplied
workspace state directory; Aperture does not currently create a separate
application Keychain item for them. Thus the important isolation boundary is
the state-directory namespace (rather than a Keychain service-name change).
Existing normal state is not migrated or modified. If a test run was already
started before this change, stop it and relaunch once; subsequent `-UITest...`
launches use the test root automatically.

### Troubleshooting: native Mac tests time out at the first `app.windows` wait

When all three `ApertureMacUITests` fail at their first
`app.windows.firstMatch.waitForExistence(timeout: 30)` (~30s in, with
`windows=0`), the native Mac window is **drawn but not exposed to the
Accessibility tree**. XCUITest's `app.windows` reads *only* the AX tree, so it
sees no window and every test times out. This is a known app-level issue,
**not** a permissions problem: Screen Recording and Accessibility are correctly
granted (verify AX works for other apps — `osascript -e 'tell application
"System Events" to get count of windows of (first process whose name is
"Xcode")'` should return a positive number).

Tell it apart from the stale-state issue (step 5) by comparing the window
server against the AX tree of the running Aperture app:

```bash
# AX tree of Aperture — the key discriminator:
osascript -e 'tell application "System Events" to get UI elements of (first process whose name is "Aperture")'
#   AX-exposure bug → "menu bar 1 of application process Aperture"   (menu bar only; NO window)
#   healthy app     → "window 1 of application process Aperture, menu bar 1 …"
```

If AX shows only the menu bar while the window *is* on screen (a `screencapture`
shows it, or a `CGWindowList` call lists an `owner=Aperture` window), the window
is AX-invisible and **no amount of permission/key work will fix the Mac tests**
— it's an app bug in the `ApertureMac` window/scene setup (see
`MacApp/ApertureMacApp.swift`, `WorkspaceWindowRoot`, and the value-based
`WindowGroup` + `.defaultLaunchBehavior(.presented)` /
`.restorationBehavior(.disabled)` modifiers). The iOS leg is unaffected (iOS
SwiftUI windows expose AX fine and the sim signs ad-hoc), so `make test-ios-ui`
runs independently of this.

## iOS UI test target (`ApertureUITests`)

### What it is

A real XCUITest target (`com.apple.product-type.bundle.ui-testing`) added by hand
to `project.pbxproj`. The reproducible edits live in
`scripts/add_uitest_target.py` — run it once on a fresh checkout to recreate the
target (it's idempotent and aborts if the target already exists).

- Sources: `UITests/`, a `PBXFileSystemSynchronizedRootGroup` (same mechanism as
  `App/` and `TSNet/`). New `.swift` files dropped in `UITests/` are
  **auto-compiled** into the test target — no `project.pbxproj` editing.
- Depends on the `Aperture` app target (`TestTargetID = Aperture`).
- Wired into the `Aperture` scheme's Test action, so `xcodebuild test … -scheme
  Aperture` picks it up.

### Running

```bash
# Boots a sim, builds for testing, runs tests, captures libtailscale logs to
# build/uitest-logs/<timestamp>/{combined,unified,tsnet-stdout}.log:
scripts/run-uitests.sh

# Skip the build (reuse a prior build-for-testing):
scripts/run-uitests.sh --no-build

# Pick a different simulator:
scripts/run-uitests.sh "iPhone 17 Pro"

# Raw xcodebuild (no log capture):
xcodebuild test -project Aperture.xcodeproj -scheme Aperture \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData
```

### What the current tests cover

The app's root is a Safari-style multi-tab browser. Until the tailnet first
reaches `Running` it shows a **connection gate** (brand header + "Tailscale
Status" + Login); once connected it switches to the **tabbed browser**. Tests
split accordingly:

Connection-independent (run on any sim; use the `-UITestResetLogin` launch arg
to clear persisted node creds so they always start at the gate, even after a
prior connected test logged the sim in):

- `testAppLaunchesAndShowsStatus` — the gate's brand header
  (`aperture-brand-header`) + "Tailscale Status" section appear.
- `testOpenAndCloseSettings` — tap the gear → "Settings" → Done → back at the
  root (verified via the gear becoming hittable again — it's in both the gate
  and the browser).
- `testHomePageSettingPersistsAcrossSettingsReopen` — hermetic Home-Page
  persistence across a `terminate()` + `launch()` (see the test's doc comment).

Connected (require a working tailnet connection; authenticate via an auth key —
see below — and otherwise **fail** so a broken connection is never silently
green):

- `testHomePageLoadsWhenConnected` — the first tab (always an Aperture chat =
  the home page) auto-loads; confirm the WKWebView appears and the URL field
  shows the home page URL.
- `testOpenAndCancelAddBookmark` — the browser toolbar's bookmark button opens
  the "New Bookmark" editor; Save is disabled on empty fields; Cancel returns
  to the browser.
- `testOpenNewChatTab` — the "+" opens a new chat tab; the tab-overview button
  opens the "Tabs" grid.

Interactive login (connected, but does **NOT** use an auth key — it drives the
real `ASWebAuthenticationSession` web-auth flow against the public control
plane + the `testuser@nullid.fly.dev` null identity provider; needs network
reach to controlplane/login.tailscale.com + nullid.fly.dev):

- `testInteractiveLoginLogoutRelogin` — the full Login → Logout → Relogin
  cycle: tap the gate's Login button, type `testuser@nullid.fly.dev` in the
  Tailscale login sheet, submit, confirm on the nullid page, authorize the
  device on the "Connect" page, then verify the browser comes up; open
  Settings (via the compact browser's More menu), tap the red Logout button,
  confirm the alert, verify the `LoginBanner` appears; tap it and re-login,
  verifying the banner clears. Exercises the real interactive auth path, the
  Settings logout, and the post-logout relogin — none of which the auth-key
  connected tests touch.

  Notes: the auth sheet's web content is out-of-process, so XCUITest can't see
  it right away — there's a 10–30s accessibility-bridging lag before
  `app.webViews.textFields` / `app.webViews.buttons` surface it (the test uses
  generous timeouts). The "Connect" button's a11y label is "Connect device to
  tailnet", not "Connect". This test also depends on a `StatusViewModel` fix
  (clearing a stale `browseToURL` after login) so that post-logout relogin
  requests a fresh auth URL instead of reusing a stale one.

  **macOS difference (the interactive Mac test cannot use `app.webViews`):**
  on macOS `ASWebAuthenticationSession` does NOT present an in-process web
  view the way iOS does — per Apple's docs it opens the user's **default
  browser (Safari) as a separate process**. `app.webViews` queries Aperture's
  process, so it will never see the login form (it lives in Safari). The iOS
  `app.webViews.textFields` approach is therefore not portable to the Mac
  test as written; it would need to drive Safari via a separate
  `XCUIApplication(bundleIdentifier: "com.apple.Safari")`, which is fragile,
  or use a non-web-auth path. The auth itself no longer crashes on macOS (the
  `AuthManager.makeCompletion` nonisolated closure fixed the `EXC_BREAKPOINT`
  that happened when AuthenticationServices called a MainActor-isolated
  completion on its XPC queue).

### Automating login with an auth key (`AUTHKEY`)

The auth key is required for the auth-key-connected tests, but it does **not**
disable or replace either platform's required interactive nullid test. A full
suite exercises both authentication mechanisms.

`testHomePageLoadsWhenConnected` and the other connected tests can log a fresh
simulator into a Tailnet non-interactively instead of showing the "Login"
button, so the whole suite runs green on a sim with no prior interactive
login. Auth-key resolution order:

1. `make test AUTHKEY=tskey-auth-...` (Makefile var → `APERTURE_TEST_AUTHKEY`).
2. `APERTURE_TEST_AUTHKEY` env var seen by `run-uitests.sh`.
3. `~/.aperture-ios-authkey` file (the default local-dev fallback).

```bash
make test                                # auto-stages ~/.aperture-ios-authkey if present
make test AUTHKEY=tskey-auth-...        # explicit key
```

If **none** of those is available, connected tests **fail** after the
connection timeout—by design, so a missing/broken key is loud rather than a
silent green suite.

The app reads the key from the `APERTURE_AUTHKEY` env var (or `-AuthKey`
launch arg) and authenticates on `up()`; `APERTURE_EPHEMERAL`/`-Ephemeral`
marks the node ephemeral (auto-cleanup). See `TSNetManager.launchAuthKey`.

**Why a file, not just an env var:** `xcodebuild` does **not** forward
arbitrary parent-shell env vars to the UI-test runner process, so the test
can't read `APERTURE_TEST_AUTHKEY` from its own `ProcessInfo.environment`.
`scripts/run-uitests.sh` (a shell script, which *does* see the env) stages the
key to `/tmp/aperture-test-authkey` (overridable via `APERTURE_TEST_AUTHKEY_FILE`)
and cleans it up on exit; the test reads that file
(`ApertureUITests.resolvedTestAuthKey`) and forwards it to the app via
`launchEnvironment`. `APERTURE_TEST_EPHEMERAL` (default `"1"`) controls
ephemerality and must match the key's type on the admin side.

### Do the tests use screenshots / vision?

The tests **attach screenshots** to the test results (via `XCTAttachment` /
`app.screenshot()`) on both success and failure paths — e.g. the connected test
attaches `page-loaded` / `page-load-failed` / `not-connected` / `no-webview`.
Those land in the `.xcresult` and are viewable in Xcode's Report navigator or
via `xcrun xcresulttool`.

The tests do **not** invoke the vision sub-pi (`scripts/look.sh` / `gpt-4.1-nano`)
at runtime — XCTest can't shell out to `pi` mid-test, and vision reads are slow /
non-deterministic. Vision is a **manual / agent-driven** verification tool: *you*
(or the agent) run `make look Q="…"` after a test run to visually confirm what
the screenshot shows. The tests assert on native XCUITest signals (element
existence, hittability, the nav-bar URL text field value) instead.

If you want a test that *does* verify pixels, the right approach is a reference
snapshot test (e.g. `swift-snapshot-testing` or Xcode's built-in `XCTAttachment`
reference-image comparison) — not an LLM vision call. That's a future addition.

They find buttons via `accessibilityIdentifier`s added to the app's icon-only
buttons (`settings-button`, `add-bookmark-button`, `settings-done-button`,
`bookmark-cancel-button`, `bookmark-save-button`). Add more identifiers as you
wire up tests for new flows.

The test class is `@MainActor` (the project is Swift 6 / `MainActor`-default
isolated, and the XCUITest APIs are main-actor). XCTest's `setUp`/`tearDown`
overrides stay nonisolated, so don't touch XCUITest APIs there — do it in the
`@MainActor` test methods.

### The `libtailscale` submodule's own tests (separate)

```bash
cd ThirdParty/libtailscale/swift && make test   # macOS-side TailscaleKitXCTests
```

---

## Capturing libtailscale logs

`TSNet/Logging.swift` routes every libtailscale message to **both**:

- `print("tsnet: …")` — the app's stdout (captured by `xcodebuild` for unit tests,
  but **not** surfaced by the UI-test runner, so it's unreliable for UI tests), and
- `os_log(...)` under subsystem `io.tailscale.Aperture`, category `tsnet` —
  Apple's unified logging system, which **is** reliably captured by `log stream` /
  `log show` / Console.app. This is the authoritative source for UI tests.

`log` is `nonisolated` (libtailscale calls it from its Go-backed threads, off the
main actor); it touches only `nonisolated` `Sendable` globals, so it's
concurrency-safe under the project's strict-concurrency setting.

### Stream live

```bash
# While the app runs in the booted simulator:
xcrun simctl spawn booted log stream \
  --predicate 'subsystem == "io.tailscale.Aperture"' --level debug
```

### Read captured logs from a test run

`scripts/run-uitests.sh` writes to `build/uitest-logs/<timestamp>/`:

- `unified.log` — the streamed OSLog (the authoritative libtailscale log source).
- `combined.log` — full `xcodebuild` output.
- `tsnet-stdout.log` — `tsnet:` lines grepped from `combined.log` (usually empty
  for UI tests; kept as a fallback).

### The critical transitions to watch for

These are the libtailscale state changes that tell you what the node is doing:

```
Foreground: Reconnecting...
Tailscale starting: <pid>
Bringing Tailscale up :<port>
State: NeedsLogin
Authenticate at: https://login.tailscale.com/a/<token>
State: Running
```

`State: NeedsLogin` + `Authenticate at:` are the signals that interactive login is
required; `State: Running` means the tailnet is up and the WebKit proxy can reach
tailnet nodes.

---

## Run destinations — what works where

There are now two products. Do not confuse the iOS scheme's compatibility
run destination with the native Mac scheme:

| Scheme | Destination | Product |
|---|---|---|
| `Aperture` | iOS Simulator / iPhone / iPad | shipping iOS/iPadOS app |
| `Aperture` | My Mac (Designed for iPad) | compatibility run of the iOS app; not the native Mac app |
| `ApertureMac` | My Mac | native macOS app with the Virtualization entitlement |

| Capability | iOS Simulator | Native `ApertureMac` |
|---|---|---|
| Build from CLI | ✅ no signing required | ✅ `make mac-app` unsigned or `make mac-app-signed` |
| Run | ✅ `simctl install` + `simctl launch` | ✅ Xcode/Finder/direct launch when signed; smoke script ad-hoc signs |
| Screenshot | ✅ `simctl io` without TCC | ✅ `screencapture` once Screen Recording is granted to the shell's responsible process |
| UI automation | ✅ XCUITest | ✅ `ApertureMacUITests`, requires logged-in GUI + Automation/Accessibility approval |

**For autonomous visual work, prefer the simulator.** Native Mac builds and
process smoke tests can run headlessly, but native Mac XCUITest and screenshots
are GUI/TCC-dependent.

Build the native Mac target explicitly:

```bash
make mac-app
# equivalent:
xcodebuild build -project Aperture.xcodeproj -scheme ApertureMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedDataMac CODE_SIGNING_ALLOWED=NO
```

### Driving macOS UI from a headless / SSH session

Once `scripts/check-mac-automation.sh` is green, a non-vision agent can capture
**and drive** the native Mac UI from an SSH session. The non-obvious parts:

- **`screencapture` works from SSH** once Screen Recording is granted to the
  responsible process (`/usr/libexec/sshd-keygen-wrapper` for SSH; see the
  preflight script, which detects it). Capture to a file and either attach it
  to a vision sub-pi (below) or read the PNG.
- **`CGEventPost` (synthetic HID clicks) does NOT deliver from SSH** — the
  events are silently dropped even with Accessibility granted. Use **System
  Events `click <element>`** instead, which performs `AXPress` via the trusted
  System Events process and works from SSH.
- **Clicking a control with no readable `name`.** Image-only buttons (e.g. the
  gate's gear) report `name = missing value` to System Events, so you can't
  click by name. `entire contents` is flaky (it races the gate's ~5s status
  re-render). Instead traverse the stable structure: the window's first UI
  element is the content group, and the gear is its second child:
  ```bash
  osascript -e 'tell application "System Events" to click \
    (UI element 2 of (UI element 1 of window 1 of \
    (first process whose name is "Aperture")))'
  ```
- **The native app opts out of window restoration** (`.restorationBehavior(.disabled)`)
  so launches are deterministic. If an old build or a real crash left
  talagent's `restorecount.plist` non-zero, the next launch blocks on a
  "Reopen windows?" modal (suppressed under XCUITest → no window → tests
  timeout). `scripts/check-mac-automation.sh --fix` clears it.
- **Reading a screenshot.** pi's main model may not ingest images; describe a
  captured PNG with a vision sub-pi: `pi --provider aperture --model
  gpt-4.1-nano -p @/tmp/shot.png "describe the UI"` (see *Vision* below).

---

## Vision — letting a non-vision agent "see" the app

pi's main model may not ingest images, but a vision-capable model can be spawned as
a one-shot **sub-pi** to describe screenshots.

### Setup (one-time)

`~/.pi/agent/models.json` declares image-capable models under
`providers.aperture.modelOverrides`. Example:

```json
{"providers":{"aperture":{"modelOverrides":{
  "gpt-4.1-nano": {"input": ["text","image"]},
  "gpt-4.1-mini": {"input": ["text","image"]},
  "gpt-4.1":      {"input": ["text","image"]},
  "gpt-4o-mini":  {"input": ["text","image"]}
}}}}
```

### Model choice

**`gpt-4.1-nano`** is recommended: newer and cheaper than `gpt-4o-mini` ($0.10 vs
$0.15 /M input; $0.40 vs $0.60 /M output) and confirmed working through the
`ai`/aperture proxy. Avoid `gpt-5-nano` for vision — its reasoning overhead returns
empty content at low `max_completion_tokens` budgets.

The `ai` proxy's `/v1/models` endpoint does **not** report input modalities, so the
`models.json` override is how pi learns a model takes images. Re-check with
`pi --list-models <id>` (look for `images: yes`).

### Use it

```bash
# Helper: screenshot the booted sim + ask a vision sub-pi about it
scripts/look.sh "list the buttons and where they are"
# --mac targets the Mac display instead (needs Screen Recording)

# Raw sub-pi:
pi --provider aperture --model gpt-4.1-nano -p @/path/to/screenshot.png "describe the UI"
```

Verified end-to-end: a sim screenshot was correctly read as "Aperture" nav bar,
"Login Required" status, a Login button, a gear icon, and Edit/+ buttons — matching
the libtailscale `State: NeedsLogin` log line emitted at the same time.

---

## xcodebuild CLI vs Xcode MCP tools

**Prefer CLI `xcodebuild` / `simctl` for simulator build / test / see / poke.** It is
destination-explicit and deterministic, and does not depend on Xcode's GUI
run-destination. The MCP `BuildProject` / `RunAllTests` use **whatever scheme and destination
Xcode's dropdown is set to**. For Mac tests select `ApertureMac` + `My Mac`; for
iOS tests select `Aperture` + an iOS simulator. `RunSomeTests` has successfully
run native Mac tests after Automation Mode approval, but it is still tied to the
open Xcode workspace's destination.

Keep the MCP tools for the things they're good at and that don't need a
destination:

- Project file edits: `XcodeRead` / `XcodeWrite` / `XcodeUpdate` / `XcodeRM` /
  `XcodeMV` / `XcodeMakeDir` / `XcodeLS` / `XcodeGrep` / `XcodeGlob`
- Live diagnostics: `XcodeRefreshCodeIssuesInFile`, `XcodeListNavigatorIssues`
- SwiftUI previews: `RenderPreview`
- In-file code snippets (builds + runs a snippet in a file's context):
  `RunCodeSnippet`
- Apple documentation search: `DocumentationSearch`
- Current file / window info: `XcodeGetCurrentFile`, `XcodeListWindows`

---

## Xcode MCP server setup (optional)

pi has no built-in MCP client, so a global pi extension at
`~/.pi/agent/extensions/xcode-mcp.ts` bridges to Apple's Xcode MCP server
(`xcrun mcpbridge`, shipped with Xcode 26.x). It spawns the bridge over stdio,
speaks JSON-RPC 2.0, and re-exposes every Xcode tool as a pi tool named
`xcode_<tool>` (plus `xcode_mcp_connect` / `xcode_mcp_status` and a `/xcode-mcp`
command). The bridge is connected lazily and kept alive for the session.

### One-time + per-connection setup (Apple requires a GUI click)

1. Xcode → Settings → Intelligence → Model Context Protocol → turn ON
   "Allow external agents to use Xcode tools".
2. Open this project in Xcode (the bridge needs a running Xcode with a project).
3. Run `/xcode-mcp` (or call `xcode_mcp_connect`) in pi. Xcode shows an approval
   banner — click **Allow**. Each raw `xcrun mcpbridge` connection prompts once;
   the extension keeps one connection alive for the whole session to minimize
   prompts.

In a fully headless/SSH context you can't click the banner, so `tools/list` /
`tools/call` time out until someone approves in the Xcode GUI. You don't need the
MCP server for headless builds/tests — `xcodebuild` / `simctl` /
`scripts/run-uitests.sh` work without it.

### Diagnosing connection issues

```bash
# Minimal probe — reports which JSON-RPC step stalls, with timings:
python3 scripts/probe-xcode-mcp.py
python3 scripts/probe-xcode-mcp.py --timeout 30
python3 scripts/probe-xcode-mcp.py --pid <xcode-pid>
```

Interpreting the probe:
- `initialize` fails → `xcrun mcpbridge` can't run / no Xcode reachable.
- `initialize OK`, `tools/list` hangs → Xcode is gating tool access. If **no
  banner** appears, the Intelligence→MCP toggle is likely off, or no project is
  open, or you're attaching to the wrong Xcode PID.
- `tools/list` returns → fully working; prints the tool count + names.

---

## Scripts reference

| Script | Purpose |
|---|---|
| `scripts/add_uitest_target.py` | One-shot: add the `ApertureUITests` target to `project.pbxproj` (idempotent). |
| `scripts/run-uitests.sh` | Build + run every required iOS UI test on the simulator, capturing logs to `build/uitest-logs/<ts>/`. |
| `scripts/run-mac-uitests.sh` | Stage the required auth key and run every native Mac UI test. |
| `scripts/test-mac-foundation.sh` | Build/ad-hoc-sign the native app, verify virtualization entitlement, and launch-smoke-test it. |
| `scripts/look.sh` | Screenshot the booted simulator (or `--mac` display) + describe it with a vision sub-pi. |
| `scripts/check-mac-automation.sh` | Preflight: verify the macOS permissions (Screen Recording + Accessibility for the SSH/Terminal responsible process) and prerequisites (frameworks, auth key, simulator) needed for autonomous Mac UI automation; `--fix` clears stale talagent window-restoration state. |
| `scripts/probe-xcode-mcp.py` | Minimal probe of the Xcode MCP server (`xcrun mcpbridge`); reports which JSON-RPC step stalls. |
