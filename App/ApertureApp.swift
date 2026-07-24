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

    @State private var workspaceManager: WorkspaceManager?

    init() {
        // Only construct the (heavy) WorkspaceManager — which runs one-time
        // app setup (CrashCapture) and starts the tsnet node — in normal mode.
        // In `-TimingHarness` mode we bypass the app entirely and run the
        // text-mode TimingHarness instead, so the harness's own nodes are the
        // only ones running (and CrashCapture's stderr redirect doesn't fire).
        if !ProcessInfo.processInfo.arguments.contains("-TimingHarness") {
            _workspaceManager = State(initialValue: WorkspaceManager())
        }
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-TimingHarness") {
                TimingHarnessView()
            } else if let workspaceManager {
                TabbedBrowserView(workspaceManager: workspaceManager)
                    .overlay {
                        // Test-only surface for the crash-capture UI test: when
                        // `-UITestCrashReport` is set, show the previous run's
                        // captured Go panic text under `crash-capture-debug` so
                        // the test can assert the capture worked. Invisible
                        // otherwise.
                        if CrashCapture.shouldShowDebugReport {
                            CrashCaptureDebugView()
                        }
                    }
            } else {
                ProgressView()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Don't fan scenePhase to WorkspaceManager in harness mode (there
            // is none); the harness manages its own node lifecycles.
            guard !ProcessInfo.processInfo.arguments.contains("-TimingHarness") else { return }
            guard let workspaceManager else { return }
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
