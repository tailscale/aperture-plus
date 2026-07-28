//
//  CompactBrowserToolbar.swift
//  Aperture
//
//  The single, combined bottom bar for iPhone (compact width): back/forward,
//  a *narrow* URL pill that pops out to a full-width editable field when
//  tapped, and the tab/action cluster (new chat tab, tab overview, add
//  bookmark, and a "more" menu for bookmarks list / reload / settings).
//
//  This replaces the old two-bar layout (top toolbar + bottom BrowserNavigator)
//  on iPhone, reclaiming a bar's worth of vertical space. URL visibility is
//  intentionally low-key — the pill shows just the host — because in this
//  browser the URL is usually an internal Aperture/chat address; the full URL
//  is revealed by tapping the pill to edit.
//
//  iPad (regular width) keeps the separate TabBar + BrowserNavigator layout
//  (see TabbedBrowserView), so this view is only used when compact.
//

import SwiftUI
import WebKit

struct CompactBrowserToolbar: View {
    @ObservedObject var tab: BrowserTab
    let tabManager: TabManager
    let onNewChat: () -> Void
    let onTabOverview: () -> Void
    let onBookmarks: () -> Void
    let onAddBookmark: () -> Void
    let onSettings: () -> Void
    /// Opens the in-app log viewer — the only way to read the app's logs on a
    /// device that can't be attached to a Mac (no `log stream`/Console.app).
    let onLogs: () -> Void

    @State private var isEditing = false
    @State private var urlFieldText = ""
    @State private var backPressed = false
    @State private var forwardPressed = false
    @FocusState private var urlFieldFocused: Bool

    private var viewModel: BrowserViewModel { tab.viewModel }

    private var canGoBack: Bool { viewModel.canGoBack }
    private var canGoForward: Bool { viewModel.canGoForward }

    /// What the pill shows when not editing: the host, or a placeholder for an
    /// empty/unknown page.
    private var pillText: String {
        let host = tab.displayHost
        return host.isEmpty ? "Search or enter URL" : host
    }

    /// A lock icon for https/wss, a globe for everything else (http, etc.).
    private var pillIcon: String {
        let scheme = viewModel.url?.scheme?.lowercased() ?? ""
        return (scheme == "https" || scheme == "wss") ? "lock.fill" : "globe"
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isEditing {
                    editingBar
                } else {
                    compactBar
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isEditing)

            // Thin progress bar under the bar while a page is loading.
            if viewModel.isLoading {
                ProgressView(value: viewModel.estimatedProgress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
                    .frame(height: 2)
            }
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Compact (non-editing) bar

    private var compactBar: some View {
        HStack(spacing: 6) {
            if canGoBack {
                toolbarIcon("chevron.left", pressed: backPressed,
                            action: { viewModel.goBack() },
                            onPress: { backPressed = $0 })
            }
            if canGoForward {
                toolbarIcon("chevron.right", pressed: forwardPressed,
                            action: { viewModel.goForward() },
                            onPress: { forwardPressed = $0 })
            }

            // Narrow URL pill — tap to expand into a full-width editor.
            Button {
                startEditing()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: pillIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(pillText)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Connection-type indicator (direct/derped/internet).
                    ConnectionTypeIcon(type: tab.connectionType)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(Color(.secondarySystemBackground)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("url-pill")
            .accessibilityLabel("Address: \(pillText)")

            toolbarIcon("plus", action: onNewChat)
                .accessibilityIdentifier("new-chat-tab-button")
                .accessibilityLabel("New Chat Tab")

            Button {
                onTabOverview()
            } label: {
                tabOverviewIcon
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tab-overview-button")
            .accessibilityLabel("Tabs")

            toolbarIcon("bookmark", action: onAddBookmark)
                .accessibilityIdentifier("add-bookmark-button")
                .accessibilityLabel("Add Bookmark")

            Menu {
                Button {
                    viewModel.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                Button {
                    onBookmarks()
                } label: {
                    Label("Bookmarks", systemImage: "book")
                }
                Divider()
                Button {
                    onLogs()
                } label: {
                    Label("Logs", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    onSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .frame(width: 28, height: 28)
            }
            .accessibilityIdentifier("more-menu-button")
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    // MARK: - Editing (expanded) bar

    private var editingBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Enter URL", text: $urlFieldText)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($urlFieldFocused)
                .onSubmit(submit)
                .accessibilityIdentifier("url-field")

            if !urlFieldText.isEmpty {
                Button {
                    urlFieldText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }

            Button("Cancel") {
                cancelEditing()
            }
            .font(.subheadline)
            .accessibilityIdentifier("url-cancel-button")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    // MARK: - Editing helpers

    private func startEditing() {
        urlFieldText = viewModel.url?.absoluteString ?? tab.displayURL
        isEditing = true
        urlFieldFocused = true
    }

    private func cancelEditing() {
        isEditing = false
        urlFieldText = ""
    }

    private func submit() {
        let trimmed = BrowserNavigator.trimmedURLInput(urlFieldText)
        guard !trimmed.isEmpty else { return }
        if ProcessInfo.processInfo.arguments.contains("-UITestLogResponses") {
            logger.log("URL submit raw=\(Array(trimmed.utf8)) (\(trimmed.count) chars)")
        }
        let normalized = BrowserNavigator.normalizedURLString(from: trimmed)
        if let url = URL(string: normalized) {
            viewModel.load(url: url)
        } else {
            logger.log("Could not parse URL: \(normalized)")
            viewModel.reportURLParseFailure(normalized)
        }
        isEditing = false
    }

    // MARK: - Subviews

    /// Safari-style overlapping-squares icon with a count badge.
    private var tabOverviewIcon: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "square.on.square")
                .font(.system(size: 18))
            if tabManager.tabCount > 1 {
                Text("\(tabManager.tabCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(height: 14)
                    .background(Capsule().fill(Color.blue))
                    .offset(x: 6, y: -6)
            }
        }
    }

    /// A small circular toolbar icon with optional press feedback. Mirrors the
    /// `NavCircleButton` look from BrowserNavigator so the two layouts feel
    /// consistent. When `pressed`/`onPressChange` are nil it's a plain button.
    @ViewBuilder
    private func toolbarIcon(_ systemName: String,
                             pressed: Bool = false,
                             action: @escaping () -> Void,
                             onPress: ((Bool) -> Void)? = nil) -> some View {
        Button {
            onPress?(false)
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 30, height: 30)
                .scaleEffect(pressed ? 0.9 : 1.0)
        }
        .buttonStyle(.plain)
        .ifLet(onPress) { view, pressChange in
            view.simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressChange(true) }
                    .onEnded { _ in pressChange(false) }
            )
        }
    }
}

// MARK: - Conditional modifier helper

private extension View {
    /// Applies `transform` only when `value` is non-nil.
    @ViewBuilder
    func ifLet<Value, Transformed: View>(
        _ value: Value?,
        _ transform: (Self, Value) -> Transformed
    ) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
