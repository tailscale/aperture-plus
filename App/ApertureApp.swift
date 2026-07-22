//
//  ApertureApp.swift
//  Aperture
//
//  Created by Jonathan Nobels on 2025-12-16.
//

import SwiftUI
import SwiftData
import TailscaleKit

@main
struct ApertureApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State var manager = TSNetManager()

    init() {
        // UI-test hook: start from a known home page so the persistence test
        // isn't polluted by whatever a prior run left in UserDefaults. Harmless
        // in normal use — the launch argument is never set outside UI tests.
        if ProcessInfo.processInfo.arguments.contains("-UITestResetHomePage") {
            HomePage.standard.url = HomePage.defaultURL
        }
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Bookmark.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            TabbedBrowserView(manager: manager)
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background, .inactive:
                manager.willEnterBackground()
            case .active:
                manager.willEnterForeground()
            @unknown default:
                break
            }
        }
    }
}
