import Combine
import SwiftUI

/// Workspace-specific appliance controls. This view is compiled for iOS as a
/// harmless unavailable section; the native Mac supervisor supplies the real
/// implementation and lifecycle.
struct WorkspaceVMSettingsSection: View {
    @ObservedObject var workspace: Workspace
    let manager: (any WorkspaceVMManaging)?
    @State private var showingDeleteConfirmation = false

    private var status: WorkspaceVMStatus {
        manager?.vmStatus(for: workspace.id) ?? .absent
    }

    var body: some View {
        Section(header: Text("Thundersnap Appliance")) {
            statusRow
            controls
        }
        .onReceive(manager?.changes ?? Empty<Void, Never>(completeImmediately: false).eraseToAnyPublisher()) { _ in
            // The supervisor publishes transient lifecycle changes. Reading
            // status again through the computed property invalidates this view.
        }
        .confirmationDialog("Delete Thundersnap VM?", isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete VM and All Data", role: .destructive) {
                manager?.deleteVM(for: workspace)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes the appliance disk, including its Thundersnap data and guest Tailscale identity. The workspace itself is not deleted.")
        }
    }

    @ViewBuilder private var statusRow: some View {
        HStack {
            Label(status.phase.title, systemImage: iconName)
            Spacer()
            if let desired = status.desiredState {
                Text(desired == .running ? "Auto-start" : "Stopped")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .accessibilityIdentifier("thundersnap-vm-status")
        if case .running(let hostname, let addresses) = status.phase {
            if let hostname, !hostname.isEmpty { Text(hostname).font(.caption.monospaced()) }
            if !addresses.isEmpty { Text(addresses.joined(separator: ", ")).font(.caption.monospaced()) }
        }
        if case .waitingForLogin = status.phase {
            Text("The guest needs its own Tailscale sign-in. The workspace node and guest node are separate identities.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if case .failed(let stage, let message) = status.phase {
            Text("\(stage): \(message)")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var controls: some View {
        switch status.phase {
        case .absent:
            Button("Create & Start Thundersnap VM") {
                manager?.createAndStartVM(for: workspace)
            }
            .accessibilityLabel("Create and start Thundersnap VM")
            .accessibilityHint("Creates a persistent workspace appliance and starts it")
            .accessibilityIdentifier("thundersnap-vm-create")
        case .stopped:
            Button("Start") { manager?.startVM(for: workspace) }
                .accessibilityIdentifier("thundersnap-vm-start")
            Button("Delete VM", role: .destructive) { showingDeleteConfirmation = true }
                .accessibilityIdentifier("thundersnap-vm-delete")
        case .creating, .starting, .stopping:
            ProgressView()
            Button("Open Console") { manager?.openVMConsole(for: workspace) }
                .accessibilityIdentifier("thundersnap-vm-console")
            Button("Stop", role: .destructive) { manager?.stopVM(for: workspace) }
                .accessibilityIdentifier("thundersnap-vm-stop")
        case .waitingForLogin(let url):
            Button("Sign in to Tailscale") { manager?.signInToVM(for: workspace) }
                .accessibilityHint("Opens the guest Tailscale enrollment page")
                .disabled(URL(string: url) == nil)
                .accessibilityIdentifier("thundersnap-vm-sign-in")
            Button("Open Console") { manager?.openVMConsole(for: workspace) }
                .accessibilityIdentifier("thundersnap-vm-console")
            Button("Stop", role: .destructive) { manager?.stopVM(for: workspace) }
                .accessibilityIdentifier("thundersnap-vm-stop")
        case .running:
            Button("Open Console") { manager?.openVMConsole(for: workspace) }
                .accessibilityIdentifier("thundersnap-vm-console")
            Button("Restart") { manager?.restartVM(for: workspace) }
                .accessibilityIdentifier("thundersnap-vm-restart")
            Button("Stop", role: .destructive) { manager?.stopVM(for: workspace) }
                .accessibilityIdentifier("thundersnap-vm-stop")
        case .failed:
            Button("Open Console") { manager?.openVMConsole(for: workspace) }
                .accessibilityIdentifier("thundersnap-vm-console")
            Button("Restart") { manager?.restartVM(for: workspace) }
                .accessibilityIdentifier("thundersnap-vm-restart")
            Button("Delete VM", role: .destructive) { showingDeleteConfirmation = true }
                .accessibilityIdentifier("thundersnap-vm-delete")
        }
    }

    private var iconName: String {
        switch status.phase {
        case .absent: return "shippingbox"
        case .creating, .starting, .stopping: return "arrow.triangle.2.circlepath"
        case .waitingForLogin: return "person.badge.key"
        case .running: return "checkmark.circle"
        case .stopped: return "stop.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}
