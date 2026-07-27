//  SettingsViewModel.swift
//  Aperture
//
//  Backs the Settings sheet for the ACTIVE workspace. Reads the workspace's
//  hostname/home page from its `WorkspaceDefinition` and writes edits back
//  through the workspace (which persists the definition). Exit-node state is
//  observed from the workspace's tsnet prefs; logout deletes the workspace's
//  tsnet profile.
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

    private let workspace: Workspace
    private var observers: Set<AnyCancellable> = []

    init(workspace: Workspace) {
        self.workspace = workspace
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

    func setExitNodeEnabled(_ enabled: Bool) {
        workspace.setExitNodeEnabled(enabled)
        // Re-run the diagnostic shortly after the pref write so the banner
        // reflects the new routing state. (The pref apply + route install is
        // async on the tsnet side; 1s is enough for the localAPI editPrefs to
        // land and the netmap/routes to update.)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.runExitNodeDiagnostic()
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
        return peers.filter { $0.ExitNodeOption }
    }

    /// Runs the exit-node diagnostic: fetches `https://api.ipify.org` through
    /// the tsnet SOCKS proxy and records the egress IP (or the error). Also
    /// records how many exit-node-capable peers are in the tailnet. The result
    /// drives the banner in the Exit Node section. Safe to call repeatedly.
    func runExitNodeDiagnostic() {
        let available = availableExitNodes
        // Build the diagnostic skeleton (availability is known now; IP fetch
        // is async).
        let prefID = workspace.model.prefs?.ExitNodeID ?? ""
        let d = ExitNodeDiagnostic(
            availableExitNodeCount: available.count,
            exitNodeID: prefID,
            fetchedIP: nil,
            fetchError: nil,
            fetching: true
        )
        exitNodeDiagnostic = d
        Task { [weak self] in
            await self?.fetchEgressIP(into: d)
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
    }

    func setTailnetHostName(_ hostName: String) {
        workspace.setHostName(hostName)
    }

    func logout() {
        workspace.logout()
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
