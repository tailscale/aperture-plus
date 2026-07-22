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

    var canGoBack: Bool {
        model.page.backForwardList.backList.count > 0
    }

    var canGoForward: Bool {
        model.page.backForwardList.forwardList.count > 0
    }

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
                        .onSubmit {
                            // Normalize and load URL
                            let trimmed = urlFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            let normalized = BrowserNavigator.normalizedURLString(from: trimmed)
                            urlFieldText = normalized
                            model.page.load(URL(string: normalized))
                        }
                    if model.page.isLoading {
                        ProgressView(value: model.page.estimatedProgress)
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
                    } else if model.page.isLoading {
                        Button(action: { model.page.stopLoading() }) {
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
                .animation(.easeInOut(duration: 0.2), value: model.page.isLoading)
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
        .animation(.snappy, value: model.page.backForwardList.backList.count)
        .animation(.snappy, value: model.page.backForwardList.forwardList.count)
        // Seed the URL field from the current page whenever this navigator
        // appears (e.g. when switching tabs — the navigator is keyed by tab
        // id, so it re-appears with the new tab's page). Without this the
        // field would be blank until the next navigation.
        .onAppear {
            if !isEditingURL {
                urlFieldText = currentURLString
            }
        }
        .onChange(of: model.page.backForwardList.currentItem?.url) {
            if !isEditingURL {
                urlFieldText = model.page.backForwardList.currentItem?.url.absoluteString ?? ""
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
        model.page.backForwardList.currentItem?.url.absoluteString
            ?? model.failedInitialURL?.absoluteString
            ?? ""
    }

    private static func normalizedURLString(from input: String) -> String {
        if let url = URL(string: input), let scheme = url.scheme, !scheme.isEmpty {
            return input
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

