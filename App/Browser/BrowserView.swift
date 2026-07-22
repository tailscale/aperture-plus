//  Created by Jonathan Nobels on 2025-12-16.
//

import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var model: BrowserViewModel

    // Transient overlay state
    @State private var showNavErrorOverlay: Bool = false
    @State private var navErrorURLText: String = ""
    @State private var overlayTask: Task<Void, Never>?

    init(model: BrowserViewModel) {
        self.model = model
    }

    var body: some View {
        ZStack {
            // The webview itself. The navigation/URL toolbar and tab chrome
            // are owned by `TabbedBrowserView` (so they persist across tab
            // switches and can carry tab controls); this view is just the
            // page plus its transient error overlay.
            WebView(model.page)

            if showNavErrorOverlay {
                VStack(spacing: 8) {
                    Text("Unable to load")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if !navErrorURLText.isEmpty {
                        Text(navErrorURLText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: 260)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
                .shadow(radius: 8)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showNavErrorOverlay)
        .onChange(of: model.navError?.url) { _, newURL in
            // When a nav error occurs (model sets (error, url)), show overlay for 2 seconds.
            guard let failedURL = newURL else { return }
            navErrorURLText = failedURL.absoluteString

            // Cancel any existing overlay timer to avoid overlap
            overlayTask?.cancel()
            showNavErrorOverlay = true

            overlayTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showNavErrorOverlay = false
                    }
                }
            }
        }
        .onDisappear {
            overlayTask?.cancel()
        }
    }
}

struct LoadingView: View {
    var body: some View {
        VStack {
            Text("Connecting to your Tailnet...")
            ProgressView()
        }
    }
}
