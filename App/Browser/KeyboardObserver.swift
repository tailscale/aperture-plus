//  KeyboardObserver.swift
//  Aperture
//
//  Publishes the on-screen software-keyboard height so SwiftUI chrome that
//  lives in a `.safeAreaInset(.bottom)` can float above the keyboard.
//
//  Why this is needed at all: the browser's web content is a full-screen
//  `WKWebView` (its frame is the whole window; safe areas are applied via the
//  scroll view's `contentInset`, not by shrinking the view). When a text field
//  *inside the webview* is focused, the keyboard's first responder lives in
//  UIKit land, and SwiftUI's built-in keyboard avoidance does NOT reliably
//  propagate the keyboard safe-area inset to surrounding SwiftUI views — so a
//  `.safeAreaInset(.bottom)` URL toolbar stays parked at its no-keyboard
//  position and gets covered by the keyboard (the "URL bar disappears" bug),
//  while WebKit still scrolls the focused input up to make room for the
//  keyboard, leaving the input floating above an empty gap instead of sitting
//  next to the URL bar.
//
//  The fix (in `TabbedBrowserView`): append a transparent `Color.clear` spacer
//  of `keyboardHeight` points to the bottom safe-area-inset content. That both
//  floats the toolbar above the keyboard AND grows the bottom safe area so the
//  webview's scroll-view `contentInset` includes the keyboard — WebKit then
//  scrolls the focused input to just above the toolbar (Safari-style: input →
//  URL bar → keyboard), with no gap and no overlap. See
//  `UITests/…/testChatInputKeyboardLayoutRepro`.
//
//  The published height is the keyboard frame's full height (the amount of
//  vertical room the keyboard occupies). On a real device the keyboard is
//  docked to the bottom of the screen, so its full height is on-screen. (On
//  some simulator states the keyboard frame can be reported off-screen; we
//  still publish the height so the layout reserves the right amount of room —
//  the toolbar ends up where it would be above a docked keyboard.)

import UIKit
import Combine

@MainActor
final class KeyboardObserver: ObservableObject {
    /// Current software-keyboard height in points (0 when hidden/dismissed).
    @Published private(set) var keyboardHeight: CGFloat = 0

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let center = NotificationCenter.default
        // `keyboardWillChangeFrameNotification` fires for both show (with the
        // end frame) and interactive-dismiss drag updates; `keyboardWillHide`
        // fires on full dismissal. Merge and reduce to a single height.
        center.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .merge(with: center.publisher(for: UIResponder.keyboardWillHideNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self else { return }
                if note.name == UIResponder.keyboardWillHideNotification {
                    self.keyboardHeight = 0
                    return
                }
                guard let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                    as? CGRect else {
                    self.keyboardHeight = 0
                    return
                }
                // Height only — the keyboard is docked to the bottom on real
                // hardware, so its full height is the on-screen overlap. Ignore
                // the frame's vertical position (see the sim note above).
                self.keyboardHeight = max(0, endFrame.height)
            }
            .store(in: &cancellables)
    }
}
