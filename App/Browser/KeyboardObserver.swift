//  KeyboardObserver.swift
//  Aperture
//
//  Publishes the on-screen software-keyboard height (and the keyboard's own
//  animation duration) so the bottom URL toolbar can float above the keyboard
//  when a web text field is focused, in lockstep with the keyboard's animation.
//
//  Why this is needed at all: the browser's web content is a full-screen
//  `WKWebView` (its frame is the whole window; safe areas are applied via the
//  scroll view's `contentInset`, not by shrinking the view). When a text field
//  *inside the webview* is focused, the keyboard's first responder lives in
//  UIKit land, and SwiftUI's built-in keyboard avoidance does NOT reliably
//  propagate the keyboard safe-area inset to surrounding SwiftUI views — so a
//  `.safeAreaInset(.bottom)` URL toolbar stays parked at its no-keyboard
//  position and gets covered by the keyboard (the "URL bar disappears" bug).
//  The chat page itself does nothing for the iOS keyboard (its viewport meta
//  deliberately leaves it to the OS, like Safari), so we must float the chrome.
//
//  The fix (in `TabbedBrowserView`): append a transparent `Color.clear` spacer
//  of `keyboardHeight` points to the bottom safe-area-inset content. That both
//  floats the toolbar above the keyboard AND grows the bottom safe area so the
//  webview's scroll-view `contentInset` includes the keyboard — WebKit then
//  scrolls the focused input to just above the toolbar (input → URL bar →
//  keyboard).
//
//  Why the animation duration matters: the spacer height MUST change on the
//  keyboard's own animation timeline, not a hardcoded one. If the inset
//  collapses on a different clock than the keyboard, the three motions (our
//  inset, the keyboard, WebKit's scroll-to-focus) desynchronize — producing
//  janky mid-transition frames, and on dismiss leaving the page scrolled up
//  (the inset hits 0 while the keyboard still covers the bottom, so WebKit
//  clamps the scroll offset at the wrong moment). Driving the spacer with the
//  keyboard's reported duration keeps them in sync; on dismiss the inset
//  retreats with the keyboard and WebKit auto-clamps the offset back down —
//  Safari-style restore. See `UITests/…/testChatInputKeyboardLayoutRepro`.
//
//  The published height is the keyboard frame's full height (the amount of
//  vertical room the keyboard occupies). On real hardware the keyboard is
//  docked to the bottom, so its full height is the on-screen overlap. (On some
//  simulator states the keyboard frame can be reported off-screen; we still
//  publish the height so the layout reserves the right amount of room.)

import UIKit
import Combine

@MainActor
final class KeyboardObserver: ObservableObject {
    /// Current software-keyboard height in points (0 when hidden/dismissed).
    @Published private(set) var keyboardHeight: CGFloat = 0
    /// The keyboard's own animation duration for the *current* transition, in
    /// seconds. The spacer animates with this so it stays in lockstep with the
    /// keyboard (see the class doc). Defaults to 0.25 (the typical keyboard
    /// duration) when a notification omits it.
    @Published private(set) var animationDuration: Double = 0.25

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let center = NotificationCenter.default
        // `keyboardWillChangeFrameNotification` fires for show (with the end
        // frame) and interactive-dismiss drag updates; `keyboardWillHide` fires
        // on full dismissal. Both carry the keyboard's animation duration/curve
        // in userInfo, which we use to stay synchronized.
        center.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .merge(with: center.publisher(for: UIResponder.keyboardWillHideNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self else { return }
                let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
                    as? Double) ?? 0.25
                let height: CGFloat
                if note.name == UIResponder.keyboardWillHideNotification {
                    height = 0
                } else if let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                    as? CGRect {
                    // Height only — the keyboard is docked to the bottom on real
                    // hardware, so its full height is the on-screen overlap.
                    height = max(0, endFrame.height)
                } else {
                    height = 0
                }
                self.animationDuration = max(duration, 0.001)
                self.keyboardHeight = height
            }
            .store(in: &cancellables)
    }
}
