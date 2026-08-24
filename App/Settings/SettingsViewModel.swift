// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  SettingsViewModel.swift
//  Aperture
//
//  Backs the Settings sheet for the ACTIVE workspace. Reads the workspace's
//  hostname/home page from its `WorkspaceDefinition` and writes edits back
//  through the workspace (which persists the definition). Exit-node state is
//  observed from the workspace's tsnet prefs. Logout is coordinated by
//  WorkspaceManager because it deletes the complete session.
//

import Foundation
import Combine
import Network
import TailscaleKit

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var exitNodeEnabled: Bool = false
    @Published var exitNodeDisplayName: String = "None"

    @Published var tailnetHostName: String = ""
    @Published var homePage: String = ""
    @Published private(set) var availableExitNodeCount: Int = 0

    /// Live exit-node diagnostic, shown in the Exit Node section banner.
    /// Updated by `runExitNodeDiagnostic()` (called on appear and after each
    /// toggle). Fetches `https://api.ipify.org` THROUGH the tsnet SOCKS proxy
    /// (via `URLSessionConfiguration.tailscaleSession`), so the IP reflects
    /// what tsnet's `UserDial` actually egresses — i.e. if an exit node is
    /// active and working, the exit node's IP; if the toggle is off, the node's
    /// direct egress (your ISP); if `auto:any` is set but no exit node is
    /// resolvable, the blackhole route makes the fetch FAIL (proving the
    /// blackhole is real and that the SOCKS path consults tsnet's route table).
    @Published var exitNodeDiagnostic: ExitNodeDiagnostic?

    /// The live split-tunnel rule set: which hosts go through the tsnet SOCKS
    /// proxy vs. load DIRECT. Surfaced in Settings because the device that
    /// showed the `-1000` "invalid URL" bug can't be attached to a Mac (broken
    /// USB port), so `log stream` isn't available — this is the on-device way
    /// to confirm the fix is active and see exactly what is being proxied.
    /// See `TailnetProxyPolicy`.
    var proxyPolicy: TailnetProxyPolicy? { workspace.model.proxyPolicy }

    /// Whether ALL traffic is currently routed through the tailnet proxy rather
    /// than just tailnet destinations. True when the Exit Node toggle is on
    /// (public traffic must be proxied to egress via the exit node) or the
    /// `-ProxyEverything` launch override is set.
    ///
    /// The Exit Node toggle doubles as the routing control: there is no reason
    /// to send non-tailnet traffic through the proxy unless an exit node is
    /// carrying it — without one it just fails. That also makes the toggle the
    /// on-device way to A/B the "invalid URL" bug, since launch arguments can't
    /// be set on a physical device.
    var proxyEverything: Bool {
        workspace.model.proxyPolicy?.proxiesEverything ?? TSNetManager.proxyEverythingOverride()
    }

    /// Classifies `host` the way `matchDomains` does — label-wise suffix for
    /// name rules, membership for CIDR rules — so the user can type a host in
    /// Settings and see whether it will be proxied or loaded DIRECT.
    /// Mirrors the semantics verified against a real SOCKS proxy; see the
    /// file comment in `TailnetProxyPolicy.swift`.
    func routeExplanation(for input: String) -> String? {
        let host = TailnetProxyPolicy.normalizeDomain(hostComponent(of: input))
        guard !host.isEmpty else { return nil }
        guard !proxyEverything else {
            return "⚠️ \(host) → PROXY (Exit Node on: all traffic goes through the tailnet)"
        }
        guard let policy = proxyPolicy else {
            return "\(host) → not connected yet (no proxy rules applied)"
        }
        if let rule = policy.matchingRule(for: host) {
            return "\(host) → PROXY via tailnet (matched rule: \(rule))"
        }
        if policy.shortNamesWithheldAsPublicTLD.contains(host) {
            return "\(host) → PROXY after expansion to its tailnet FQDN"
        }
        return "\(host) → DIRECT (not a tailnet host)"
    }

    /// Extracts a bare host from whatever the user typed (a full URL, a
    /// host:port, or just a hostname).
    private func hostComponent(of input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("://"), let h = URL(string: trimmed)?.host() { return h }
        if let h = URL(string: "http://\(trimmed)")?.host() { return h }
        return trimmed
    }

    private let workspace: Workspace
    private let deleteSession: () -> Void
    let vmManager: (any WorkspaceVMManaging)?
    var workspaceForSettings: Workspace { workspace }
    private var observers: Set<AnyCancellable> = []
    private var homePageNormalizationTask: Task<Void, Never>?

    init(workspace: Workspace,
         deleteSession: @escaping () -> Void,
         vmManager: (any WorkspaceVMManaging)? = nil) {
        self.workspace = workspace
        self.deleteSession = deleteSession
        self.vmManager = vmManager
        // Seed from the workspace's persisted definition + home page.
        self.tailnetHostName = workspace.definition.hostname
        self.homePage = workspace.homePage.url
        bindPrefs()
        observeWorkspace()
    }

    private func bindPrefs() {
        // Observe prefs to drive exit node UI.
        workspace.model.$prefs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prefs in
                guard let self else { return }
                let id = prefs?.ExitNodeID ?? ""
                self.exitNodeEnabled = !id.isEmpty
                self.exitNodeDisplayName = id.isEmpty ? "None" : id
            }
            .store(in: &observers)

        // `availableExitNodes` is computed from localStatus, but SettingsView
        // observes this view model rather than TSNetModel directly. Mirror the
        // count as published state so a status poll that discovers exit nodes
        // re-enables the toggle while Settings is already open.
        workspace.model.$localStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.availableExitNodeCount = status?.Peer?.values
                    .filter { $0.ExitNodeOption && $0.Online }.count ?? 0
            }
            .store(in: &observers)
    }

    /// Keep the hostname/home-page fields in sync if they change elsewhere
    /// (e.g. the workspace identity refresh, or a future workspace switch).
    private func observeWorkspace() {
        workspace.$definition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] def in
                guard let self else { return }
                if self.tailnetHostName != def.hostname {
                    self.tailnetHostName = def.hostname
                }
            }
            .store(in: &observers)

        workspace.homePage.$url
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self, self.homePage != url else { return }
                self.homePage = url
            }
            .store(in: &observers)
    }

    // MARK: - Exit node

    func applyExitNodeEnabled(_ enabled: Bool) {
        // Ignore a programmatic write of the value we already display, but
        // otherwise hold the user's selection optimistically until the LocalAPI
        // response (or later prefs notification) confirms it.
        guard exitNodeEnabled != enabled else { return }
        exitNodeEnabled = enabled
        if !enabled { exitNodeDisplayName = "None" }
        Task { [weak self] in
            guard let self else { return }
            do {
                let prefs = try await workspace.setExitNodeEnabled(enabled)
                let id = prefs.ExitNodeID
                exitNodeEnabled = !id.isEmpty
                exitNodeDisplayName = id.isEmpty ? "None" : id
            } catch {
                // Revert the optimistic toggle if the local preference write
                // failed, rather than leaving UI and routing inconsistent.
                exitNodeEnabled = !enabled
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            runExitNodeDiagnostic()
        }
    }

    /// Peers in the current netmap/status that advertise exit-node routes
    /// (`ExitNodeOption == true`). From the polled `localStatus` (local-API
    /// `/status`). Empty if status hasn't been polled yet OR no peers advertise
    /// exit routing. The Exit Node toggle only does something useful when this
    /// is non-empty; with `auto:any` and zero exit nodes, tsnet installs a
    /// blackhole for all non-tailnet traffic (see `unresolvedExitNodeID` in
    /// libtailscale).
    var availableExitNodes: [IpnState.PeerStatus] {
        guard let peers = workspace.model.localStatus?.Peer?.values else { return [] }
        return peers.filter { $0.ExitNodeOption && $0.Online }
    }

    /// Runs the exit-node diagnostic: fetches `https://api.ipify.org` through
    /// the tsnet SOCKS proxy and records the egress IP (or the error). Also
    /// records how many exit-node-capable peers are in the tailnet. The result
    /// drives the banner in the Exit Node section. Safe to call repeatedly.
    func runExitNodeDiagnostic() {
        Task { [weak self] in
            guard let self else { return }
            // Settings can open between periodic polls. Refresh first so the
            // availability banner and toggle use the same current peer set.
            await workspace.manager.refreshStatusNow()
            let available = availableExitNodes
            let prefID = workspace.model.prefs?.ExitNodeID ?? ""
            let d = ExitNodeDiagnostic(
                availableExitNodeCount: available.count,
                exitNodeID: prefID,
                fetchedIP: nil,
                fetchError: nil,
                fetching: true
            )
            exitNodeDiagnostic = d
            await fetchEgressIP(into: d)
        }
    }

    /// Fetches `https://api.ipify.org` through the tsnet SOCKS proxy and
    /// updates `exitNodeDiagnostic` with the egress IP or the error.
    private func fetchEgressIP(into d: ExitNodeDiagnostic) async {
        guard let node = workspace.manager.node else {
            await MainActor.run {
                self.exitNodeDiagnostic = d.with(ip: nil, error: "tsnet node not running", fetching: false)
            }
            return
        }
        let session: URLSession
        do {
            let (cfg, _) = try await URLSessionConfiguration.tailscaleSession(node)
            session = URLSession(configuration: cfg)
        } catch {
            await MainActor.run {
                self.exitNodeDiagnostic = d.with(ip: nil, error: "SOCKS proxy setup failed: \(error)", fetching: false)
            }
            return
        }
        guard let url = URL(string: "https://api.ipify.org") else {
            await MainActor.run {
                self.exitNodeDiagnostic = d.with(ip: nil, error: "bad URL", fetching: false)
            }
            return
        }
        let req = URLRequest(url: url, timeoutInterval: 12)
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await MainActor.run {
                if code == 200 && !ip.isEmpty {
                    self.exitNodeDiagnostic = d.with(ip: ip, error: nil, fetching: false)
                } else {
                    self.exitNodeDiagnostic = d.with(ip: nil, error: "HTTP \(code)", fetching: false)
                }
            }
        } catch {
            let ns = error as NSError
            await MainActor.run {
                self.exitNodeDiagnostic = d.with(ip: nil, error: "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]", fetching: false)
            }
        }
    }

    func setHomePage(_ url: String) {
        workspace.setHomePage(url)

        // Settings' TextField publishes each keystroke, and relying only on
        // focus/submit callbacks is inconsistent across SwiftUI Form on iOS
        // and macOS. Debounce the same URL-bar normalization so the completed
        // value is qualified automatically after the user pauses typing.
        homePageNormalizationTask?.cancel()
        guard !url.isEmpty else { return }
        homePageNormalizationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self,
                      self.homePage == url else { return }
                self.qualifyHomePage()
            } catch {
                // A subsequent keystroke cancels this task.
            }
        }
    }

    /// Commits the Home Page field using the same normalization as the
    /// browser's URL bar. In particular, `google.com` becomes
    /// `https://google.com`, while a bare tailnet name such as `ai` becomes
    /// `http://ai` and is subsequently qualified using the live tailnet data.
    /// This is intentionally called when editing ends/submission occurs,
    /// rather than on every keystroke, so typing is not disrupted by adding a
    /// scheme after the first character.
    func qualifyHomePage() {
        let trimmed = BrowserNavigator.trimmedURLInput(homePage)
        guard !trimmed.isEmpty else { return }
        homePageNormalizationTask?.cancel()
        let normalized = BrowserNavigator.normalizedURLString(from: trimmed)
        logger.log("Settings: normalized home page \(trimmed) -> \(normalized)")
        if homePage != normalized {
            homePage = normalized
        }
        // Persist directly as well as through the TextField's onChange. This
        // makes normalization reliable even when SwiftUI coalesces the
        // Published update while the Settings sheet is being dismissed.
        workspace.setHomePage(normalized)
    }

    func setTailnetHostName(_ hostName: String) {
        workspace.setHostName(hostName)
    }

    func logout() {
        deleteSession()
    }
}

/// Snapshot of the exit-node diagnostic shown in the Settings banner.
struct ExitNodeDiagnostic: Equatable {
    /// Number of peers advertising exit-node routes (ExitNodeOption). 0 means
    /// the tailnet has no exit nodes, so `auto:any` will blackhole internet.
    let availableExitNodeCount: Int
    /// The current `prefs.ExitNodeID` ("" = off, "auto:any" = auto, or a
    /// specific StableNodeID).
    let exitNodeID: String
    /// The egress IP seen by a fetch through the tsnet SOCKS proxy, or nil if
    /// the fetch failed (which is itself diagnostic — a blackhole makes it
    /// fail).
    let fetchedIP: String?
    let fetchError: String?
    let fetching: Bool

    func with(ip: String?, error: String?, fetching: Bool) -> ExitNodeDiagnostic {
        ExitNodeDiagnostic(
            availableExitNodeCount: availableExitNodeCount,
            exitNodeID: exitNodeID,
            fetchedIP: ip,
            fetchError: error,
            fetching: fetching
        )
    }
}
