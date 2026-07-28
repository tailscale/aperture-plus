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

/// Browser state for the raw-WKWebView spike. Unlike the iOS 26 SwiftUI
/// `WebView`/`WebPage` wrapper, this model owns the actual `WKWebView`, so its
/// UIKit frame and scroll view are no longer hidden from us.
@MainActor
final class BrowserViewModel: NSObject, ObservableObject {
    @Published var failedInitialURL: URL?
    @Published var navError: (err: Error, url: URL?)?
    @Published var navErrorMessage: String?
    @Published var navErrorKind: NavErrorKind?
    @Published var navErrorURLString: String?
    @Published private(set) var isConnected = false

    // Raw WKWebView state consumed by browser chrome.
    @Published private(set) var title = ""
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
    private var webView: WKWebView?

    private(set) var didLoadInitial = false
    private var pendingRetryURL: URL?
    private var pendingLoadURL: URL?

    init(model: TSNetModel, initialURL: URL, dataStore: WKWebsiteDataStore) {
        self.tsnetModel = model
        self.initialURL = initialURL
        self.dataStore = dataStore
        super.init()

        if let proxy = model.proxyConfiguration {
            dataStore.proxyConfigurations = [proxy]
            isConnected = true
        }

        model.$proxyConfiguration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] proxy in self?.applyProxy(proxy) }
            .store(in: &observers)
    }

    /// Creates the tab's one WKWebView when SwiftUI installs it in a real view
    /// hierarchy. Creating it here (rather than in the model initializer) keeps
    /// the existing first-tap/crashed-gesture workaround intact.
    func makeWebView() -> WKWebView {
        if let webView { return webView }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.upgradeKnownHostsToHTTPS = false

        let view = WKWebView(frame: .zero, configuration: configuration)
        // Let the page's viewport-fit=cover / env(safe-area-inset-*) CSS own
        // notch padding instead of UIKit inserting scroll-view safe-area
        // content insets on top of the web layout.
        view.scrollView.contentInsetAdjustmentBehavior = .never
        attach(view)

        if let pendingLoadURL {
            self.pendingLoadURL = nil
            loadResolved(pendingLoadURL)
        } else {
            loadInitial()
        }
        return view
    }

    /// Keeps delegates/observation attached if SwiftUI reuses the view.
    func attach(_ view: WKWebView) {
        guard webView !== view else { return }
        webView = view
        view.navigationDelegate = self
        observeWebView(view)
    }

    private func observeWebView(_ view: WKWebView) {
        webViewObservations.removeAll()
        webViewObservations = [
            view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.title = view.title ?? "" }
            },
            view.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.url = view.url }
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

    func applyProxy(_ proxy: ProxyConfiguration?) {
        if let proxy {
            dataStore.proxyConfigurations = [proxy]
            let wasConnected = isConnected
            isConnected = true
            if !didLoadInitial {
                loadInitial()
            } else if let retry = pendingRetryURL {
                pendingRetryURL = nil
                logger.log("Proxy reconnected — retrying held load \(retry)")
                load(url: retry)
            } else if !wasConnected {
                logger.log("Proxy reconnected — page kept, no reload")
            }
        } else {
            isConnected = false
            dataStore.proxyConfigurations = []
            logger.log("Proxy dropped — page kept, holding loads until reconnect")
        }
    }

    func loadInitial() {
        guard !didLoadInitial, isConnected else { return }
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
            pendingLoadURL = target
            return
        }
        loadResolved(target)
    }

    private func loadResolved(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }

    func reload() {
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
        if !isConnected {
            pendingRetryURL = url
            return
        }
        navError = (error, url)
        navErrorMessage = Self.describe(error)
        navErrorKind = Self.categorize(error)
        navErrorURLString = url.absoluteString
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

    private func refreshState(from view: WKWebView) {
        title = view.title ?? ""
        url = view.url
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

extension BrowserViewModel: WKNavigationDelegate {
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
        refreshState(from: webView)
        maybeDumpLoadedPage(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationError(error, for: webView.url ?? initialURL)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationError(error, for: (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url ?? initialURL)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationError(URLError(.cannotLoadFromNetwork), for: webView.url ?? initialURL)
    }
}
