// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  ApertureApp.swift
//  Aperture
//
//  Created by Jonathan Nobels on 2025-12-16.
//

import SwiftUI
import SwiftData
import AppIntents
import TailscaleKit

@main
struct ApertureApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var workspaceManager: WorkspaceManager?

    init() {
        // Only construct the (heavy) WorkspaceManager — which initializes the
        // process logger and starts tsnet nodes — in normal mode. Harness modes
        // bypass it and own their node lifecycle.
        if !ProcessInfo.processInfo.arguments.contains("-TimingHarness")
            && !ProcessInfo.processInfo.arguments.contains("-UITestProxyBounceHarness") {
            _workspaceManager = State(initialValue: WorkspaceManager())
        }
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-TimingHarness") {
                TimingHarnessView()
            } else if ProcessInfo.processInfo.arguments.contains("-UITestProxyBounceHarness") {
                ProxyBounceTestHarnessView()
            } else if let workspaceManager {
                TabbedBrowserView(workspaceManager: workspaceManager)
            } else {
                ProgressView()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Don't fan scenePhase to WorkspaceManager in harness mode (there
            // is none); the harness manages its own node lifecycles.
            guard !ProcessInfo.processInfo.arguments.contains("-TimingHarness"),
                  !ProcessInfo.processInfo.arguments.contains("-UITestProxyBounceHarness")
            else { return }
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
