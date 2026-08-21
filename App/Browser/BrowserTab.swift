//
//  BrowserTab.swift
//  Aperture
//
//  A lightweight tab record. Its WKWebView is created only when selected and
//  can be released again while the persisted URL/title remain available.
//

import SwiftUI
import WebKit
import Combine
import TailscaleKit

@MainActor
final class BrowserTab: Identifiable, ObservableObject {
    let id: UUID
    let viewModel: BrowserViewModel
    let initialURL: URL
    private let model: TSNetModel
    private let onMetadataChange: () -> Void

    @Published private(set) var displayTitle: String
    @Published private(set) var displayURL: String
    @Published private(set) var displayHost: String
    @Published private(set) var connectionType: ConnectionType = .internet

    private var cancellables: Set<AnyCancellable> = []

    /// The latest trimmed page title, held until the debounce fires or the
    /// page finishes loading (whichever comes first). Decouples the tab bar
    /// width from the page title churn that happens during load.
    private var pendingTitle: String = ""
    /// While loading, title commits are delayed by this interval so a title
    /// that changes several times mid-load only resizes the tab chip once.
    private static let titleDebounce: Duration = .milliseconds(300)
    private var titleDebounceTask: Task<Void, Never>?

    init(id: UUID = UUID(), model: TSNetModel, initialURL: URL,
         restoredTitle: String? = nil, dataStore: WKWebsiteDataStore,
         isHomePage: Bool = false,
         openNewTab: @escaping (URL) -> Void = { _ in },
         onMetadataChange: @escaping () -> Void = {}) {
        self.id = id
        self.initialURL = initialURL
        self.model = model
        self.onMetadataChange = onMetadataChange
        // Default to the hostname (not the app name) so a no-title page shows
        // where it is rather than "Aperture".
        let initialHost = initialURL.host?.isEmpty == false
            ? initialURL.host!
            : initialURL.absoluteString
        self.displayTitle = restoredTitle?.isEmpty == false ? restoredTitle! : initialHost
        self.displayURL = initialURL.absoluteString
        self.displayHost = initialURL.host ?? initialURL.absoluteString
        self.viewModel = BrowserViewModel(model: model, initialURL: initialURL,
                                          dataStore: dataStore,
                                          isHomePage: isHomePage,
                                          openNewTab: openNewTab)

        viewModel.$title
            .combineLatest(viewModel.$url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshDisplayed() }
            .store(in: &cancellables)

        // When the page finishes loading, commit any pending title immediately
        // instead of waiting out the debounce timer.
        viewModel.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                if !loading { self?.refreshDisplayed() }
            }
            .store(in: &cancellables)

        model.$localStatus
            .combineLatest(model.$proxyPolicy)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshConnectionType() }
            .store(in: &cancellables)
    }

    var stored: StoredBrowserTab {
        StoredBrowserTab(id: id, url: displayURL, title: displayTitle)
    }

    var hasWebView: Bool { viewModel.hasWebView }
    func unloadWebView() { viewModel.unloadWebView() }

    private func refreshDisplayed() {
        let previousURL = displayURL

        // Hold the latest trimmed title and commit it on a debounce while the
        // page is loading (the title churns during load and would jiggle the
        // tab bar), or immediately once the page is no longer loading.
        pendingTitle = viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines)
        scheduleTitleCommit()

        let newURL = viewModel.url?.absoluteString ?? displayURL
        displayURL = newURL
        displayHost = viewModel.url?.host ?? URL(string: displayURL)?.host ?? ""
        refreshConnectionType()
        if displayURL != previousURL {
            onMetadataChange()
        }
    }

    /// Commits `pendingTitle` to `displayTitle` now if the page is not loading,
    /// or after a short debounce if it is. The debounce keeps the tab chip from
    /// resizing on every interim title change during load; the load-finished
    /// observer forces an immediate commit so the final title appears without
    /// waiting the full debounce.
    private func scheduleTitleCommit() {
        if viewModel.isLoading {
            titleDebounceTask?.cancel()
            titleDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: Self.titleDebounce)
                guard !Task.isCancelled, let self else { return }
                self.commitTitle()
            }
        } else {
            titleDebounceTask?.cancel()
            titleDebounceTask = nil
            commitTitle()
        }
    }

    private func commitTitle() {
        let previous = displayTitle
        let trimmed = pendingTitle
        if !trimmed.isEmpty {
            displayTitle = trimmed
        } else if let host = viewModel.url?.host, !host.isEmpty {
            // Pages with no <title> show where they are (the host) instead of
            // the app name, which was confusing.
            displayTitle = host
        } else if let host = URL(string: displayURL)?.host, !host.isEmpty {
            displayTitle = host
        } else {
            displayTitle = "Aperture"
        }
        if displayTitle != previous {
            onMetadataChange()
        }
    }

    private func refreshConnectionType() {
        connectionType = ConnectionTypeResolver.resolve(
            host: viewModel.url?.host ?? URL(string: displayURL)?.host ?? initialURL.host,
            status: model.localStatus,
            proxyPolicy: model.proxyPolicy
        )
    }
}
