//  Created by Jonathan Nobels on 2025-12-16.
//

import SwiftUI
import Combine
import WebKit
import TailscaleKit

/// Broad category of a navigation error, so the error overlay can distinguish a
/// **URL format** problem (the URL itself is bad — a parse/validation failure)
/// from a **retrieval** problem (the URL is fine but we couldn't reach it —
/// DNS, proxy, TLS, timeout). Set by `BrowserViewModel.categorize`.
enum NavErrorKind: Sendable, Equatable {
    case urlFormat
    case retrieval
    case other
}

@MainActor
final class BrowserViewModel: ObservableObject {

    @Published var page: WebPage
    @Published var failedInitialURL: URL?
    /// The current navigation error, if any. `url` is the URL we tried to load
    /// (nil for a Swift `URL(string:)` parse failure, where there's no URL —
    /// see `reportURLParseFailure`). Cleared on the next navigation.
    @Published var navError: (err: Error, url: URL?)?
    /// A human-readable description of the current navigation error, for the
    /// error overlay. Cleared alongside `navError`.
    @Published var navErrorMessage: String?
    /// The category of the current navigation error, so the overlay can
    /// distinguish a **URL format/parse** problem (`.urlFormat` — the URL
    /// itself is bad) from a **retrieval/connection** problem (`.retrieval` —
    /// the URL is fine but we couldn't reach it). `.other` for page-closed /
    /// content-process crashes. Cleared alongside `navError`.
    @Published var navErrorKind: NavErrorKind?
    /// The string to render (escaped) in the error overlay: `url.absoluteString`
    /// for WebKit errors, or the raw typed input for a Swift parse failure
    /// (where there's no URL). Shown via `debugEscaped` so invisible/problematic
    /// characters (non-breaking space, zero-width space, smart quotes, etc.)
    /// the keyboard may have injected are visible. Cleared alongside `navError`.
    @Published var navErrorURLString: String?
    /// Whether the SOCKS5 proxy is currently available. While false (e.g. the
    /// node is reconnecting after the app was backgrounded) the browser shows a
    /// "Reconnecting…" indicator and holds any navigation error instead of
    /// surfacing the overlay — the load will be retried automatically once the
    /// proxy returns, so a transient drop shouldn't look like a page failure.
    @Published private(set) var isConnected: Bool = false

    private var observers: [AnyCancellable] = []
    private var tsnetModel: TSNetModel
    private let initialURL: URL

    /// This tab's web data store (per-workspace, NOT a process-wide singleton).
    /// Isolates cookies/cache/service workers per identity and is where the
    /// SOCKS5 proxy is applied/updated in place (see `applyProxy`), so a proxy
    /// change does NOT require recreating the WebPage.
    private let dataStore: WKWebsiteDataStore

    /// Whether the tab's initial URL has been loaded at least once.
    private(set) var didLoadInitial: Bool = false

    /// A navigation that failed while `isConnected` was false, to be retried
    /// once the proxy returns. See `navigationError` / `applyProxy`.
    private var pendingRetryURL: URL?

    /// - parameter model: The workspace's `TSNetModel` (proxy state, etc.).
    /// - parameter initialURL: The URL the tab opens with (e.g. the Aperture
    ///   chat home page).
    /// - parameter dataStore: The workspace's per-identity `WKWebsiteDataStore`.
    init(model: TSNetModel, initialURL: URL, dataStore: WKWebsiteDataStore) {
        self.tsnetModel = model
        self.initialURL = initialURL
        self.dataStore = dataStore

        // Create the page once, with the workspace's data store.
        // HTTPS-upgrade is disabled — see `pageConfiguration()` doc comment.
        // A logging decider is attached (no-op unless `-UITestLogResponses`).
        var config = Self.pageConfiguration()
        config.websiteDataStore = dataStore
        self.page = WebPage(configuration: config, navigationDecider: LoggingNavigationDecider())

        // If the proxy is already up (e.g. opening a new tab while connected),
        // apply it and load the initial URL immediately.
        if let proxy = model.proxyConfiguration {
            dataStore.proxyConfigurations = [proxy]
            isConnected = true
            loadInitial()
        }

        // React to proxy changes by updating the workspace data store in place
        // — NOT by recreating the WebPage. The webview/page persists across
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
    ///
    /// TODO(https): Safari's *literal* behavior is upgrade + automatic HTTP
    /// fallback on failure (`.automaticFallbackToHTTP`), which we can't use
    /// safely today because WebKit applies that fallback to *explicit* https://
    /// navigations too (silently downgrading a user-typed https URL on cert
    /// failure — Safari shows a cert interstitial instead) and routes the
    /// fallback's async navigation through a separate sequence we don't watch
    /// (so failed loads go silent). To get true Safari behavior we'd need to
    /// (a) build a Safari-style certificate-interstitial UI for explicit
    /// https failures, and (b) make `watchForNavitationErrors` follow the
    /// fallback sequence. Revisit once we have (a); until then, disabling the
    /// upgrade is the safe choice that matches Safari's visible result for the
    /// cases that matter here (http:// tailnet hosts, server-side http→https
    /// redirects, explicit-https cert errors).
    private static func pageConfiguration() -> WebPage.Configuration {
        var config = WebPage.Configuration()
        config.upgradeKnownHostsToHTTPS = false
        return config
    }

    /// Applies a proxy change by updating the workspace data store's
    /// `proxyConfigurations` **in place** — the WebPage is never recreated, so
    /// the current page, scroll position, and history survive reconnects.
    /// On the first connection, loads the tab's initial URL. On a reconnect
    /// after a drop, retries any navigation that failed while disconnected
    /// (see `navigationError`).
    func applyProxy(_ proxy: ProxyConfiguration?) {
        if let proxy {
            dataStore.proxyConfigurations = [proxy]
            let wasConnected = isConnected
            isConnected = true
            if !didLoadInitial {
                // First connect (or a later policy update that finally brought
                // peer data — loadInitial holds bare single-label URLs until
                // then, so this is also the retry path for those).
                loadInitial()
            } else if let retry = pendingRetryURL {
                // Reconnect after a drop: retry the navigation that failed
                // while we were disconnected, instead of leaving the error
                // overlay up.
                pendingRetryURL = nil
                logger.log("Proxy reconnected — retrying held load \(retry)")
                // Via `load(url:)` so the retry re-applies short-name
                // expansion against the (possibly updated) policy.
                load(url: retry)
            } else if !wasConnected {
                logger.log("Proxy reconnected — page kept, no reload")
            }
        } else {
            // Disconnected (e.g. app backgrounded / node closed). Don't touch
            // the page — it stays loaded (cached); only live fetches stall until
            // the proxy returns. Clearing the store proxy stops new fetches from
            // hitting a dead proxy.
            isConnected = false
            dataStore.proxyConfigurations = []
            logger.log("Proxy dropped — page kept, holding loads until reconnect")
        }
    }

    /// Loads the tab's initial URL once. Idempotent. Only loads when connected
    /// (proxy up); if called before the proxy is available, it's a no-op and
    /// `applyProxy` will load on first connect.
    func loadInitial() {
        guard !didLoadInitial else { return }
        guard isConnected else { return }
        // The proxy is published as soon as the node starts — BEFORE the first
        // `/status` poll — so at this instant the routing rules may still be
        // IP-ranges-only. A bare single-label home page (the default is
        // `http://ai/chat`) can't be routed yet: it isn't a rule, and there's
        // no known MagicDNS suffix to expand it with. Loading now would send it
        // DIRECT and fail. Wait for peer data; `applyProxy` re-runs this when
        // the policy updates (a few seconds at most).
        if needsPeerDataToRoute(initialURL), tsnetModel.proxyPolicy?.hasPeerData != true {
            logger.log("loadInitial: holding \(initialURL) until tailnet peer data arrives")
            return
        }
        didLoadInitial = true
        // Goes through `load(url:)` so the initial URL gets the same
        // short-name -> FQDN expansion as a typed one. The default home page
        // is `http://ai/chat` — a bare MagicDNS name, and `ai` is exactly the
        // kind of label withheld from the proxy rules (it collides with the
        // public `.ai` TLD), so without expansion the home page would load
        // DIRECT and fail for anyone not also running the system Tailscale VPN.
        load(url: initialURL)
    }

    func reload() {
        if let item = page.backForwardList.currentItem {
            let nav = page.load(item)
            watchForNavitationErrors(nav, for: item.url)
        } else {
            // Same expansion as loadInitial (see above).
            load(url: initialURL)
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
        let target = resolveForTailnet(url)
        let nav = page.load(target)
        watchForNavitationErrors(nav, for: target)
    }

    /// Rewrites a bare MagicDNS short name to its tailnet FQDN when that name
    /// had to be withheld from the proxy's `matchDomains` because the label
    /// collides with a public TLD (e.g. a peer named `ai`, which as a match
    /// entry would also capture all of `*.ai`).
    ///
    /// Without the rewrite such a URL would load DIRECT and fail; with it the
    /// host becomes `ai.<magicdns-suffix>`, which matches the suffix rule, is
    /// proxied, and presents the hostname the peer's TLS cert is issued for.
    /// No-op for every other URL. See `TailnetProxyPolicy`.
    /// Whether `url` can only be routed correctly once tailnet peer data is
    /// known: a bare single-label host (`http://ai/`) that is neither an IP
    /// literal nor already covered by the current rules. Such a host is only
    /// reachable as an explicit rule or via FQDN expansion, both of which need
    /// the peer list / MagicDNS suffix.
    private func needsPeerDataToRoute(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        guard !host.contains("."), !host.contains(":") else { return false }
        return true
    }

    private func resolveForTailnet(_ url: URL) -> URL {
        guard let policy = tsnetModel.proxyPolicy else { return url }
        let suffix = tsnetModel.localStatus?.CurrentTailnet?.MagicDNSSuffix
        let expanded = policy.expandWithheldShortName(in: url, magicDNSSuffix: suffix)
        if expanded != url {
            logger.log("Expanded withheld short name \(url) -> \(expanded)")
        }
        return expanded
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
        navErrorKind = Self.categorize(error)
        navErrorURLString = url.absoluteString
        if url == initialURL {
            failedInitialURL = url
        } else {
            failedInitialURL = nil
        }
    }

    /// Surfaces a **URL format/parse** error that failed BEFORE reaching WebKit
    /// — i.e. Swift's `URL(string:)` returned `nil` for the normalized input in
    /// a toolbar's submit handler (previously this failed silently with just a
    /// log line). Shows the overlay with `navErrorKind = .urlFormat` and the raw
    /// typed string (escaped in the UI) so the user can see what went wrong,
    /// instead of nothing happening. Not subject to the `isConnected` hold
    /// (it's a local parse error, not a network retry candidate).
    func reportURLParseFailure(_ raw: String) {
        logger.log("URL parse failure (URL(string:) returned nil): \(raw)")
        navError = (URLError(.badURL), nil)
        navErrorMessage = "The URL has a format error — check the escaped text above for unexpected characters."
        navErrorKind = .urlFormat
        navErrorURLString = raw
        failedInitialURL = nil
    }

    /// Maps a `WebPage.NavigationError` (or any error) to a short user-facing
    /// string for the error overlay.
    nonisolated static func describe(_ error: Error) -> String {
        if let navError = error as? WebPage.NavigationError {
            switch navError {
            case .failedProvisionalNavigation(let underlying):
                // The underlying NSError from CFNetwork/WKWebView carries the
                // real reason (e.g. "A server with the specified hostname could
                // not be found", proxy refusal, cancelled navigation). Include
                // the domain + code so the on-device overlay is diagnostically
                // useful even when localizedDescription is vague/empty (e.g.
                // distinguishing a DNS failure NSURLErrorDomain -1003 from a
                // proxy/tunnel failure from a sandbox/generic block).
                let ns = underlying as NSError
                var detail = ns.localizedDescription
                if detail.isEmpty { detail = "The page could not be loaded." }
                return "\(detail) [\(ns.domain) \(ns.code)]"
            case .pageClosed:
                return "The page was closed before it finished loading."
            case .webContentProcessTerminated:
                return "The page's content process crashed. Try reloading."
            case .invalidURL:
                // WebKit rejected the URL — a format problem, not a network
                // problem. The overlay shows the URL escaped so any unexpected
                // characters the keyboard injected are visible.
                return "The URL has a format error — check the escaped text above for unexpected characters."
            @unknown default:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    /// Classifies a navigation error into a broad category so the overlay can
    /// distinguish a URL **format** problem from a **retrieval** problem.
    /// `.invalidURL` is a parse/validation rejection from WebKit;
    /// `.failedProvisionalNavigation` is a retrieval/connection failure (DNS,
    /// proxy, TLS, timeout, cancelled); the rest are lifecycle/crash errors.
    nonisolated static func categorize(_ error: Error) -> NavErrorKind {
        if let navError = error as? WebPage.NavigationError {
            switch navError {
            case .invalidURL: return .urlFormat
            case .failedProvisionalNavigation: return .retrieval
            default: return .other
            }
        }
        return .other
    }

    /// Clears the current navigation error (e.g. the user dismissed the
    /// overlay). Does not affect the page itself.
    func clearNavError() {
        navError = nil
        navErrorMessage = nil
        navErrorKind = nil
        navErrorURLString = nil
    }

    /// Diagnostic (launch arg `-UITestLogResponses`): after a page finishes
    /// loading, dump the final URL, document title, and a snippet of the body
    /// text — useful for seeing exactly what a page loaded (e.g. distinguishing
    /// a 404 page from the real content). No-op without the arg. Pairs with
    /// `LoggingNavigationDecider` (which logs response status codes).
    private static func maybeDumpLoadedPage(page: WebPage) async {
        guard ProcessInfo.processInfo.arguments.contains("-UITestLogResponses") else { return }
        let js = "return JSON.stringify({href:location.href,title:document.title,contentType:document.contentType,body:(document.body?document.body.innerText:'(no body)').substring(0,300)})"
        do {
            let result = try await page.callJavaScript(js)
            logger.log("LOADED-PAGE: \(result ?? "(null)")")
        } catch {
            logger.log("LOADED-PAGE error: \(error)")
        }
    }

    var navTask : Task<Void, Never>?
    func watchForNavitationErrors(_ nav: some AsyncSequence<WebPage.NavigationEvent, any Error>, for url: URL) {
        navTask?.cancel()
        failedInitialURL = nil
        navError = nil
        navErrorMessage = nil
        navErrorKind = nil
        navErrorURLString = nil
        navTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in nav {
                    if Task.isCancelled { return }
                    logger.log("Nav event: \(event)")
                    if event == .finished {
                        await Self.maybeDumpLoadedPage(page: self.page)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                navigationError(error, for: url)
            }
        }
    }
}
