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

- [x] Add a native macOS application target and shared scheme (`ApertureMac`; product name is `AperturePlus`, with the user-facing display name `Aperture+`).
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
- [x] Remove the iPad-style workspace selector from the Mac tab overview (windows are the Mac workspace switcher); pin the overview to its native window's workspace.
- [x] Add a Mac toolbar/address field and desktop tab presentation (persistent pointer-friendly tab strip plus shared address/navigation toolbar).
- [x] Add application commands and menus: New Tab, Close Tab, Focus Location, Reload, Settings, Logs, and tab navigation.
- [ ] Verify standard keyboard, pointer, context-menu, text-selection, and clipboard behavior.
- [x] Add Settings and Logs presentation appropriate for macOS (native Settings scene plus in-window workspace Settings/Logs sheets and menu access).
- [x] Use the shared iOS/macOS AppIcon asset catalog for the native Mac app.
- [ ] Review Mac App Store screenshots/metadata.

## Experimental Linux VM prototype

- [x] Add File → New VM (experimental), with no keyboard shortcut and one disposable VM per window.
- [x] Boot a cached ARM64 Alpine Linux ISO with EFI and display it in `VZVirtualMachineView`.
- [x] Stop the VM and delete its temporary EFI state when its window closes; provide no persistent guest disk.
- [x] Validate multiple independent VM windows can be created and that Alpine reaches `localhost login:`.
- [x] Prototype tailvisor's Ethernet/DHCP/DNS/gVisor bridge with `VZFileHandleNetworkDeviceAttachment`.
- [x] Put that bridge in `TailscaleKit` and make it borrow the owning workspace's existing tsnet node without adding a second Go runtime or identity.
- [x] Temporarily restore `VZNATNetworkDeviceAttachment` as the GUI default after diagnosing the custom bridge's broken UDP receive lifecycle. The bridge remains available to the diagnostic CLI and for future isolation work; see `TODO.vmnet.md`.

## Automated testing

- [x] Add a native macOS UI test target with window, auth-presentation, and auth-key login/logout cases.
- [x] Execute native Mac UI tests from Xcode/MCP after Automation Mode approval; expose `make test-mac-ui` as the required CLI entry point.
- [x] Add a hermetic no-login process launch smoke test for the shared browser app, including framework loading and entitlement verification.
- [x] Extend smoke/UI coverage to Settings, tabs, and bookmark editor (no-login Settings/tab overview plus connected desktop commands/bookmark editor).
- [x] Add a connected macOS test using the existing staged auth-key convention.
- [x] Add native interactive nullid login → logout → relogin coverage and make it required (no skip path).
- [ ] Add tests for platform adapters and native WebKit navigation behavior.
- [x] Add an automated assertion that a built app carries `com.apple.security.virtualization` (Debug/ad-hoc today; repeat against the future distribution archive).
- [ ] Document local and CI test commands.

## Distribution

- [x] Add macOS to the existing App Store Connect app record for `io.tailscale.Aperture` (native build successfully uploaded to TestFlight).
- [x] Verify a development-signed Mac app carries the Virtualization entitlement. Xcode's direct Mac development signing succeeds without an embedded profile and preserves `com.apple.security.virtualization=true`.
- [x] Verify the Mac App Store distribution profile/archive authorizes the Virtualization entitlement; the distribution archive/export uploaded successfully and `tf-mac-archive` verified the signed archived app retains it.
- [x] Archive and validate a native Mac build before implementing VM functionality.
- [x] Add TestFlight archive/export/upload commands and documentation for macOS (`make tf-mac*`, `README.testflight.md`).
- [ ] Record any App Store Connect or App Review response about the entitlement.

## Virtualization

- [x] Do not implement until the native app foundation and entitlement distribution check are complete (the native TestFlight upload now proves distribution signing).
- [x] Design the first prototype's Linux boot artifacts, storage lifecycle, and CPU architecture handling: cached ARM64 Alpine ISO; disposable EFI state; Apple silicon only; no persistent guest disk.
- [x] Implement the first userspace packet transport: tailvisor Ethernet + DHCP + DNS + gVisor TCP/UDP proxy, carried over a Unix datagram `VZFileHandleNetworkDeviceAttachment` and the owning workspace node.
- [x] Use Virtualization.framework NAT for GUI VMs until the experimental userspace transport's UDP model is repaired and hardened.
- [ ] Decide whether VM state should remain intentionally disposable or gain persistence, and add guest-network recovery/diagnostics beyond deterministic bridge teardown.

## Questions to batch for the owner

- [x] Minimum macOS version: 26.0.
- [x] Apple silicon only for now.
- [x] The first Mac TestFlight build contains no VM UI at all.
- [x] Tailvisor source supplied at `../tailvisor`; bridge integrated into the existing libtailscale/TailscaleKit archive and workspace node.
