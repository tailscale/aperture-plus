# Native macOS port

Working checklist for adding a native macOS version of Aperture. Keep this file tracked and update it as the port progresses.

## Decisions / constraints

- [x] Use a native macOS target, not Mac Catalyst (`Virtualization.framework` explicitly excludes Catalyst).
- [x] Keep the iOS app and its existing behavior/build settings intact.
- [x] Add `com.apple.security.virtualization = true` to the macOS app now; do not add virtualization code yet.
- [x] Start sandboxed with client/server network entitlements. The VM will use app-supplied userspace networking, with no host filesystem sharing entitlement.
- [x] Assume a pure Linux guest, no host filesystem sharing, with userspace networking supplied by the app.
- [x] Use macOS 26.0 as the minimum version for now.
- [x] Support Apple silicon only for now; do not build an Intel slice.

## Project and dependency foundation

- [x] Add a native macOS application target and shared scheme (`ApertureMac`; product name remains Aperture).
- [x] Add a macOS entitlements file containing the Virtualization entitlement.
- [x] Verify the built macOS app's signed entitlements, not just the source plist (`make test-mac` ad-hoc signs and inspects it).
- [x] Build/link the native macOS `TailscaleKit.framework` from the existing libtailscale macOS scheme.
- [x] Add top-level `make mac-framework`, `make mac-app`, and `make test-mac` entry points.
- [x] Make ordinary Apple Development signing reliable in the current environment. After the keychain was unlocked/approved, Xcode signed the framework and app successfully and the resulting app retained the virtualization entitlement.
- [x] Keep host-only policy tests green (102 routing checks + 17 hostname checks at foundation milestone).
- [x] Keep the iOS simulator app build green at the foundation milestone.
- [ ] Keep the full iOS UI suite green after shared-source porting begins.

## Shared app port

- [x] Inventory source into platform-neutral, iOS-specific, and macOS-specific pieces.
- [x] Share workspace, bookmarks, tab state, routing policy, and tsnet lifecycle code in the native target.
- [x] Add native macOS `WKWebView` hosting via `NSViewRepresentable`.
- [ ] Port custom browser context menus to AppKit (native WebKit defaults work for now; iOS keeps its custom menu).
- [x] Port log-viewer pasteboard use to AppKit.
- [x] Port `ASWebAuthenticationSession` presentation anchoring to `NSWindow`.
- [x] Replace UIKit semantic colors and guard UIKit-only text-input/sheet APIs behind platform adapters/conditions.
- [ ] Decide whether website data/proxy configuration behaves identically in macOS WebKit and add focused coverage.
- [ ] Preserve per-workspace SwiftData stores and web-data isolation.

## Native Mac experience

- [x] Create a normal resizable browser window with initial 1100×760 and minimum 720×480 sizes.
- [x] Use native window sheets instead of iPad-style full-screen covers.
- [x] Represent each workspace as a value-addressed native window; closing a window preserves the workspace.
- [x] Make Command-N create a persisted workspace and open its native window.
- [x] List every persisted workspace in the Window menu so closed windows can be reopened and open ones raised.
- [ ] Remove the iPad-style workspace selector from the Mac tab overview (windows are the Mac workspace switcher).
- [ ] Add a Mac toolbar/address field and desktop tab presentation.
- [ ] Add application commands and menus: New Tab, Close Tab, Focus Location, Reload, Settings, and tab navigation.
- [ ] Verify standard keyboard, pointer, context-menu, text-selection, and clipboard behavior.
- [ ] Add Settings and Logs presentation appropriate for macOS.
- [x] Use the shared iOS/macOS AppIcon asset catalog for the native Mac app.
- [ ] Review Mac App Store screenshots/metadata.

## Experimental Linux VM prototype

- [x] Add File → New VM (experimental), with no keyboard shortcut and one disposable VM per window.
- [x] Boot a cached ARM64 Alpine Linux ISO with EFI and display it in `VZVirtualMachineView`.
- [x] Stop the VM and delete its temporary EFI state when its window closes; provide no persistent guest disk.
- [x] Validate multiple independent VM windows can be created and that Alpine reaches `localhost login:`.
- [ ] Replace the prototype `VZNATNetworkDeviceAttachment` with tailvisor's Ethernet/DHCP/gVisor bridge.
- [ ] Put that bridge in `TailscaleKit` and use the owning workspace's existing tsnet node. Do not link tailvisor's standalone 59 MB Go c-archive beside TailscaleKit: that duplicates the Go runtime and creates a second tsnet identity instead of merging networking.
- [ ] Decide whether each VM should share its workspace's tailnet identity or deliberately receive a distinct tailnet identity.

## Automated testing

- [x] Add a native macOS UI test target with window, auth-presentation, and auth-key login/logout cases.
- [x] Execute native Mac UI tests from Xcode/MCP after Automation Mode approval; expose `make test-mac-ui` as the required CLI entry point.
- [x] Add a hermetic no-login process launch smoke test for the shared browser app, including framework loading and entitlement verification.
- [ ] Extend no-login smoke coverage to Settings, tabs, and bookmark editor as those are ported.
- [x] Add a connected macOS test using the existing staged auth-key convention.
- [x] Add native interactive nullid login → logout → relogin coverage and make it required (no skip path).
- [ ] Add tests for platform adapters and native WebKit navigation behavior.
- [x] Add an automated assertion that a built app carries `com.apple.security.virtualization` (Debug/ad-hoc today; repeat against the future distribution archive).
- [ ] Document local and CI test commands.

## Distribution

- [ ] Add macOS to the existing App Store Connect app record for `io.tailscale.Aperture`.
- [x] Verify a development-signed Mac app carries the Virtualization entitlement. Xcode's direct Mac development signing succeeds without an embedded profile and preserves `com.apple.security.virtualization=true`.
- [ ] Verify the Mac App Store distribution profile/archive authorizes the Virtualization entitlement; the currently cached provisioning profiles are iOS-only.
- [ ] Archive and validate a native Mac build before implementing VM functionality.
- [ ] Add TestFlight archive/export/upload commands and documentation for macOS.
- [ ] Record any App Store Connect or App Review response about the entitlement.

## Virtualization (explicitly deferred)

- [ ] Do not implement until the native app foundation and entitlement distribution check are complete.
- [ ] Later: design Linux boot artifacts, storage lifecycle, CPU architecture handling, userspace packet transport, VM state, and recovery.

## Questions to batch for the owner

- [x] Minimum macOS version: 26.0.
- [x] Apple silicon only for now.
- [x] The first Mac TestFlight build contains no VM UI at all.
