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

    @State var workspaceManager = WorkspaceManager()

    var body: some Scene {
        WindowGroup {
            TabbedBrowserView(workspaceManager: workspaceManager)
                .overlay {
                    // Test-only surface for the crash-capture UI test: when
                    // `-UITestCrashReport` is set, show the previous run's
                    // captured Go panic text under `crash-capture-debug` so the
                    // test can assert the capture worked. Invisible otherwise.
                    if CrashCapture.shouldShowDebugReport {
                        CrashCaptureDebugView()
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background, .inactive:
                workspaceManager.willEnterBackground()
            case .active:
                workspaceManager.willEnterForeground()
            @unknown default:
                break
            }
        }
    }
}
