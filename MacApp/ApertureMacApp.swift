import SwiftUI
import SwiftData
import TailscaleKit

/// Native macOS entry point. Each persisted Tailscale workspace is represented
/// by one value-addressed native window. Closing a window releases only that
/// window; the workspace/node/session remains available from the Window menu.
///
/// This target intentionally contains no Virtualization framework code or UI
/// yet. Its signed product already carries the entitlement so distribution can
/// be validated before VM implementation starts.
@main
struct ApertureMacApp: App {
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
                workspaceID: workspaceID.wrappedValue
            )
            .frame(minWidth: 720, minHeight: 480)
        } defaultValue: {
            workspaceManager.activeWorkspace?.id ?? workspaceManager.addWorkspace().id
        }
        .defaultSize(width: 1100, height: 760)
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

        Settings {
            NativeMacSettingsView()
        }
    }
}

private struct WorkspaceWindowRoot: View {
    @ObservedObject var workspaceManager: WorkspaceManager
    let workspaceID: UUID

    var body: some View {
        if let workspace = workspaceManager.workspace(id: workspaceID) {
            TabbedBrowserView(
                workspaceManager: workspaceManager,
                pinnedWorkspaceID: workspaceID
            )
            .navigationTitle(workspace.identifier)
        } else {
            ContentUnavailableView(
                "Workspace Unavailable",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Choose a workspace from the Window menu.")
            )
        }
    }
}

private struct MacWorkspaceCommands: Commands {
    @ObservedObject var workspaceManager: WorkspaceManager
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Workspace") {
                let workspace = workspaceManager.addWorkspace()
                openWindow(id: "workspace", value: workspace.id)
            }
            .keyboardShortcut("n", modifiers: .command)
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

private struct NativeMacSettingsView: View {
    var body: some View {
        Form {
            LabeledContent("Platform", value: "Native macOS")
            Text("Workspace settings are available from each browser window.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460)
        .accessibilityIdentifier("mac-settings-view")
    }
}
