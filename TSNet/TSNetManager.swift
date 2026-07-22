//  Created by Jonathan Nobels on 2025-12-09.
//

import Foundation
import TailscaleKit
import Network
import WebKit
@preconcurrency import Combine

enum TSNetError: Error {
    case noNode
}

typealias MessageSender = @Sendable (String) async  -> Void

private enum DefaultsKeys {
    static let tailnetHostName = "TailnetHostName"
}

/// How an auth key may be supplied to the node for non-interactive (headless)
/// login — used by UI tests and any automated run that can't show the web
/// auth sheet. Checked once at launch, in priority order:
///
///   1. `APERTURE_AUTHKEY` environment variable (preferred for secrets —
///      doesn't appear in the process argument list).
///   2. `-AuthKey <key>` launch argument (convenient for `simctl launch`).
///
/// When set, the node authenticates with this key on `up()` instead of going
/// to `NeedsLogin` and showing the "Login" button. A matching
/// `APERTURE_EPHEMERAL`/`-Ephemeral` flag marks the node ephemeral so test
/// nodes clean themselves up when closed.

@MainActor
final class TSNetManager {
    @MainActor var node: TailscaleNode?

    let config: Configuration

    // The model will be the consumer for our the busWatcher
    let consumer: TSNetConsumer
    let model: TSNetModel

    var localAPIClient: LocalAPIClient?
    var processor: MessageProcessor?

    /// True while a start is in-flight or the node is up. Guards against the
    /// launch double-start: `init()` kicks off a start, and the
    /// `scenePhase == .active` notification (fired right after init on a fresh
    /// launch) calls `willEnterForeground()`, which would start again —
    /// producing the double `Brought Tailscale up` / double proxy reset seen
    /// in the logs. MainActor so the check-and-set is atomic.
    @MainActor private var startInFlight = false

    @MainActor
    init() {
        // UI-test hook: clear the persisted tsnet state (node credentials) so
        // the next launch starts from NeedsLogin (the connection gate) rather
        // than silently re-using a login a prior test left in the container.
        // Harmless in normal use — the launch argument is never set outside
        // UI tests. Must run before the node is created from this path.
        if ProcessInfo.processInfo.arguments.contains("-UITestResetLogin") {
            Self.resetStateDir()
        }

        let temp = Self.getDocumentDirectoryPath().path()

        // Load persisted hostname, or generate a fresh
        // `aperture-<6-digit>` default and persist it so the node name is
        // stable across launches (rather than regenerating every cold start).
        let savedHostName = UserDefaults.standard.string(forKey: DefaultsKeys.tailnetHostName)
        let hostName = savedHostName ?? Self.generateDefaultHostName()
        if savedHostName == nil {
            UserDefaults.standard.set(hostName, forKey: DefaultsKeys.tailnetHostName)
        }

        let authKey = Self.launchAuthKey()
        let ephemeral = Self.launchEphemeral()
        if let authKey {
            logger.log("Launching with auth key (ephemeral=\(ephemeral))")
        }

        self.config = Configuration(hostName:  hostName,
                                    path: temp,
                                    authKey: authKey,
                                    controlURL: kDefaultControlURL,
                                    ephemeral: ephemeral)

        let model = TSNetModel()
        let consumer = TSNetConsumer(logger: logger, model: model)
        self.model = model
        self.consumer = consumer

        startTailscaleIfNeeded()
    }

    /// Starts the node iff no start is already in flight. The single entry
    /// point for both the initial launch and foreground reconnects, so the
    /// guard lives in one place.
    @MainActor
    func startTailscaleIfNeeded() {
        guard !startInFlight else {
            logger.log("startTailscale: already in flight, skipping")
            return
        }
        startInFlight = true
        Task(priority: .userInitiated) {
            await startTailscale()
        }
    }

    func getModel() -> TSNetModel {
        return model
    }

    nonisolated static func getDocumentDirectoryPath() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory().appending("aperture"))
        return url
    }

    /// A fresh default tailnet hostname: `aperture-` + a random 6-digit number
    /// (100000–999999, always exactly six digits with no leading zeros).
    nonisolated static func generateDefaultHostName() -> String {
        let number = Int.random(in: 100_000..<1_000_000)
        return "aperture-\(number)"
    }

    /// Removes the on-disk tsnet state directory (node credentials, prefs) so
    /// the next node start is a fresh, not-logged-in node. Used by the
    /// `-UITestResetLogin` UI-test hook to keep connection-independent tests
    /// hermetic against logins left behind by prior connected tests.
    nonisolated static func resetStateDir() {
        let url = Self.getDocumentDirectoryPath()
        try? FileManager.default.removeItem(at: url)
    }

    /// The auth key supplied at launch, if any. See `DefaultsKeys`-adjacent
    /// doc comment for the resolution order. `nonisolated` so it's safe to
    /// call from any isolation context.
    nonisolated static func launchAuthKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let key = env["APERTURE_AUTHKEY"], !key.isEmpty {
            return key
        }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-AuthKey"), i + 1 < args.count {
            let key = args[i + 1]
            if !key.isEmpty { return key }
        }
        return nil
    }

    /// Whether the node should register as ephemeral. Honors either the
    /// `APERTURE_EPHEMERAL` env var ("1") or the `-Ephemeral` launch arg.
    nonisolated static func launchEphemeral() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let v = env["APERTURE_EPHEMERAL"], v == "1" { return true }
        return ProcessInfo.processInfo.arguments.contains("-Ephemeral")
    }

    nonisolated private func startTailscale() async {
        do {
            // This sets up a localAPI client attached to the local node.
            let node = try await MainActor.run { try setupNode() }

            // Create a localAPIClient instance for our local node
            let localAPIClient = await LocalAPIClient(localNode: node, logger: logger)
            await MainActor.run { setLocalAPIClient(localAPIClient) }

            try await tailscaleUp(localAPI: localAPIClient, consumer: consumer)
        } catch {
            await MainActor.run { startInFlight = false }
            fatalError("Error setting up Tailscale: \(error)")
        }
    }

    func tailscaleUp(localAPI: LocalAPIClient, consumer: TSNetConsumer) async throws {
        let processor = try await startEventBus(localAPI: localAPI, consumer: consumer)
        await MainActor.run { setProcessor(processor) }
        try await node?.up()
        if let loopback = try await self.node?.loopback() {
            await MainActor.run {
                model.proxyConfiguration = proxyConfig(loopback)
            }
        }
    }

    var busErrorWatcher: AnyCancellable?
    func startEventBus(localAPI: LocalAPIClient, consumer: TSNetConsumer) async throws  -> MessageProcessor {
        // This sets up a bus watcher to listen for changes in the netmap.  These will be sent to the given consumer, in
        // this case, a TSNetModel which will keep track of the changes and publish them.
        let busEventMask: Ipn.NotifyWatchOpt = [.initialState]
        let processor = try await localAPI.watchIPNBus(mask: busEventMask,
                                                       consumer: consumer)

        // Any error on the bus consumer indicates that it needs to be restarted.
        let busObserver = await consumer.$error
            .sink { [weak self] error in
                guard error != nil else { return }
                logger.log("Restarting bus watcher")
                Task { [weak self] in
                    guard let self else { return }
                    await MainActor.run { consumer.error = nil }
                    let processor = try await startEventBus(localAPI: localAPI, consumer: consumer)
                    await MainActor.run { self.setProcessor(processor) }
                }
            }

        await MainActor.run { busErrorWatcher = busObserver }
        return processor
    }

    func setLocalAPIClient(_ client: TailscaleKit.LocalAPIClient) {
        self.localAPIClient = client
    }

    func setProcessor(_ processor: MessageProcessor) {
        self.processor?.cancel()
        self.processor = processor
    }

    func setupNode() throws -> TailscaleNode {
        guard self.node == nil else { return self.node! }
        self.node = try TailscaleNode(config: config, logger: logger)
        return self.node!
    }

    func proxyConfig(_ loopbackConfig: TailscaleNode.LoopbackConfig) -> ProxyConfiguration? {
        if let ip = loopbackConfig.ip,
           let port = loopbackConfig.port {
            let proxy = NWEndpoint.hostPort(host: NWEndpoint.Host(ip),
                                            port: NWEndpoint.Port("\(port)")!)

            let proxyConfig = ProxyConfiguration(socksv5Proxy: proxy)
            proxyConfig.applyCredential(username: "tsnet",
                                        password: loopbackConfig.proxyCredential)
            return proxyConfig
        }

        return nil
    }

    func willEnterBackground() {
        logger.log("Background: Disconnecting...")
        startInFlight = false
        busErrorWatcher?.cancel()
        model.proxyConfiguration = nil
        let nodeTmp = self.node
        self.node = nil
        Task {
            // node.down() isn't enough here because of iOS lifecycle management.
            // We're about to have our threads paused and our network taken away
            // because Apple doesn't let us have nice things.  We need to close
            // the device completely.
            try await nodeTmp?.close()
        }
    }

    func willEnterForeground() {
        logger.log("Foreground: Reconnecting...")
        startTailscaleIfNeeded()
    }

    func setExitNodeEnabled(_ enabled: Bool) {
        let id = enabled ? "auto:any" : ""
        let mask = Ipn.MaskedPrefs().exitNodeID(id)
        let client = localAPIClient
        Task {
            try await client?.editPrefs(mask: mask)
            logger.log("Set exit node Id to \(id)")
        }
    }

    func setHostName(_ newHostName: String) {
        let trimmed = newHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: DefaultsKeys.tailnetHostName)

        let mask = Ipn.MaskedPrefs().hostname(trimmed)
        let client = localAPIClient
        Task {
            try await client?.editPrefs(mask: mask)
            logger.log("Set hostname to \(newHostName)")
        }
    }
}

