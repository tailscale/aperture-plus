//
//  StatusViewModel.swift
//  Aperture
//
//  Created by Jonathan Nobels on 2025-12-16.
//

import SwiftUI

struct StatusView: View {

    @ObservedObject var viewModel: StatusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tailscale Status")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                Image(systemName: viewModel.statusIconName)
                    .foregroundStyle(iconColor)
                    .imageScale(.large)

                Text(viewModel.statusText)
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer()
            }

            if viewModel.needsAuth {
                StatusButton(text: "Login", action: viewModel.showAuth)
            }
        }
        .padding(.vertical, 8)
    }

    private var iconColor: Color {
        switch viewModel.statusIconName {
        case "checkmark.circle.fill":
            return .green
        case "person.crop.circle.badge.exclamationmark":
            return .orange
        case "stop.circle.fill":
            return .red
        case "hourglass.circle.fill":
            return .blue
        default:
            return .secondary
        }
    }
}

struct StatusButton: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button( action: action ) {
            Text(text)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.blue)
        )
    }
}

