//
//  ConnectionTypeIcon.swift
//  Aperture
//
//  The per-tab connection-type indicator. Small and harmless-looking (the
//  direct/derped distinction is for diagnostics, not a warning):
//
//    .direct   — two green dots (both ends directly connected)
//    .derped   — one green dot (going via a relay)
//    .unknownTailnetHost — a red dot (tailnet namespace, but no such peer)
//    .internet — an external-link icon (this page leaves the tailnet)
//
//  Shown next to the URL pill (iPhone), on each tab chip (iPad TabBar), and on
//  each card in the tab overview.
//

import SwiftUI

struct ConnectionTypeIcon: View {
    let type: ConnectionType

    var body: some View {
        switch type {
        case .direct:
            // Two green dots — a direct peer-to-peer path (both ends).
            HStack(spacing: 2) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Circle().fill(.green).frame(width: 8, height: 8)
            }
            .accessibilityLabel("Direct tailnet connection")
        case .derped:
            // One green dot — connected via a DERP relay.
            Circle().fill(.green).frame(width: 8, height: 8)
                .accessibilityLabel("Tailnet connection via relay")
        case .unknownTailnetHost:
            Circle().fill(.red).frame(width: 8, height: 8)
                .accessibilityLabel("Unknown tailnet host")
        case .internet:
            // External-link-style icon — this page is off the tailnet.
            Image(systemName: "arrow.up.forward.square")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Internet (off tailnet)")
        }
    }
}
