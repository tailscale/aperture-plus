//  Created by Jonathan Nobels on 2025-12-16.
//

import SwiftUI
import Combine
import WebKit
import TailscaleKit

@MainActor
final class BrowserViewModel: ObservableObject {

    @Published var page: WebPage
    @Published var failedInitialURL: URL?
    @Published var navError: (err: Error, url: URL)?
    /// A human-readable description of the current navigation error, for the
    /// error overlay. Cleared alongside `navError`.
    @Published var navErrorMessage: String?

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
        // Create the initial page with our trust-the-tailnet-cert decider so
        // any pre-proxy load attempt (and the proxied reload path) both honor
        // it. The page is swapped again in `setPageAndProxy` when the SOCKS5
        // proxy arrives, with the same decider.
        self.page = WebPage(navigationDecider: ApertureNavigationDecider())

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
        // Recreate the page with the proxy AND the trust-the-tailnet-cert
        // decider (see ApertureNavigationDecider).
        self.page = WebPage(configuration: config, navigationDecider: ApertureNavigationDecider())
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

    /// Loads an arbitrary URL typed/chosen by the user (e.g. from the URL
    /// bar). This is the single entry point for user-initiated navigations so
    /// that *every* such load is watched for errors. Previously the URL bar
    /// called `page.load` directly without `watchForNavitationErrors`, so a
    /// failed load (e.g. an unreachable http URL) failed silently with no
    /// overlay. Pass a URL with an explicit scheme.
    func load(url: URL) {
        let nav = page.load(url)
        watchForNavitationErrors(nav, for: url)
    }

    func navigationError(_ error: Error, for url: URL) {
        logger.log("Navigation error for \(url): \(error)")
        navError = (error, url)
        navErrorMessage = Self.describe(error)
        if url == initialURL {
            failedInitialURL = url
        } else {
            failedInitialURL = nil
        }
    }

    /// Maps a `WebPage.NavigationError` (or any error) to a short user-facing
    /// string for the error overlay.
    nonisolated static func describe(_ error: Error) -> String {
        if let navError = error as? WebPage.NavigationError {
            switch navError {
            case .failedProvisionalNavigation(let underlying):
                // The underlying NSError from CFNetwork/WKWebView carries the
                // real reason (e.g. "A server with the specified hostname could
                // not be found", proxy refusal, cancelled navigation).
                let detail = (underlying as NSError).localizedDescription
                return detail.isEmpty ? "The page could not be loaded." : detail
            case .pageClosed:
                return "The page was closed before it finished loading."
            case .webContentProcessTerminated:
                return "The page's content process crashed. Try reloading."
            case .invalidURL:
                return "That URL is invalid."
            @unknown default:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    /// Clears the current navigation error (e.g. the user dismissed the
    /// overlay). Does not affect the page itself.
    func clearNavError() {
        navError = nil
        navErrorMessage = nil
    }

    var navTask : Task<Void, Never>?
    func watchForNavitationErrors(_ nav: some AsyncSequence<WebPage.NavigationEvent, any Error>, for url: URL) {
        navTask?.cancel()
        failedInitialURL = nil
        navError = nil
        navErrorMessage = nil
        navTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in nav {
                    if Task.isCancelled { return }
                    logger.log("Nav event: \(event)")
                }
            } catch {
                if Task.isCancelled { return }
                navigationError(error, for: url)
            }
        }
    }
}
