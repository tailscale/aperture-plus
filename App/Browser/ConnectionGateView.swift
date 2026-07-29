//
//  ConnectionGateView.swift
//  Aperture
//
//  The pre-connection "onboarding" screen: the brand header + Tailscale status
//  + Login button. Shown by `TabbedBrowserView` until the tailnet first
//  reaches `Running`, after which the tabbed browser takes over for the rest
//  of the session. Keeps the brand header (with the Settings gear) and the
//  "Tailscale Status" section so the connection-independent UI tests still
//  have their anchors here.
//

import SwiftUI

struct ConnectionGateView: View {
    @ObservedObject var statusViewModel: StatusViewModel
    let onTabs: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ApertureBrandHeader {
                HStack(spacing: 14) {
                    Button {
                        onTabs()
                    } label: {
                        Image(systemName: "square.on.square")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("tab-overview-button")
                    .accessibilityLabel("Tabs")

                    Button {
                        onSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("settings-button")
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 10)

            StatusView(viewModel: statusViewModel)
                .padding()

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
