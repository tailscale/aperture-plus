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
    /// Whether the SOCKS5 proxy is currently available. While false (e.g. the
    /// node is reconnecting after the app was backgrounded) the browser shows a
    /// "Reconnecting…" indicator and holds any navigation error instead of
    /// surfacing the overlay — the load will be retried automatically once the
    /// proxy returns, so a transient drop shouldn't look like a page failure.
    @Published private(set) var isConnected: Bool = false

    private var observers: [AnyCancellable] = []
    private var tsnetModel: TSNetModel
    private let initialURL: URL

    /// Whether the tab's initial URL has been loaded at least once.
    private(set) var didLoadInitial: Bool = false

    /// A navigation that failed while `isConnected` was false, to be retried
    /// once the proxy returns. See `navigationError` / `applyProxy`.
    private var pendingRetryURL: URL?

    /// The shared, **persistent** on-disk website data store. Created once per
    /// app install (the UUID is stored in UserDefaults) and reused by every
    /// tab and across launches, so the HTTP cache, service workers, IndexedDB,
    /// etc. persist — the Aperture chat PWA reloads as fast as when installed
    /// to the home screen, instead of re-fetching everything each time.
    /// It's also where the SOCKS5 proxy is applied/updated in place (see
    /// `applyProxy`), so a proxy change does NOT require recreating the WebPage.
    @MainActor private static let sharedDataStore: WKWebsiteDataStore = {
        let key = "apertureWebDataStoreUUID"
        if let s = UserDefaults.standard.string(forKey: key),
           let u = UUID(uuidString: s) {
            return WKWebsiteDataStore(forIdentifier: u)
        }
        let u = UUID()
        UserDefaults.standard.set(u.uuidString, forKey: key)
        return WKWebsiteDataStore(forIdentifier: u)
    }()

    /// - parameter initialURL: The URL the tab opens with (e.g. the Aperture
    ///   chat home page).
    init(model: TSNetModel, initialURL: URL) {
        self.tsnetModel = model
        self.initialURL = initialURL

        // Create the page once, with the persistent shared data store.
        // HTTPS-upgrade is disabled — see `pageConfiguration()` doc comment.
        var config = Self.pageConfiguration()
        config.websiteDataStore = Self.sharedDataStore
        self.page = WebPage(configuration: config)

        // If the proxy is already up (e.g. opening a new tab while connected),
        // apply it and load the initial URL immediately.
        if let proxy = model.proxyConfiguration {
            Self.sharedDataStore.proxyConfigurations = [proxy]
            isConnected = true
            loadInitial()
        }

        // React to proxy changes by updating the SHARED DATA STORE in place —
        // NOT by recreating the WebPage. The webview/page persists across
        // reconnects (no reload, no lost scroll/history); WebKit retries
        // in-flight requests with the new proxy. This is why returning from a
        // brief background trip no longer reloads the page.
        tsnetModel.$proxyConfiguration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] proxy in
                self?.applyProxy(proxy)
            }.store(in: &observers)
    }

    /// Builds a `WebPage.Configuration` with HTTPS-upgrade disabled. The
    /// persistent shared data store is assigned by the caller (init); the proxy
    /// is applied to that store in place via `applyProxy`, not here.
    ///
    /// `upgradeKnownHostsToHTTPS` is **disabled** because WebKit's HTTPS Upgrade
    /// breaks bare tailnet hostnames: `http://ai/` is upgraded to `https://ai/`,
    /// but the node's cert is issued for the FQDN (`ai.<tailnet>.ts.net`), not
    /// the short MagicDNS name, so the upgraded load fails (-1202). Safari does
    /// the same upgrade but falls back to HTTP; WebKit's
    /// `.automaticFallbackToHTTP` policy also silently downgrades *explicit*
    /// https:// on cert failure (a security regression Safari doesn't have) and
    /// routes fallback failures to an async sequence we don't watch (silent
    /// errors). Disabling the upgrade makes `http://` load as typed — matching
    /// Safari's *visible* result — while explicit `https://` cert errors still
    /// surface. No certificate checks are bypassed.
    private static func pageConfiguration() -> WebPage.Configuration {
        var config = WebPage.Configuration()
        config.upgradeKnownHostsToHTTPS = false
        return config
    }

    /// Applies a proxy change by updating the shared data store's
    /// `proxyConfigurations` **in place** — the WebPage is never recreated, so
    /// the current page, scroll position, and history survive reconnects.
    /// On the first connection, loads the tab's initial URL. On a reconnect
    /// after a drop, retries any navigation that failed while disconnected
    /// (see `navigationError`).
    func applyProxy(_ proxy: ProxyConfiguration?) {
        if let proxy {
            Self.sharedDataStore.proxyConfigurations = [proxy]
            let wasConnected = isConnected
            isConnected = true
            if !didLoadInitial {
                // First connect: bring up the home page.
                loadInitial()
            } else if let retry = pendingRetryURL {
                // Reconnect after a drop: retry the navigation that failed
                // while we were disconnected, instead of leaving the error
                // overlay up.
                pendingRetryURL = nil
                logger.log("Proxy reconnected — retrying held load \(retry)")
                let nav = page.load(retry)
                watchForNavitationErrors(nav, for: retry)
            } else if !wasConnected {
                logger.log("Proxy reconnected — page kept, no reload")
            }
        } else {
            // Disconnected (e.g. app backgrounded / node closed). Don't touch
            // the page — it stays loaded (cached); only live fetches stall until
            // the proxy returns. Clearing the store proxy stops new fetches from
            // hitting a dead proxy.
            isConnected = false
            Self.sharedDataStore.proxyConfigurations = []
            logger.log("Proxy dropped — page kept, holding loads until reconnect")
        }
    }

    /// Loads the tab's initial URL once. Idempotent. Only loads when connected
    /// (proxy up); if called before the proxy is available, it's a no-op and
    /// `applyProxy` will load on first connect.
    func loadInitial() {
        guard !didLoadInitial else { return }
        guard isConnected else { return }
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
    /// bar). The single entry point for user-initiated navigations so that
    /// every such load is watched for errors.
    func load(url: URL) {
        let nav = page.load(url)
        watchForNavitationErrors(nav, for: url)
    }

    func navigationError(_ error: Error, for url: URL) {
        logger.log("Navigation error for \(url): \(error)")
        // While disconnected, don't surface a scary error overlay — hold the
        // URL and retry once the proxy returns (see `applyProxy`). The
        // "Reconnecting…" indicator tells the user what's happening instead.
        if !isConnected {
            pendingRetryURL = url
            return
        }
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
