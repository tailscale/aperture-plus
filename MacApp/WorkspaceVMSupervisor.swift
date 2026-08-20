import AppKit
import Combine
import Foundation
import SwiftUI
import TailscaleKit
import ApertureVM

/// Native-macOS owner of all workspace appliances. It is intentionally kept
/// above any SwiftUI window: closing a browser or console window cannot stop a
/// VM, and the same controller is reused when a console is reopened.
@MainActor
final class WorkspaceVMSupervisor: NSObject, ObservableObject, WorkspaceVMManaging {
    @Published private(set) var revision = 0
    var changes: AnyPublisher<Void, Never> {
        $revision.map { _ in () }.eraseToAnyPublisher()
    }

    private weak var workspaceManager: WorkspaceManager?
    private var controllers: [UUID: ManagedWorkspaceVMController] = [:]
    private var launchTask: Task<Void, Never>?

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        super.init()
        discover()
    }

    deinit { launchTask?.cancel() }

    func discover() {
        guard let workspaceManager else { return }
        for workspace in workspaceManager.workspaces {
            if WorkspaceStore.loadVMMetadata(workspace.id) != nil {
                _ = controller(for: workspace)
            }
        }
        revision += 1
    }

    func startDesiredVMs() {
        launchTask?.cancel()
        launchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // The workspace node must be alive before the VM bridge is created.
            // Controllers themselves wait for that node and report a useful
            // failure if the workspace has not reached a usable state.
            for workspace in workspaceManager?.workspaces ?? [] {
                guard let metadata = WorkspaceStore.loadVMMetadata(workspace.id),
                      metadata.desiredState == .running else { continue }
                controller(for: workspace).start()
            }
        }
    }

    func vmStatus(for workspaceID: UUID) -> WorkspaceVMStatus {
        guard workspaceManager?.workspace(id: workspaceID) != nil else {
            return .absent
        }
        if let controller = controllers[workspaceID] {
            return controller.status
        }
        guard let metadata = WorkspaceStore.loadVMMetadata(workspaceID) else {
            return .absent
        }
        return WorkspaceVMStatus(phase: .stopped,
                                 desiredState: metadata.desiredState,
                                 hasPersistentDisk: FileManager.default.fileExists(
                                    atPath: WorkspaceStore.vmDiskURL(workspaceID).path))
    }

    func createAndStartVM(for workspace: Workspace) {
        let metadata = WorkspaceStore.loadVMMetadata(workspace.id)
            ?? WorkspaceVMMetadata(desiredState: .running)
        WorkspaceStore.saveVMMetadata(metadata.withDesiredState(.running), workspaceID: workspace.id)
        controller(for: workspace).start()
        revision += 1
    }

    func startVM(for workspace: Workspace) {
        guard var metadata = WorkspaceStore.loadVMMetadata(workspace.id) else {
            createAndStartVM(for: workspace)
            return
        }
        metadata.desiredState = .running
        WorkspaceStore.saveVMMetadata(metadata, workspaceID: workspace.id)
        controller(for: workspace).start()
        revision += 1
    }

    func stopVM(for workspace: Workspace) {
        guard var metadata = WorkspaceStore.loadVMMetadata(workspace.id) else { return }
        metadata.desiredState = .stopped
        WorkspaceStore.saveVMMetadata(metadata, workspaceID: workspace.id)
        controller(for: workspace).stop()
        revision += 1
    }

    func restartVM(for workspace: Workspace) {
        guard var metadata = WorkspaceStore.loadVMMetadata(workspace.id) else { return }
        metadata.desiredState = .running
        WorkspaceStore.saveVMMetadata(metadata, workspaceID: workspace.id)
        controller(for: workspace).restart()
        revision += 1
    }

    func deleteVM(for workspace: Workspace) {
        guard let controller = controllers[workspace.id] else {
            WorkspaceStore.removeVM(workspace.id)
            revision += 1
            return
        }
        Task { @MainActor [weak self] in
            await controller.deleteAndWait()
            WorkspaceStore.removeVM(workspace.id)
            self?.controllers.removeValue(forKey: workspace.id)
            self?.revision += 1
        }
    }

    func deleteVMAndWait(for workspace: Workspace) async {
        guard let controller = controllers[workspace.id] else {
            WorkspaceStore.removeVM(workspace.id)
            revision += 1
            return
        }
        await controller.deleteAndWait()
        WorkspaceStore.removeVM(workspace.id)
        controllers.removeValue(forKey: workspace.id)
        revision += 1
    }

    func openVMConsole(for workspace: Workspace) {
        controller(for: workspace).openConsole()
    }

    func signInToVM(for workspace: Workspace) {
        guard case .waitingForLogin(let url) = vmStatus(for: workspace.id).phase,
              let parsed = URL(string: url),
              ["https", "http"].contains(parsed.scheme?.lowercased()) else { return }
        NSWorkspace.shared.open(parsed)
    }

    private func controller(for workspace: Workspace) -> ManagedWorkspaceVMController {
        if let existing = controllers[workspace.id] { return existing }
        let created = ManagedWorkspaceVMController(workspace: workspace) { [weak self] in
            self?.revision += 1
        }
        controllers[workspace.id] = created
        return created
    }
}

private extension WorkspaceVMMetadata {
    func withDesiredState(_ state: WorkspaceVMDesiredState) -> WorkspaceVMMetadata {
        var copy = self
        copy.desiredState = state
        return copy
    }
}
