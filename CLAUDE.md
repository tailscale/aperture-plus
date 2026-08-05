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
  `cd ThirdParty/libtailscale/swift && make ios-fat` (needs Go 1.26.5). The
  `FRAMEWORK_SEARCH_PATHS` in the project also references `Release-iphoneos`; the
  xcframework reference itself points at `Release-iphonefat` — both are produced by
  `make ios-fat` / `make ios` / `make ios-sim`.
- **`ThirdParty/libtailscale` is a git submodule**, and it contains the nested
  `tailscale-patched` submodule. They are not vendored copies. After cloning,
  run `git submodule update --init --recursive`. Commit changes deepest-first
  (`tailscale-patched`, then `libtailscale`, then this repo) so every gitlink
  points at a real commit.
- **Run `make subtrac` after every top-level commit**, especially any commit that
  changes a submodule pointer. The submodule remotes are intentionally local
  (`url = .`), so ordinary gitlinks alone are not portable. `make subtrac`
  preserves HEAD and recursively embeds both nested commits in `<branch>.trac`
  (normally `main.trac`). It is content-addressed/idempotent and verifies the
  tracking ref equals `git-subtrac cid HEAD`, so running it after every commit
  is safe and cheap. Do not commit the generated tracking commit onto `main`;
  it lives on `main.trac`.

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
`make help` lists all targets. See `README.md` for the full table. After making
and committing changes, run `make subtrac` as the final repository-hygiene step.

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



## Split tunnel: only tailnet traffic goes through the proxy

`TSNet/TailnetProxyPolicy.swift` decides which hosts are routed through the tsnet
SOCKS5 proxy. **Only tailnet destinations are proxied** (the `100.64.0.0/10`
CGNAT + `fd7a:115c:a1e0::/48` ranges, the MagicDNS suffix, peer FQDNs, peer short
names); everything else loads DIRECT. This is applied via
`ProxyConfiguration.matchDomains` in `TSNetManager.proxyConfig`.

Do **not** "simplify" this back to an unscoped `ProxyConfiguration`. Proxying
everything is what caused the reported bug where every non-tailnet URL failed
with an "invalid URL" popup (`NSURLErrorDomain -1000`) on a real iPad. Measured
fact: **any** SOCKS5 CONNECT failure surfaces as `-1000`, so that error means
"the proxy couldn't connect", not "bad URL" (see
`scripts/proxy-semantics/README.md` and the "RESOLVED" section of
`timing/README.md`).

Gotchas encoded in that file, all empirically verified — read its header comment
before touching it:

- `matchDomains = []` means **proxy everything**; an empty-string entry also
  matches everything. Never emit either.
- Matching is **label-wise suffix**, so a single-label entry for a peer named
  `ai` would also capture the whole public `.ai` TLD. Such names are withheld
  and reached by rewriting to their FQDN (`BrowserViewModel.resolveForTailnet`).
- Peer names are **untrusted input**: a peer called `localhost` must not become
  a rule (it would route the app's own loopback through the proxy).
- Rules are **sorted** so the 5s status poll doesn't republish the proxy config
  (and reset it under live page loads) on every tick.
- `excludedDomains` is avoided: broken getter, surprising matching.

Testing and diagnostics:

- `make test-policy` — 90 host-only unit tests (~2s, no sim/xcframework).
  `make test` runs it first.
- **Settings → Routing** shows the live rules and answers "proxy or direct?" for
  any host you type. This is the on-device diagnostic for devices that can't be
  attached to a Mac.
- **The Exit Node toggle doubles as the routing control.** Exit node ON => proxy
  everything (public traffic must be proxied to egress via the exit node); OFF =>
  tailnet only. That's the on-device way to A/B the bug, since launch arguments
  can't be set on a physical device. `-ProxyEverything` does the same on the sim.
- **Settings -> Logs / the "more" menu -> Logs** shows the app's own recent log
  lines (`LogRing` in `TSNet/Logging.swift`), including the `socks[n]` lines from
  `TSNet/SocksLogProxy.swift` — a pass-through SOCKS5 relay in front of tsnet
  that logs EVERY connection attempt and its outcome. tsnet's own SOCKS server
  logs only failures and not the reply code, so without the relay the absence of
  a log line is ambiguous. Disable the relay with `-NoSocksLog`.
- **iOS pre-filters by `matchDomains` against the literal host**, then resolves
  unmatched hosts itself (applying system search domains). It never expands a
  bare label for the proxy, and never asks the proxy to decide. Hence the URL
  rewrite: a bare `http://ai/` must become `ai.<suffix>` to be routable.
- `scripts/proxy-semantics/` — the SOCKS proxies + WebKit harnesses used to
  measure all of the above.

## Other gotchas

- **libtailscale logs** go through `TSNet/Logging.swift` to `os_log` under subsystem
  `io.tailscale.Aperture` / category `tsnet` (and `print("tsnet: …")`). Stream
  them with `xcrun simctl spawn booted log stream --predicate 'subsystem == "io.tailscale.Aperture"'`.
  See `README.ui-automation.md` for the full log-capture workflow and the critical
  state transitions (`State: NeedsLogin`, `Authenticate at: …`).

- The bookmarks directory is **`App/Bookmarks/`** (previously a typo,
  `Boomarks`, since fixed). SwiftData `Bookmark` model + per-workspace
  `HomePage`.
- `Aperture/Info.plist` sets `NSAllowsArbitraryLoads` / `NSAllowsArbitraryLoadsInWebContent`
  in the ATS dictionary. This is intentional — the browser must load plain-HTTP and
  self-signed tailnet nodes. Don't remove it.
- SwiftData is used for bookmarks (`App/Bookmarks/Bookmark.swift`). Each
  workspace owns its own `ModelContainer` (per-identity bookmarks store at
  `Workspaces/<id>/Bookmarks.store`); the active workspace's container is
  injected into the browser view tree via `.modelContainer`. See
  `App/Workspace/`.
- `build/` (including `build/DerivedData`) is gitignored, as is the submodule's
  `swift/build/`. Don't commit build artifacts.


