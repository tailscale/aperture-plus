Now I have all the information needed. Let me compile the analysis.

---

## Ranked suspect list

### Suspect 1 · `.buttonStyle(.plain)` hit area vs visual background mismatch

**Location:** `App/Tailnet Status/StatusView.swift` — `StatusButton` body (lines 52–65)

**Layout (annotated):**

```swift
Button( action: action ) {
    Text(text)                         // intrinsic width = text length
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)    // ← asks to fill available width
        .padding(.vertical, 12)        // ← adds 12pt top/bottom
}
.buttonStyle(.plain)                   // ← hit-area = label's computed frame
.background(
    RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(color)                   // ← visual background, NOT part of hit area
)
```

**Why it'd differ device-vs-sim:**
With `.buttonStyle(.plain)`, SwiftUI's `PlainButtonStyle` makes the tappable region equal to the *label's actual frame* — no automatic minimum-hit-area enforcement (unlike the default button style, which enforces a ≥44pt tappable region). The RoundedRectangle `.background` draws a full-width pill that *looks* like the button, but it does not extend the hit area.

On a real device, subtle layout differences (safe-area insets, dynamic type, notch width) can cause the `VStack(alignment: .leading)` in `StatusView` to propose a *slightly different* width to the label's `.frame(maxWidth: .infinity)`. If the computed label frame is even 1–2pt narrower than the parent, the visual background bleeds beyond the tappable region, and taps on the visual edges silently miss. The user perceives "inactive."

The gear button (which works) uses the **default** button style (no `.buttonStyle(.plain)`) — it gets iOS's built-in minimum hit-area enlargement, so small frame discrepancies don't cause misses.

**Fix:** Add `.contentShape(Rectangle())` to the button, either after `.background` or directly on the `StatusButton`:
```swift
.buttonStyle(.plain)
.contentShape(Rectangle())
.background(RoundedRectangle(...).fill(color))
```
`.contentShape(Rectangle())` explicitly defines the hit-test shape as the button's entire rendered frame (including the background), overriding the plain-style label-only hit area.

**Confirm:** Add `print("StatusButton frame: \(geometry.size)")` via a `GeometryReader` overlay on the button, and compare the label's computed size to the visual background's size under a device-vs-sim screen dimension.


### Suspect 2 · No `.contentShape` on a shaped `.background` — classic SwiftUI `.plain` gotcha

**Location:** `App/Tailnet Status/StatusView.swift:52–65`

This is an elaboration on Suspect 1, but with a sharper trigger: SwiftUI has a known (if infrequent) bug where stacking `.buttonStyle(.plain)` → `.background(RoundedRectangle)` **without** an intervening `.contentShape` causes the button to lose hit-testing entirely in certain layout contexts — the background view absorbs the touch itself rather than forwarding it to the button. The bug is more reproducible on **physical devices** because the window server's pixel-hit path goes through UIKit's `point(inside:with:)` rather than SwiftUI's rendering server fallback used by the simulator.

**Fix:** Same as Suspect 1 — `.contentShape(Rectangle())` before or after `.background` forces SwiftUI to set the button's `point(inside:)` shape to the full frame.

**Confirm:** Temporarily swap `.buttonStyle(.plain)` for `.buttonStyle(.borderedProminent)` — if the button suddenly works on device, the `.plain`+background hit-area discrepancy was the cause. (`.borderedProminent` applies its own shape and minimum size.)


### Suspect 3 · `ApertureBrandHeader` ZStack consuming taps on the upper portion of `StatusView`

**Location:** `App/ApertureBrandHeader.swift:34–59`

**Layout:**
```swift
ZStack {               // ← no fixed height, default alignment .center
    HStack(spacing:10) { Icon + Wordmark }
        .frame(maxWidth:.infinity, alignment:.center)
    HStack { Spacer(); trailing() }   // gear button
}
```

The first HStack has `.frame(maxWidth: .infinity)`. In a `ZStack` with no alignment, both children are centered and sized to fit the taller content. The first HStack's `.frame(maxWidth: .infinity)` expands its **width** to fill the screen — but that should not affect height. However, if the icon images are missing/empty on a real device (e.g., `ApertureIcon` asset failed to load in a non-standard build), the first HStack collapses to zero height, and the ZStack sizes to the trailing `HStack { Spacer(); trailing() }` — which contains only the gear button. In that scenario, the ZStack height is just ~18pt (gear icon), and the remaining gap below it (before the `.padding(.bottom, 10)`) is **unfilled ZStack whitespace** that still belongs to the ZStack's frame. If the ZStack renders a transparent hit-testable region because of `.frame(maxWidth: .infinity)` on the (now-collapsed) first child, taps on the gap would land on the ZStack rather than the `StatusView` below.

**But** — this is unlikely with a normal build where icons exist. Ruled out for the fresh `make ipa` build described.

**Ruling:** Low probability. The VStack in `ConnectionGateView` should vertically separate the header and `StatusView` without overlap. Confirm by setting a border on the header: `ApertureBrandHeader { ... }.border(.red)` and inspect on device.


### Suspect 4 · `Spacer()` in `ConnectionGateView` collapsing the login button frame

**Location:** `App/Browser/ConnectionGateView.swift:38`

```swift
VStack(spacing: 0) {
    ApertureBrandHeader { ... }.padding(...)
    StatusView(viewModel: statusViewModel).padding()
    Spacer()   // ← fills rest of screen
}
```

A `Spacer()` at the bottom of a `.frame(maxHeight: .infinity)` VStack **expands** downward, NOT upward. It cannot collapse the views above it. However, on a very short device (unlikely for an iPhone), if the content above the Spacer already fills the screen, the Spacer gets zero height and everything above is at minimum size. The Login button's `Text(...).padding(.vertical, 12)` still has a 44pt+ tappable height — not collapsible.

**Ruling:** Not guilty. The Login button cannot be squeezed to zero height by the Spacer.


### Suspect 5 · `ASWebAuthenticationSession.presentationAnchor` frameless fallback

**Location:** `TSNet/AuthManager.swift:38–46`

```swift
func presentationAnchor(for:) -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let key = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) { return key }
    if let scene = scenes.first { return ASPresentationAnchor(windowScene: scene) }
    logger.log("no UIWindowScene connected")
    return ASPresentationAnchor(frame: .zero)   // ← last resort
}
```

If the key window isn't found on device (e.g., the scene is still transitioning when `showAuth()` is called synchronously from a button action), the fallback creates a zero-frame anchor. The `ASWebAuthenticationSession` would *start* (`session.start()` returns true) but the sheet would appear at a zero-size rectangle — invisible to the user. The button action ran, the log fires, but no sheet appears.

**Why device-vs-sim:** On simulator, `UIApplication.shared.connectedScenes` is usually populated before the first frame. On a real device, especially during cold launch or when the app is launched from a background state, scene/window setup timing can be slightly different. If the user taps the Login button before the window scene is fully connected, the key-window lookup fails.

**Why it hits Login but not gear:** The gear button triggers `showingSettings = true`, which presents a SwiftUI `.fullScreenCover` — that uses SwiftUI's own presentation system (not ASWebAuthenticationSession), which does not need an explicit `presentationAnchor`. So the gear works regardless of window-scene readiness.

**Fix:** Add a brief retry or defer the anchor lookup:
```swift
func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    // Retry a few times if the key window isn't ready (common on cold launch).
    for _ in 0..<3 {
        if let key = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            return key
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    // ... existing fallback ...
}
```

**Confirm:** Add `logger.log("anchor = \(anchor.frame)")` in `presentationAnchor` and inspect device logs.


### Suspect 6 · `prefersEphemeralWebBrowserSession = true` blocking presentation on device

**Location:** `TSNet/AuthManager.swift:26`

```swift
session.prefersEphemeralWebBrowserSession = true
```

On iOS 17+, ephemeral sessions on real devices may require the scene to be in the **foreground active** state at the exact moment `start()` is called. If `showAuth()` fires during a scene-phase transition (e.g., the app just became active), the ephemeral session can fail to present silently. The simulator is more lenient with this timing.

**Fix:** Guard `showAuth()` with a scene-phase check, or queue the call if the scene is inactive.

**Confirm:** Set `prefersEphemeralWebBrowserSession = false` temporarily — if the sheet appears on device, timing/scene-phase was the culprit.


### Suspect 7 · No `onAppear` `needsAuth` processing at gate display

**Location:** `App/Tailnet Status/StatusViewModel.swift:35–62`

The `observeAuthURL()` combine pipeline watches `$state` + `$browseToURL`. If the user launches the app and the bus delivers `NeedsLogin+BrowseToURL` *before* `StatusView` appears and `observeAuthURL()` is subscribed, the `authURL` is set correctly. But on a real device with slower bus initialization, the initial state emission might arrive, set `authURL`, and then a second "restart" emission (bus watcher restart at ~60s) might arrive with a *different* state order — `browseToURL` nil + `state` NeedsLogin, then `browseToURL` filled later. The `.combineLatest` would first pair (NeedsLogin, nil) setting `authURL = nil`, then later pair (NeedsLogin, URL) setting it correctly. If the user taps in the brief window between the two emissions, `authURL` is nil and `showAuth()` falls through to `startLoginInteractive()`, which might not produce a visual result on device due to bus timing.

**Why device only:** Simulator is faster, so the two emissions arrive in the same runloop and the user can't tap fast enough.

**Suspect for "inactive" symptom (no sheet):** yes, but **only** if the button tap **does** fire the action. The spinner diagnostic will disambiguate.

---

### Summary table

| # | Suspect | Blocks tap? | Fix | Confidence |
|---|---------|-------------|-----|------------|
| 1 | `StatusButton` `.plain` hit area ≠ visual background | ✅ Yes | `.contentShape(Rectangle())` | Highest — classic SwiftUI `.plain` pitfall |
| 2 | `.plain` + `.background` SwiftUI hit-test bug on device | ✅ Yes | Same as #1 | High — reproducible with shaped backgrounds |
| 3 | Header ZStack overlapping StatusView | ❌ Ruled out | — | Low |
| 4 | Spacer collapsing button frame | ❌ Ruled out | — | None |
| 5 | `presentationAnchor` frameless fallback on device | ❌ No (tap works, sheet invisible) | Retry anchor lookup | Medium — depends on scene timing |
| 6 | `prefersEphemeral` failing on device | ❌ No (tap works, sheet invisible) | Scene-phase guard | Medium |
| 7 | Race in `observeAuthURL` combineLatest | ❌ No (tap works, no URL) | `.removeDuplicates()` on state | Low — and only transient window |

**Takeaway:** The highest-probability fix is adding `.contentShape(Rectangle())` to the `StatusButton` in `StatusView.swift` — it costs nothing, fixes a known SwiftUI `.plain` + `.background` pitfall, and does not affect the simulator test (which may succeed through a slightly different rendering path or because the test's `tap()` dispatches a centroid touch that always hits the label's frame).
