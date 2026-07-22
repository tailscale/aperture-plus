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

    /// Live, UI-facing metadata (mirrored from `WebPage`; see class doc).
    @Published private(set) var displayTitle: String = "Aperture"
    @Published private(set) var displayURL: String = ""

    private var cancellables: Set<AnyCancellable> = []

    init(model: TSNetModel, initialURL: URL) {
        self.viewModel = BrowserViewModel(model: model, initialURL: initialURL)
        self.initialURL = initialURL
        self.displayURL = initialURL.absoluteString

        // Re-arm the WebPage observation whenever the ViewModel swaps its page
        // (proxy arrival/change), then mirror the new page's title/url.
        viewModel.$page
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.observePage()
            }
            .store(in: &cancellables)

        observePage()
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
    }
}
