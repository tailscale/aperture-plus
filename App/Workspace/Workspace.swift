//  Workspace.swift
//  Aperture
//
//  A workspace = one Tailscale (tsnet) identity + everything that belongs to
//  it: its own node, model, tab manager, home page, bookmarks store, and web
//  data store. All workspaces are live concurrently (each runs its own
//  `TailscaleNode`; the node docs allow several per app, each gets its own
//  tailnet IP). Switching the "active" workspace (Phase 3) just changes which
//  one's tabs/home page the browser pane shows — nothing is torn down.
//
//  This bundles what used to be process-wide singletons (one `TSNetManager`,
//  one shared `WKWebsiteDataStore`, one global `HomePage`, one global SwiftData
//  container) into a per-identity object owned by `WorkspaceManager`.
//

import Combine
import SwiftUI
import SwiftData
import WebKit
import TailscaleKit

@MainActor
final class Workspace: ObservableObject, Identifiable {
    let id: UUID

    /// The persisted definition. `@Published` so Settings (hostname/home page)
    /// and the workspace identifier react to edits. Mutations are written back
    /// to disk via `onChange` (set by `WorkspaceManager`).
    @Published private(set) var definition: WorkspaceDefinition

    /// Last-known Tailscale identity, persisted in the definition so the
    /// identifier renders immediately on the next launch (before the node
    /// reconnects), then live-updated from the netmap/prefs while connected.
    @Published private(set) var identity: WorkspaceIdentity

    let manager: TSNetManager
    var model: TSNetModel { manager.model }

    let homePage: HomePage
    /// Per-workspace web data store (isolated cookies/cache/service workers +
    /// the SOCKS5 proxy is applied here, in place, on reconnect).
    let dataStore: WKWebsiteDataStore
    /// Per-workspace SwiftData container for bookmarks.
    let modelContainer: ModelContainer

    /// Browser/session state is lazy so its first WKWebView is still created
    /// from `WorkspaceRoot.init`, after a window exists. Unlike a view-local
    /// StateObject, workspace ownership keeps tabs alive while another account
    /// is selected.
    lazy var tabManager = TabManager(workspaceID: id,
                                     model: model,
                                     homePage: homePage,
                                     dataStore: dataStore)
    lazy var statusViewModel = StatusViewModel(manager: manager)

    /// Called whenever the definition changes, so `WorkspaceManager` can
    /// persist the workspace list. Set after init to avoid a retain cycle.
    var onChange: ((WorkspaceDefinition) -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var profileRefreshInFlight = false

    /// - Parameters:
    ///   - definition: The persisted definition (hostname, home page, etc.).
    ///   - authKey: The shared launch-arg auth key (tests), or nil for a
    ///     workspace that authenticates via web auth. NOT stored in the
    ///     definition — it lives only in the live `Configuration`.
    ///   - onChange: Persist-on-change callback (set by `WorkspaceManager`).
    init(definition: WorkspaceDefinition, authKey: String?,
         onChange: ((WorkspaceDefinition) -> Void)? = nil) {
        self.id = definition.id
        self.definition = definition
        self.identity = definition.lastKnownIdentity
            ?? WorkspaceIdentity(hostname: definition.hostname)
        self.onChange = onChange

        let config = Configuration(hostName: definition.hostname,
                                    path: WorkspaceStore.stateDir(definition.id).path,
                                    authKey: authKey,
                                    controlURL: definition.controlURL,
                                    ephemeral: definition.ephemeral)
        self.manager = TSNetManager(config: config)

        self.homePage = HomePage(url: definition.homePageURL)
        self.dataStore = WKWebsiteDataStore(forIdentifier: definition.dataStoreUUID)

        // Per-workspace bookmarks store. Falls back to an in-memory container
        // only if the on-disk file can't be opened (shouldn't happen in
        // practice — the workspace dir is created in `WorkspaceStore`).
        let url = WorkspaceStore.bookmarksURL(definition.id)
        if let container = try? ModelContainer(
            for: Bookmark.self,
            configurations: ModelConfiguration(url: url)) {
            self.modelContainer = container
        } else {
            logger.log("Workspace: failed to open bookmarks store at \(url.path); using in-memory")
            self.modelContainer = Self.fallbackContainer
        }

        // Persist home-page edits back into the definition.
        homePage.$url
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self, self.definition.homePageURL != url else { return }
                self.definition.homePageURL = url
                self.onChange?(self.definition)
            }
            .store(in: &cancellables)

        // Live-update the identity from the netmap + prefs (tailnet name, user
        // profile, hostname) and persist it so it's available immediately on
        // the next launch. Handles hostname changes made in the admin console
        // or via Settings while connected.
        manager.model.$netmap
            .combineLatest(manager.model.$prefs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshIdentity() }
            .store(in: &cancellables)

        // Tagged/auth-key nodes can have incomplete user data in the decoded
        // netmap. The local profile endpoint carries the authoritative login
        // username, so fold it into the persisted identifier after status is
        // available.
        manager.model.$localStatus
            .compactMap { $0 }
            .prefix(while: { [weak self] _ in self?.identity.loginName?.isEmpty != false })
            .sink { [weak self] _ in self?.refreshLoginProfile() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle (forwarded to the per-workspace tsnet controller)

    func willEnterBackground() { manager.willEnterBackground() }
    func willEnterForeground() { manager.willEnterForeground() }

    // MARK: - Settings actions

    func setHostName(_ newHostName: String) {
        let trimmed = newHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        definition.hostname = trimmed
        onChange?(definition)
        manager.setHostName(trimmed)
    }

    func setHomePage(_ url: String) {
        homePage.url = url   // observer persists into the definition
    }

    func setExitNodeEnabled(_ enabled: Bool) {
        manager.setExitNodeEnabled(enabled)
    }

    func logout() {
        Task { [manager] in
            do {
                guard let profile = try await manager.localAPIClient?.currentProfile() else {
                    logger.log("Logout: no current profile; nothing to delete")
                    return
                }
                try await manager.localAPIClient?.deleteProfile(profileID: profile.id)
                logger.log("Logout: deleted profile \(profile.id)")
            } catch {
                // Previously this swallowed every error with `try?`, so a failed
                // logout (network blip, node not running) left the UI silently
                // stuck on the browser with no LoginBanner — the user could tap
                // Logout repeatedly with no effect and no clue why. At least log
                // it now; surfacing the error to the user is a follow-up.
                logger.log("Logout failed: \(error)")
            }
        }
    }

    // MARK: - Identity

    /// Human-readable workspace identifier: `login · tailnet · hostname` once
    /// known, degrading to the display name (then hostname) before connect.
    var identifier: String {
        var parts: [String] = []
        if let ln = identity.loginName, !ln.isEmpty { parts.append(ln) }
        if let tn = identity.tailnetName, !tn.isEmpty { parts.append(tn) }
        if let h = identity.hostname, !h.isEmpty { parts.append(h) }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return definition.displayName.isEmpty ? definition.hostname : definition.displayName
    }

    private func refreshLoginProfile() {
        guard !profileRefreshInFlight else { return }
        profileRefreshInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.profileRefreshInFlight = false }
            guard let profile = try? await manager.localAPIClient?.currentProfile() else { return }
            var updated = identity
            let login = profile.UserProfile.LoginName
            let display = profile.UserProfile.DisplayName
            if !login.isEmpty { updated.loginName = login }
            if !display.isEmpty { updated.displayName = display }
            if let domain = profile.NetworkProfile?.DomainName, !domain.isEmpty {
                updated.tailnetName = domain
            }
            persistIdentity(updated)
        }
    }

    private func refreshIdentity() {
        let nm = model.netmap
        let prefs = model.prefs
        let tailnetName = nm?.Domain ?? identity.tailnetName
        let profile = nm?.currentUserProfile()
        let loginName = profile?.LoginName ?? identity.loginName
        let displayName = profile?.DisplayName ?? identity.displayName
        // Prefer the configured hostname from prefs (it's what setHostName
        // edits), then the netmap self node, then the definition's hostname.
        let hostname = (prefs?.Hostname.isEmpty == false ? prefs?.Hostname : nil)
            ?? nm?.SelfNode.Name
            ?? definition.hostname
        let newID = WorkspaceIdentity(loginName: loginName,
                                       displayName: displayName,
                                       tailnetName: tailnetName,
                                       hostname: hostname)
        persistIdentity(newID)
    }

    private func persistIdentity(_ newIdentity: WorkspaceIdentity) {
        guard newIdentity != identity else { return }
        identity = newIdentity
        definition.lastKnownIdentity = newIdentity
        onChange?(definition)
    }

    // MARK: - Fallbacks

    /// A last-resort in-memory bookmarks container, used only if a workspace's
    /// on-disk store can't be opened. In-memory containers essentially never
    /// fail to create.
    private nonisolated(unsafe) static let fallbackContainer: ModelContainer = {
        do {
            return try ModelContainer(for: Bookmark.self,
                                      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            fatalError("Could not create fallback ModelContainer: \(error)")
        }
    }()
}
