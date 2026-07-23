//  Created by Jonathan Nobels on 2025-12-16.
//

import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var model: BrowserViewModel

    init(model: BrowserViewModel) {
        self.model = model
    }

    var body: some View {
        ZStack {
            // The webview itself. The navigation/URL toolbar and tab chrome
            // are owned by `TabbedBrowserView` (so they persist across tab
            // switches and can carry tab controls); this view is just the
            // page plus its error overlay.
            //
            // The webview respects the top safe area (notch / Dynamic Island)
            // so the page's top bar sits below it, not under it. The Aperture
            // chat UI uses `viewport-fit=cover` + Tailwind `pt-[env(safe-area-
            // inset-top)]`, but the iOS 26 WebKit SwiftUI `WebView` does not
            // propagate the safe-area inset as `env()` (verified: it resolves
            // to 0px even when the webview extends under the notch), so letting
            // the webview go under the notch would put the page's top bar at
            // top:0 = under the notch. Keeping the webview in the safe area
            // avoids that. (Safari's "text scrolls under the notch while the
            // header stays put" needs `env()` support we don't have yet — see
            // TODO #6.)
            WebView(model.page)

            // Navigation error overlay. Driven directly by `model.navError`
            // (set by `watchForNavitationErrors` on a failed load, cleared on
            // the next navigation), so it stays visible until the user retries
            // or navigates away — previously it auto-hid after 2s, which made
            // real failures easy to miss and hard for tests to catch.
            if let navError = model.navError {
                NavErrorOverlay(
                    url: navError.url,
                    message: model.navErrorMessage,
                    onRetry: { model.reload() },
                    onDismiss: { model.clearNavError() }
                )
                .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.navError?.url)
    }
}

/// The "Unable to load" card shown over the webview when a navigation fails.
/// Persistent (no auto-hide): tap Retry to reload, or the close button to
/// dismiss. Carries the `nav-error-overlay` accessibility identifier so UI
/// tests can detect that a load failed.
struct NavErrorOverlay: View {
    let url: URL
    let message: String?
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Unable to Load Page")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }

            Text(url.absoluteString)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                onRetry()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: 300)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .shadow(radius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav-error-overlay")
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
