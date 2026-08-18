//
//  WorkspaceVMModel.swift
//  Aperture
//
//  Platform-neutral persistence and state types for the optional workspace
//  Thundersnap appliance. Virtualization.framework lives in the native Mac
//  supervisor; these types are deliberately safe to compile into iOS too.
//

import Foundation

/// The desired state is persisted separately from the VM's transient state.
/// A running VM is restarted on the next app launch; a stopped VM is not.
enum WorkspaceVMDesiredState: String, Codable, Equatable, Sendable {
    case running
    case stopped
}

/// Versioned, per-workspace VM metadata. The existence of this file together
/// with `disk.raw` is the durable record that a workspace owns a VM.
struct WorkspaceVMMetadata: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let defaultDiskSize = UInt64(64 * 1024 * 1024 * 1024)

    var formatVersion: Int
    var vmID: UUID
    var desiredState: WorkspaceVMDesiredState
    var createdAt: Date
    var applianceFormatVersion: Int
    var diskSize: UInt64

    init(vmID: UUID = UUID(),
         desiredState: WorkspaceVMDesiredState = .stopped,
         createdAt: Date = Date(),
         applianceFormatVersion: Int = 1,
         diskSize: UInt64 = WorkspaceVMMetadata.defaultDiskSize,
         formatVersion: Int = WorkspaceVMMetadata.currentVersion) {
        self.formatVersion = formatVersion
        self.vmID = vmID
        self.desiredState = desiredState
        self.createdAt = createdAt
        self.applianceFormatVersion = applianceFormatVersion
        self.diskSize = diskSize
    }

    /// Decode old records without making a missing optional metadata field
    /// destroy an otherwise recoverable workspace. Unknown future versions are
    /// rejected by the supervisor before a VM is started.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        vmID = try c.decode(UUID.self, forKey: .vmID)
        desiredState = try c.decodeIfPresent(WorkspaceVMDesiredState.self,
                                              forKey: .desiredState) ?? .stopped
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        applianceFormatVersion = try c.decodeIfPresent(Int.self,
                                                        forKey: .applianceFormatVersion) ?? 1
        diskSize = try c.decodeIfPresent(UInt64.self, forKey: .diskSize)
            ?? WorkspaceVMMetadata.defaultDiskSize
    }
}

enum WorkspaceVMPhase: Equatable, Sendable {
    case absent
    case creating
    case starting
    case waitingForLogin(authURL: String)
    case running(hostname: String?, addresses: [String])
    case stopping
    case stopped
    case failed(stage: String, message: String)

    var title: String {
        switch self {
        case .absent: return "Not created"
        case .creating: return "Creating"
        case .starting: return "Starting"
        case .waitingForLogin: return "Waiting for Tailscale sign-in"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }
}

struct WorkspaceVMStatus: Equatable, Sendable {
    var phase: WorkspaceVMPhase
    var desiredState: WorkspaceVMDesiredState?
    var hasPersistentDisk: Bool

    static let absent = WorkspaceVMStatus(phase: .absent,
                                          desiredState: nil,
                                          hasPersistentDisk: false)
}

/// The Mac supervisor conforms to this protocol. Keeping the UI dependency
/// here allows the shared Settings view to remain available on iOS without
/// importing Virtualization.framework.
@MainActor
protocol WorkspaceVMManaging: AnyObject {
    func vmStatus(for workspaceID: UUID) -> WorkspaceVMStatus
    func createAndStartVM(for workspace: Workspace)
    func startVM(for workspace: Workspace)
    func stopVM(for workspace: Workspace)
    func restartVM(for workspace: Workspace)
    func deleteVM(for workspace: Workspace)
    func openVMConsole(for workspace: Workspace)
    func signInToVM(for workspace: Workspace)
}
