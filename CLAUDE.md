# CLAUDE.md

Working notes for AI coding agents (and humans) on this repo. Read alongside
`README.md`, which has the full build/setup instructions. This file captures the
non-obvious things that are easy to get wrong.

## What this is

An iOS-only SwiftUI browser (WebKit) that routes traffic through an embedded
userspace Tailscale node (`TailscaleKit` / `libtailscale`). Single Xcode target,
single scheme, both named **`Aperture`**. Bundle ID `io.tailscale.Aperture`.

## Hard constraints (will break the build if ignored)

- **iOS 26.0 only.** `IPHONEOS_DEPLOYMENT_TARGET = 26.0`, `SDKROOT = iphoneos`. No
  macOS target. Do not lower the deployment target or add macOS-only APIs without
  `if #available`/availability guards.
- **Swift 6 strict concurrency.** `SWIFT_STRICT_CONCURRENCY = complete` and
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. The whole module is implicitly
  `@MainActor`-isolated unless you opt out. New code must be concurrency-clean
  (Sendable annotations, explicit `@GlobalActor`/`nonisolated` where needed).
- **The app embeds `TailscaleKit.xcframework`**, which is **not in git**. It must
  exist at `ThirdParty/libtailscale/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework`
  before the project will build. If a build fails with a missing-framework /
  file-not-found error on `TailscaleKit.xcframework`, run
  `cd ThirdParty/libtailscale/swift && make ios-fat` (needs Go 1.26.3). The
  `FRAMEWORK_SEARCH_PATHS` in the project also references `Release-iphoneos`; the
  xcframework reference itself points at `Release-iphonefat` — both are produced by
  `make ios-fat` / `make ios` / `make ios-sim`.
- **`ThirdParty/libtailscale` is a git submodule** on a WIP `aperture` branch, not
  a vendored copy. After cloning, run `git submodule update --init`. Be careful
  about committing changes inside that directory; they belong upstream.

## Adding source files (do NOT hand-edit project.pbxproj for new files)

`App/` and `TSNet/` are Xcode **synchronized folder groups**
(`PBXFileSystemSynchronizedRootGroup`). New `.swift` files dropped into either
directory are automatically compiled into the `Aperture` target — no
`project.pbxproj` editing required. The `UITests/` directory is the same kind of
synchronized folder group, but for the `ApertureUITests` target.

The `TSNet/` group is different: it has a `membershipExceptions` list in
`project.pbxproj` naming the files that ARE compiled into the `Aperture` target,
and in this project's configuration that list **does** gate compilation — a new
`.swift` file dropped into `TSNet/` is NOT picked up until you add its name to the
`membershipExceptions` list (e.g. `TSNet/CrashCapture.swift` had to be added).
(`App/` and `UITests/` have no such list, so files there are auto-compiled.)

Other files (Info.plist, README.md, assets) are normal pbxproj references and do
require project edits if you add/relocate them.

## UI automation & agent tooling

There is a UI test target (`ApertureUITests`; sources in `UITests/`, another
synchronized folder group) plus helpers for running tests, capturing libtailscale
logs, letting a non-vision agent "see" the app, and the optional Xcode MCP server.
All of that — setup steps, the run-destination matrix (simulator vs "My Mac"),
vision-model config, CLI-vs-MCP guidance, and a scripts reference — is documented
in **[`README.ui-automation.md`](README.ui-automation.md)**. Read that when working
on tests, logs, vision, or the MCP bridge.

Headline for always-context: **use the simulator for autonomous work** (build +
`simctl install`/`launch` + `simctl io booted screenshot` + XCUITest + `log stream`
all work with zero permission grants). The "My Mac (Designed for iPad)" target
can't be launched headlessly. The UI tests include a `testHomePageLoadsWhenConnected`
connected test that **fails** (never skips) if the tailnet doesn't come up, so a
broken connection is never silently green. Connected tests need an auth key —
stage one at `~/.aperture-ios-authkey` (or `make test AUTHKEY=...`).

## Command-line builds that actually work

The **top-level Makefile** is the entry point: `make` builds everything
(libtailscale xcframework + app for sim), `make test` builds + runs the UI
tests with log capture, `make look Q="…"` screenshots + vision-describes.
`make help` lists all targets. See `README.md` for the full table.

Raw `xcodebuild` (what `make` runs) — simulator (no signing needed):
```bash
xcodebuild build -project Aperture.xcodeproj -scheme Aperture \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData
```
Use `xcrun simctl list devices available` to find a simulator name; an iPhone 17
sim is usually present with the iOS 26 SDK.

Device/generic builds try to sign (team `W5364U7YZB`, automatic signing) and will
fail at `CodeSign …/TailscaleKit.framework` in headless/SSH environments with
`errSecInternalComponent`. For a non-installable build in such environments add
`CODE_SIGNING_ALLOWED=NO`. A real device install still needs a valid identity +
provisioning profile and an unlocked keychain.

Prefer `-derivedDataPath build/DerivedData` to keep DerivedData inside the
`.gitignore`d `build/` directory.



## Other gotchas

- **libtailscale logs** go through `TSNet/Logging.swift` to `os_log` under subsystem
  `io.tailscale.Aperture` / category `tsnet` (and `print("tsnet: …")`). Stream
  them with `xcrun simctl spawn booted log stream --predicate 'subsystem == "io.tailscale.Aperture"'`.
  See `README.ui-automation.md` for the full log-capture workflow and the critical
  state transitions (`State: NeedsLogin`, `Authenticate at: …`).

- The bookmarks directory is spelled **`Boomarks`** (missing 'k') throughout the
  codebase — match the existing spelling if you reference it; don't "fix" it
  casually without renaming everything.
- `Aperture/Info.plist` sets `NSAllowsArbitraryLoads` / `NSAllowsArbitraryLoadsInWebContent`
  in the ATS dictionary. This is intentional — the browser must load plain-HTTP and
  self-signed tailnet nodes. Don't remove it.
- SwiftData is used for bookmarks (`App/Boomarks/Bookmark.swift`); the
  `ModelContainer` is created in `ApertureApp.swift` and injected via
  `.modelContainer`.
- `build/` (including `build/DerivedData`) is gitignored, as is the submodule's
  `swift/build/`. Don't commit build artifacts.


