# Aperture

A small WebKit-based iOS browser that proxies all requests through an embedded,
userspace Tailscale node ([TailscaleKit](https://github.com/tailscale/libtailscale) /
`libtailscale`). Browse URLs on your Tailnet **without** running the system VPN.

## Supported platforms

- **iOS only.** The app target's `SDKROOT` is `iphoneos`; there is no macOS target.
- **iPhone and iPad** (`TARGETED_DEVICE_FAMILY = 1,2`).
- **Deployment target: iOS 26.0.** You need the iOS 26 SDK (ships with Xcode 26.x).

## Requirements

- **Xcode 26.x** (project uses Xcode synchronized folder groups and the iOS 26 SDK).
- **iOS 26.0 SDK** (included with Xcode 26).
- **Go 1.26.3** — only needed to build the embedded `TailscaleKit.xcframework`
  dependency (see `ThirdParty/libtailscale/go.mod`). You do **not** need Go to build
  the app itself once the framework exists.
- `git` (for the `libtailscale` submodule).
- Optional: `xcpretty` for nicer `xcodebuild`/`make` output (the Makefiles fall back
  to `cat` if it is missing).

## First-time setup & building

The app embeds `TailscaleKit.xcframework`, which is **not checked into git** —
it's built from the `libtailscale` submodule. The top-level **Makefile** handles
the whole flow: fetch the submodule, build the xcframework, then build the app.

```bash
# 1. Fetch the libtailscale submodule (one-time)
$ git submodule update --init

# 2. Build everything (libtailscale xcframework + app for the simulator)
$ make
```

`make` skips rebuilding the xcframework if it already exists. The libtailscale
build needs **Go 1.26.3** and the iOS SDK, and is slow the first time; the app
build needs **Xcode 26.x**. Run `make help` to see all targets:

| Target | What it does |
|---|---|
| `make` (aka `make all`) | Build the xcframework (if missing) + the app for the simulator |
| `make test` | `make all`, then run the UI tests on the simulator (with log capture) |
| `make look` | Screenshot the booted sim + describe it with a vision sub-pi (`make look Q="describe the UI"`) |
| `make framework` | Build just the `TailscaleKit.xcframework` |
| `make app` | Build just the app (depends on `framework`) |
| `make ipa` | Archive + export a dev-signed `.ipa` for a real iOS device (needs an unlocked keychain; prompts or aborts — see [Installing on a real device](#installing-on-a-real-device)) |
| `make clean` | Remove app build artifacts (keeps the xcframework) |
| `make clean-all` | Also remove the libtailscale build artifacts |

Pick a different simulator with `SIM_NAME=`:

```bash
$ make test SIM_NAME="iPad (A16)"
```

### From Xcode

Open `Aperture.xcodeproj` in Xcode 26.x and build the **Aperture** scheme
(⌘B). Pick an iOS 26 simulator or a provisioned device.

### Raw xcodebuild (without make)

Simulator builds do not require code signing:

```bash
$ xcodebuild build \
    -project Aperture.xcodeproj -scheme Aperture \
    -configuration Debug \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -derivedDataPath build/DerivedData
```

List available simulators with `xcrun simctl list devices available`.

For a device build (`-destination 'generic/platform=iOS'` or a specific device ID),
automatic code signing is configured for development team `W5364U7YZB`, so you need a
matching signing identity and provisioning profile, and the keychain must be unlocked.
In headless/CI contexts where signing is unavailable, you can produce a non-installable
build by passing `CODE_SIGNING_ALLOWED=NO`:

```bash
$ xcodebuild build \
    -project Aperture.xcodeproj -scheme Aperture \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO
```

(Note: a real device install still requires signing; `CODE_SIGNING_ALLOWED=NO` only
gets you a built `.app` that cannot be installed onto a device.)

### Installing on a real device

`make ipa` archives a Release build for `generic/platform=iOS` and exports a
development-signed `.ipa` (`build/ipa/Aperture.ipa`) suitable for installing on
an iPhone/iPad registered with team `W5364U7YZB`. The device **must run iOS 26**
(the deployment target).

```bash
$ make ipa            # → build/ipa/Aperture.ipa
```

The embedded `TailscaleKit.framework` is re-signed on copy, so the build needs a
valid signing identity and an **unlocked** login keychain. `make ipa` runs
`scripts/unlock-keychain.sh` first: if the keychain is already unlocked (e.g. a
local GUI session, where it's unlocked at login) it's a silent no-op; if it's
locked and you're in an interactive terminal it prompts for your login password;
if it's locked and stdin isn't a terminal (piped/CI) it aborts with a clear error
instead of hanging. The keychain re-locks on reboot, so re-unlock once per SSH
session.

To install: copy `build/ipa/Aperture.ipa` to a Mac with Xcode 26, plug the device
in, and either drag the `.ipa` onto the device in **Xcode → Window → Devices and
Simulators**, or run:

```bash
$ xcrun devicectl device install app --device <udid-or-name> build/ipa/Aperture.ipa
```

The device's UDID must be registered with team `W5364U7YZB` (plug it into a Mac,
open Xcode → Devices and Simulators, and let it enable the device for
development); once registered, automatic signing on the build host picks it up.

## Tests & UI automation

There is a **UI test target**, `ApertureUITests` (XCUITest), whose sources live
in `UITests/`. The current tests are connection-independent smoke tests (launch,
open Settings, open the Add-Bookmark editor) — no Tailnet login needed. There is
also a `testHomePageLoadsWhenConnected` test that **skips** on a sim that isn't
logged into a Tailnet and **runs** on one that is (e.g. the iPad sim).

```bash
# Easiest — builds everything then runs the UI tests with log capture:
$ make test

# Or directly:
$ scripts/run-uitests.sh
$ xcodebuild test -project Aperture.xcodeproj -scheme Aperture \
    -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
    -derivedDataPath build/DerivedData
```

The `libtailscale` submodule has its own separate tests:

```bash
$ cd ThirdParty/libtailscale/swift
$ make test        # macOS-side TailscaleKitXCTests
```

Capturing libtailscale logs, letting a non-vision agent "see" the app via a
vision sub-pi (`scripts/look.sh`), the run-destination matrix (simulator vs
"My Mac (Designed for iPad)"), the optional Xcode MCP server, and a full scripts
reference are all documented in **[README.ui-automation.md](README.ui-automation.md)**.

## Cleaning up

```bash
$ make clean        # app build artifacts (keeps the xcframework)
$ make clean-all    # also the libtailscale artifacts
# or the raw commands:
#   rm -rf build/DerivedData
#   cd ThirdParty/libtailscale/swift && make clean
```

## Project layout

```
App/                      SwiftUI app sources (synchronized folder group)
  ApertureApp.swift     @main App, owns the TSNetManager + SwiftData container
  MainView.swift          Top-level UI
  Browser/                WebKit browser view/view-model/navigator
  Boomarks/               SwiftData-backed bookmarks (note: dir is spelled "Boomarks")
  Settings/               Hostname / tailnet settings
  Tailnet Status/         Local-API-backed status view
TSNet/                    Wrapper layer over TailscaleKit
  TSNetManager.swift      Owns the TailscaleNode, lifecycle, LocalAPI plumbing
  TSNetModel.swift        Observable tailnet status model
  AuthManager.swift       Auth-key / interactive-login handling
  Logging.swift           Logger
Aperture/Info.plist    ATS exceptions (NSAllowsArbitraryLoads) so WebKit can load
                          tailnet HTTP / self-signed nodes
Makefile                 Top-level build/test entry point (make, make test, make look, ...)
UITests/                 XCUITest UI tests (synchronized folder group -> ApertureUITests)
scripts/
  add_uitest_target.py    One-shot script that added the UI test target to project.pbxproj
  run-uitests.sh          Build + run UI tests on the simulator, capturing libtailscale logs
  probe-xcode-mcp.py      Minimal probe of the Xcode MCP server (xcrun mcpbridge)
  look.sh                 Screenshot the sim/Mac + describe it with a vision sub-pi
ThirdParty/libtailscale/  git submodule -> github.com/tailscale/libtailscale
  swift/build/...         Generated TailscaleKit.xcframework (NOT in git; build it)
```
