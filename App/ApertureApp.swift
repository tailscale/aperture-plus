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
            case .background:
                workspaceManager.willEnterBackground()
            case .inactive:
                // Do NOT tear down the node on .inactive. That scenePhase
                // fires for Control Center, the app-switcher peek, an incoming
                // call, a notification banner, etc. — the app is still in the
                // foreground. Tearing the tsnet node down and recreating it on
                // the return to .active is expensive AND dangerous mid-login:
                // it recreated the node (new auth URL) while an
                // ASWebAuthenticationSession sheet was still open on the OLD
                // url → the OAuth completed on the control plane but the new
                // node wasn't watching that callback → silent login failure
                // (the stale-URL bug). Only a real .background disconnects;
                // .active reconnects (a no-op via the startInFlight guard if
                // we never went to background).
                break
            case .active:
                workspaceManager.willEnterForeground()
            @unknown default:
                break
            }
        }
    }
}
