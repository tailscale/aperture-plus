//
//  KeyboardObserver.swift
//  Aperture
//
//  Publishes the on-screen software-keyboard assembly height (and the
//  keyboard's own animation duration) so the compact URL toolbar can float
//  above the keyboard DETERMINISTICALLY — driven by the real keyboard
//  notifications, not by SwiftUI's implicit keyboard-avoidance for an overlay.
//
//  Why we can't rely on SwiftUI's implicit avoidance here: the URL toolbar is a
//  sibling of the webview in a `ZStack(.bottom)` (the webview
//  `.ignoresSafeArea(.keyboard)`, so it stays full-screen). SwiftUI *does*
//  float a bottom-aligned bar above the keyboard on its own, but that implicit
//  avoidance DESYNCS after a UIKit (web) text field is focused then blurred:
//  on the next SwiftUI field focus the bar floats by the wrong amount and ends
//  up parked under the keyboard (the "URL bar disappears after a web-focus/blur
//  cycle" bug — see `testURLBarSurvivesWebFocusBlurCycle`). Driving the float
//  explicitly from the keyboard notifications is immune to that desync: the bar
//  always moves by exactly the keyboard height.
//
//  The published height is the keyboard frame's full height (the assembly:
//  suggestion bar + keys + home-indicator area). On real hardware the keyboard
//  is docked to the bottom, so its full height is the on-screen overlap.
//
//  In `TabbedBrowserView` the toolbar applies `.offset(y: -max(0,
//  keyboardHeight - bottomSafeInset))` (the home-indicator inset is subtracted
//  so the bar's bottom lands exactly at the keyboard's top edge, not
//  overshooting by the home-indicator height), animated on the keyboard's own
//  duration so the bar rises/falls in lockstep with the keyboard.

import UIKit
import Combine

@MainActor
final class KeyboardObserver: ObservableObject {
    /// Current software-keyboard assembly height in points (0 when hidden).
    @Published private(set) var keyboardHeight: CGFloat = 0
    /// The keyboard's own animation duration for the current transition.
    @Published private(set) var animationDuration: Double = 0.25

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let center = NotificationCenter.default
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
