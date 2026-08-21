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
    /// workspaceID -> windowID for currently open workspace windows. At most
    /// one window per workspace is allowed (a second window in the same
    /// workspace would share one `TabManager` and fight it, so Cmd+N refuses
    /// to open one). In-memory only.
    @Published private(set) var openWorkspaceWindows: [UUID: UUID] = [:]
    /// The most recently focused (key) workspace window's workspace. Retained
    /// when its window closes so Cmd+N can reopen it after ALL windows are
    /// gone (the last workspace to have focus is the one to reopen). Mirrored
    /// into the persisted `activeWorkspace` on each focus. In-memory only; on
    /// relaunch it falls back to the persisted active workspace.
    private(set) var lastFocusedWorkspaceID: UUID?
    /// Native macOS installs a supervisor here. It is nil on iOS and keeps
    /// workspace deletion independent of any VM console window.
    weak var vmManager: (any WorkspaceVMManaging)?
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

        // The home-page value and the restored tab session are intentionally
        // separate in normal use: changing the home page must not rewrite open
        // tabs. Connected UI tests, however, need their first tab to start at
        // the known home page even when an earlier test persisted a bad URL.
        // Keep this a distinct test-only hook so tab-persistence coverage can
        // continue to relaunch with `-UITestResetHomePage` without losing tabs.
        if args.contains("-UITestResetTabs") {
            for d in defs { WorkspaceStore.removeTabs(d.id) }
        }

        // UI-test-only override for flows that exercise authentication rather
        // than a particular tailnet web service. Keeping those tests on a
        // direct HTTPS page prevents an unrelated private-service outage from
        // masquerading as a login failure.
        if let index = args.firstIndex(of: "-UITestHomePage"), index + 1 < args.count {
            let testURL = args[index + 1]
            defs = defs.map {
                var d = $0
                d.homePageURL = testURL
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

    func workspace(id: UUID) -> Workspace? {
        workspaces.first(where: { $0.id == id })
    }

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

    /// A workspace window appeared. Records it as open and, if no window has
    /// been focused yet, treats it as the current workspace. Idempotent: a
    /// no-op when the window is already recorded as open, so re-registration
    /// (e.g. from a SwiftUI view re-render) does not publish.
    func windowDidOpen(windowID: UUID, workspaceID: UUID) {
        if openWorkspaceWindows[workspaceID] == windowID, lastFocusedWorkspaceID != nil {
            return
        }
        openWorkspaceWindows[workspaceID] = windowID
        if lastFocusedWorkspaceID == nil { lastFocusedWorkspaceID = workspaceID }
        selectWorkspace(id: workspaceID)
    }

    /// A workspace window became key. Updates the most-recently-focused
    /// workspace (the Cmd+N target) and mirrors it into the persisted active
    /// workspace. Driven by NSWindow.didBecomeKeyNotification for reliability
    /// (per-scene scenePhase does not reliably fire on macOS when another
    /// window closes and this one becomes key). Idempotent.
    func windowBecameKey(windowID: UUID, workspaceID: UUID) {
        guard lastFocusedWorkspaceID != workspaceID else { return }
        lastFocusedWorkspaceID = workspaceID
        selectWorkspace(id: workspaceID)
    }

    /// A workspace window closed. Removes it from the open set only when the
    /// closing window is the one currently recorded as open for this workspace.
    /// Keying the removal on `windowID` (not just `workspaceID`) is what makes
    /// the close→reopen sequence correct: the dismissed window's `onDisappear`
    /// fires asynchronously (SwiftUI tears the window down whenever it gets
    /// around to it), and a Cmd+N issued right after Cmd+W opens the
    /// replacement window *before* the old view's `onDisappear` runs. If that
    /// late cleanup were keyed only by `workspaceID` it would wipe the new
    /// window's entry, `hasOpenWindow` would report false, and the next Cmd+N
    /// would open a second window on the same workspace. Matching the windowID
    /// makes the stale cleanup a no-op. `lastFocusedWorkspaceID` is
    /// intentionally retained so Cmd+N can reopen the last-focused workspace
    /// after all windows are closed.
    func windowDidClose(windowID: UUID, workspaceID: UUID) {
        guard openWorkspaceWindows[workspaceID] == windowID else { return }
        openWorkspaceWindows.removeValue(forKey: workspaceID)
    }

    /// True if this workspace currently has an open window.
    func hasOpenWindow(_ workspaceID: UUID) -> Bool {
        openWorkspaceWindows[workspaceID] != nil
    }

    /// The workspace Cmd+N / "new window" should target: the most recently
    /// focused one that still exists, falling back to the persisted active
    /// workspace. Returns nil only if there are no workspaces at all.
    var currentWorkspaceID: UUID? {
        let candidate = lastFocusedWorkspaceID ?? activeId ?? activeWorkspace?.id
        if let candidate, workspaces.contains(where: { $0.id == candidate }) {
            return candidate
        }
        return activeWorkspace?.id ?? workspaces.first?.id
    }

    /// Removes a session rather than leaving a logged-out shell behind. If it
    /// was the final session, create and activate a fresh blank one first so
    /// the app always has a valid workspace and immediately returns to the
    /// connection gate.
    func deleteWorkspace(id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let removed = workspaces[index]

        var replacement: Workspace?
        if workspaces.count == 1 {
            replacement = makeWorkspace(from: .makeDefault())
        } else if activeId == id {
            replacement = workspaces[index == workspaces.count - 1 ? index - 1 : index + 1]
        }

        workspaces.remove(at: index)
        if let replacement {
            if workspaces.isEmpty { workspaces.append(replacement) }
            activeWorkspace = replacement
            activeId = replacement.id
            // If the deleted workspace was the most-recently-focused one, hand
            // that role to the replacement so Cmd+N still has a valid target.
            if lastFocusedWorkspaceID == id { lastFocusedWorkspaceID = replacement.id }
        }
        openWorkspaceWindows.removeValue(forKey: id)
        persist()

        // Publish the replacement/removal immediately, then tear down and
        // erase the old session away from the button action. The Workspace is
        // retained by this task until its node and stores are no longer in use.
        Task {
            await vmManager?.deleteVMAndWait(for: removed)
            await removed.deleteSessionData()
        }
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
    static let fallbackModelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: Bookmark.self,
                                      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            fatalError("Could not create fallback ModelContainer: \(error)")
        }
    }()
}
