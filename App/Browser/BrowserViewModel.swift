//  Created by Jonathan Nobels on 2025-12-16.
//

import SwiftUI
import Combine
import WebKit
import TailscaleKit

@MainActor
final class BrowserViewModel: ObservableObject {

    @Published var page: WebPage = WebPage()
    @Published var failedInitialURL: URL?
    @Published var navError: (err: Error, url: URL)?

    private var observers: [AnyCancellable] = []
    private var tsnetModel: TSNetModel
    private var authURL: String?
    private var initialURL: URL = URL(string: "https://tailscale.com")!

    init(model: TSNetModel) {
        self.tsnetModel = model

        tsnetModel.$proxyConfiguration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] proxy  in
                guard let self, let proxy else { return }
                logger.log("Reseting webview with new proxy: \(proxy)")
                setPageAndProxy(proxy: proxy)
            }.store(in: &observers)
    }

    func setPageAndProxy(proxy: ProxyConfiguration) {
        let config = WebPage.Configuration()
        config.websiteDataStore.proxyConfigurations = [proxy]
        let item = page.backForwardList.currentItem
        self.page = WebPage(configuration: config)
        if let item {
            self.page.load(item)
        }
    }

    func loadInitialURL(_ url: URL) {
        initialURL = url
        let nav = page.load(initialURL)
        watchForNavitationErrors(nav, for: initialURL)
    }

    func reload() {
        if let item = page.backForwardList.currentItem {
            let nav = page.load(item)
            watchForNavitationErrors(nav, for: item.url)
        } else {
            let nav = page.load(initialURL)
            watchForNavitationErrors(nav, for: initialURL)
        }
    }

    func goBack() {
        guard let item = page.backForwardList.backList.last else { return }
        let nav = page.load(item)
        watchForNavitationErrors(nav, for: item.url)
    }

    func goForward() {
        guard let item = page.backForwardList.forwardList.first else { return }
        let nav = page.load(item)
        watchForNavitationErrors(nav, for: item.url)
    }

    func navigationError(_ error: Error, for url: URL) {
        logger.log("Navigation error: \(error)")
        navError = (error, url)
        if url == initialURL {
            failedInitialURL = url
        } else {
            failedInitialURL = nil
        }
    }

    var navTask : Task<Void, Never>?
    func watchForNavitationErrors(_ nav: some AsyncSequence<WebPage.NavigationEvent, any Error>, for url: URL) {
        navTask?.cancel()
        failedInitialURL = nil
        navError = nil
        navTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in nav {
                    if Task.isCancelled { return }
                    logger.log("Event: \(event)")
                }
            } catch {
                if Task.isCancelled { return }
                navigationError(error, for: url)
            }
        }
    }
}
