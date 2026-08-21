//
//  TabManager.swift
//  Aperture
//
//  Owns one workspace's lightweight persisted tab list. At most ten tabs are
//  retained. Only the selected tab is allowed to retain a WKWebView; restored
//  and hidden tabs remain URL/title records until selected.
//

import Combine
import SwiftUI
import WebKit
import TailscaleKit

@MainActor
final class TabManager: ObservableObject {
    static let maximumTabCount = 10

    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var selectedIndex: Int = 0

    private let workspaceID: UUID
    private let model: TSNetModel
    private let homePage: HomePage
    private let dataStore: WKWebsiteDataStore

    /// Set by native macOS windows so closing the last tab closes the window
    /// (and, on reopen, a fresh home-page tab is created) instead of silently
    /// reopening the home page in place. iOS leaves this nil: the last tab
    /// closes back to a fresh home-page tab (there's no window to close).
    var onLastTabClosed: (() -> Void)?

    var currentTab: BrowserTab? {
        guard tabs.indices.contains(selectedIndex) else { return nil }
        return tabs[selectedIndex]
    }

    var tabCount: Int { tabs.count }
    var canOpenNewTab: Bool { tabs.count < Self.maximumTabCount }

    init(workspaceID: UUID, model: TSNetModel, homePage: HomePage,
         dataStore: WKWebsiteDataStore) {
        self.workspaceID = workspaceID
        self.model = model
        self.homePage = homePage
        self.dataStore = dataStore

        if let session = WorkspaceStore.loadTabs(workspaceID), !session.tabs.isEmpty {
            let records = Array(session.tabs.prefix(Self.maximumTabCount))
            // Restored tabs are resumed exactly where the user left them. A
            // restored tab is treated as the home page only when it still has
            // the configured home-page URL; a tab the user navigated away from
            // must not be unexpectedly redirected on the next launch.
            tabs = records.compactMap { record in
                guard let url = URL(string: record.url) else { return nil }
                return makeTab(id: record.id, url: url, restoredTitle: record.title,
                               isHomePage: record.url == homePage.url)
            }
            selectedIndex = min(max(session.selectedIndex, 0), max(tabs.count - 1, 0))
        }
        if tabs.isEmpty {
            _ = openChatTab(select: true)
        } else {
            unloadHiddenTabs()
        }
        persist()
    }

    @discardableResult
    func openChatTab(select: Bool = true) -> BrowserTab? {
        let url = URL(string: homePage.url) ?? URL(string: HomePage.defaultURL)!
        return openTab(url: url, select: select, isHomePage: true)
    }

    /// Opens a page requested by web content (target=_blank/window.open) in
    /// this workspace, preserving the same website data store and proxy.
    @discardableResult
    func openTab(url: URL, select: Bool = true, isHomePage: Bool = false) -> BrowserTab? {
        guard canOpenNewTab else { return nil }
        let tab = makeTab(url: url, isHomePage: isHomePage)
        tabs.append(tab)
        if select {
            selectedIndex = tabs.count - 1
            unloadHiddenTabs()
        }
        persist()
        return tab
    }

    func select(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        selectedIndex = index
        unloadHiddenTabs()
        persist()
    }

    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.unloadWebView()
        tabs.remove(at: index)

        if tabs.isEmpty {
            if let onLastTabClosed {
                // Persist the now-empty tab list so reopening the workspace
                // window creates a fresh home-page tab rather than restoring
                // the closed one, then hand the close to the window.
                persist()
                onLastTabClosed()
                return
            }
            _ = openChatTab(select: true)
            return
        }
        if selectedIndex > tabs.count - 1 {
            selectedIndex = tabs.count - 1
        } else if index < selectedIndex {
            selectedIndex -= 1
        }
        unloadHiddenTabs()
        persist()
    }

    func closeCurrentTab() {
        guard let currentTab else { return }
        closeTab(currentTab)
    }

    func selectPreviousTab() {
        guard !tabs.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + tabs.count) % tabs.count
        unloadHiddenTabs()
        persist()
    }

    func selectNextTab() {
        guard !tabs.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % tabs.count
        unloadHiddenTabs()
        persist()
    }

    /// Called when its workspace leaves the visible pane.
    func unloadAllWebViews() {
        for tab in tabs { tab.unloadWebView() }
    }

    private func unloadHiddenTabs() {
        for (index, tab) in tabs.enumerated() where index != selectedIndex {
            tab.unloadWebView()
        }
    }

    private func makeTab(id: UUID = UUID(), url: URL,
                         restoredTitle: String? = nil,
                         isHomePage: Bool = false) -> BrowserTab {
        BrowserTab(id: id, model: model, initialURL: url,
                   restoredTitle: restoredTitle, dataStore: dataStore,
                   isHomePage: isHomePage,
                   openNewTab: { [weak self] url in self?.openTab(url: url) },
                   onMetadataChange: { [weak self] in self?.persist() })
    }

    private func persist() {
        WorkspaceStore.saveTabs(
            StoredBrowserSession(tabs: tabs.map(\.stored), selectedIndex: selectedIndex),
            workspaceID: workspaceID
        )
    }
}
