import SwiftUI
import SwiftData
import TailscaleKit

/// Native macOS entry point. The app shares its workspace, browser, bookmarks,
/// and userspace-Tailscale implementation with iOS, while platform bridges and
/// desktop presentation remain native macOS code paths.
///
/// This target intentionally contains no Virtualization framework code yet.
/// Its signed product already carries the entitlement so distribution can be
/// validated before VM implementation starts.
@main
struct ApertureMacApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var workspaceManager = WorkspaceManager()

    var body: some Scene {
        WindowGroup {
            TabbedBrowserView(workspaceManager: workspaceManager)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 760)
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

        // The in-browser Settings sheet remains available while the port is
        // underway. Keep a native Settings command as a transparent status
        // surface rather than leaving Command-, unhandled.
        Settings {
            NativeMacSettingsView()
        }
    }
}

private struct NativeMacSettingsView: View {
    var body: some View {
        Form {
            LabeledContent("Platform", value: "Native macOS")
            Text("Browser settings are available from the browser toolbar.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460)
        .accessibilityIdentifier("mac-settings-view")
    }
}
