# Webview / keyboard layout — analysis & probe plan

Status: **investigating.** No code changes committed yet. This file captures the
analysis and the probe sequence agreed before editing.

## Goal

When the software keyboard appears (a text field in the web page is focused),
the layout should be a simple three-way vertical split:

```
  webpage  (shrinks to make room)
  url bar  (sits just above the keyboard)
  keyboard
```

No special cases per field. No url bar flying to the top of the screen mid
transition. Behavior should match Safari, and not introduce bugs Safari doesn't
have.

## Current state (commits a962b79, f298b81)

The layout is **not** "webpage shrinks, url bar rides up." It's the
**Safari scroll-under model**: the `WKWebView` stays full-screen, and the chrome
is carved out of the webview's **content inset**, not its frame.

- `BrowserView` → `WebView(model.page)`, full-screen, `.ignoresSafeArea(.keyboard)`.
- `.safeAreaInset(.bottom)` holds `CompactBrowserToolbar` **plus an animated
  `Color.clear` spacer of `keyboardHeight`**. Growing that safe area grows the
  webview's `scrollView.contentInset.bottom`, so WebKit scrolls the focused
  input to just above the url bar.
- `KeyboardObserver` feeds the spacer height on the keyboard's own animation
  clock.

Why `.ignoresSafeArea(.keyboard)` is there: the test doc at
`UITests/ApertureUITests.swift:651-655` asserts the trap — *"`WebView`'s frame
shrinks for the keyboard (safe area) AND WebKit independently adds a keyboard
`contentInset`… so the input is scrolled up by ~2× the keyboard height (double
accounting)."* So they turned SwiftUI's frame-shrink **off** and drive the inset
**manually** instead.

## Why the "url bar flies to the top" happens

The fragile part is the **SwiftUI safe-area entanglement**, not the webview:
an animated-height element *inside* `.safeAreaInset(.bottom)`, combined with
`.ignoresSafeArea(.keyboard)`, inside a `NavigationStack` with a hidden nav bar.
During the keyboard transition SwiftUI recomputes safe areas, and that
three-way interaction can hand the url bar a transient wrong frame. The two
commits kept patching *symptoms* (the per-field `isEditingURL` gate, then the
clock-sync) instead of removing the entanglement.

`KeyboardObserver` itself is **not** a special case — it's the one uniform
driver for both native and web inputs. The earlier `isEditingURL` gate was a
genuine special case and the second commit correctly deleted it.

## On the TODO / "migrate off WebPage"

`WebPage` (verified in the iOS 26.5 SDK interface) exposes **no** `webView`,
`scrollView`, or `contentInset` — only navigation/JS/state. So the TODO's
*premise* is technically right: to touch `scrollView.contentInsetAdjustment
Behavior` you need your own raw `WKWebView` in a `UIViewRepresentable`.

But the TODO's **stated rationale is muddled.** `contentInsetAdjustmentBehavior`
governs *safe-area (notch)* inset adjustment — it does **not** "let the OS fully
own the keyboard." As written, that path sounds like trading one set of special
cases for another.

The *real* reason a raw `WKWebView` would help, stated honestly:

> It gives a handle to `scrollView`, so we can set
> `contentInset.bottom = urlBarHeight + keyboardHeight` **directly** and
> **delete the `.safeAreaInset(.bottom)` + animated-spacer +
> `.ignoresSafeArea(.keyboard)` dance entirely** — which is exactly the part
> that's glitching. The url bar becomes a plain overlay floated above the
> keyboard by `KeyboardObserver`; the webview stays full-screen; WebKit scrolls
> the focused input to above the url bar because *we* told it the bottom inset.
> One explicit value, no SwiftUI safe-area negotiation.

That **is** simpler in the steady state. The cost is the **refactor to get
there**: `BrowserViewModel` is built on `WebPage` (`page.load`, `backForward
List`, `callJavaScript`, the `navigations` async sequence,
`WebPage.NavigationError`, `NavigationDeciding`, `Configuration`). Dropping
`WebPage` means re-implementing that plumbing on `WKNavigationDelegate`/
`WKUIDelegate`/`evaluateJavaScript` — real work, and a chance to regress the
proxy-in-place / error-overlay / retry behavior that's currently working.

Scope narrowing:
- The bug is **compact (iPhone) only.** The iPad path uses the system
  `.bottomBar` toolbar, which the comment says iOS keyboard-avoids on its own —
  no `safeAreaInset`, no spacer. So any refactor really only has to fix the
  compact branch.
- `KeyboardObserver` stays as-is regardless.

## The decisive measurement

There are two mutually exclusive theories about what WebKit does, and the whole
design hinges on which is true:

- **Theory A (what the commits/test doc assert):** Inside SwiftUI's `WebView`,
  when the keyboard appears, **WebKit adds its own `scrollView.contentInset.
  bottom` = keyboard height.** If SwiftUI *also* shrinks the webview frame for
  the keyboard safe area, the focused input gets scrolled up by **2×** (frame
  shrank 1×, inset grew 1×). The current "fix" is `.ignoresSafeArea(.keyboard)`
  — kill SwiftUI's frame-shrink so only WebKit's inset remains (1×, correct) —
  and then float the url bar manually with `KeyboardObserver` + the animated
  spacer.

- **Theory B (the desired model):** Just shrink the frame; url bar rides up;
  webview is smaller; done. This only works if WebKit does **not** also add its
  own contentInset on top of the frame shrink.

Notice the two flop commits are internally inconsistent: a962b79 says "SwiftUI's
keyboard avoidance *didn't reach* the `safeAreaInset` toolbar" (avoidance
failed), while the test doc says "the WebView frame *shrinks* AND WebKit adds an
inset" (avoidance worked *too* well, plus WebKit). That inconsistency is a tell
that nobody cleanly isolated the behavior — they patched symptoms.

The decisive probe is one screenshot with **pure built-in handling** — remove
`.ignoresSafeArea(.keyboard)`, remove the spacer + its animation, stop using
`KeyboardObserver`, keep just `safeAreaInset(.bottom) { CompactBrowserToolbar }`.
Focus the chat input with the software keyboard up, and measure where the input
lands:

- **Adjacent to the url bar (1×):** Theory B wins. Delete ~100 lines
  (`KeyboardObserver`, the spacer, `.ignoresSafeArea`, the clock-sync). Ship the
  three-way frame-split model with zero custom code. Best outcome.
- **A one-keyboard-height gap above the url bar (2×):** Theory A wins — WebKit
  really does double-count. Then two honest options: (a) keep "let WebKit own
  the inset" but stop floating the url bar in a way that fights SwiftUI; or
  (b) go to a raw `WKWebView` so we can set `contentInsetAdjustmentBehavior =
  .never` and *prevent* WebKit's own inset, making the frame-shrink model clean.
  That's the TODO path — now *justified by a measurement*, not the muddled
  "let the OS own the keyboard" rationale.

Either way the probe tells us whether the big refactor is warranted or whether
the whole thing collapses to "stop fighting SwiftUI."

## Why `.bottomBar` on iPad but not iPhone

No *hard* reason — `.bottomBar` can host a custom view on iPhone too. The split
looks like a **design choice**: the compact toolbar is one combined bar
(back/fwd + a URL *pill that expands inline into a full-width editable field* +
tab cluster), awkward as `ToolbarItemGroup` items but trivial as a custom view
in `safeAreaInset(.bottom)`. iPad keeps the older separate TabBar +
BrowserNavigator. So "use the built-in feature on iPhone too" is a real option.

Unverified: does `.bottomBar`'s keyboard avoidance reach a first responder that
lives inside the `WKWebView`? The code *asserts* it does on iPad, but the two
flop commits only ever touched the compact branch, so that assertion may be
untested folklore. An iPad Pro 11-inch (M5) is booted alongside the iPhones, so
it can be checked in one screenshot.

## simctl / forcing the software keyboard

There is **no `simctl` keyboard option.** `simctl ui` only exposes
`appearance`, `increase_contrast`, `content_size`. The only automation path is
the plist write the test already documents:

```
~/Library/Preferences/com.apple.iphonesimulator.plist
  DevicePreferences:<UDID>:ConnectHardwareKeyboard = 0
```

The booted iPhone 17 Pro (`F68BE83F…`) already has `ConnectHardwareKeyboard =
0`. For CI/fresh sims, a Makefile/test-runner step doing the `PlistBuddy` Add
on the target UDID before boot is the realistic answer. The "keyboard renders
off-screen" theory is discarded — the sim can render the keyboard in this mode.

## Probe sequence

- **Probe 0** — keyboard renders on sim: boot iPhone 17 Pro (already
  no-hardware-keyboard), launch app, focus the chat input, screenshot. Confirms
  the tool works before relying on it.
- **Probe 1** — *decisive:* pure built-in handling (no `.ignoresSafeArea(
  .keyboard)`, no spacer, no `KeyboardObserver`). Screenshot + measure
  input↔url-bar gap. 1× → basically done. 2× → Theory A confirmed.
- **Probe 2** — only if Probe 1 is 2×: try `.bottomBar` placement for the
  compact toolbar (built-in feature), and separately sanity-check the booted
  iPad with a focused web input to see if its `.bottomBar` actually floats
  above the keyboard (testing the folklore claim).
- **Probe 3** — only if 1 and 2 both confirm Theory A and `.bottomBar` doesn't
  save us: raw `WKWebView` + `UIViewRepresentable`,
  `contentInsetAdjustmentBehavior = .never`, frame-shrink model. The real
  refactor, now earned.

## Probe results (run 2026-07-27)

Sim: iPhone 17 (5D18FC7D), `ConnectHardwareKeyboard = 0` (software keyboard
renders on-screen — the "keyboard off-screen" theory is discarded). Screen
402×874. Drove the existing `testChatInputKeyboardLayoutRepro` (taps the chat
input, waits for the software keyboard, prints `REPRO:` frame lines, saves
`/tmp/repro-*.png`). Layout outcome is logged, not hard-asserted, so both runs
"passed" while still exposing the broken layout in the frame numbers.

Keyboard in both runs: `(0, 583, 402, 233)` → y=583..816, height 233.

### Probe 0 — current code (`.ignoresSafeArea(.keyboard)` + animated spacer)

Focused state (keyboard up):
- webview frame: `(0, 0, 402, 874)` — full screen (ignoresSafeArea working).
- **url-pill: `(6, 53.67, 250, 31)` → y≈54, the TOP of the screen.**
- input: `(29, 246, 344, 47)` → y=246..293 (visible, mid-screen).
- Order: url bar (top, y≈54) → input (mid, y≈246) → ~290pt gap → keyboard
  (bottom, y=583).

Vision confirms: before focus the url bar is at the bottom; after focus it is
at the **top** with a large empty gap to the keyboard. **This is the reported
"url bar flies to the top" bug, reproduced and pinned to the
`.safeAreaInset(.bottom)`-spacer + `.ignoresSafeArea(.keyboard)` combination.**
The input, by contrast, stays visible (WebKit's own contentInset handles the
keyboard at 1× because the frame didn't shrink).

### Probe 1 — pure built-in (no `.ignoresSafeArea(.keyboard)`, no spacer, no
KeyboardObserver driving layout; url bar in plain `.safeAreaInset(.bottom)`)

Focused state (keyboard up):
- webview frame: `(0, 0, 402, 874)` — reported full screen (XCUITest may
  report the WKWebView container; not a reliable shrink signal here).
- **url-pill: `(6, 434, 250, 31)` → y=434** — floated UP, above the keyboard
  (no longer at the top). The url bar behaves correctly on its own here.
- **input: `(29, -70, 344, 46)` → y = −70, scrolled OFF the top of the screen.**
  Before the tap it was at y=702 (genuinely bottom-anchored this run).
- Order: input (off the top, y=−70) → url bar (y=434) → ~118pt gap → keyboard
  (y=583).

**Theory B ("just shrink the frame, done") is FALSE.** With pure built-in
handling the focused input scrolls off the top of the screen (y=−70) — WebKit's
scroll-to-focus overshoots when the SwiftUI `WebView`'s safe area changes for
the keyboard. **Theory A is confirmed:** the SwiftUI `WebView` + WebKit
scroll-to-focus double-count/overshoot the keyboard inset.

### What the two probes together show

These are **two different bugs with two different causes**, and the current
code swapped one for the other:

- **url bar flies to top** (Probe 0) — caused by `.safeAreaInset(.bottom)`
  (with the animated spacer) combined with `.ignoresSafeArea(.keyboard)` on the
  webview. Removing BOTH (Probe 1) makes the url bar float correctly (y=434,
  above the keyboard). So the url bar is fine on its own without the
  ignoresSafeArea+spacer entanglement.
- **input scrolls off the top** (Probe 1) — caused by the SwiftUI `WebView`
  reacting to the keyboard safe area + WebKit scroll-to-focus overshoot.
  `.ignoresSafeArea(.keyboard)` on the webview (Probe 0) suppresses this (the
  frame doesn't change; WebKit's own contentInset handles the keyboard at 1×).

So the url bar and the input have **conflicting needs** under the SwiftUI
`WebView`:
- To keep the input from scrolling off, the webview must ignore the keyboard
  safe area — but that + `.safeAreaInset(.bottom)` flies the url bar to the top.
- To keep the url bar floating correctly, use plain `.safeAreaInset(.bottom)`
  without ignoresSafeArea — but then the input scrolls off.

### Proposed next step: Probe 2 — decouple the url bar from safeAreaInset

The conflicting needs come from entangling the url bar with the webview's safe
area via `.safeAreaInset(.bottom)`. Decouple them:

- **webview:** keep `.ignoresSafeArea(.keyboard)` (frame stays full-screen;
  WebKit's own contentInset handles the keyboard at 1× → input does NOT scroll
  off, as in Probe 0).
- **url bar:** move OUT of `.safeAreaInset(.bottom)` into a plain `ZStack`
  overlay pinned to the bottom, floated up by `keyboardObserver.keyboardHeight`.
  No safeAreaInset, no animated spacer → no SwiftUI safe-area recomputation to
  fling it to the top (the Probe 0 cause).

This keeps `WebPage` (no migration), keeps `KeyboardObserver` (now the sole
driver of the url-bar float, which is exactly what it was built for), and
removes the entanglement that caused both symptoms. If Probe 2 is clean (input
adjacent to url bar, both above the keyboard, no flying), **no raw-WKWebView
refactor is needed** — the TODO is avoided. If the url bar overlay still
glitches or the input still scrolls off even with ignoresSafeArea, THEN the
raw-`WKWebView` + `contentInsetAdjustmentBehavior = .never` refactor is
justified by measurement.

**Working-tree state:** the Probe 1 edit is currently applied (uncommitted) to
`App/Browser/TabbedBrowserView.swift`. Probe 2 will modify it further.

**Stop and report after Probe 0 + Probe 1.** No further changes until the
screenshot is reviewed and the path is agreed.

### Probe 2 — decouple the url bar from safeAreaInset (and the offset rabbit hole)

Ran FOUR sub-variants to isolate the cause. All on iPhone 17 (5D18FC7D),
software keyboard, keyboard assembly `(0, 471, 402, 403)` (top y=471), visible
keys `(0, 583, 402, 233)`.

Instrumented `KeyboardObserver` with `os_log` (category `keyboard`) — the raw
notification reports `endFrame=(0, 471, 402, 403)`, height **403** (the full
keyboard *assembly*: suggestion bar above + keys + home-indicator area below),
NOT the 233 the XCUIElement keyboard query reports. So `keyboardHeight=403` is
correct; it is the amount of the screen the keyboard assembly occupies (bottom
403pt, y=471..874).

| Probe | ignoresKb | url bar in | spacer/offset | url-pill y | input y |
|-------|-----------|------------|---------------|-----------|---------|
| 0     | yes       | safeAreaInset | spacer 403  | 54 (TOP ✗) | 246 (✓) |
| 1     | no        | safeAreaInset | none        | 434 (✓)    | −70 (OFF ✗) |
| 2     | yes       | overlay       | offset −403 | 31 (TOP ✗) | 350 (✓) |
| 2b    | yes       | overlay       | offset −233 | 201 (mid ✗)| 350 (✓) |
| 2e    | yes       | safeAreaInset | none        | 434 (✓)    | −70 (OFF ✗) |
| **2d**| **yes**   | **overlay**   | **none**    | **434 (✓)**| **350 (✓)** |

Two clean, independent findings:

1. **Url bar floats above the keyboard on its own — the manual spacer/offset
   was the bug.** A url bar placed in `.safeAreaInset(.bottom)` OR
   `.overlay(.bottom)` ALREADY anchors at the keyboard-safe-area bottom (y≈471)
   via SwiftUI's keyboard avoidance. Adding a manual spacer/offset of
   `keyboardHeight` (403) double-counts (471 − 403 = 68 → top of screen). This
   is exactly the "url bar flies to the top" bug — caused by the manual float,
   NOT by `safeAreaInset` vs `overlay`, and NOT by `ignoresSafeArea` per se.
   Probes 0, 2, 2b all had the manual push → bar at top/mid; Probes 1, 2e, 2d
   had no manual push → bar at 434 (correct).

2. **`.safeAreaInset(.bottom)` breaks the webview's keyboard content inset →
   input scrolls off.** Putting the url bar in `.safeAreaInset(.bottom)`
   *replaces* the webview's UIKit keyboard `contentInset` (403) with just the
   toolbar height (~44), which is too small, so WebKit's scroll-to-focus
   overshoots and scrolls the input off the top (y=−70). Probes 1 & 2e
   (safeAreaInset, no spacer) both did this. `.overlay(.bottom)` does NOT touch
   the webview's safe area, so UIKit's 403 contentInset survives and the input
   stays visible (Probes 2, 2b, 2d). The spacer in Probe 0 "fixed" the input by
   re-growing the inset to 447 — but it also flung the url bar (finding 1).

### Probe 2d — the winner (stop fighting SwiftUI)

`.ignoresSafeArea(.keyboard)` on the webview + url bar in
`.overlay(alignment: .bottom)` with the **plain toolbar, no spacer, no offset,
no animation, no `KeyboardObserver` driving layout.**

Measured (keyboard up): input y=350..396, url-pill y=434..465, keyboard
assembly y=471..874. Vertical order: **input → url bar → keyboard** — exactly
the webpage | url bar | keyboard model. Both visible; url bar hittable.
No-keyboard state: url bar at the bottom (correct).

Why it works:
- `.ignoresSafeArea(.keyboard)` keeps the webview frame full-screen so it does
  NOT shrink for the keyboard (avoids the Theory-A 2× double-count); UIKit's
  own keyboard `contentInset` (403) handles the input at 1× → input visible.
- `.overlay(.bottom)` (not `.safeAreaInset`) preserves that UIKit contentInset
  (finding 2).
- No manual float → SwiftUI's keyboard avoidance floats the url bar on its own
  (finding 1). The keyboard's own animation drives the transition (no manual
  clock to desync).

### Conclusion

**No raw-`WKWebView` refactor is needed.** The TODO is avoided. The fix is a
NET DELETION of code: remove `KeyboardObserver`'s layout role (the spacer,
the offset, the animation, and likely the whole `KeyboardObserver` class),
move the compact url bar from `.safeAreaInset(.bottom)` to
`.overlay(.bottom)`, keep `.ignoresSafeArea(.keyboard)` on the webview. This is
exactly the "fewer special cases, stop fighting SwiftUI" direction.

Caveats / to verify in the real cleanup:
- The dismiss/restore case was not exercised (`keyboard dismissed = false` —
  the test's "Done"-button tap didn't fire, a test-harness issue). With no
  manual animation, dismiss is SwiftUI's own keyboard avoidance (url bar floats
  back down) — correct by construction, but verify on device.
- The 38pt gap between input (396) and url bar (434) is WebKit's
  scroll-to-focus landing position (it places the input well inside the visible
  region, not hard-against the url bar). Sane and bug-free; Safari may sit
  tighter, but this is not a regression vs. the scrambled prior state.
- iPad (regular) path is untouched (system `.bottomBar`); verify its web-input
  keyboard behavior on the booted iPad separately if desired.
- `KeyboardObserver` is still declared/instantiated in `BrowserRootContent`
  after Probe 2d (now unused for layout) and still has the probe `os_log`
  instrumentation — both to be removed in the real cleanup.

## Cleanup (the actual fix)

The fix is a **net deletion of code.** No raw-`WKWebView` refactor; `WebPage`
stays; the TODO is avoided. `KeyboardObserver` is removed entirely — its sole
job was the manual float that double-counted and flung the url bar to the top.

Changes:

- `App/Browser/TabbedBrowserView.swift` (`BrowserRootContent`):
  - Removed `@StateObject keyboardObserver` and its doc comment.
  - Webview keeps `.ignoresSafeArea(.keyboard)` (frame stays full-screen;
    UIKit's own keyboard contentInset handles the focused input at 1× → input
    visible, not scrolled off).
  - Compact url bar moved from `.safeAreaInset(.bottom)` to
    `.overlay(alignment: .bottom)` — plain `CompactBrowserToolbar`, no
    spacer, no offset, no animation. `.overlay` (not `safeAreaInset`)
    preserves the webview's UIKit keyboard contentInset; and with no manual
    float, SwiftUI's keyboard avoidance floats the bar above the keyboard on
    its own (no double-count → no "flies to top"). The keyboard's own
    animation drives the transition (no manual clock to desync).
- `App/Browser/KeyboardObserver.swift`: **deleted** (dead code).
- `UITests/ApertureUITests.swift` (`testChatInputKeyboardLayoutRepro`):
  corrected the doc comment's "Root cause" — it asserted the 2×
  double-counting theory, which the probes disproved; the real causes were the
  manual spacer/offset double-count + `safeAreaInset` clobbering the webview's
  keyboard contentInset.

Verification (run 2026-07-27, iPhone 17 sim, software keyboard on):
- Full UI test suite: **15/17 passed.** The two failures are pre-existing and
  unrelated to this change (confirmed by diff scope — purely UI-layout):
  - `testExitNodeChangesEgressIP` — the documented tsnet exit-node routing bug
    (`README.tsnet-exit-nodes-dont-work.md`); the test's own message references
    it. Networking, not layout.
  - `testHTTPSCertMismatchShowsError` — TLS cert verification on a bare
    hostname (`https://ai/`); networking/cert, not layout.
- `testChatInputKeyboardLayoutRepro` **passed** and confirms the fix: input
  y=350, url-pill y=434 (hittable), keyboard assembly y=471 — input → url bar
  → keyboard, both visible.
- Dismiss/restore is NOT exercised on sim (test-harness "Done"-tap issue);
  correct by construction (SwiftUI's own keyboard avoidance floats the bar
  back down). Verify on a real device.
- iPad (regular) path untouched (system `.bottomBar`); its web-input keyboard
  behavior was not part of this bug and is unchanged.

## Open questions

1. Can probes run on a real device if needed? (The sim can now exercise the
   keyboard, so probes 0–2 are sim-valid; only a final real-device sanity check
   may be wanted.)
2. If the cheapest rock-solid option turns out to be "url bar covered by
   keyboard while a web input is focused" (zero special cases), is that
   acceptable, or is "url bar always visible above keyboard" a hard
   requirement? Assumed hard requirement (matches the stated webpage | url bar
   | keyboard model).
