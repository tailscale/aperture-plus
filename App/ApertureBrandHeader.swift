//
//  ApertureBrandHeader.swift
//  Aperture
//
//  A compact, centered brand lockup — the aperture mark alongside the
//  "aperture" wordmark — shown at the top of the main list. Both assets are
//  template SVGs (fill = currentColor), so they tint with the foreground
//  style and adapt to light/dark automatically.
//

import SwiftUI

struct ApertureBrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image("ApertureMark")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .foregroundStyle(.blue)

            Image("ApertureWordmark")
                .resizable()
                .scaledToFit()
                .frame(height: 20)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aperture")
    }
}
