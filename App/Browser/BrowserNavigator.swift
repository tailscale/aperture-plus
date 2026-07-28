//  Created by Jonathan Nobels on 2025-12-19.
//

import SwiftUI
import WebKit

struct BrowserNavigator: View {
    @ObservedObject var model: BrowserViewModel

    @State private var urlFieldText: String = ""

    // Press feedback
    @State private var backPressed: Bool = false
    @State private var forwardPressed: Bool = false
    @State private var bookmarkPressed: Bool = false

    // Editing state
    @State private var isEditingURL: Bool = false

    // Callback to request opening the bookmark editor
    let onAddBookmark: () -> Void

    init(model: BrowserViewModel, onAddBookmark: @escaping () -> Void) {
        self.model = model
        self.onAddBookmark = onAddBookmark
    }

    var canGoBack: Bool { model.canGoBack }

    var canGoForward: Bool { model.canGoForward }

    var body: some View {
        HStack(spacing: 10) {

            if canGoBack || canGoForward {
                HStack(spacing: 8) {
                    if canGoBack {
                        NavCircleButton(
                            systemName: "chevron.left",
                            pressed: backPressed,
                            action: {
                                withAnimation(.snappy) {
                                    model.goBack()
                                }
                            },
                            onPressChange: { down in
                                withAnimation(.smooth(duration: 0.12)) {
                                    backPressed = down
                                }
                            }
                        )
                    }

                    if canGoForward {
                        NavCircleButton(
                            systemName: "chevron.right",
                            pressed: forwardPressed,
                            action: {
                                withAnimation(.snappy) {
                                    model.goForward()
                                }
                            },
                            onPressChange: { down in
                                withAnimation(.smooth(duration: 0.12)) {
                                    forwardPressed = down
                                }
                            }
                        )
                    }
                }
            }

            HStack(spacing: 8) {
                VStack {
                    TextField("Enter URL", text: $urlFieldText, onEditingChanged: { isEditingURL = $0 })
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .submitLabel(.go)
                        .accessibilityIdentifier("url-field")
                        .onSubmit {
                            // Normalize and load URL via the watched loader so
                            // failures surface the error overlay (a direct
                            // `page.load` here previously failed silently).
                            let trimmed = BrowserNavigator.trimmedURLInput(urlFieldText)
                            guard !trimmed.isEmpty else { return }
                            // Diagnostic (launch arg `-UITestLogResponses`): log the
                            // raw bytes the keyboard handed us, so real-device
                            // input mangling (autocorrect / autocapitalize /
                            // smart punctuation on the toolbar field) is visible
                            // in `log stream` when chasing spurious 'That URL
                            // is invalid.' errors. Off by default.
                            if ProcessInfo.processInfo.arguments.contains("-UITestLogResponses") {
                                logger.log("URL submit raw=\(Array(trimmed.utf8)) (\(trimmed.count) chars)")
                            }
                            let normalized = BrowserNavigator.normalizedURLString(from: trimmed)
                            urlFieldText = normalized
                            if let url = URL(string: normalized) {
                                model.load(url: url)
                            } else {
                                // A normalized string (always has a scheme) is
                                // essentially always parseable; if it isn't,
                                // surface it via the error overlay (escaped)
                                // instead of failing silently.
                                logger.log("Could not parse URL: \(normalized)")
                                model.reportURLParseFailure(normalized)
                            }
                        }
                    if model.isLoading {
                        ProgressView(value: model.estimatedProgress)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                            .frame(height: 2)
                            .padding(.horizontal)
                            .padding(.top, 2)
                    }
                }

                Group {
                    if isEditingURL {
                        // Clear button while editing
                        Button(action: {
                            urlFieldText = ""
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                    } else if model.isLoading {
                        Button(action: { model.stopLoading() }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: { model.reload() }) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .foregroundStyle(.secondary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: model.isLoading)
                .animation(.easeInOut(duration: 0.2), value: isEditingURL)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )

            NavCircleButton(
                systemName: "bookmark",
                pressed: bookmarkPressed,
                action: onAddBookmark,
                onPressChange: { down in
                    withAnimation(.smooth(duration: 0.12)) {
                        bookmarkPressed = down
                    }
                }
            )
            .accessibilityLabel("Add Bookmark")
            .accessibilityIdentifier("add-bookmark-button")
        }
        .animation(.snappy, value: model.canGoBack)
        .animation(.snappy, value: model.canGoForward)
        // Seed the URL field from the current page whenever this navigator
        // appears (e.g. when switching tabs — the navigator is keyed by tab
        // id, so it re-appears with the new tab's page). Without this the
        // field would be blank until the next navigation.
        .onAppear {
            if !isEditingURL {
                urlFieldText = currentURLString
            }
        }
        .onChange(of: model.url) {
            if !isEditingURL {
                urlFieldText = model.url?.absoluteString ?? ""
            }
        }
        .onChange(of: model.failedInitialURL) {
            if let url = model.failedInitialURL, !isEditingURL {
                urlFieldText = url.absoluteString
            }
        }
    }

    /// The URL to show in the field when not actively editing: the current
    /// back/forward item's URL, falling back to the failed-initial URL.
    private var currentURLString: String {
        model.url?.absoluteString
            ?? model.failedInitialURL?.absoluteString
            ?? ""
    }

    /// Trims leading/trailing whitespace from a URL-bar input, including the
    /// Unicode whitespace characters (U+00A0 non-breaking space, U+200B
    /// zero-width space, etc.) that `.whitespacesAndNewlines` misses and that
    /// the iOS keyboard can insert. Used by both toolbars' submit paths.
    static func trimmedURLInput(_ input: String) -> String {
        // Strip ALL Unicode whitespace from both ends (CharacterSet.whitespaces
        // includes U+00A0; .whitespacesAndNewlines in some SDKs did not).
        let ws = CharacterSet.whitespaces.union(.newlines)
        var s = input.trimmingCharacters(in: ws)
        // Also drop any stray zero-width / non-breaking spaces anywhere — a
        // keyboard can inject them mid-string and they break URL parsing.
        let invisibles: Set<Character> = ["\u{00A0}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"]
        s = String(s.filter { !invisibles.contains($0) })
        return s.trimmingCharacters(in: ws)
    }

    /// Normalizes a URL-bar input into a string suitable for `URL(string:)` /
    /// `WebPage.load`. Prepends `https://` when there's no scheme, and — to
    /// survive real-keyboard input mangling on iPad (where the toolbar
    /// TextField's `.textInputAutocapitalization(.never)`/`.autocorrectionDisabled()`
    /// are not always honored, so autocorrect can mutate `https` into a
    /// non-http scheme) — if the parsed scheme is anything other than http or
    /// https, strips that scheme and prepends `https://` instead. A non-http
    /// scheme would otherwise parse as a valid `URL` but be rejected by WebKit's
    /// `WebPage.load` as `.invalidURL` ("That URL is invalid."), which is the
    /// reported iPad symptom.
    static func normalizedURLString(from input: String) -> String {
        // Fast path: already explicitly http(s) — the overwhelmingly common case.
        let lower = input.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return input
        }
        if let url = URL(string: input), let scheme = url.scheme, !scheme.isEmpty {
            let s = scheme.lowercased()
            if s == "http" || s == "https" {
                return input
            }
            // Parsed with a non-http(s) scheme (e.g. autocorrect mangled
            // "https" into "httpd"). Strip the "scheme://" and treat the rest
            // as a host/path under https.
            if let r = input.range(of: "://") {
                return "https://\(input[r.upperBound...])"
            }
            // Scheme but no "://" (e.g. "mailto:foo"); prepend https to the lot.
            return "https://\(input)"
        }
        return "https://\(input)"
    }
}

private struct NavCircleButton: View {
    let systemName: String
    let pressed: Bool
    let action: () -> Void
    let onPressChange: (Bool) -> Void

    var body: some View {
        Button(action: {
            onPressChange(false)
            action()
        }) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 32)
                .overlay(
                    Circle()
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
                .scaleEffect(pressed ? 0.92 : 1.0)
                .animation(.smooth(duration: 0.12), value: pressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    onPressChange(true)
                }
                .onEnded { _ in
                    onPressChange(false)
                }
        )
    }
}

