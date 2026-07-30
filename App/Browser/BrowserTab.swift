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

    init(id: UUID = UUID(), model: TSNetModel, initialURL: URL,
         restoredTitle: String? = nil, dataStore: WKWebsiteDataStore,
         onMetadataChange: @escaping () -> Void = {}) {
        self.id = id
        self.initialURL = initialURL
        self.model = model
        self.onMetadataChange = onMetadataChange
        self.displayTitle = restoredTitle?.isEmpty == false ? restoredTitle! : "Aperture"
        self.displayURL = initialURL.absoluteString
        self.displayHost = initialURL.host ?? initialURL.absoluteString
        self.viewModel = BrowserViewModel(model: model, initialURL: initialURL, dataStore: dataStore)

        viewModel.$title
            .combineLatest(viewModel.$url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshDisplayed() }
            .store(in: &cancellables)

        Publishers.CombineLatest3(model.$localStatus, model.$proxyPolicy, model.$state)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.refreshConnectionType() }
            .store(in: &cancellables)
    }

    var stored: StoredBrowserTab {
        StoredBrowserTab(id: id, url: displayURL, title: displayTitle)
    }

    var hasWebView: Bool { viewModel.hasWebView }
    func unloadWebView() { viewModel.unloadWebView() }

    private func refreshDisplayed() {
        let previousTitle = displayTitle
        let previousURL = displayURL
        let trimmedTitle = viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            displayTitle = trimmedTitle
        } else if previousTitle.isEmpty, let host = viewModel.url?.host, !host.isEmpty {
            displayTitle = host
        }
        displayURL = viewModel.url?.absoluteString ?? displayURL
        displayHost = viewModel.url?.host ?? URL(string: displayURL)?.host ?? ""
        refreshConnectionType()
        if displayTitle != previousTitle || displayURL != previousURL {
            onMetadataChange()
        }
    }

    private func refreshConnectionType() {
        guard model.state == .Running else {
            connectionType = .reconnecting
            return
        }
        connectionType = ConnectionTypeResolver.resolve(
            host: viewModel.url?.host ?? URL(string: displayURL)?.host ?? initialURL.host,
            status: model.localStatus,
            proxyPolicy: model.proxyPolicy
        )
    }
}
