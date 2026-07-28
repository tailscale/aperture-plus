//
//  TabbedBrowserView.swift
//  Aperture
//
//  The root window: a Safari-style multi-tab web browser, driven by the
//  ACTIVE workspace. Until that workspace's tailnet first reaches `Running`
//  it shows `ConnectionGateView` (the onboarding/login screen); once
//  connected it switches to the tabbed browser for the rest of the session
//  (subsequent reconnects show an inline banner, not the gate).
//
//  Each workspace owns its own tabs, home page, bookmarks store, and web data
//  store (see `Workspace`); this view just renders the active one. Settings is
//  global (reachable from both the gate and the browser) and reflects the
//  active workspace.
//
//  - First tab is always an Aperture chat (the workspace's home page).
//  - "+" opens an additional Aperture-chat tab.
//  - iPhone (compact): tabs are managed via the tab-overview button
//    (`square.on.square`); the overview is a full-screen card grid.
//  - iPad (regular): a persistent `TabBar` of tab chips is shown atop the
//    content, in addition to the overview button.
//

import SwiftUI
import WebKit
import SwiftData
import TailscaleKit

struct TabbedBrowserView: View {
    @ObservedObject var workspaceManager: WorkspaceManager

    /// Settings is global (reachable from both the gate and the browser), so
    /// its full-screen cover lives here.
    @State private var showingSettings = false

    var body: some View {
        Group {
            if let ws = workspaceManager.activeWorkspace {
                WorkspaceRoot(workspace: ws, showingSettings: $showingSettings)
                    // Key by workspace id so switching the active workspace
                    // (Phase 3) tears down this subtree and creates a fresh
                    // `WorkspaceRoot` with its own `@StateObject` tab manager /
                    // status VM / WKWebView for the new identity. Within one
                    // workspace the id is stable, so the WebView survives.
                    .id(ws.id)
                    // Inject the workspace's bookmarks container at this
                    // (stable) level, NOT inside `WorkspaceRoot`. `WorkspaceRoot`
                    // re-renders on every `Workspace` identity/netmap publish
                    // during load; re-applying `.modelContainer` there rebuilt
                    // the whole subtree (including the WKWebView) mid-load,
                    // which left a stale gesture recognizer in the window and
                    // crashed the app on the first tap (see
                    // `testTapOnLoadedHomePageDoesNotCrash`). `TabbedBrowserView`
                    // only re-renders when `WorkspaceManager` publishes (rare),
                    // so the container is applied once and the WebView survives.
                    .modelContainer(ws.modelContainer)
            } else {
                // No workspace — never happens (WorkspaceManager always seeds
                // one), but keep the view tree valid rather than crashing.
                ProgressView()
            }
        }
        .fullScreenCover(isPresented: $showingSettings) {
            if let ws = workspaceManager.activeWorkspace {
                SettingsView(viewModel: SettingsViewModel(workspace: ws),
                             dismissAction: { showingSettings = false })
            }
        }
    }
}

// MARK: - Per-workspace root (gate ⇄ browser)

/// The root for a single (active) workspace: shows the connection gate until
/// that workspace's tailnet first reaches `Running`, then the tabbed browser
/// for the rest of the session. Observes the workspace's `StatusViewModel`
/// directly so the `running` flip is tracked live.
private struct WorkspaceRoot: View {
    let workspace: Workspace
    @StateObject private var tabManager: TabManager
    @StateObject private var statusViewModel: StatusViewModel
    @Binding var showingSettings: Bool

    /// Flips to true the first time this workspace's tailnet reaches `Running`
    /// and stays true — so a transient reconnect doesn't kick back to the gate.
    @State private var hasConnected = false

    init(workspace: Workspace, showingSettings: Binding<Bool>) {
        self.workspace = workspace
        // Create the per-workspace tab manager + status VM here (first render)
        // — NOT in `Workspace.init` (which runs at app launch, before the
        // window/view hierarchy exists). Creating the WKWebView before
        // the window existed left WebKit's gesture recognizers in a corrupt
        // state and crashed the app on the first tap (see
        // `testTapOnLoadedHomePageDoesNotCrash`). `@StateObject` runs this
        // `wrappedValue` only on the view's first appearance, matching the
        // pre-refactor timing where `TabManager` was built in
        // `TabbedBrowserView.init`.
        _tabManager = StateObject(wrappedValue: TabManager(
            model: workspace.model, homePage: workspace.homePage, dataStore: workspace.dataStore))
        _statusViewModel = StateObject(wrappedValue: StatusViewModel(manager: workspace.manager))
        self._showingSettings = showingSettings
    }

    var body: some View {
        Group {
            if hasConnected, let tab = tabManager.currentTab {
                BrowserRootContent(
                    workspace: workspace,
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
        // The workspace's bookmarks container is injected by `TabbedBrowserView`
        // (see the comment there for why it must NOT live on this view).
    }
}

// MARK: - Browser root (connected)

/// The connected browser chrome: the current tab's `BrowserView` plus the tab
/// controls, URL/navigation toolbar, and per-tab sheets. Observes the current
/// `BrowserTab` directly so the nav title tracks live page-title changes.
private struct BrowserRootContent: View {
    let workspace: Workspace
    @ObservedObject var tabManager: TabManager
    @ObservedObject var tab: BrowserTab
    @ObservedObject var statusViewModel: StatusViewModel
    let onSettings: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var showingTabOverview = false
    @State private var showingBookmarks = false
    @State private var showingBookmarkEditor = false
    /// In-app log viewer (Settings → Logs / the "more" menu). The only way to
    /// read the app's logs on a device that can't be attached to a Mac.
    @State private var showingLogs = false
    init(workspace: Workspace,
         tabManager: TabManager,
         tab: BrowserTab,
         statusViewModel: StatusViewModel,
         onSettings: @escaping () -> Void) {
        self.workspace = workspace
        self.tabManager = tabManager
        self.tab = tab
        self.statusViewModel = statusViewModel
        self.onSettings = onSettings
    }

    var body: some View {
        NavigationStack {
            // Raw-WKWebView experiment: the compact URL toolbar is a real
            // bottom sibling and normal SwiftUI keyboard avoidance shrinks the
            // available browser region. Unlike the opaque SwiftUI WebView, the
            // owned WKWebView should now coordinate that resize correctly.
            VStack(spacing: 0) {
                BrowserView(model: tab.viewModel)
                    // The browser is the flexible child; fixed chrome below is
                    // allocated first when the keyboard reduces available room.
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .layoutPriority(-1)
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
                                showingLogs = true
                            } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                            }
                            .accessibilityIdentifier("logs-button")
                            .accessibilityLabel("Logs")

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

                if hSizeClass == .compact {
                    CompactBrowserToolbar(
                        tab: tab,
                        tabManager: tabManager,
                        onNewChat: { tabManager.openChatTab() },
                        onTabOverview: { showingTabOverview = true },
                        onBookmarks: { showingBookmarks = true },
                        onAddBookmark: { showingBookmarkEditor = true },
                        onSettings: onSettings,
                        onLogs: { showingLogs = true }
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .id(tab.id)
                }
            }
        }
        .sheet(isPresented: $showingLogs) {
            LogViewer(dismissAction: { showingLogs = false })
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
            BookmarksSheet(homePage: workspace.homePage) { bookmark in
                if let url = URL(string: bookmark.url) {
                    tab.viewModel.load(url: url)
                }
            }
        }
        .sheet(isPresented: $showingBookmarkEditor) {
            BookmarkEditor(
                dismissAction: { showingBookmarkEditor = false },
                initialName: tab.viewModel.title,
                initialURLString: tab.viewModel.url?.absoluteString ?? ""
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

    /// Spins the moment the banner Login button's action fires — tap feedback
    /// so the user can tell the tap landed (the button is small in a thin
    /// banner). The whole banner disappears when login succeeds
    /// (`needsAuth` → false removes it), so this just needs a safety timeout
    /// to return the button to tappable if the sheet never opens.
    @State private var isStartingLogin = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("Login Required")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button {
                isStartingLogin = true
                onLogin()
                Task {
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                    isStartingLogin = false
                }
            } label: {
                if isStartingLogin {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Login")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityIdentifier("login-banner-button")
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
