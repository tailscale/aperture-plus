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
        Group {
            if let navError = model.navError {
                // A failed navigation replaces the page, like a conventional
                // browser error document. Because no old page remains visible,
                // the chrome may safely show the attempted URL.
                NavErrorPage(
                    urlString: model.navErrorURLString ?? navError.url?.absoluteString ?? "",
                    kind: model.navErrorKind,
                    message: model.navErrorMessage
                )
            } else {
                // The owned WKWebView extends beneath the notch/Dynamic Island.
                // Pages using viewport-fit=cover can consume the real CSS safe-
                // area values, matching Safari's edge-to-edge model.
                RawWebView(model: model)
                    // A WKWebView belongs to exactly one tab; prevent
                    // UIViewRepresentable from reusing the previous tab's view.
                    .id(ObjectIdentifier(model))
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        // Cover the instant before UIViewRepresentable installs WKWebView with
        // the same adaptive background used by RawWebView itself.
        .background(Color.platformSystemBackground)
        // While a user-entered navigation is in flight (before commit), hide the
        // still-rendered previous page so its origin can't be mistaken for the
        // destination. The entered URL is already shown in the address bar; an
        // empty page has no phishing danger. Drops on commit/failure/stop.
        .overlay {
            if model.blankingContent {
                ZStack {
                    Color.platformSystemBackground
                    if model.isLoading {
                        ProgressView()
                            .controlSize(.large)
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
                .accessibilityIdentifier("user-load-blank")
                .transition(.opacity)
            }
        }
    }
}

/// The full-page error document shown in place of web content when navigation
/// fails. The `nav-error-overlay` identifier is retained for UI-test
/// compatibility even though this is no longer an overlay or modal card.
///
/// The URL is rendered **escaped** (via `debugEscaped`) so invisible or
/// problematic characters the keyboard may have injected — non-breaking space
/// (U+00A0), zero-width space (U+200B), smart quotes (U+201C/201D), tabs,
/// newlines, etc. — are visible as `\u{XXXX}` instead of silently breaking the
/// URL. `kind` distinguishes a URL **format** error (parse/validation rejected)
/// from a **retrieval** error (couldn't connect) via a small category label.
struct NavErrorPage: View {
    let urlString: String
    let kind: NavErrorKind?
    let message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
                .padding(.bottom, 4)
            Text("Unable to Load Page")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)

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

        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformSystemBackground)
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
