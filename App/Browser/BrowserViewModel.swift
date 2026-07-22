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
    private let initialURL: URL

    /// Whether the tab's initial URL has been loaded at least once. Used to
    /// make `loadInitial()` idempotent (it can be called both eagerly and from
    /// the proxy-arrival path).
    private(set) var didLoadInitial: Bool = false

    /// - parameter initialURL: The URL the tab opens with (e.g. the Aperture
    ///   chat home page). Known at init so that when the SOCKS5 proxy arrives
    ///   the page can (re)load the *correct* URL on the proxied `WebPage`
    ///   instead of a placeholder.
    init(model: TSNetModel, initialURL: URL) {
        self.tsnetModel = model
        self.initialURL = initialURL

        // `@Published` emits the current value to new subscribers immediately,
        // so if the proxy is already up when this tab is created (e.g. opening
        // a new tab while connected) the sink fires right away and applies it.
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
            // Reload where the user was (preserves back/forward history).
            self.page.load(item)
        } else {
            // No current item yet — first proxy arrival, or a fresh page after
            // a proxy reset (the node comes up twice on launch: once from init
            // and once from scenePhase .active, each swapping the WebPage and
            // discarding any in-flight load). (Re)load the tab's initial URL on
            // the proxied page so the home page comes up instead of staying
            // blank. Not gated by `didLoadInitial` so repeated proxy resets
            // reliably re-seed the page.
            let nav = self.page.load(initialURL)
            watchForNavitationErrors(nav, for: initialURL)
            didLoadInitial = true
        }
    }

    /// Loads the tab's initial URL once. Idempotent. Called from
    /// `setPageAndProxy` on first proxy arrival and may also be called eagerly
    /// when the proxy is already up at tab-creation time.
    func loadInitial() {
        guard !didLoadInitial else { return }
        didLoadInitial = true
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
