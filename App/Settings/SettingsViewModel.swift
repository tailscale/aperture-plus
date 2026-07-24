//  SettingsViewModel.swift
//  Aperture
//
//  Backs the Settings sheet for the ACTIVE workspace. Reads the workspace's
//  hostname/home page from its `WorkspaceDefinition` and writes edits back
//  through the workspace (which persists the definition). Exit-node state is
//  observed from the workspace's tsnet prefs; logout deletes the workspace's
//  tsnet profile.
//

import Foundation
import Combine
import TailscaleKit

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var exitNodeEnabled: Bool = false
    @Published var exitNodeDisplayName: String = "None"

    @Published var tailnetHostName: String = ""
    @Published var homePage: String = ""

    private let workspace: Workspace
    private var observers: Set<AnyCancellable> = []

    init(workspace: Workspace) {
        self.workspace = workspace
        // Seed from the workspace's persisted definition + home page.
        self.tailnetHostName = workspace.definition.hostname
        self.homePage = workspace.homePage.url
        bindPrefs()
        observeWorkspace()
    }

    private func bindPrefs() {
        // Observe prefs to drive exit node UI.
        workspace.model.$prefs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prefs in
                guard let self else { return }
                let id = prefs?.ExitNodeID ?? ""
                self.exitNodeEnabled = !id.isEmpty
                self.exitNodeDisplayName = id.isEmpty ? "None" : id
            }
            .store(in: &observers)
    }

    /// Keep the hostname/home-page fields in sync if they change elsewhere
    /// (e.g. the workspace identity refresh, or a future workspace switch).
    private func observeWorkspace() {
        workspace.$definition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] def in
                guard let self else { return }
                if self.tailnetHostName != def.hostname {
                    self.tailnetHostName = def.hostname
                }
            }
            .store(in: &observers)

        workspace.homePage.$url
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self, self.homePage != url else { return }
                self.homePage = url
            }
            .store(in: &observers)
    }

    func setExitNodeEnabled(_ enabled: Bool) {
        workspace.setExitNodeEnabled(enabled)
    }

    func setHomePage(_ url: String) {
        workspace.setHomePage(url)
    }

    func setTailnetHostName(_ hostName: String) {
        workspace.setHostName(hostName)
    }

    func logout() {
        workspace.logout()
    }
}
