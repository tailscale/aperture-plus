# CLAUDE.md

Working notes for AI coding agents (and humans) on this repo. Read alongside
`README.md`, which has the full build/setup instructions. This file captures the
non-obvious things that are easy to get wrong.

## What this is

An iOS-only SwiftUI browser (WebKit) that routes traffic through an embedded
userspace Tailscale node (`TailscaleKit` / `libtailscale`). Single Xcode target,
single scheme, both named **`TailBrowser`**. Bundle ID `io.tailscale.TailBrowse`.

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
directory are automatically compiled into the `TailBrowser` target — no
`project.pbxproj` editing required (verified: an unlisted `.swift` file in `TSNet/`
is picked up and compiled).

The `TSNet/` group has a `membershipExceptions` list in `project.pbxproj` naming its
current four files; in this project's configuration that list does **not** gate
compilation of newly added files, so you generally don't need to touch it when adding
files. If a new file under `TSNet/` ever fails to compile, that list is the first
thing to check.

Other files (Info.plist, README.md, assets) are normal pbxproj references and do
require project edits if you add/relocate them.

## There is no test target here

`xcodebuild test` / `xcodebuild build-for-testing` on `TailBrowser.xcodeproj` has
nothing to run. Don't claim tests pass/fail for the app. The only tests are in the
submodule: `cd ThirdParty/libtailscale/swift && make test`.

## Command-line builds that actually work

Simulator (no signing needed):
```bash
xcodebuild build -project TailBrowser.xcodeproj -scheme TailBrowser \
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

- The bookmarks directory is spelled **`Boomarks`** (missing 'k') throughout the
  codebase — match the existing spelling if you reference it; don't "fix" it
  casually without renaming everything.
- `TailBrowser/Info.plist` sets `NSAllowsArbitraryLoads` / `NSAllowsArbitraryLoadsInWebContent`
  in the ATS dictionary. This is intentional — the browser must load plain-HTTP and
  self-signed tailnet nodes. Don't remove it.
- SwiftData is used for bookmarks (`App/Boomarks/Bookmark.swift`); the
  `ModelContainer` is created in `TailBrowseApp.swift` and injected via
  `.modelContainer`.
- `build/` (including `build/DerivedData`) is gitignored, as is the submodule's
  `swift/build/`. Don't commit build artifacts.
