import SwiftUI
import SwiftData
import AppIntents
import AppKit
import TailscaleKit

/// Native macOS entry point. Each persisted Tailscale workspace is represented
/// by one value-addressed native window. Closing a window releases only that
/// window; the workspace/node/session remains available from the Window menu.
///
/// This target intentionally contains no Virtualization framework code or UI
/// yet. Its signed product already carries the entitlement so distribution can
/// be validated before VM implementation starts.

/// Ensures a workspace window is open on launch even when the app is launched
/// non-frontmost (XCUITest's `app.launch()`, `open -g`), where SwiftUI scenes
/// never become `.active` and `.defaultLaunchBehavior(.presented)` therefore
/// does not fire — leaving the app running with no window, so every Mac UI
/// test timed out at its first `app.windows` wait. `applicationDidFinishLaunching`
/// (which AppKit calls regardless of activation) drives this: it captures
/// `openWindow` from `MacWorkspaceCommands` (the menu bar is always built at
/// launch) into this shared holder, then calls it for the active workspace.
/// `openWindow(id:value:)` is idempotent — opening an already-open value raises
/// that window instead of duplicating — so it composes safely with the
/// `.presented` frontmost-launch path.
@MainActor
private final class WindowOpener {
    static let shared = WindowOpener()
    var openWindow: OpenWindowAction?
    var workspaceManager: WorkspaceManager?
    private var attempts = 0
    func openWorkspaceWindow() {
        guard let action = openWindow, let wm = workspaceManager else {
            // The Commands/menu that populate these may build just after launch.
            attempts += 1
            guard attempts < 40 else { return }  // ~2s of retries at 50ms
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                WindowOpener.shared.openWorkspaceWindow()
            }
            return
        }
        let id = wm.activeWorkspace?.id ?? wm.addWorkspace().id
        action(id: "workspace", value: id)
    }
}

private final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            WindowOpener.shared.openWorkspaceWindow()
        }
    }
}

@main
struct ApertureMacApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: MacAppDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var workspaceManager = WorkspaceManager()

    var body: some Scene {
        WindowGroup(
            "Aperture",
            id: "workspace",
            for: UUID.self
        ) { workspaceID in
            WorkspaceWindowRoot(
                workspaceManager: workspaceManager,
                workspaceID: workspaceID
            )
            .frame(minWidth: 720, minHeight: 480)
        } defaultValue: {
            workspaceManager.activeWorkspace?.id ?? workspaceManager.addWorkspace().id
        }
        .defaultSize(width: 1100, height: 760)
        // A value-based WindowGroup does not auto-present a window on launch
        // (it opens only via `openWindow` or state restoration). Without this,
        // a fresh launch — or relaunch after the app was terminated with no
        // open windows — shows no window at all: the process runs (tsnet
        // starts) but there's nothing to interact with, and clicking the Dock
        // icon of a running-with-no-windows app does nothing either. `.presented`
        // makes the workspace scene present itself on launch using `defaultValue`
        // when there is no saved state to restore, which is exactly the
        // always-show-a-window behavior a single-window-by-default browser
        // needs. (macOS 15.0+; the target is macOS 26.0.)
        .defaultLaunchBehavior(.presented)
        // Opt out of AppKit window state restoration. The workspace list and
        // each workspace's tsnet state are persisted in workspaces.json +
        // per-workspace dirs, so NSWindow restoration is not load-bearing —
        // and leaving it enabled makes the app hostage to macOS's
        // "Aperture unexpectedly quit while reopening windows" guard. That
        // dialog is driven by talagent's per-app `restorecount.plist`: once
        // the count is non-zero (after a crash or an abrupt UI-test terminate
        // mid-restoration), the next launch blocks on a Reopen/Don't-Reopen
        // modal — and under XCUITest the dialog is suppressed, so the app
        // comes up with NO window at all and every test times out at its
        // first `app.windows` wait. Disabling scene restoration stops the
        // app from participating in that flow, so launches are deterministic
        // for both users and the test harness.
        .restorationBehavior(.disabled)
        .commands {
            MacWorkspaceCommands(workspaceManager: workspaceManager)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                workspaceManager.willEnterBackground()
            case .inactive:
                break
            case .active:
                workspaceManager.willEnterForeground()
            @unknown default:
                break
            }
        }

        WindowGroup("Linux VM (Experimental)", id: "experimental-vm", for: UUID.self) { vmID in
            ExperimentalVMView(id: vmID.wrappedValue)
        } defaultValue: {
            UUID()
        }
        .defaultSize(width: 960, height: 640)
        .restorationBehavior(.disabled)

        Settings {
            MacSettingsHost(workspaceManager: workspaceManager)
        }
    }
}

private struct WorkspaceWindowRoot: View {
    @ObservedObject var workspaceManager: WorkspaceManager
    @Binding var workspaceID: UUID

    private var resolvedWorkspace: Workspace? {
        workspaceManager.workspace(id: workspaceID) ?? workspaceManager.activeWorkspace
    }

    var body: some View {
        if let workspace = resolvedWorkspace {
            TabbedBrowserView(
                workspaceManager: workspaceManager,
                pinnedWorkspaceID: workspace.id
            )
            .navigationTitle(workspace.identifier)
            .onDisappear {
                // Closing a native workspace window deletes the workspace when
                // it was never connected (still at NeedsLogin) and it isn't the
                // last one. A fresh Cmd+N workspace that you close right away
                // shouldn't linger in the Window menu — it has no session data
                // worth keeping. Connected workspaces are preserved (closing a
                // window keeps the workspace, reachable from the Window menu),
                // and the last workspace is never auto-deleted, so closing the
                // final window just leaves the app running with no windows
                // rather than churning a replacement node.
                if let ws = workspaceManager.workspace(id: workspaceID),
                   ws.statusViewModel.needsAuth,
                   workspaceManager.workspaces.count > 1 {
                    workspaceManager.deleteWorkspace(id: workspaceID)
                }
            }
        } else {
            ProgressView("Restoring Workspace…")
        }
    }
}

private struct MacWorkspaceCommands: Commands {
    @ObservedObject var workspaceManager: WorkspaceManager
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = {
            WindowOpener.shared.openWindow = openWindow
            WindowOpener.shared.workspaceManager = workspaceManager
        }()
        CommandGroup(replacing: .newItem) {
            Button("New Workspace") {
                let workspace = workspaceManager.addWorkspace()
                openWindow(id: "workspace", value: workspace.id)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New VM (experimental)") {
                openWindow(id: "experimental-vm", value: UUID())
            }
            // Deliberately no keyboard shortcut while VM support is experimental.
        }

        // The standard Window menu lists only windows that are currently open.
        // Add every persisted workspace so a closed window can be recreated;
        // passing the same value raises an already-open window instead.
        CommandGroup(before: .windowArrangement) {
            Divider()
            ForEach(workspaceManager.workspaces) { workspace in
                Button(workspace.identifier) {
                    workspaceManager.selectWorkspace(id: workspace.id)
                    openWindow(id: "workspace", value: workspace.id)
                }
            }
            Divider()
        }
    }
}

/// macOS app-menu Settings (Cmd+,). Hosts the SAME shared `SettingsView` the
/// browser/gear sheet uses, so there is one settings codebase across iOS and
/// macOS. "Done" closes the settings window (`dismissWindow`); Logout deletes
/// the active workspace's session exactly as it does from the in-window sheet.
private struct MacSettingsHost: View {
    @ObservedObject var workspaceManager: WorkspaceManager
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let ws = workspaceManager.activeWorkspace {
            SettingsView(
                viewModel: SettingsViewModel(workspace: ws) {
                    workspaceManager.deleteWorkspace(id: ws.id)
                },
                dismissAction: { dismissWindow() }
            )
        } else {
            ContentUnavailableView(
                "No Workspace",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Open a workspace window to configure it.")
            )
        }
    }
}
