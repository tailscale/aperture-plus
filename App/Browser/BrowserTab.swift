//
//  BrowserTab.swift
//  Aperture
//
//  A single browser tab: owns its BrowserViewModel/raw WKWebView and mirrors
//  the current title/URL into compact UI-facing metadata.
//

import SwiftUI
import WebKit
import Combine
import TailscaleKit

@MainActor
final class BrowserTab: Identifiable, ObservableObject {
    let id = UUID()
    let viewModel: BrowserViewModel
    let initialURL: URL
    private let model: TSNetModel

    @Published private(set) var displayTitle = "Aperture"
    @Published private(set) var displayURL = ""
    @Published private(set) var displayHost = ""
    @Published private(set) var connectionType: ConnectionType = .internet

    private var cancellables: Set<AnyCancellable> = []

    init(model: TSNetModel, initialURL: URL, dataStore: WKWebsiteDataStore) {
        viewModel = BrowserViewModel(model: model, initialURL: initialURL, dataStore: dataStore)
        self.initialURL = initialURL
        self.model = model
        displayURL = initialURL.absoluteString
        displayHost = initialURL.host ?? initialURL.absoluteString

        viewModel.$title
            .combineLatest(viewModel.$url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshDisplayed() }
            .store(in: &cancellables)

        model.$localStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshConnectionType() }
            .store(in: &cancellables)
    }

    func loadInitial() { viewModel.loadInitial() }
    var didLoadInitial: Bool { viewModel.didLoadInitial }

    private func refreshDisplayed() {
        let trimmedTitle = viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            displayTitle = trimmedTitle
        } else if let host = viewModel.url?.host, !host.isEmpty {
            displayTitle = host
        } else {
            displayTitle = "Aperture"
        }
        displayURL = viewModel.url?.absoluteString ?? initialURL.absoluteString
        displayHost = viewModel.url?.host ?? initialURL.host ?? ""
        refreshConnectionType()
    }

    private func refreshConnectionType() {
        connectionType = ConnectionTypeResolver.resolve(host: viewModel.url?.host, status: model.localStatus)
    }
}
