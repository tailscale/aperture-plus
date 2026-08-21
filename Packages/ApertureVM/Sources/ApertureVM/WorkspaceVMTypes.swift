import Foundation

public enum VMDesiredState: String, Codable, Sendable, Equatable {
    case running
    case stopped
}

public struct VMMetadata: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let defaultDiskSize = UInt64(64 * 1024 * 1024 * 1024)

    public var formatVersion: Int
    public var vmID: UUID
    public var desiredState: VMDesiredState
    public var createdAt: Date
    public var applianceFormatVersion: Int
    public var diskSize: UInt64

    public init(vmID: UUID = UUID(), desiredState: VMDesiredState = .stopped,
                createdAt: Date = Date(), applianceFormatVersion: Int = 1,
                diskSize: UInt64 = VMMetadata.defaultDiskSize,
                formatVersion: Int = VMMetadata.currentVersion) {
        self.formatVersion = formatVersion
        self.vmID = vmID
        self.desiredState = desiredState
        self.createdAt = createdAt
        self.applianceFormatVersion = applianceFormatVersion
        self.diskSize = diskSize
    }
}

public enum VMPhase: Sendable, Equatable {
    case absent
    case creating
    case starting
    case waitingForLogin(String)
    case running(hostname: String?, addresses: [String])
    case stopped
    case failed(stage: String, message: String)

    public var description: String {
        switch self {
        case .absent: return "absent"
        case .creating: return "creating"
        case .starting: return "starting"
        case .waitingForLogin: return "waiting-for-login"
        case .running: return "running"
        case .stopped: return "stopped"
        case .failed: return "failed"
        }
    }
}

public struct VMStatus: Sendable, Equatable {
    public var phase: VMPhase
    public var desiredState: VMDesiredState?
    public var diskURL: URL?
    public var console: String
}

public enum VMEvent: Sendable, Equatable {
    case log(String)
    case phase(VMPhase)
    case parentStatus(String)
}

@MainActor
public protocol VMNetworkAttachment: AnyObject, Sendable {
    func open() async throws -> (FileHandle, AnyObject)
    func close() async
}

/// Selects how Virtualization.framework connects the guest's virtio network
/// device. Apple's NAT is the normal, unrestricted Internet path. The custom
/// file-handle attachment remains available for callers that need to supply a
/// packet bridge or isolation boundary.
public enum VMNetworkMode: Sendable {
    case none
    case nat
    case custom(VMNetworkAttachment)
}

public struct VMConfiguration: @unchecked Sendable {
    public var workspaceID: UUID
    public var workspaceDirectory: URL
    public var artifactRoots: [URL]
    public var diskSize: UInt64
    public var cpus: Int
    public var memory: UInt64
    public var storageOnly: Bool
    public var guestAuthKey: String?
    public var networkMode: VMNetworkMode

    public init(workspaceID: UUID, workspaceDirectory: URL,
                artifactRoots: [URL], diskSize: UInt64 = VMMetadata.defaultDiskSize,
                cpus: Int = 2, memory: UInt64 = 2 * 1024 * 1024 * 1024,
                storageOnly: Bool = false,
                guestAuthKey: String? = nil,
                networkMode: VMNetworkMode = .none) {
        self.workspaceID = workspaceID
        self.workspaceDirectory = workspaceDirectory
        self.artifactRoots = artifactRoots
        self.diskSize = diskSize
        self.cpus = cpus
        self.memory = memory
        self.storageOnly = storageOnly
        self.guestAuthKey = guestAuthKey
        self.networkMode = networkMode
    }
}
