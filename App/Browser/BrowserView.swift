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
            //
            // TODO(#6 notch): to get true Safari behavior (page content extends
            // under the notch, page's own sticky header pins just below it via
            // `env(safe-area-inset-top)`), we need `env()` to be non-zero.
            // The iOS 26 SwiftUI `WebView` doesn't propagate the safe-area
            // inset as `env()` (verified via JS: 0px even under the notch), so
            // the fix is to drop down to a raw `WKWebView` wrapped in a
            // `UIViewRepresentable`, set `scrollView.contentInsetAdjustment
            // Behavior = .never`, and lay it out under the notch — then the
            // page's `pt-[env(safe-area-inset-top)]` resolves to the real
            // inset. Verify on a real device (sim safe-area may differ).
            WebView(model.page)

            // Navigation error overlay. Driven directly by `model.navError`
            // (set by `watchForNavitationErrors` on a failed load, cleared on
            // the next navigation), so it stays visible until the user retries
            // or navigates away — previously it auto-hid after 2s, which made
            // real failures easy to miss and hard for tests to catch.
            if let navError = model.navError {
                NavErrorOverlay(
                    urlString: model.navErrorURLString ?? navError.url?.absoluteString ?? "",
                    kind: model.navErrorKind,
                    message: model.navErrorMessage,
                    onRetry: { model.reload() },
                    onDismiss: { model.clearNavError() }
                )
                .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.navErrorURLString)
    }
}

/// The "Unable to load" card shown over the webview when a navigation fails.
/// Persistent (no auto-hide): tap Retry to reload, or the close button to
/// dismiss. Carries the `nav-error-overlay` accessibility identifier so UI
/// tests can detect that a load failed.
///
/// The URL is rendered **escaped** (via `debugEscaped`) so invisible or
/// problematic characters the keyboard may have injected — non-breaking space
/// (U+00A0), zero-width space (U+200B), smart quotes (U+201C/201D), tabs,
/// newlines, etc. — are visible as `\u{XXXX}` instead of silently breaking the
/// URL. `kind` distinguishes a URL **format** error (parse/validation rejected)
/// from a **retrieval** error (couldn't connect) via a small category label.
struct NavErrorOverlay: View {
    let urlString: String
    let kind: NavErrorKind?
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

            // Category label — distinguishes a URL format problem (the URL
            // itself is bad) from a retrieval problem (the URL is fine but we
            // couldn't reach it). Helps the user know whether to fix the URL
            // or check their connection.
            if let kind, let label = categoryLabel(for: kind) {
                Text(label.text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(label.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The URL, escaped for diagnosis. Monospaced so the `\u{XXXX}`
            // sequences align and any unexpected characters stand out.
            VStack(alignment: .leading, spacing: 2) {
                Text("URL (escaped for debugging):")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(debugEscaped(urlString))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

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

    /// A short label + color for each error category, or nil for `.other`
    /// (page-closed / content-process crash — no useful category to show).
    private func categoryLabel(for kind: NavErrorKind) -> (text: String, color: Color)? {
        switch kind {
        case .urlFormat:
            return ("URL format error", .orange)
        case .retrieval:
            return ("Connection error", .secondary)
        case .other:
            return nil
        }
    }
}

/// Returns a diagnostic, escape-only representation of `s` for the error
/// overlay: every Unicode scalar outside printable ASCII (0x20–0x7E) is
/// rendered as `\u{XXXX}` so invisible/problematic characters the keyboard may
/// have injected (non-breaking space U+00A0, zero-width space U+200B, smart
/// quotes U+201C/201D, tabs, newlines, etc.) are visible. Printable ASCII
/// (including the regular space) is shown as-is, so a clean URL reads normally.
///
/// Percent-encoding is decoded first, so a percent-encoded bad char (e.g.
/// `%C2%A0` for a non-breaking space that `URL(string:)` encoded) reveals its
/// true scalar (`\u{A0}`) rather than the opaque encoding.
func debugEscaped(_ s: String) -> String {
    let decoded = s.removingPercentEncoding ?? s
    var out = ""
    for scalar in decoded.unicodeScalars {
        if scalar.value >= 0x20 && scalar.value <= 0x7E {
            out += String(scalar)
        } else {
            out += String(format: "\\u{%X}", scalar.value)
        }
    }
    return out
}

struct LoadingView: View {
    var body: some View {
        VStack {
            Text("Connecting to your Tailnet...")
            ProgressView()
        }
    }
}
