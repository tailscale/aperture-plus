# Native macOS port

Working checklist for adding a native macOS version of Aperture. Keep this file tracked and update it as the port progresses.

## Decisions / constraints

- [x] Use a native macOS target, not Mac Catalyst (`Virtualization.framework` explicitly excludes Catalyst).
- [x] Keep the iOS app and its existing behavior/build settings intact.
- [x] Add `com.apple.security.virtualization = true` to the macOS app now; do not add virtualization code yet.
- [x] Start sandboxed with client/server network entitlements. The VM will use app-supplied userspace networking, with no host filesystem sharing entitlement.
- [x] Assume a pure Linux guest, no host filesystem sharing, with userspace networking supplied by the app.
- [ ] Confirm the intended minimum macOS version. Initially use macOS 26.0 to match the project's iOS-26-only posture and reduce compatibility branches.
- [ ] Confirm whether Intel Macs matter. The initial build may support the architectures supplied by native `TailscaleKit`; Linux virtualization itself can be supported on both Intel and Apple silicon, but guest artifacts differ by architecture.

## Project and dependency foundation

- [x] Add a native macOS application target and shared scheme (`ApertureMac`; product name remains Aperture).
- [x] Add a macOS entitlements file containing the Virtualization entitlement.
- [x] Verify the built macOS app's signed entitlements, not just the source plist (`make test-mac` ad-hoc signs and inspects it).
- [x] Build/link the native macOS `TailscaleKit.framework` from the existing libtailscale macOS scheme.
- [x] Add top-level `make mac-framework`, `make mac-app`, and `make test-mac` entry points.
- [ ] Make ordinary Apple Development signing reliable in the current headless environment. It currently reaches framework signing and fails with `errSecInternalComponent`, matching the repository's known locked-keychain behavior; unsigned/ad-hoc automated tests pass.
- [x] Keep host-only policy tests green (102 routing checks + 17 hostname checks at foundation milestone).
- [x] Keep the iOS simulator app build green at the foundation milestone.
- [ ] Keep the full iOS UI suite green after shared-source porting begins.

## Shared app port

- [ ] Inventory source into platform-neutral, iOS-specific, and macOS-specific pieces.
- [ ] Share workspace, bookmarks, tab state, routing policy, and tsnet lifecycle code.
- [ ] Add native macOS `WKWebView` hosting via `NSViewRepresentable`.
- [ ] Port browser context menus and pasteboard use to AppKit.
- [ ] Port `ASWebAuthenticationSession` presentation anchoring to `NSWindow`.
- [ ] Replace UIKit semantic colors and other UIKit-only APIs behind small platform adapters.
- [ ] Decide whether website data/proxy configuration behaves identically in macOS WebKit and add focused coverage.
- [ ] Preserve per-workspace SwiftData stores and web-data isolation.

## Native Mac experience

- [ ] Create a normal resizable browser window with sensible default and minimum sizes.
- [ ] Use native window sheets instead of iPad-style full-screen covers.
- [ ] Add a Mac toolbar/address field and desktop tab presentation.
- [ ] Add application commands and menus: New Tab, Close Tab, Focus Location, Reload, Settings, and tab navigation.
- [ ] Verify standard keyboard, pointer, context-menu, text-selection, and clipboard behavior.
- [ ] Add Settings and Logs presentation appropriate for macOS.
- [ ] Review app icon and Mac App Store screenshots/metadata.

## Automated testing

- [ ] Add a native macOS UI test target or a small launch/smoke test target.
- [x] Add a no-login process launch smoke test for the foundation app, including framework loading and entitlement verification.
- [ ] Extend no-login smoke coverage to Settings, tabs, and bookmark editor as those are ported.
- [ ] Add a connected macOS test using the existing staged auth-key convention.
- [ ] Add tests for platform adapters and native WebKit navigation behavior.
- [x] Add an automated assertion that a built app carries `com.apple.security.virtualization` (Debug/ad-hoc today; repeat against the future distribution archive).
- [ ] Document local and CI test commands.

## Distribution

- [ ] Add macOS to the existing App Store Connect app record for `io.tailscale.Aperture`.
- [ ] Verify the App ID/provisioning profile authorizes the Virtualization entitlement.
- [ ] Archive and validate a native Mac build before implementing VM functionality.
- [ ] Add TestFlight archive/export/upload commands and documentation for macOS.
- [ ] Record any App Store Connect or App Review response about the entitlement.

## Virtualization (explicitly deferred)

- [ ] Do not implement until the native app foundation and entitlement distribution check are complete.
- [ ] Later: design Linux boot artifacts, storage lifecycle, CPU architecture handling, userspace packet transport, VM state, and recovery.

## Questions to batch for the owner

- [ ] Minimum macOS version?
- [ ] Apple silicon only, or Intel too?
- [ ] Should the first Mac TestFlight build expose a placeholder/disabled VM UI, or contain no VM UI at all?
