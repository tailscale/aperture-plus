//
//  ApertureBrandHeader.swift
//  Aperture
//
//  A compact, centered brand lockup — the aperture app icon alongside the
//  "aperture" wordmark — shown at the top of the main list.
//
//  The icon uses the same full-color artwork as the app's home-screen icon
//  (AppIcon.appiconset) so the in-app branding matches the icon the user
//  sees on their home screen. It is clipped to a continuous-corner squircle
//  to read as an app icon rather than a square tile. The wordmark is a
//  template SVG (fill = currentColor) so it tints with the foreground style
//  and adapts to light/dark automatically.
//
//  An optional `trailing` view (e.g. the Settings gear) is pinned to the
//  trailing edge while the logo stays visually centered — this lets the
//  main screen drop its navigation bar (and the duplicate "Aperture" title
//  it carried) without losing access to Settings.
//

import SwiftUI

struct ApertureBrandHeader<Trailing: View>: View {
    @ViewBuilder var trailing: () -> Trailing

    init(@ViewBuilder trailing: @escaping () -> Trailing) {
        self.trailing = trailing
    }

    var body: some View {
        ZStack {
            // Centered logo: app icon + wordmark.
            HStack(spacing: 10) {
                Image("ApertureIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                Image("ApertureWordmark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 21)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Aperture")
            .accessibilityIdentifier("aperture-brand-header")

            // Trailing control (e.g. Settings gear), pinned to the trailing
            // edge. Kept outside the centered logo's accessibility element so
            // it remains independently tappable/identifiable.
            HStack {
                Spacer()
                trailing()
            }
        }
    }
}

/// Convenience initializer for a header with no trailing control.
extension ApertureBrandHeader where Trailing == EmptyView {
    init() {
        self.init { EmptyView() }
    }
}
