//
//  BrowserTab.swift
//  Aperture
//
//  A single browser tab: owns its own BrowserViewModel (and therefore its own
//  WebPage / WKWebView), the URL it was opened with, and live display metadata
//  (title / url string) for tab bars and the tab-overview grid.
//
//  `WebPage` is `@Observable` (Observation framework), not an
//  `ObservableObject`, so it doesn't expose Combine publishers. To let tab
//  chrome react to title/url changes we mirror the relevant `WebPage`
//  properties into `@Published` fields here via `withObservationTracking`,
//  re-arming the observation whenever the page object is swapped (which
//  `BrowserViewModel` does when the SOCKS5 proxy arrives/changes).
//

import SwiftUI
import WebKit
import Observation
import Combine
import TailscaleKit

@MainActor
final class BrowserTab: Identifiable, ObservableObject {
    let id = UUID()
    let viewModel: BrowserViewModel
    let initialURL: URL
    private let model: TSNetModel

    /// Live, UI-facing metadata (mirrored from `WebPage`; see class doc).
    @Published private(set) var displayTitle: String = "Aperture"
    @Published private(set) var displayURL: String = ""
    /// Just the host (or a placeholder) — what the compact URL pill shows,
    /// since the full URL isn't worth the screen real estate.
    @Published private(set) var displayHost: String = ""
    /// How the current page is reached: direct tailnet (p2p), via a DERP relay,
    /// or the internet (not a tailnet peer). Drives the per-tab indicator.
    /// Updated whenever the page URL or the live peer status changes.
    @Published private(set) var connectionType: ConnectionType = .internet

    private var cancellables: Set<AnyCancellable> = []

    init(model: TSNetModel, initialURL: URL) {
        self.viewModel = BrowserViewModel(model: model, initialURL: initialURL)
        self.initialURL = initialURL
        self.model = model
        self.displayURL = initialURL.absoluteString
        self.displayHost = initialURL.host ?? initialURL.absoluteString

        // Re-arm the WebPage observation whenever the ViewModel swaps its page
        // (proxy arrival/change), then mirror the new page's title/url.
        viewModel.$page
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.observePage()
                self?.observeNavigations()
            }
            .store(in: &cancellables)

        // Recompute the connection type when the live peer status updates
        // (polled in TSNetManager) — the page's host may switch between
        // direct/derped as the path changes.
        model.$localStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshConnectionType()
            }
            .store(in: &cancellables)

        observePage()
        observeNavigations()
    }

    /// Loads the tab's initial URL once. Safe to call multiple times; the
    /// underlying `BrowserViewModel.loadInitial()` is idempotent.
    func loadInitial() {
        viewModel.loadInitial()
    }

    var didLoadInitial: Bool { viewModel.didLoadInitial }

    // MARK: - Observation mirroring

    private func observePage() {
        let page = viewModel.page
        withObservationTracking {
            _ = page.title
            _ = page.url
        } onChange: { [weak self] in
            // `withObservationTracking` fires once, non-isolated; re-arm on the
            // main actor so we keep tracking future changes to this page.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshDisplayed()
                self.observePage()
            }
        }
        refreshDisplayed()
    }

    /// Observes the page's lifelong navigation stream and refreshes the
    /// displayed title/host on each event. SPA pages (like the Aperture chat
    /// UI) set `document.title` *after* `.finished` (once the JS app hydrates),
    /// and `withObservationTracking` alone can miss that late update — so after
    /// `.finished` we also poll the title a few times to catch it. Restarted
    /// when the page is swapped (proxy change).
    private func observeNavigations() {
        let page = viewModel.page
        Task { [weak self, page] in
            for try await event in page.navigations {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.refreshDisplayed() }
                if event == .finished {
                    // Catch late SPA title updates.
                    for delay: UInt64 in [300_000_000, 700_000_000, 1_500_000_000, 3_000_000_000] {
                        try? await Task.sleep(nanoseconds: delay)
                        guard !Task.isCancelled else { return }
                        await MainActor.run { self?.refreshDisplayed() }
                    }
                }
            }
        }
    }

    private func refreshDisplayed() {
        let page = viewModel.page
        let trimmedTitle = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            displayTitle = trimmedTitle
        } else if let host = page.url?.host, !host.isEmpty {
            displayTitle = host
        } else {
            displayTitle = "Aperture"
        }
        displayURL = page.url?.absoluteString ?? initialURL.absoluteString
        displayHost = page.url?.host ?? initialURL.host ?? ""
        refreshConnectionType()
    }

    /// Recomputes `connectionType` from the current page host + the live peer
    /// status. Called on page-url changes and on local-status updates.
    private func refreshConnectionType() {
        let host = viewModel.page.url?.host
        connectionType = ConnectionTypeResolver.resolve(host: host, status: model.localStatus)
    }
}
