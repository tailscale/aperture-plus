//
//  TabManager.swift
//  Aperture
//
//  Owns the ordered list of open browser tabs and the selected tab, and drives
//  the "first tab is always an Aperture chat" rule.
//
//  Tabs are only loaded once the userspace Tailscale SOCKS5 proxy is available
//  (`TSNetModel.proxyConfiguration`): loading before the proxy exists would
//  fail (the home page lives on the tailnet). When the proxy arrives, any
//  pending tabs are loaded; tabs opened after that load immediately.
//

import Combine
import SwiftUI
import WebKit
import TailscaleKit

@MainActor
final class TabManager: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedIndex: Int = 0

    private let model: TSNetModel
    private let homePage: HomePage
    private let dataStore: WKWebsiteDataStore
    private var cancellables: Set<AnyCancellable> = []

    /// The currently selected tab, if any.
    var currentTab: BrowserTab? {
        guard tabs.indices.contains(selectedIndex) else { return nil }
        return tabs[selectedIndex]
    }

    var tabCount: Int { tabs.count }

    init(model: TSNetModel, homePage: HomePage, dataStore: WKWebsiteDataStore) {
        self.model = model
        self.homePage = homePage
        self.dataStore = dataStore

        // The first tab is always the Aperture chat (home page).
        openChatTab(select: true)

        // Load any still-pending tabs the moment the proxy comes online.
        model.$proxyConfiguration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] proxy in
                guard let self, proxy != nil else { return }
                self.loadPendingTabs()
            }
            .store(in: &cancellables)
    }

    private func loadPendingTabs() {
        for tab in tabs where !tab.didLoadInitial {
            tab.loadInitial()
        }
    }

    /// Opens a new Aperture-chat tab (the home page) and selects it. Returns
    /// the new tab. This is the "open an additional aperture chat tab" button.
    @discardableResult
    func openChatTab(select: Bool = true) -> BrowserTab {
        let urlString = homePage.url
        let url = URL(string: urlString) ?? URL(string: HomePage.defaultURL)!
        let tab = BrowserTab(model: model, initialURL: url, dataStore: dataStore)
        tabs.append(tab)
        if select {
            selectedIndex = tabs.count - 1
        }
        // If the proxy is already up, load right away; otherwise TabManager
        // will load it when the proxy arrives.
        if model.proxyConfiguration != nil {
            tab.loadInitial()
        }
        return tab
    }

    /// Selects the given tab (by identity).
    func select(_ tab: BrowserTab) {
        if let i = tabs.firstIndex(where: { $0.id == tab.id }) {
            selectedIndex = i
        }
    }

    /// Closes a tab. If it was the last one, a fresh chat tab is opened so
    /// there is always at least one tab (Safari behavior).
    func closeTab(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: i)

        if tabs.isEmpty {
            openChatTab(select: true)
            return
        }

        // Keep a valid selection.
        if selectedIndex > tabs.count - 1 {
            selectedIndex = tabs.count - 1
        } else if i < selectedIndex {
            selectedIndex -= 1
        }
    }
}
