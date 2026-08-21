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

    /// True while a user-entered address-bar navigation is in flight but has
    /// not yet committed. While set, `BrowserView` covers the still-rendered
    /// previous page with a blank sheet so the old origin can't be mistaken
    /// for the destination (no phishing danger on an empty page). The entered
    /// URL is shown in the address bar immediately; this flag drops on commit,
    /// failure, or stop.
    @Published private(set) var blankingContent = false

    /// True while an app-chrome input (the address bar) has keyboard focus.
    /// While set, programmatic `focus()` calls from web content are suppressed
    /// so a page that focuses its own input on load can't steal focus from the
    /// field the user is actively typing in. The toolbar updates this via
    /// `setChromeInputFocus(_:)`; it's re-asserted on each navigation so a
    /// freshly committed document can't grab focus mid-edit.
    @Published private(set) var chromeInputFocused = false

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
    private let isHomePage: Bool
    private let dataStore: WKWebsiteDataStore
    private let configureWebView: ((WKWebViewConfiguration) -> Void)?
    private let openNewTab: (URL) -> Void
    private var webView: WKWebView?

    private(set) var didLoadInitial = false
    private var pendingLoadURL: URL?
    /// The backend can publish Running a moment before its first SOCKS dial is
    /// usable. Only the automatic startup navigation gets this settling grace;
    /// user-initiated loads continue to surface failures immediately.
    private var startupLoad: (url: URL, deadline: ContinuousClock.Instant)?
    private var startupRetryTask: Task<Void, Never>?

    init(model: TSNetModel, initialURL: URL, dataStore: WKWebsiteDataStore,
         isHomePage: Bool = false,
         configureWebView: ((WKWebViewConfiguration) -> Void)? = nil,
         openNewTab: @escaping (URL) -> Void = { _ in }) {
        self.tsnetModel = model
        self.initialURL = initialURL
        self.isHomePage = isHomePage
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

        // Running can arrive just before the first complete status response,
        // and vice versa. Re-evaluate on both publications so the initial
        // request is made only after the hostname check has an answer.
        model.$localStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.loadInitial() }
            .store(in: &observers)
        model.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.loadInitial() }
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
#if canImport(UIKit)
        // Match Safari's subtle feathering as content scrolls beneath the
        // status indicators. This is iOS 26's public scroll-edge effect, not a
        // hand-built blur/gradient overlay.
        view.scrollView.topEdgeEffect.style = .soft
#endif
        // Install the focus-suppression user script before any navigation so
        // it runs at every document start, ahead of the page's own scripts.
        installFocusSuppressionScript(into: configuration.userContentController)
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
        } else if let url {
            // The tab had committed a page but lost its pending-restore URL
            // (a transient state). Restore the committed page rather than
            // sending the tab back to its initial/home URL.
            didLoadInitial = true
            loadResolved(url)
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
        startupRetryTask?.cancel()
        startupRetryTask = nil
        startupLoad = nil
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
        // A hidden tab's page can't steal focus, and its address bar isn't
        // shown; reset so the next makeWebView bakes the default as off.
        chromeInputFocused = false
    }

    /// Keeps delegates/observation attached if SwiftUI reuses the view.
    func attach(_ view: WKWebView) {
        guard webView !== view else { return }
        webView = view
        view.navigationDelegate = self
        view.uiDelegate = self
        observeWebView(view)
    }

    // MARK: - Chrome focus suppression

    /// Called by the address bar when it gains/loses keyboard focus. While a
    /// chrome input is focused, web content's programmatic `focus()` calls are
    /// suppressed so a page that focuses its own input on load can't steal the
    /// focus the user is actively typing in. Reinstalls the suppression user
    /// script (so the current state is baked in for the next navigation) and
    /// patches the live document immediately.
    func setChromeInputFocus(_ focused: Bool) {
        guard chromeInputFocused != focused else { return }
        chromeInputFocused = focused
        applyFocusSuppressionToCurrentDocument()
        reinstallFocusSuppressionScript()
    }

    /// Patches the live document's suppression flag so the already-installed
    /// `focus()` wrapper takes effect (or clears) without a navigation.
    private func applyFocusSuppressionToCurrentDocument() {
        let value = chromeInputFocused ? "true" : "false"
        webView?.evaluateJavaScript("window.__apertureSuppressFocus = \(value);")
    }

    /// Re-adds the document-start user script with the current suppression
    /// state baked in as the default, so a freshly committed document can't
    /// grab focus before native gets a chance to re-assert the flag.
    private func reinstallFocusSuppressionScript() {
        guard let controller = webView?.configuration.userContentController else { return }
        installFocusSuppressionScript(into: controller)
    }

    /// Installs (replacing any prior) a document-start script that wraps
    /// `HTMLElement.prototype.focus` to no-op while
    /// `window.__apertureSuppressFocus` is true. The baked default reflects the
    /// current `chromeInputFocused` so the very first `focus()` a new page
    /// makes (before any native callback) is already suppressed when the
    /// address bar is being edited.
    private func installFocusSuppressionScript(into controller: WKUserContentController) {
        let value = chromeInputFocused ? "true" : "false"
        let source = """
        (function(){
          window.__apertureSuppressFocus = \(value);
          if (window.__apertureFocusWrapped) return;
          window.__apertureFocusWrapped = true;
          var f = HTMLElement.prototype.focus;
          HTMLElement.prototype.focus = function(){
            if (window.__apertureSuppressFocus) return;
            return f.apply(this, arguments);
          };
        })();
        """
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: source,
                                               injectionTime: .atDocumentStart,
                                               forMainFrameOnly: false))
    }

    private func observeWebView(_ view: WKWebView) {
        webViewObservations.removeAll()
        webViewObservations = [
            view.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.acceptSameDocumentURL(candidate: view.url) }
            },
            view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.title = view.title ?? "" }
            },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.isLoading = view.isLoading }
            },
            view.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.estimatedProgress = view.estimatedProgress }
            },
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.canGoForward = view.canGoForward }
            },
        ]
    }

    func applyProxy(_ proxy: ProxyConfiguration) {
        dataStore.proxyConfigurations = [proxy]
        if !didLoadInitial { loadInitial() }
    }

    func loadInitial() {
        guard !didLoadInitial, tsnetModel.state == .Running else { return }

        // A tab that has already committed a page (or has a pending restore
        // URL captured at unload) must never be sent back to its initial/home
        // URL. `loadInitial` is only for the very first load of a tab that has
        // never committed; restoration of an unloaded tab's committed page is
        // handled by `makeWebView` via `pendingLoadURL`/`url`. Without this
        // guard, a status/state poll firing on an unloaded (didLoadInitial was
        // reset) but already-committed tab would reload its home page when the
        // user next selects it.
        if url != nil || pendingLoadURL != nil { return }

        var target = initialURL
        if isHomePage {
            switch HomePageAvailabilityChecker.initialLoadDecision(
                urlString: initialURL.absoluteString,
                status: tsnetModel.localStatus) {
            case .wait:
                logger.log("loadInitial: holding \(initialURL) until home-page availability is known")
                return
            case .load(let decidedURL):
                if decidedURL != initialURL {
                    logger.log("Home page host is not in this tailnet; opening \(decidedURL)")
                }
                target = decidedURL
            }
        }

        if needsPeerDataToRoute(target), tsnetModel.proxyPolicy?.hasPeerData != true {
            logger.log("loadInitial: holding \(target) until tailnet peer data arrives")
            return
        }
        didLoadInitial = true
        load(url: target, isAutomaticStartupLoad: true)
    }

    func load(url: URL) {
        load(url: url, isAutomaticStartupLoad: false)
    }

    /// User entered a URL in the address bar. Show the entered URL immediately
    /// and blank the page content so the previous origin can't be mistaken for
    /// the destination while the new page loads — no phishing danger on an
    /// empty page. The blanking flag drops on commit/failure/stop.
    func loadUserEntered(url: URL) {
        load(url: url, isAutomaticStartupLoad: false, blankUntilCommit: true)
    }

    private func load(url requestedURL: URL, isAutomaticStartupLoad: Bool, blankUntilCommit: Bool = false) {
        if !isAutomaticStartupLoad {
            startupRetryTask?.cancel()
            startupRetryTask = nil
            startupLoad = nil
        }
        guard let target = resolveForTailnet(requestedURL) else {
            // resolveForTailnet already reported the error (unknown/ambiguous
            // tailnet host) and set navError; drop any in-flight blanking so
            // the error page is visible.
            if blankingContent { blankingContent = false }
            return
        }
        if isAutomaticStartupLoad {
            startupLoad = (target, ContinuousClock.now + .seconds(20))
        }
        clearNavError()
        if blankUntilCommit {
            // Show the entered destination immediately and hide the old page
            // until the new one commits. `url` advances now (the user typed
            // this URL, so showing it is honest); `blankingContent` covers the
            // still-rendered previous origin. Guard the sets: this runs on the
            // synchronous load path (including from makeWebView during a view
            // update), and @Published fires objectWillChange even for no-op
            // assignments.
            if url != target { url = target }
            if !blankingContent { blankingContent = true }
        } else {
            // A non-blanking load supersedes any prior user-entered blanking.
            if blankingContent { blankingContent = false }
        }
        guard webView != nil else {
            // Preserve an unloaded tab's committed URL. Automatic initial-load
            // attempts must not overwrite it while the tab has no WKWebView.
            if pendingLoadURL == nil { pendingLoadURL = target }
            return
        }
        if blankUntilCommit {
            // A user-entered navigation cancels any in-flight load so the new URL
            // takes precedence immediately (a slow page the user is leaving
            // must not keep them waiting). WKWebView.load would cancel the
            // prior provisional load too, but be explicit; the cancelled error
            // is ignored in didFail.
            webView?.stopLoading()
        }
        loadResolved(target)
    }

    private func loadResolved(_ url: URL) {
        // Be deliberately patient with slow private services. This does not
        // delay explicit connection failures; it only extends how long an
        // otherwise-silent request may remain pending.
        webView?.load(URLRequest(url: url, timeoutInterval: 120))
    }

    /// During initial connection only, retry immediate transport failures while
    /// tsnet settles instead of replacing the page with an error that requires
    /// a manual reload. Returns true when the failure has been consumed.
    private func retryStartupLoadIfAppropriate(_ error: Error, failedURL: URL) -> Bool {
        guard let startupLoad, startupLoad.url == failedURL,
              ContinuousClock.now < startupLoad.deadline,
              Self.isTransientStartupError(error)
        else { return false }

        startupRetryTask?.cancel()
        startupRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self,
                      let pending = self.startupLoad,
                      pending.url == failedURL,
                      ContinuousClock.now < pending.deadline
                else { return }
                logger.log("Startup page transport not ready; retrying \(failedURL)")
                self.loadResolved(failedURL)
            } catch {
                return
            }
        }
        return true
    }

    nonisolated private static func isTransientStartupError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        // WebKit maps any SOCKS CONNECT failure to badURL (-1000), so it is a
        // transport error here despite the misleading name.
        return [NSURLErrorBadURL,
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorCannotLoadFromNetwork].contains(ns.code)
    }

    func reload() {
        // Cancel any in-flight user-entered blanking: reload re-fetches the
        // committed page (or retries a failed URL), so the previous-origin
        // disguise concern no longer applies.
        blankingContent = false
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

    func stopLoading() {
        blankingContent = false
        webView?.stopLoading()
    }
    func goBack() { if webView?.canGoBack == true { webView?.goBack() } }
    func goForward() { if webView?.canGoForward == true { webView?.goForward() } }

    private func needsPeerDataToRoute(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        return !host.contains(".") && !host.contains(":")
    }

    /// Canonicalizes every known bare MagicDNS peer name to its FQDN. iOS
    /// applies proxy match rules to the literal URL host before DNS search-path
    /// expansion, so the rewrite is required for deterministic routing. A bare
    /// name absent from the complete peer list is rejected rather than leaked
    /// to public/system DNS.
    private func resolveForTailnet(_ url: URL) -> URL? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased(),
              !host.isEmpty, !host.contains("."), !host.contains(":")
        else { return url }

        guard let status = tsnetModel.localStatus else { return url }
        let result = TailnetHostnameQualifier.qualify(
            url,
            searchDomains: status.CurrentTailnet.map { [$0.MagicDNSSuffix] } ?? [],
            hosts: tailnetHostRecords(from: status)
        )
        switch result {
        case .unchanged(let unchanged):
            return unchanged
        case .qualified(let qualified):
            logger.log("Expanded known tailnet short name \(url) -> \(qualified)")
            return qualified
        case .unknown(let label):
            reportUnknownTailnetHost(label, attemptedURL: url)
            return nil
        case .ambiguous(let label, let candidates):
            reportAmbiguousTailnetHost(label, candidates: candidates, attemptedURL: url)
            return nil
        }
    }

    private func tailnetHostRecords(from status: IpnState.Status) -> [TailnetHostRecord] {
        var peers: [IpnState.PeerStatus] = Array(status.Peer?.values ?? [:].values)
        if let selfStatus = status.SelfStatus { peers.append(selfStatus) }
        return peers.map { TailnetHostRecord(shortName: $0.HostName, fullName: $0.DNSName) }
    }

    private func reportAmbiguousTailnetHost(_ host: String, candidates: [String], attemptedURL: URL) {
        logger.log("Ambiguous tailnet short name \(host): \(candidates.joined(separator: ", "))")
        let error = URLError(.cannotFindHost)
        navError = (error, attemptedURL)
        navErrorMessage = "More than one tailnet device matches “\(host)”: \(candidates.joined(separator: ", ")). Enter the full name."
        navErrorKind = .retrieval
        navErrorURLString = attemptedURL.absoluteString
        url = attemptedURL
        failedInitialURL = attemptedURL == initialURL ? attemptedURL : nil
    }

    private func reportUnknownTailnetHost(_ host: String, attemptedURL: URL) {
        logger.log("Unknown tailnet short name: \(host)")
        let error = URLError(.cannotFindHost)
        navError = (error, attemptedURL)
        navErrorMessage = "No device named “\(host)” exists in this tailnet. Check the name and try again."
        navErrorKind = .retrieval
        navErrorURLString = attemptedURL.absoluteString
        url = attemptedURL
        failedInitialURL = attemptedURL == initialURL ? attemptedURL : nil
    }

    func navigationError(_ error: Error, for url: URL) {
        blankingContent = false
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
        // Guard each set: clearNavError runs on the synchronous load path
        // (including from makeWebView during a SwiftUI view update), and
        // @Published fires objectWillChange even when assigning the same value.
        // Skipping no-op assignments avoids publishing during a view update.
        if navError != nil { navError = nil }
        if navErrorMessage != nil { navErrorMessage = nil }
        if navErrorKind != nil { navErrorKind = nil }
        if navErrorURLString != nil { navErrorURLString = nil }
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
    private func acceptSameDocumentURL(candidate: URL?) {
        guard let candidate,
              let current = url,
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
#if canImport(UIKit)
    /// Supply a deliberately preview-free menu for links. WebKit's default
    /// context menu includes Safari's large live preview, which can obscure
    /// actions on compact screens.
    func webView(_ webView: WKWebView,
                 contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping @MainActor @Sendable (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL else {
            completionHandler(nil)
            return
        }
        let configuration = UIContextMenuConfiguration(
            identifier: nil,
            previewProvider: nil
        ) { [weak self] _ in
            let open = UIAction(title: "Open", image: UIImage(systemName: "arrow.up.right.square")) { _ in
                Task { @MainActor [weak self] in self?.load(url: url) }
            }
            let openInTab = UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                Task { @MainActor [weak self] in self?.openNewTab(url) }
            }
            let copy = UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                Task { @MainActor in UIPasteboard.general.url = url }
            }
            return UIMenu(children: [open, openInTab, copy])
        }
        completionHandler(configuration)
    }
#endif

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
        blankingContent = false
        startupRetryTask?.cancel()
        startupRetryTask = nil
        startupLoad = nil
        refreshState(from: webView, includeCommittedURL: true)
        failedInitialURL = nil
        // A freshly committed document resets its JS context, so re-assert the
        // suppression flag before the page's focus scripts run while the address
        // bar is being edited.
        if chromeInputFocused { applyFocusSuppressionToCurrentDocument() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if ProcessInfo.processInfo.arguments.contains("-UITestLogResponses") {
            logger.log("RESP-LOG action: \(navigationAction.request.url?.absoluteString ?? "(nil)") type=\(navigationAction.navigationType.rawValue)")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
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
        // Backstop: if a page still managed to focus an element while the
        // address bar was being edited (e.g. a deferred setTimeout focus that
        // slipped past the wrapper), blur it so the chrome field keeps focus.
        if chromeInputFocused {
            webView.evaluateJavaScript(
                "if (window.__apertureSuppressFocus && document.activeElement && document.activeElement !== document.body) document.activeElement.blur();")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return }
        let failedURL = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? url ?? initialURL
        if retryStartupLoadIfAppropriate(error, failedURL: failedURL) { return }
        startupLoad = nil
        navigationError(error, for: failedURL)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return }
        // Prefer the failing URL carried by CFNetwork. `webView.url` can be the
        // provisional destination or the old committed page depending on the
        // failure phase, so it is never used as address-bar truth here.
        let failedURL = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? url ?? initialURL
        if retryStartupLoadIfAppropriate(error, failedURL: failedURL) { return }
        startupLoad = nil
        navigationError(error, for: failedURL)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationError(URLError(.cannotLoadFromNetwork), for: webView.url ?? initialURL)
    }
}
