# Aperture

A small WebKit-based iOS browser that reaches your Tailnet through an embedded,
userspace Tailscale node ([TailscaleKit](https://github.com/tailscale/libtailscale) /
`libtailscale`). Browse URLs on your Tailnet **without** running the system VPN.

## How traffic is routed (split tunnel)

Only **tailnet** destinations go through the embedded node's SOCKS5 proxy:

| destination | route |
| --- | --- |
| Tailnet IPs (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) | via the tsnet proxy |
| MagicDNS names — `http://nas/`, `https://nas.your-tailnet.ts.net/` | via the tsnet proxy |
| Everything else (`https://google.com/`, …) | **direct**, like any other app |

This is least-privilege (your public browsing never traverses the tailnet node)
and it is also required for correctness: routing public traffic through a proxy
that resolves names proxy-side made **every** non-tailnet URL fail with an
"invalid URL" error (`NSURLErrorDomain -1000`) on some hardware. TLS is
unaffected either way — certificates are still validated normally end-to-end.

See **Settings → Routing** in the app to view the live rules and test any host,
`TSNet/TailnetProxyPolicy.swift` for the implementation, and
`scripts/proxy-semantics/README.md` for how the behaviour was measured.

## Supported platforms

- **iPhone and iPad** (`TARGETED_DEVICE_FAMILY = 1,2`), deployment target iOS 26.0.
- **Native macOS foundation**, deployment target macOS 26.0. The `ApertureMac`
  target builds and launches the shared browser/workspace implementation using
  native AppKit WebKit bridges. Desktop-specific UI polish is in progress; see
  [`TODO.mac.md`](TODO.mac.md).
- The native Mac app is sandboxed and already carries the
  `com.apple.security.virtualization` entitlement for a future pure-Linux guest.
  It contains **no virtualization implementation yet**.

## Requirements

- **Xcode 26.x** (project uses Xcode synchronized folder groups and the iOS/macOS 26 SDKs).
- **iOS 26.0 and macOS 26.0 SDKs** (included with Xcode 26).
- **Go 1.26.5** — only needed to build the embedded `TailscaleKit.xcframework`
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
build needs **Go 1.26.5** and the iOS SDK, and is slow the first time; the app
build needs **Xcode 26.x**. Run `make help` to see all targets:

| Target | What it does |
|---|---|
| `make` (aka `make all`) | Build the xcframework (if missing) + the app for the simulator |
| `make test` | Run the complete required suite: policy checks, all iOS UI tests, Mac smoke/entitlement check, and all native Mac UI tests |
| `make test-policy` | Split-tunnel routing unit tests (~2s, host-only — no simulator or xcframework needed) |
| `make look` | Screenshot the booted sim + describe it with a vision sub-pi (`make look Q="describe the UI"`) |
| `make framework` | Build just the iOS `TailscaleKit.xcframework` |
| `make app` | Build just the iOS simulator app (depends on `framework`) |
| `make mac-framework` | Build native macOS `TailscaleKit.framework` |
| `make mac-app` | Build the native macOS app unsigned |
| `make mac-app-signed` | Apple Development-sign the native Mac app and verify its virtualization entitlement |
| `make test-mac` | Build, ad-hoc sign, verify the virtualization entitlement, and launch-smoke-test the native Mac app |
| `make build-mac-uitests` | Compile all native Mac UI tests without running them |
| `make test-mac-ui` | Run every required native Mac UI test, including nullid login/logout/relogin |
| `make ipa` | Archive + export a dev-signed `.ipa` for a real iOS device (needs an unlocked keychain; prompts or aborts — see [Installing on a real device](#installing-on-a-real-device)) |
| `make clean` | Remove app build artifacts (keeps the xcframework) |
| `make clean-all` | Also remove the libtailscale build artifacts |

Pick a different simulator with `SIM_NAME=`. This changes the iOS leg of the
complete suite; the native Mac leg still runs on the local Apple-silicon Mac:

```bash
$ make test SIM_NAME="iPad (A16)"
```

### From Xcode

Open `Aperture.xcodeproj` in Xcode 26.x. Build the **Aperture** scheme for iOS
or **ApertureMac** for native macOS. Pick an iOS 26 simulator/provisioned device
for the former or My Mac for the latter.

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

There are two XCUITest targets:

- **`ApertureUITests`** (`UITests/`) runs on an iOS simulator.
- **`ApertureMacUITests`** (`MacUITests/`) runs against the native Mac app and
  covers native workspace windows, auth-key login/logout, and the complete
  interactive nullid login → logout → relogin flow.

Every test is required: there are no skip paths. The full environment therefore
needs a compatible ephemeral auth key, a working exit-node peer, network access
to Tailscale's control plane and `nullid.fly.dev`, the simulator software
keyboard configuration used by keyboard tests, and macOS Automation permission.
See [`README.ui-automation.md`](README.ui-automation.md) for exact setup.

```bash
# Complete required suite (iOS + native Mac):
$ make test
$ make test AUTHKEY=tskey-auth-...   # explicit key alternative

# Individual required legs:
$ make test-policy
$ make test-ios-ui
$ make test-mac       # native build/entitlement/launch smoke check
$ make test-mac-ui    # all native Mac XCUITests, including nullid

# Compile Mac UI tests without claiming to run them:
$ make build-mac-uitests
```

Stage the normal local key at `~/.aperture-ios-authkey`. Both UI runners copy it
to `/tmp/aperture-test-authkey` because sandboxed XCTest runners don't reliably
inherit shell environment variables or the login user's home directory.

The `libtailscale` submodule has its own separate tests:

```bash
$ cd ThirdParty/libtailscale/swift
$ make test        # macOS-side TailscaleKitXCTests
```

Capturing libtailscale logs, letting a non-vision agent "see" the app via a
vision sub-pi (`scripts/look.sh`), the iOS simulator / iOS-on-Mac / native-Mac
run-destination matrix, native Mac permission setup, the optional Xcode MCP
server, and a full scripts reference are all documented in
**[README.ui-automation.md](README.ui-automation.md)**.

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
  ApertureApp.swift     @main App, owns the WorkspaceManager
  Workspace/            Workspace + WorkspaceManager + on-disk workspace store
  Browser/              WebKit browser view/view-model/navigator
  Bookmarks/            SwiftData-backed bookmarks (per-workspace) + HomePage
  Settings/             Hostname / home page / exit-node / logout (per active workspace)
  Tailnet Status/         Local-API-backed status view
TSNet/                    Wrapper layer over TailscaleKit
  TSNetManager.swift      Owns the TailscaleNode, lifecycle, LocalAPI plumbing
  TSNetModel.swift        Observable tailnet status model
  TailnetProxyPolicy.swift  Split tunnel: which hosts go via the SOCKS proxy vs DIRECT
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
  test-proxy-policy.sh    Split-tunnel routing unit tests (make test-policy)
  proxy-semantics/        SOCKS5 + WebKit harnesses used to measure proxy behaviour
ThirdParty/libtailscale/  git submodule -> github.com/tailscale/libtailscale
  swift/build/...         Generated TailscaleKit.xcframework (NOT in git; build it)
```

