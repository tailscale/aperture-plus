import Combine
import SwiftUI

/// Bridges the workspace VM supervisor's lifecycle into SwiftUI reactivity.
///
/// `WorkspaceVMManaging` is a plain protocol, and views hold it as a protocol
/// existential (`any WorkspaceVMManaging`), so a view can't `@ObservedObject` it
/// directly. This tracker owns the live VM status as a `@Published` property —
/// the canonical SwiftUI reactivity path — and refreshes it from
/// `manager.vmStatus(for:)` on two cues:
///
/// 1. The supervisor's `changes` publisher fires (immediate feedback after a
///    button click kicks off a phase transition).
/// 2. A 1 s polling backstop, so phases that evolve without a published event
///    (guest-driven transitions, runtime stop notifications, etc.) still
///    surface. Because `WorkspaceVMStatus` is `Equatable`, `@Published`
///    suppresses redundant re-renders when the value is unchanged.
///
/// When `manager` is `nil` (the iOS target, where the VM supervisor is absent),
/// the tracker is inert: status stays `.absent` and no timers run.
@MainActor
final class WorkspaceVMStatusTracker: ObservableObject {
    @Published private(set) var status: WorkspaceVMStatus = .absent

    private let manager: (any WorkspaceVMManaging)?
    private let workspaceID: UUID
    private var cancellables = Set<AnyCancellable>()

    init(manager: (any WorkspaceVMManaging)?, workspaceID: UUID) {
        self.manager = manager
        self.workspaceID = workspaceID
        guard manager != nil else { return }
        refresh()
        manager?.changes
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func refresh() {
        status = manager?.vmStatus(for: workspaceID) ?? .absent
    }
}

/// Workspace-specific appliance controls. This view is compiled for iOS as a
/// harmless unavailable section; the native Mac supervisor supplies the real
/// implementation and lifecycle.
struct WorkspaceVMSettingsSection: View {
    @ObservedObject var workspace: Workspace
    let manager: (any WorkspaceVMManaging)?
    @State private var showingDeleteConfirmation = false
    @StateObject private var tracker: WorkspaceVMStatusTracker

    init(workspace: Workspace, manager: (any WorkspaceVMManaging)?) {
        self.workspace = workspace
        self.manager = manager
        // `@StateObject` only consumes this on first init; `manager` is stable
        // for the life of a settings window, so later re-inits reuse the tracker
        // (and its subscriptions) rather than rebuilding it on every render.
        _tracker = StateObject(wrappedValue: WorkspaceVMStatusTracker(
            manager: manager, workspaceID: workspace.id))
    }

    private var status: WorkspaceVMStatus { tracker.status }

    var body: some View {
        Section(header: Text("Thundersnap Appliance")) {
            statusRow
            controls
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
