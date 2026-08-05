//  WorkspaceManager.swift
//  Aperture
//
//  The app-level coordinator: owns the workspace list + the active workspace,
//  initializes process-wide persistent logging, applies the UI-test
//  launch-arg resets across all workspaces, fans out `scenePhase` to every
//  workspace, and persists the workspace list. Replaces the old single
//  `TSNetManager` held directly by `ApertureApp`.
//
//  In Phase 1 there is exactly one workspace (the default), so behavior is
//  identical to the pre-refactor app. The concurrency plumbing for multiple
//  live workspaces lands in Phase 2; creating a second workspace lands in
//  Phase 3.
//

import Combine
import SwiftUI
import SwiftData
import TailscaleKit

@MainActor
final class WorkspaceManager: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var activeWorkspace: Workspace?

    private var activeId: UUID?
    /// Shared launch-only auth key used by automation. Never persisted.
    private let authKey: String?

    init() {
        // App-level one-time setup — MUST run before any TailscaleNode is
        // created so all nodes share one logtail and Go runtime stderr is
        // captured by its persistent filch from the beginning.
        do {
            try TailscaleLogging.setup(directory: WorkspaceStore.logsDir.path)
        } catch {
            fatalError("Could not initialize process logging: \(error)")
        }

        let args = ProcessInfo.processInfo.arguments

        // Load the workspace list (or seed a single default on first launch).
        let loaded = WorkspaceStore.load()
        var defs: [WorkspaceDefinition]
        if let loaded {
            defs = loaded.workspaces
            activeId = loaded.activeId
        } else {
            let d = WorkspaceDefinition.makeDefault()
            defs = [d]
            activeId = d.id
            WorkspaceStore.save(defs, activeId: activeId)
        }

        // Hermetic multi-workspace UI-test hook. Remove all prior workspace
        // data and seed one fresh definition before any tsnet node is created.
        if args.contains("-UITestResetWorkspaces") {
            for d in defs { WorkspaceStore.removeWorkspaceDir(d.id) }
            let d = WorkspaceDefinition.makeDefault()
            defs = [d]
            activeId = d.id
        }

        // UI-test hook: wipe every workspace's tsnet state dir so the next
        // launch starts from NeedsLogin (the connection gate) rather than
        // silently re-using a login a prior test left behind. Harmless in
        // normal use — the launch argument is never set outside UI tests.
        // Must run before the workspaces (and their nodes) are created.
        if args.contains("-UITestResetLogin") {
            for d in defs { try? FileManager.default.removeItem(at: WorkspaceStore.stateDir(d.id)) }
        }

        // UI-test hook: reset every workspace's home page to the default so
        // connected tests are hermetic (a prior test may have left a non-default
        // value). Mirrors the old `HomePage.standard.url = default` in
        // `ApertureApp.init`.
        if args.contains("-UITestResetHomePage") {
            defs = defs.map {
                var d = $0
                d.homePageURL = HomePage.defaultURL
                return d
            }
        }

        if activeId == nil { activeId = defs.first?.id }

        // The shared launch-arg auth key (tests). Applied to every workspace —
        // in tests all workspaces join the same tailnet with the same user,
        // differing only by hostname. Real (non-test) workspaces have a nil
        // key and authenticate via web auth. NOT persisted.
        let authKey = TSNetManager.launchAuthKey()
        self.authKey = authKey

        // Ephemeral is a launch-time input for test nodes (the APERTURE_EPHEMERAL
        // env / -Ephemeral arg), re-resolved every launch — matching the
        // pre-refactor behavior where `TSNetManager.init` read it fresh each
        // launch. When the launch flag is explicitly set, override the persisted
        // definition so test nodes register ephemeral (auto-cleanup) even if the
        // definition was first created by a connection-independent test launch
        // that didn't set the flag. When the flag is absent, leave the
        // definition's value alone (a real user's persistent workspace stays
        // non-ephemeral; a user-created ephemeral workspace stays ephemeral).
        if TSNetManager.launchEphemeral() {
            defs = defs.map {
                var d = $0
                d.ephemeral = true
                return d
            }
        }

        self.workspaces = defs.map { def in
            Workspace(definition: def, authKey: authKey) { [weak self] updated in
                self?.handleDefinitionChange(updated)
            }
        }
        self.activeWorkspace = workspaces.first(where: { $0.id == activeId }) ?? workspaces.first
        self.activeId = self.activeWorkspace?.id

        // Persist once up front so the test-reset home-page edits (above) and
        // any default seeding are written even if nothing else changes.
        persist()
    }

    // MARK: - Workspace actions

    /// Creates and immediately activates a fresh, independently persisted
    /// tsnet identity. Constructing `Workspace` starts its node; existing
    /// workspaces remain alive and are not torn down when selection changes.
    @discardableResult
    func addWorkspace() -> Workspace {
        let workspace = makeWorkspace(from: .makeDefault())
        workspaces.append(workspace)
        activeWorkspace = workspace
        activeId = workspace.id
        persist()
        return workspace
    }

    /// Changes only which workspace is rendered. Every workspace's tsnet node
    /// continues running in the background.
    func selectWorkspace(id: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == id }),
              workspace.id != activeId else { return }
        activeWorkspace = workspace
        activeId = workspace.id
        persist()
    }

    private func makeWorkspace(from definition: WorkspaceDefinition) -> Workspace {
        Workspace(definition: definition, authKey: authKey) { [weak self] updated in
            self?.handleDefinitionChange(updated)
        }
    }

    // MARK: - Lifecycle

    func willEnterBackground() {
        for w in workspaces { w.willEnterBackground() }
    }

    func willEnterForeground() {
        for w in workspaces { w.willEnterForeground() }
    }

    // MARK: - Persistence

    /// A workspace reports a definition change here; update the in-memory list
    /// and re-save the whole list to disk.
    private func handleDefinitionChange(_ updated: WorkspaceDefinition) {
        // The owning Workspace already mutated its own `definition` (it's the
        // source of truth); we just need to persist the full list.
        persist()
    }

    private func persist() {
        WorkspaceStore.save(workspaces.map { $0.definition }, activeId: activeId)
    }

    /// An in-memory bookmarks container used by the view tree when there is no
    /// active workspace (shouldn't happen — there's always at least one) so
    /// `.modelContainer` always has a valid container.
    nonisolated(unsafe) static let fallbackModelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: Bookmark.self,
                                      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            fatalError("Could not create fallback ModelContainer: \(error)")
        }
    }()
}
