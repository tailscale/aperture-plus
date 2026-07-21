//  Created by Jonathan Nobels on 2025-12-19.
//

import Foundation
import Combine
import TailscaleKit

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var exitNodeEnabled: Bool = false
    @Published var exitNodeDisplayName: String = "None"

    @Published var tailnetHostName: String = ""
    @Published var homePage: String = HomePage.standard.url

    private let manager: TSNetManager
    private var observers: Set<AnyCancellable> = []

    init(manager: TSNetManager) {
        self.manager = manager
        // Initialize from saved defaults (or manager.config)
        let saved = UserDefaults.standard.string(forKey: "TailnetHostName")
        self.tailnetHostName = saved ?? manager.config.hostName
        bindPrefs()
    }

    private func bindPrefs() {
        // Observe prefs to drive exit node UI
        manager.model.$prefs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prefs in
                guard let self else { return }
                let id = prefs?.ExitNodeID ?? ""
                self.exitNodeEnabled = !id.isEmpty
                self.exitNodeDisplayName = id.isEmpty ? "None" : id
            }
            .store(in: &observers)
    }

    func setExitNodeEnabled(_ enabled: Bool) {
        manager.setExitNodeEnabled(enabled)
    }

    func setHomePage(_ url: String) {
        HomePage.standard.url = url
    }

    func setTailnetHostName(_ hostName: String) {
        manager.setHostName(hostName)
    }

    func logout() {
        Task {
            let currentUser = try? await manager.localAPIClient?.currentProfile()
            if let currentUser {
                try? await manager.localAPIClient?.deleteProfile(profileID: currentUser.id)
            }
        }
    }
}

