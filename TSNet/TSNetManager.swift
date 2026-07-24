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

    /// Background poll of the localAPI `/status` endpoint (every few seconds
    /// while connected) so the UI can classify each tab's connection as
    /// direct vs derped vs internet (see `ConnectionTypeResolver`). Stopped
    /// when the node goes down.
    @MainActor private var statusPollTask: Task<Void, Never>?

    /// True while a start is in-flight or the node is up. Guards against the
    /// launch double-start: `init()` kicks off a start, and the
    /// `scenePhase == .active` notification (fired right after init on a fresh
    /// launch) calls `willEnterForeground()`, which would start again —
    /// producing the double `Brought Tailscale up` / double proxy reset seen
    /// in the logs. MainActor so the check-and-set is atomic.
    @MainActor private var startInFlight = false

    /// Creates a per-workspace tsnet controller. `config.path` is the
    /// workspace's state dir (Application Support — persistent, unlike the
    /// old `NSTemporaryDirectory` location; see `WorkspaceStore.stateDir`);
    /// `config.hostName`/`controlURL`/`ephemeral`/`authKey` come from the
    /// workspace's `WorkspaceDefinition` (plus the shared launch-arg auth key
    /// for the default/test workspace).
    ///
    /// App-level one-time setup (CrashCapture, `-UITestResetLogin` state-dir
    /// wipe) is handled by `WorkspaceManager`, NOT here — this class is now
    /// instantiated once per workspace and must not repeat global setup.
    @MainActor
    init(config: Configuration) {
        if let authKey = config.authKey {
            logger.log("Launching with auth key (ephemeral=\(config.ephemeral))")
        }
        self.config = config

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

    /// A fresh default tailnet hostname: `aperture-` + a random 6-digit number
    /// (100000–999999, always exactly six digits with no leading zeros).
    nonisolated static func generateDefaultHostName() -> String {
        let number = Int.random(in: 100_000..<1_000_000)
        return "aperture-\(number)"
    }

    /// The auth key supplied at launch, if any. See the doc comment above the
    /// class for the resolution order. `nonisolated` so it's safe to call from
    /// any isolation context.
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

    /// The deliberate-crash mode requested via launch args, or nil if no crash
    /// is requested. `-CrashTest` alone → mode 0 (immediate panic, the exact
    /// overnight-crash mechanism); `-CrashTest -CrashTestMode <n>` → mode n.
    /// TEST/DEBUG ONLY — see `TailscaleNode.crashTest` and the crash-capture UI
    /// test. Never set outside automated tests.
    nonisolated static func crashTestMode() -> Int? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-CrashTest") else { return nil }
        if let i = args.firstIndex(of: "-CrashTestMode"), i + 1 < args.count,
           let m = Int(args[i + 1]) {
            return m
        }
        return 0
    }

    nonisolated private func startTailscale() async {
        do {
            // This sets up a localAPI client attached to the local node.
            let node = try await MainActor.run { try setupNode() }

            // Test/debug hook: deliberately crash the Go runtime to verify that
            // panic output is captured to stderr.log (see TSNet/CrashCapture.swift
            // and UITests.testGoPanicIsCapturedToStderrLog). Gated by a launch
            // arg so it can never fire in normal/TestFlight use. Done right after
            // node creation (before `up()`) so it's connection-independent and
            // deterministic. Mode 0 panics synchronously and does not return.
            if let mode = Self.crashTestMode() {
                logger.log("CrashTest: triggering deliberate Go runtime panic (mode \(mode))")
                // TailscaleNode is an actor, so cross the boundary with `await`
                // (mode 0 panics inside the call and aborts before this resumes).
                await node.crashTest(mode: mode)
            }

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
        startStatusPolling()
    }

    /// Polls `backendStatus()` every few seconds and publishes it on the model,
    /// so per-tab connection-type indicators stay current. Stops on
    /// `willEnterBackground` / when the client is gone.
    @MainActor
    func startStatusPolling() {
        guard statusPollTask == nil else { return }
        statusPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let client = await MainActor.run(body: { self.localAPIClient }) {
                    if let status = try? await client.backendStatus() {
                        await MainActor.run { self.model.localStatus = status }
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
            }
        }
    }

    @MainActor
    func stopStatusPolling() {
        statusPollTask?.cancel()
        statusPollTask = nil
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
        stopStatusPolling()
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
        let mask = Ipn.MaskedPrefs().hostname(trimmed)
        let client = localAPIClient
        Task {
            try await client?.editPrefs(mask: mask)
            logger.log("Set hostname to \(newHostName)")
        }
    }
}

