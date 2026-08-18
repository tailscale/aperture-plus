//  WorkspaceStore.swift
//  Aperture
//
//  On-disk persistence for the workspace list + per-workspace path helpers.
//
//  Each workspace is a separate Tailscale (tsnet) identity, so each one gets
//  its own state directory, its own SwiftData bookmarks store, and (via the
//  definition) its own WKWebsiteDataStore UUID. Everything lives under the
//  app's persistent Application Support — NOT NSTemporaryDirectory, which iOS
//  purges under storage pressure (a logged-in node could silently lose its
//  credentials). Process-wide logtail state also uses Application Support;
//  this does the same for tsnet state.
//
//  Layout:
//
//    <Application Support>/Aperture/
//        workspaces.json                 # [WorkspaceDefinition] + activeId
//        Workspaces/<id>/
//            state/                       # tsnet state dir (tailscale_set_dir)
//            Bookmarks.store              # per-workspace SwiftData file
//            tabs.json                     # lightweight restored tab metadata
//            VM/metadata.json              # optional workspace-owned appliance metadata
//            VM/disk.raw                   # optional persistent appliance disk
//
//  Auth keys are NEVER stored here — they come from launch args/env (tests) or
//  persist implicitly inside each workspace's tsnet state dir (real logins).
//  UI tests use a separate top-level Application Support namespace, so their
//  state can never reset or delete a normal app session (even though the app
//  and UI-test target intentionally share a bundle identifier).
//

import Foundation
import TailscaleKit

/// The last-known Tailscale identity for a workspace, persisted so the
/// workspace identifier can render immediately on the next launch (before the
/// node has reconnected), then live-updated from the netmap/prefs once
/// connected. See `Workspace.refreshIdentity`.
struct WorkspaceIdentity: Codable, Equatable {
    var loginName: String?
    var displayName: String?
    var tailnetName: String?
    var hostname: String?
}

struct StoredBrowserTab: Codable, Equatable, Identifiable {
    var id: UUID
    var url: String
    var title: String
}

struct StoredBrowserSession: Codable, Equatable {
    var tabs: [StoredBrowserTab]
    var selectedIndex: Int
}

/// The persisted definition of a workspace. The in-memory `Workspace` object is
/// built from this; changes are written back through `Workspace`'s `onChange`
/// closure (set by `WorkspaceManager`).
struct WorkspaceDefinition: Codable, Identifiable {
    let id: UUID
    var displayName: String
    var hostname: String
    var homePageURL: String
    var controlURL: String
    var ephemeral: Bool
    /// Stable UUID for this workspace's `WKWebsiteDataStore` — keeps the HTTP
    /// cache / cookies / service workers isolated per identity and stable
    /// across launches.
    var dataStoreUUID: UUID
    /// Last-known identity, persisted for immediate display on next launch.
    var lastKnownIdentity: WorkspaceIdentity?

    /// The single workspace created on first launch (or when the list is
    /// empty). Matches the pre-multi-workspace defaults: an
    /// `aperture-<6digit>` hostname, the `http://ai/chat` home page, the
    /// default control URL, and the launch-arg ephemeral flag.
    static func makeDefault() -> WorkspaceDefinition {
        WorkspaceDefinition(
            id: UUID(),
            displayName: "Aperture",
            hostname: TSNetManager.generateDefaultHostName(),
            homePageURL: HomePage.defaultURL,
            controlURL: kDefaultControlURL,
            ephemeral: TSNetManager.launchEphemeral(),
            dataStoreUUID: UUID(),
            lastKnownIdentity: nil
        )
    }
}

/// Persists the workspace list + computes per-workspace paths. All members are
/// `@MainActor` (the module is MainActor-isolated by default).
@MainActor
enum WorkspaceStore {
    /// UI tests must not share the persistent credential/state directory with
    /// the normal app. This matters especially on native macOS, where the UI
    /// test launches the same bundle identifier as the user's running app.
    ///
    /// The explicit `-UITest...` check covers the launch hooks used by the
    /// suite. The XCTest environment check also protects newly-added tests
    /// that forget to add a reset hook. Neither signal exists during a normal
    /// app launch.
    private static let isUITestProcess: Bool = {
        let process = ProcessInfo.processInfo
        if process.arguments.contains(where: { $0.hasPrefix("-UITest") }) {
            return true
        }
        let environment = process.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCInjectBundleInto"] != nil
    }()

    /// Root for all Aperture data. Normal launches use
    /// `<Application Support>/Aperture/`; UI tests use a platform-specific
    /// sibling so iOS and macOS test credentials are isolated from normal
    /// credentials and from each other.
    static var appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
#if os(iOS)
        let name = isUITestProcess ? "Aperture-UI-Test-iOS" : "Aperture"
#elseif os(macOS)
        let name = isUITestProcess ? "Aperture-UI-Test-macOS" : "Aperture"
#else
        let name = isUITestProcess ? "Aperture-UI-Test" : "Aperture"
#endif
        let dir = base.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }()

    /// Process-wide filch/logtail state, independent of workspace/login resets.
    static var logsDir: URL = {
        let dir = appSupportDir.appending(path: "Logs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// `appSupportDir/Workspaces/` (created lazily).
    static var workspacesDir: URL = {
        let dir = appSupportDir.appending(path: "Workspaces", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// `appSupportDir/workspaces.json` — the workspace list + active id.
    static var definitionsFile: URL {
        appSupportDir.appending(path: "workspaces.json")
    }

    /// `<workspacesDir>/<id>/` — a workspace's private directory (created).
    static func workspaceDir(_ id: UUID) -> URL {
        let dir = workspacesDir.appending(path: id.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `<workspaceDir>/state/` — the tsnet state dir passed to
    /// `tailscale_set_dir`. Created so `tailscale_set_dir` has a writable home.
    static func stateDir(_ id: UUID) -> URL {
        let dir = workspaceDir(id).appending(path: "state", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `<workspaceDir>/Bookmarks.store` — this workspace's SwiftData file.
    static func bookmarksURL(_ id: UUID) -> URL {
        workspaceDir(id).appending(path: "Bookmarks.store")
    }

    static func tabsURL(_ id: UUID) -> URL {
        workspaceDir(id).appending(path: "tabs.json")
    }

    static func loadTabs(_ id: UUID) -> StoredBrowserSession? {
        guard let data = try? Data(contentsOf: tabsURL(id)) else { return nil }
        return try? JSONDecoder().decode(StoredBrowserSession.self, from: data)
    }

    static func saveTabs(_ session: StoredBrowserSession, workspaceID: UUID) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: tabsURL(workspaceID), options: .atomic)
    }

    static func removeTabs(_ workspaceID: UUID) {
        try? FileManager.default.removeItem(at: tabsURL(workspaceID))
    }

    // MARK: - Workspace appliance paths

    static func vmDir(_ id: UUID) -> URL {
        workspaceDir(id).appending(path: "VM", directoryHint: .isDirectory)
    }

    static func vmMetadataURL(_ id: UUID) -> URL {
        vmDir(id).appending(path: "metadata.json")
    }

    static func vmDiskURL(_ id: UUID) -> URL {
        vmDir(id).appending(path: "disk.raw")
    }

    static func vmArtifactDirectory(_ id: UUID) -> URL {
        vmDir(id).appending(path: "Artifacts", directoryHint: .isDirectory)
    }

    static func loadVMMetadata(_ id: UUID) -> WorkspaceVMMetadata? {
        guard let data = try? Data(contentsOf: vmMetadataURL(id)) else { return nil }
        return try? JSONDecoder.workspaceVM.decode(WorkspaceVMMetadata.self, from: data)
    }

    static func saveVMMetadata(_ metadata: WorkspaceVMMetadata, workspaceID: UUID) {
        guard let data = try? JSONEncoder.workspaceVM.encode(metadata) else { return }
        let dir = vmDir(workspaceID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: vmMetadataURL(workspaceID), options: .atomic)
    }

    static func removeVM(_ workspaceID: UUID) {
        try? FileManager.default.removeItem(at: vmDir(workspaceID))
    }

    // MARK: - Load / save

    /// On-disk envelope for `workspaces.json`.
    private struct Envelope: Codable {
        var workspaces: [WorkspaceDefinition]
        var activeId: UUID?
    }

    /// Loads the workspace list + active id, or nil if there's no file yet
    /// (first launch) or it can't be decoded (treated as a fresh start).
    static func load() -> (workspaces: [WorkspaceDefinition], activeId: UUID?)? {
        guard let data = try? Data(contentsOf: definitionsFile),
              let env = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        return (env.workspaces, env.activeId)
    }

    /// Atomically writes the workspace list + active id.
    static func save(_ workspaces: [WorkspaceDefinition], activeId: UUID?) {
        let env = Envelope(workspaces: workspaces, activeId: activeId)
        guard let data = try? JSONEncoder().encode(env) else { return }
        try? data.write(to: definitionsFile, options: .atomic)
    }

    /// Removes a workspace's entire on-disk directory (state + bookmarks).
    static func removeWorkspaceDir(_ id: UUID) {
        try? FileManager.default.removeItem(at: workspaceDir(id))
    }
}

private extension JSONEncoder {
    static var workspaceVM: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var workspaceVM: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
