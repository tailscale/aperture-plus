//  Created by Jonathan Nobels on 2025-12-16.

import SwiftUI
import Combine
import WebKit
import TailscaleKit

/// Broad category of a navigation error, so the error overlay can distinguish a
/// URL format problem from a retrieval problem.
enum NavErrorKind: Sendable, Equatable {
    case urlFormat
    case retrieval
    case other
}

/// Browser state backed by an owned `WKWebView`. Its UIKit frame, scroll view,
/// navigation lifecycle, and committed URL remain available to the app.
@MainActor
final class BrowserViewModel: NSObject, ObservableObject {
    @Published var failedInitialURL: URL?
    @Published var navError: (err: Error, url: URL?)?
    @Published var navErrorMessage: String?
    @Published var navErrorKind: NavErrorKind?
    @Published var navErrorURLString: String?

    // Raw WKWebView state consumed by browser chrome.
    @Published private(set) var title = ""
    /// Security-sensitive, user-visible URL. This advances after WebKit commits
    /// a document navigation, when the committed document makes a same-origin
    /// History API / fragment change, or after a failed navigation replaces
    /// web content with our own full-page error document. It never follows an
    /// in-flight cross-origin provisional request.
    @Published private(set) var url: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var estimatedProgress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    private var observers: [AnyCancellable] = []
    private var webViewObservations: [NSKeyValueObservation] = []
    private var tsnetModel: TSNetModel
    private let initialURL: URL
    private let dataStore: WKWebsiteDataStore
    private let configureWebView: ((WKWebViewConfiguration) -> Void)?
    private let openNewTab: (URL) -> Void
    private var webView: WKWebView?

    private(set) var didLoadInitial = false
    private var pendingLoadURL: URL?

    init(model: TSNetModel, initialURL: URL, dataStore: WKWebsiteDataStore,
         configureWebView: ((WKWebViewConfiguration) -> Void)? = nil,
         openNewTab: @escaping (URL) -> Void = { _ in }) {
        self.tsnetModel = model
        self.initialURL = initialURL
        self.dataStore = dataStore
        self.configureWebView = configureWebView
        self.openNewTab = openNewTab
        super.init()

        if let proxy = model.proxyConfiguration {
            dataStore.proxyConfigurations = [proxy]
        }
        model.$proxyConfiguration
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] proxy in self?.applyProxy(proxy) }
            .store(in: &observers)
    }

    var hasWebView: Bool { webView != nil }

    /// Creates the tab's one WKWebView when SwiftUI installs it in a real view
    /// hierarchy. Creating it here (rather than in the model initializer) keeps
    /// the existing first-tap/crashed-gesture workaround intact.
    func makeWebView() -> WKWebView {
        if let webView { return webView }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.upgradeKnownHostsToHTTPS = false
        configureWebView?(configuration)

        let view = WKWebView(frame: .zero, configuration: configuration)
        // Match Safari's subtle feathering as content scrolls beneath the
        // status indicators. This is iOS 26's public scroll-edge effect, not a
        // hand-built blur/gradient overlay.
        view.scrollView.topEdgeEffect.style = .soft
        // Keep UIKit's default automatic adjustment. With the WKWebView laid
        // out beneath the notch, WebKit can then distinguish ordinary pages
        // (safe rectangular viewport) from viewport-fit=cover pages (edge to
        // edge with CSS env(safe-area-inset-*) values), as Safari does.
        attach(view)

        if let pendingLoadURL {
            self.pendingLoadURL = nil
            // This is a restored committed page, not a never-loaded tab. A
            // later proxy-policy publication must not replace it with initialURL.
            didLoadInitial = true
            loadResolved(pendingLoadURL)
        } else {
            loadInitial()
        }
        return view
    }

    /// Releases the heavy page process/view when this tab is hidden. The tab's
    /// committed URL/title stay in BrowserTab's lightweight metadata and the
    /// page is recreated on demand when selected again.
    func unloadWebView() {
        guard let webView else { return }
        webView.stopLoading()
        // `url` is our validated address-bar URL. Do not read WKWebView.url here:
        // at an unload boundary it could be exposing a provisional destination.
        if let url { pendingLoadURL = url }
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webViewObservations.removeAll()
        self.webView = nil
        isLoading = false
        estimatedProgress = 0
        canGoBack = false
        canGoForward = false
        didLoadInitial = false
    }

    /// Keeps delegates/observation attached if SwiftUI reuses the view.
    func attach(_ view: WKWebView) {
        guard webView !== view else { return }
        webView = view
        view.navigationDelegate = self
        view.uiDelegate = self
        observeWebView(view)
    }

    private func observeWebView(_ view: WKWebView) {
        webViewObservations.removeAll()
        webViewObservations = [
            view.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.acceptSameDocumentURL(from: view) }
            },
            view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.title = view.title ?? "" }
            },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.isLoading = view.isLoading }
            },
            view.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.estimatedProgress = view.estimatedProgress }
            },
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoForward = view.canGoForward }
            },
        ]
    }

    func applyProxy(_ proxy: ProxyConfiguration) {
        dataStore.proxyConfigurations = [proxy]
        if !didLoadInitial { loadInitial() }
    }

    func loadInitial() {
        guard !didLoadInitial, tsnetModel.state == .Running else { return }
        if needsPeerDataToRoute(initialURL), tsnetModel.proxyPolicy?.hasPeerData != true {
            logger.log("loadInitial: holding \(initialURL) until tailnet peer data arrives")
            return
        }
        didLoadInitial = true
        load(url: initialURL)
    }

    func load(url: URL) {
        let target = resolveForTailnet(url)
        clearNavError()
        guard webView != nil else {
            // Preserve an unloaded tab's committed URL. Automatic initial-load
            // attempts must not overwrite it while the tab has no WKWebView.
            if pendingLoadURL == nil { pendingLoadURL = target }
            return
        }
        loadResolved(target)
    }

    private func loadResolved(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }

    func reload() {
        // Retry the attempted URL shown in the error overlay. Do not ask
        // WKWebView to reload its still-committed old page: that mismatch is
        // both confusing and dangerous in browser chrome.
        if let failedURL = navError?.url {
            load(url: failedURL)
            return
        }
        guard let webView else {
            load(url: initialURL)
            return
        }
        clearNavError()
        webView.reload()
    }

    func stopLoading() { webView?.stopLoading() }
    func goBack() { if webView?.canGoBack == true { webView?.goBack() } }
    func goForward() { if webView?.canGoForward == true { webView?.goForward() } }

    private func needsPeerDataToRoute(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        return !host.contains(".") && !host.contains(":")
    }

    private func resolveForTailnet(_ url: URL) -> URL {
        guard let policy = tsnetModel.proxyPolicy else { return url }
        let suffix = tsnetModel.localStatus?.CurrentTailnet?.MagicDNSSuffix
        let expanded = policy.expandWithheldShortName(in: url, magicDNSSuffix: suffix)
        if expanded != url { logger.log("Expanded withheld short name \(url) -> \(expanded)") }
        return expanded
    }

    func navigationError(_ error: Error, for url: URL) {
        logger.log("Navigation error for \(url): \(error)")
        navError = (error, url)
        navErrorMessage = Self.describe(error)
        navErrorKind = Self.categorize(error)
        navErrorURLString = url.absoluteString
        // The failed page has been replaced by our trusted error document, so
        // showing the attempted URL cannot disguise the previously rendered
        // origin. Slow/in-flight loads still retain the committed URL.
        self.url = url
        failedInitialURL = url == initialURL ? url : nil
    }

    func reportURLParseFailure(_ raw: String) {
        logger.log("URL parse failure (URL(string:) returned nil): \(raw)")
        navError = (URLError(.badURL), nil)
        navErrorMessage = "The URL has a format error — check the escaped text above for unexpected characters."
        navErrorKind = .urlFormat
        navErrorURLString = raw
        failedInitialURL = nil
    }

    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var detail = ns.localizedDescription
        if detail.isEmpty { detail = "The page could not be loaded." }
        return "\(detail) [\(ns.domain) \(ns.code)]"
    }

    nonisolated static func categorize(_ error: Error) -> NavErrorKind {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorBadURL { return .urlFormat }
        if ns.domain == NSURLErrorDomain { return .retrieval }
        return .other
    }

    func clearNavError() {
        navError = nil
        navErrorMessage = nil
        navErrorKind = nil
        navErrorURLString = nil
    }

    /// Accepts URL KVO changes only when they cannot change the security origin
    /// shown in browser chrome. WKWebView.url is KVO-compliant and changes for
    /// `history.pushState`, `history.replaceState`, and fragment navigation,
    /// none of which necessarily calls a WKNavigationDelegate commit method.
    ///
    /// WebKit enforces the History API's same-origin rule too, but checking it
    /// again here is deliberate defense in depth: URL KVO also participates in
    /// ordinary/provisional navigation, and a cross-origin request must not be
    /// able to spoof the address bar before it commits.
    private func acceptSameDocumentURL(from view: WKWebView) {
        guard webView === view,
              let current = url,
              let candidate = view.url,
              Self.haveSameWebOrigin(current, candidate)
        else { return }
        url = candidate
    }

    nonisolated static func haveSameWebOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              ["http", "https"].contains(lhsScheme),
              lhsScheme == rhsScheme,
              let lhsHost = lhs.host()?.lowercased(),
              let rhsHost = rhs.host()?.lowercased(),
              lhsHost == rhsHost
        else { return false }

        func effectivePort(of url: URL, scheme: String) -> Int? {
            url.port ?? (scheme == "http" ? 80 : 443)
        }
        return effectivePort(of: lhs, scheme: lhsScheme)
            == effectivePort(of: rhs, scheme: rhsScheme)
    }

    private func refreshState(from view: WKWebView, includeCommittedURL: Bool = false) {
        title = view.title ?? ""
        if includeCommittedURL {
            // Delegate commit/finish is the authority allowed to change origin.
            url = view.url
        }
        isLoading = view.isLoading
        estimatedProgress = view.estimatedProgress
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
    }

    private func maybeDumpLoadedPage(_ view: WKWebView) {
        guard ProcessInfo.processInfo.arguments.contains("-UITestLogResponses") else { return }
        let js = "JSON.stringify({href:location.href,title:document.title,contentType:document.contentType,body:(document.body?document.body.innerText:'(no body)').substring(0,300)})"
        view.evaluateJavaScript(js) { result, error in
            if let error { logger.log("LOADED-PAGE error: \(error)") }
            else { logger.log("LOADED-PAGE: \(result ?? "(null)")") }
        }
    }
}

extension BrowserViewModel: WKUIDelegate {
    /// WebKit asks its UI delegate to create a view for target=_blank,
    /// window.open(), and links whose target requests another browsing context.
    /// Route that request into this workspace's tab manager instead.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url
        else { return nil }
        openNewTab(url)
        return nil
    }
}

extension BrowserViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // A new attempt supersedes any old failure UI, but deliberately does
        // not alter the committed URL rendered in browser chrome.
        clearNavError()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        refreshState(from: webView, includeCommittedURL: true)
        failedInitialURL = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if ProcessInfo.processInfo.arguments.contains("-UITestLogResponses") {
            logger.log("RESP-LOG action: \(navigationAction.request.url?.absoluteString ?? "(nil)") type=\(navigationAction.navigationType.rawValue)")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if ProcessInfo.processInfo.arguments.contains("-UITestLogResponses") {
            let response = navigationResponse.response
            let url = response.url?.absoluteString ?? "(nil)"
            if let http = response as? HTTPURLResponse {
                logger.log("RESP-LOG response: \(http.statusCode) \(url) mime=\(response.mimeType ?? "?")")
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshState(from: webView, includeCommittedURL: true)
        maybeDumpLoadedPage(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return }
        navigationError(error, for: ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? url ?? initialURL)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return }
        // Prefer the failing URL carried by CFNetwork. `webView.url` can be the
        // provisional destination or the old committed page depending on the
        // failure phase, so it is never used as address-bar truth here.
        navigationError(error, for: ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? url ?? initialURL)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationError(URLError(.cannotLoadFromNetwork), for: webView.url ?? initialURL)
    }
}
