# UI automation & agent tooling

How to build, run, see, poke, and read logs from Aperture — with an emphasis
on what works **autonomously** (no GUI clicks, no permission prompts) versus
what needs a human in the loop.

This file is the deep dive. `README.md` and `CLAUDE.md` keep only short pointers
to it so the always-in-context docs stay small.

## TL;DR — the autonomous loop (simulator)

The top-level **Makefile** wraps the common flow. Everything below works
headlessly over SSH with **zero permission grants**:

```bash
make            # build everything (libtailscale xcframework + app for sim)
make test       # build, then run UI tests on the sim (with log capture)
make look Q="describe the UI"   # screenshot sim + vision-describe it
```

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

## UI test target (`ApertureUITests`)

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

### Automating login with an auth key (`AUTHKEY`)

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

If **none** of those is available, connected tests **fail** (they no longer
skip) after the connection timeout — by design, so a missing/broken key is
loud rather than a silent green suite.

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

The app has two runnable destinations. What an agent in a headless/SSH context can
actually do differs sharply between them:

| | Simulator | My Mac (Designed for iPad) |
|---|---|---|
| Build (CLI) | ✅ | ✅ with `CODE_SIGNING_ALLOWED=NO` (`-destination 'name=My Mac'`) |
| Run | ✅ `simctl install` + `simctl launch` | ❌ headless — the product is an iOS-platform binary (`LC_BUILD_VERSION` platform 2) that `open` refuses even when ad-hoc signed; direct exec gets `Killed: 9`. Only Xcode's private iOS-on-macOS launcher (or a Finder double-click of a properly-signed build) can start it. Run it from the Xcode GUI. |
| See (screenshot) | ✅ `simctl io booted screenshot` (no permission needed) | ❌ `screencapture` needs Screen Recording TCC — grant it in System Settings → Privacy & Security → Screen Recording. Note: over SSH, TCC sometimes won't attribute `screencapture` correctly; it's been observed to work only from a local Terminal, not an SSH session. |
| Poke the UI | XCUITest (there is no `simctl tap`) | `osascript` System Events can click by AX identifier — but needs Accessibility granted to `osascript`, and only useful when the app is running + visible |

**For autonomous agent work, use the simulator** — it's the only path where
build/run/see/poke all work without permission grants. The "My Mac (Designed for
iPad)" target is user-driven in Xcode.

Build the Mac target from CLI (non-installable) with:

```bash
xcodebuild build -project Aperture.xcodeproj -scheme Aperture \
  -configuration Debug -destination 'name=My Mac' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

A future "normal Mac" (macOS/Catalyst) target would lift these headless limits,
but that's not today.

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

**Prefer CLI `xcodebuild` / `simctl` for build / test / see / poke.** It is
destination-explicit and deterministic, and does not depend on Xcode's GUI
run-destination. The MCP `BuildProject` / `RunAllTests` use **whatever destination
Xcode's dropdown is set to** — when that's a device/Mac target, UI tests report
`No result` / `TEST FAILED` because they have nowhere to run (seen in practice;
the build itself succeeds but the test execution step has no destination).

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
| `scripts/run-uitests.sh` | Build + run UI tests on the simulator, capturing libtailscale logs to `build/uitest-logs/<ts>/`. |
| `scripts/look.sh` | Screenshot the booted simulator (or `--mac` display) + describe it with a vision sub-pi. |
| `scripts/probe-xcode-mcp.py` | Minimal probe of the Xcode MCP server (`xcrun mcpbridge`); reports which JSON-RPC step stalls. |
