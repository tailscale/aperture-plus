//
//  TabbedBrowserView.swift
//  Aperture
//
//  The root window: a Safari-style multi-tab web browser. Until the tailnet
//  first reaches `Running` it shows `ConnectionGateView` (the onboarding/login
//  screen); once connected it switches to the tabbed browser for the rest of
//  the session (subsequent reconnects show an inline banner, not the gate).
//
//  - First tab is always an Aperture chat (the home page).
//  - "+" opens an additional Aperture-chat tab.
//  - iPhone (compact): tabs are managed via the tab-overview button
//    (`square.on.square`); the overview is a full-screen card grid.
//  - iPad (regular): a persistent `TabBar` of tab chips is shown atop the
//    content, in addition to the overview button.
//

import SwiftUI
import WebKit
import TailscaleKit

struct TabbedBrowserView: View {
    let manager: TSNetManager
    @StateObject private var tabManager: TabManager
    @StateObject private var statusViewModel: StatusViewModel

    /// Flips to true the first time the tailnet reaches `Running` and stays
    /// true — so a transient reconnect doesn't kick the user back to the gate.
    @State private var hasConnected = false

    /// Settings is global (reachable from both the gate and the browser), so
    /// its full-screen cover lives here.
    @State private var showingSettings = false

    init(manager: TSNetManager) {
        self.manager = manager
        _tabManager = StateObject(wrappedValue: TabManager(model: manager.model))
        _statusViewModel = StateObject(wrappedValue: StatusViewModel(manager: manager))
    }

    var body: some View {
        Group {
            if hasConnected, let tab = tabManager.currentTab {
                BrowserRootContent(
                    manager: manager,
                    tabManager: tabManager,
                    tab: tab,
                    statusViewModel: statusViewModel,
                    onSettings: { showingSettings = true }
                )
            } else {
                ConnectionGateView(
                    statusViewModel: statusViewModel,
                    onSettings: { showingSettings = true }
                )
            }
        }
        .onAppear {
            if statusViewModel.running { hasConnected = true }
        }
        .onChange(of: statusViewModel.running) { _, running in
            if running { hasConnected = true }
        }
        .fullScreenCover(isPresented: $showingSettings) {
            SettingsView(viewModel: SettingsViewModel(manager: manager),
                         dismissAction: { showingSettings = false })
        }
    }
}

// MARK: - Browser root (connected)

/// The connected browser chrome: the current tab's `BrowserView` plus the tab
/// controls, URL/navigation toolbar, and per-tab sheets. Observes the current
/// `BrowserTab` directly so the nav title tracks live page-title changes.
private struct BrowserRootContent: View {
    let manager: TSNetManager
    @ObservedObject var tabManager: TabManager
    @ObservedObject var tab: BrowserTab
    @ObservedObject var statusViewModel: StatusViewModel
    let onSettings: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var showingTabOverview = false
    @State private var showingBookmarks = false
    @State private var showingBookmarkEditor = false

    var body: some View {
        NavigationStack {
            BrowserView(model: tab.viewModel)
                .safeAreaInset(edge: .top) {
                    // Persistent tab bar on iPad / regular width only.
                    if hSizeClass == .regular {
                        TabBar(tabManager: tabManager, onNewChat: { tabManager.openChatTab() })
                    }
                }
                .toolbar {
                    if hSizeClass == .regular {
                        // iPad: keep the top action cluster + bottom URL bar.
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button {
                                tabManager.openChatTab()
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityIdentifier("new-chat-tab-button")
                            .accessibilityLabel("New Chat Tab")

                            Button {
                                showingTabOverview = true
                            } label: {
                                tabOverviewIcon
                            }
                            .accessibilityIdentifier("tab-overview-button")
                            .accessibilityLabel("Tabs")

                            Button {
                                showingBookmarks = true
                            } label: {
                                Image(systemName: "book")
                            }
                            .accessibilityIdentifier("bookmarks-button")
                            .accessibilityLabel("Bookmarks")

                            Button {
                                onSettings()
                            } label: {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityIdentifier("settings-button")
                            .accessibilityLabel("Settings")
                        }

                        ToolbarItemGroup(placement: .bottomBar) {
                            // Key by tab id so the URL field re-seeds on tab switch.
                            BrowserNavigator(
                                model: tab.viewModel,
                                onAddBookmark: { showingBookmarkEditor = true }
                            )
                            .id(tab.id)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if hSizeClass == .compact {
                        CompactBrowserToolbar(
                            tab: tab,
                            tabManager: tabManager,
                            onNewChat: { tabManager.openChatTab() },
                            onTabOverview: { showingTabOverview = true },
                            onBookmarks: { showingBookmarks = true },
                            onAddBookmark: { showingBookmarkEditor = true },
                            onSettings: onSettings
                        )
                        .id(tab.id)
                    }
                }
                .navigationTitle(hSizeClass == .compact ? "" : (tab.displayTitle.isEmpty ? "Aperture" : tab.displayTitle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(hSizeClass == .compact ? .hidden : .visible, for: .navigationBar)
                .overlay(alignment: .top) {
                    if statusViewModel.needsAuth {
                        LoginBanner(onLogin: { statusViewModel.showAuth() })
                    } else if !tab.viewModel.isConnected {
                        ReconnectingBanner()
                    }
                }
        }
        .fullScreenCover(isPresented: $showingTabOverview) {
            TabOverview(
                tabManager: tabManager,
                onNewChat: {
                    tabManager.openChatTab()
                    showingTabOverview = false
                }
            )
        }
        .sheet(isPresented: $showingBookmarks) {
            BookmarksSheet { bookmark in
                if let url = URL(string: bookmark.url) {
                    tab.viewModel.load(url: url)
                }
            }
        }
        .sheet(isPresented: $showingBookmarkEditor) {
            BookmarkEditor(
                dismissAction: { showingBookmarkEditor = false },
                initialName: tab.viewModel.page.title,
                initialURLString: tab.viewModel.page.url?.absoluteString ?? ""
            )
        }
    }

    /// Safari-style overlapping-squares icon with a count badge.
    private var tabOverviewIcon: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "square.on.square")
            if tabManager.tabCount > 1 {
                Text("\(tabManager.tabCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(height: 14, alignment: .center)
                    .background(Capsule().fill(Color.blue))
                    .offset(x: 6, y: -6)
            }
        }
    }
}

/// Inline "login required" banner shown over the browser if the node drops to
/// `NeedsLogin` after having connected (e.g. the user logged out).
private struct LoginBanner: View {
    let onLogin: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("Login Required")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("Login", action: onLogin)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Inline "Reconnecting…" banner shown over the browser when the tailnet proxy
/// drops (e.g. right after returning from the background, before the node
/// finishes reconnecting). Loads are held and auto-retried (see
/// `BrowserViewModel.applyProxy`), so this is informational — no retry button.
private struct ReconnectingBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Reconnecting to your Tailnet…")
                .font(.subheadline.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}
