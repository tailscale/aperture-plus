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

    // The consumer is replaced on each lifecycle generation so callbacks
    // already queued by a cancelled observer cannot mutate current state.
    private(set) var consumer: TSNetConsumer
    let model: TSNetModel

    var localAPIClient: LocalAPIClient?
    var processor: MessageProcessor?

    /// Background poll of the localAPI `/status` endpoint (every few seconds
    /// while connected) so the UI can classify each tab's connection as
    /// direct vs derped vs internet (see `ConnectionTypeResolver`). Stopped
    /// when the node goes down.
    @MainActor private var statusPollTask: Task<Void, Never>?

    /// True while a start is in-flight or the node is up. Guards against the
    /// launch double-start: `init()` kicks off a start, and the initial
    /// `scenePhase == .active` notification calls `willEnterForeground()` too.
    /// MainActor so the check-and-set is atomic.
    @MainActor private var startInFlight = false

    /// Logging SOCKS5 relay in front of tsnet's proxy, so every connection
    /// attempt + outcome is visible in Settings → Logs on a device that can't
    /// be attached to a Mac. See `SocksLogProxy`.
    @MainActor private var socksLogProxy: SocksLogProxy?
    @MainActor private var socksLogProxyPort: UInt16?
    @MainActor private var didRunTCPChaosTest = false

    /// Creates a per-workspace tsnet controller. `config.path` is the
    /// workspace's state dir (Application Support — persistent, unlike the
    /// old `NSTemporaryDirectory` location; see `WorkspaceStore.stateDir`);
    /// `config.hostName`/`controlURL`/`ephemeral`/`authKey` come from the
    /// workspace's `WorkspaceDefinition` (plus the shared launch-arg auth key
    /// for the default/test workspace).
    ///
    /// App-level one-time setup (process logging, `-UITestResetLogin` state-dir
    /// wipe) is handled by `WorkspaceManager`, NOT here — this class is now
    /// instantiated once per workspace and must not repeat global setup.
    @MainActor
    init(config: Configuration) {
        if config.authKey != nil {
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

#if os(macOS)
    /// Creates a disposable VM packet bridge inside this workspace's existing
    /// TailscaleNode. No second node, identity, or Go archive is created.
    func startVMNetworkBridge(socketURL: URL) async throws -> TailscaleKit.VMNetworkBridge {
        guard let node else { throw TSNetError.noNode }
        return try await node.startVMNetworkBridge(
            socketURL: socketURL,
            magicDNSSuffix: model.tailnetName ?? ""
        )
    }
#endif

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
    /// is requested. `-CrashTest` alone → mode 0; `-CrashTestMode 1` panics in
    /// a background goroutine. TEST/DEBUG ONLY.
    nonisolated static func tcpChaosTestRequested() -> Bool {
        ProcessInfo.processInfo.arguments.contains("-UITestDefunctLoopback")
            || ProcessInfo.processInfo.arguments.contains("-UITestShutdownTCPConnections")
    }

    nonisolated static func flushLogsRequested() -> Bool {
        ProcessInfo.processInfo.arguments.contains("-UITestFlushLogs")
    }

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

            // Test/debug hook: deliberately crash the Go runtime to verify the
            // process-wide filch/logtail recovery path. Gated by a launch arg so
            // it can never fire in normal/TestFlight use. Done right after
            // node creation (before `up()`) so it's connection-independent and
            // deterministic. Mode 0 panics synchronously and does not return.
            if let mode = Self.crashTestMode() {
                logger.log("CrashTest: triggering deliberate Go runtime panic (mode \(mode))")
                // TailscaleNode is an actor, so cross the boundary with `await`
                // (mode 0 panics inside the call and aborts before this resumes).
                await node.crashTest(mode: mode)
            }

            // Create a localAPIClient instance for our local node
            let localAPIClient = LocalAPIClient(localNode: node, logger: logger)
            await MainActor.run { setLocalAPIClient(localAPIClient) }

            try await tailscaleUp(localAPI: localAPIClient, consumer: consumer)

            // Test-only synchronization point: after startup leftovers have
            // drained, force one subsequent acknowledged HTTP upload.
            if Self.flushLogsRequested() {
                do {
                    try await TailscaleLogging.flush()
                    logger.log("UITest log flush succeeded")
                } catch {
                    logger.log("UITest log flush failed: \(error)")
                }
            }
        } catch {
            await MainActor.run { startInFlight = false }
            fatalError("Error setting up Tailscale: \(error)")
        }
    }

    func tailscaleUp(localAPI: LocalAPIClient, consumer: TSNetConsumer) async throws {
        setProcessor(try await startEventBus(localAPI: localAPI, consumer: consumer))

        // Deliberately do NOT call `node?.up()`. `up()` calls Go's
        // `Up(context.Background())` (non-cancellable), which blocks until the
        // node reaches `Running`. For a no-auth-key node sitting at
        // `NeedsLogin` (every real user before they log in), that blocks the
        // `TailscaleNode` actor's serial executor INDEFINITELY — and since
        // `loopback()`, `close()`, `addrs()` are all on the same actor, EVERY
        // localAPI call (`backendStatus()` polling, `startLoginInteractive()`,
        // logout's `currentProfile`/`deleteProfile`) queues behind it and hangs
        // for the whole login window. It also deadlocks `close()` on
        // background (close queues behind up() forever) → two tsnet servers
        // on the same state dir after a bg/fg cycle.
        //
        // `tailscale_start` (called in `TailscaleNode.init`) already sets
        // `WantRunning` + calls `StartLoginInteractive`, so the IPN bus emits
        // `NeedsLogin` + `BrowseToURL` (and later `Running` when the user
        // completes login) on its own — `Up`'s only extra work is a redundant
        // wait-for-`Running`. The bus watcher attached above is the source of
        // truth for state; `startStatusPolling` is the fallback. (Confirmed by
        // the timing harness in timing/: Start→Running ≈ Up→Running, with no
        // actor freeze — see timing/README.md.)
        //
        // The loopback SOCKS5 proxy is up as soon as the node is started, so
        // `proxyConfiguration` can be published now. The initial connection
        // gate does not create the browser until the bus reports `Running`.
        if let loopback = try await self.node?.loopback() {
            await MainActor.run {
                model.proxyConfiguration = proxyConfig(loopback)
            }
        }
    }

    @MainActor var busErrorWatcher: AnyCancellable?

    /// Watches `prefs` so flipping the Exit Node toggle re-scopes the proxy
    /// immediately (exit node on => proxy everything so public traffic can
    /// egress; off => tailnet only). Without this the change would only take
    /// effect on the next 5s status poll.
    @MainActor private var prefsWatcher: AnyCancellable?

    /// Owns the ordinary IPN-bus error retry. It must be explicitly cancelled:
    /// cancelling the Combine sink does not cancel a Task it already spawned.
    @MainActor private var busRestartTask: Task<Void, Never>?
    /// Backoff belongs to the watcher lifecycle, not to one restart Task. A
    /// LocalAPI listener can accept a request and then fail it asynchronously;
    /// treating creation of that request as "restart succeeded" otherwise
    /// resets backoff on every -1004 and creates a hot retry loop.
    @MainActor private var busRestartBackoff: Duration = .milliseconds(500)
    @MainActor private var loopbackRecoveryTask: Task<Void, Never>?
    @MainActor private var loopbackRecoveryGeneration: UInt64 = 0

    /// Starts observing `prefs` for exit-node changes. Idempotent.
    @MainActor
    private func startPrefsObservation() {
        guard prefsWatcher == nil else { return }
        prefsWatcher = model.$prefs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshProxyPolicyIfNeeded()
            }
    }

    func startEventBus(localAPI: LocalAPIClient,
                       consumer: TSNetConsumer) async throws -> MessageProcessor {
        // This sets up a bus watcher to listen for changes in the netmap.  These will be sent to the given consumer, in
        // this case, a TSNetModel which will keep track of the changes and publish them.
        let busEventMask: Ipn.NotifyWatchOpt = [.initialState]
        let processor = try await localAPI.watchIPNBus(mask: busEventMask,
                                                       consumer: consumer)

        // Any error on the bus consumer indicates the watcher died and needs to
        // be restarted. The watch-ipn-bus long-poll has no keep-alive, so
        // URLSession's default 60s request timeout kills it every minute of
        // idleness — this restart is what keeps state flowing.
        //
        // The restart MUST be robust: the previous version did
        // `let processor = try await startEventBus(...)` inside an unawaited
        // Task with no catch. If that threw (e.g. loopback not ready after a
        // bg/fg cycle), the error was silently swallowed, `consumer.error` had
        // already been cleared, and NO new watcher existed — the app then had
        // NO bus observation forever, so state never updated again (the
        // "click Login/Logout and nothing happens for minutes/ever" hang).
        // Now we catch, log, back off, and retry until the bus comes back or
        // the node is torn down (background).
        let busObserver = await consumer.$error
            .sink { [weak self] error in
                guard let self, let error else { return }
                self.scheduleBusRestart(localAPI: localAPI, consumer: consumer,
                                        error: error)
            }

        // Cancel any prior observer before installing the new one, so the old
        // watcher's sink can't fire again and cascade into concurrent restarts.
        await MainActor.run {
            busErrorWatcher?.cancel()
            busErrorWatcher = busObserver
        }
        return processor
    }

    @MainActor
    private func scheduleBusRestart(localAPI: LocalAPIClient, consumer: TSNetConsumer,
                                    error: Error) {
        if Self.isLocalLoopbackConnectionFailure(error) {
            recoverLoopbackAfterFailure(error)
            return
        }
        let delay = busRestartBackoff
        busRestartBackoff = min(busRestartBackoff * 2, .seconds(30))
        logger.log("Bus watcher error: \(error); retrying after \(delay)")
        busRestartTask?.cancel()
        consumer.error = nil
        busRestartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                let processor = try await self.startEventBus(
                    localAPI: localAPI, consumer: consumer)
                guard !Task.isCancelled else {
                    processor.cancel()
                    return
                }
                self.setProcessor(processor)
                self.busRestartTask = nil
            } catch is CancellationError {
                return
            } catch {
                // A synchronous setup failure has no consumer callback to drive
                // the next attempt, so feed it through the same persistent
                // backoff path. Async URLSession failures arrive via consumer.
                self.busRestartTask = nil
                self.scheduleBusRestart(localAPI: localAPI, consumer: consumer,
                                        error: error)
            }
        }
    }

    nonisolated private static func isLocalLoopbackConnectionFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain,
              (ns.code == NSURLErrorCannotConnectToHost
                || ns.code == NSURLErrorNetworkConnectionLost)
        else { return false }
        let rawURL = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? ""
        guard let host = URL(string: rawURL)?.host()?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    @MainActor
    private func recoverLoopbackAfterFailure(_ cause: Error) {
        guard loopbackRecoveryTask == nil, let node else { return }
        loopbackRecoveryGeneration &+= 1
        let generation = loopbackRecoveryGeneration
        logger.log("LocalAPI loopback failure: \(cause); replacing loopback generation \(generation)")
        busRestartTask?.cancel()
        busRestartTask = nil
        loopbackRecoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loopback = try await node.restartLoopback()
                guard !Task.isCancelled,
                      generation == self.loopbackRecoveryGeneration else { return }

                // Every LocalAPI request asks the node actor for its cached
                // config, now replaced above. Restart the stream immediately.
                let newConsumer = TSNetConsumer(logger: logger, model: self.model)
                let newClient = LocalAPIClient(localNode: node, logger: logger)
                let newProcessor = try await self.startEventBus(
                    localAPI: newClient, consumer: newConsumer)
                guard !Task.isCancelled,
                      generation == self.loopbackRecoveryGeneration else {
                    newProcessor.cancel()
                    return
                }
                self.consumer = newConsumer
                self.localAPIClient = newClient
                self.setProcessor(newProcessor)

                // Replace the app-owned relay too: its upstream port and SOCKS
                // credential changed with the tsnet loopback listener.
                self.socksLogProxy?.stop()
                self.socksLogProxy = nil
                self.socksLogProxyPort = nil
                self.model.proxyConfiguration = self.proxyConfig(loopback)
                self.busRestartBackoff = .milliseconds(500)
                self.loopbackRecoveryTask = nil
                self.model.tcpChaosTestStatus = "recovered"
                logger.log("LocalAPI loopback recovered at \(loopback.address), generation \(generation)")
            } catch {
                guard !Task.isCancelled,
                      generation == self.loopbackRecoveryGeneration else { return }
                self.loopbackRecoveryTask = nil
                logger.log("LocalAPI loopback replacement failed: \(error); retrying through bus backoff")
                self.scheduleBusRestart(localAPI: localAPIClient ?? LocalAPIClient(localNode: node, logger: logger),
                                        consumer: self.consumer, error: error)
            }
        }
    }

    func setLocalAPIClient(_ client: TailscaleKit.LocalAPIClient) {
        self.localAPIClient = client
        startPrefsObservation()
        startStatusPolling()
    }

    /// Polls `backendStatus()` every few seconds and publishes it on the model,
    /// so per-tab connection-type indicators stay current.
    @MainActor
    func startStatusPolling() {
        guard statusPollTask == nil else { return }
        statusPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let client = await MainActor.run(body: { self.localAPIClient }) {
                    do {
                        let status = try await client.backendStatus()
                        await MainActor.run {
                            // A successful request proves the local listener is
                            // carrying bytes again; future watcher failures may
                            // start from the short retry delay.
                            self.busRestartBackoff = .milliseconds(500)
                            self.model.localStatus = status
                            if status.BackendState == "Running" {
                                self.runTCPChaosTestIfNeeded()
                            }
                            // Fallback state signal: model.state is normally
                            // driven by the IPN bus, but if the bus watcher is
                            // mid-restart (or has died — see startEventBus),
                            // state would go stale indefinitely. Mirror the
                            // polled BackendState into model.state so the UI's
                            // gate/LoginBanner/Login-button react within one
                            // poll interval (5s) instead of waiting for the bus.
                            if let s = Self.ipnState(fromBackendState: status.BackendState),
                               self.model.state != s {
                                self.model.state = s
                            }
                            // Fold newly-discovered peers / the MagicDNS suffix
                            // into the proxy's split-tunnel rules. The proxy is
                            // published before the first poll, so without this
                            // the rule set would stay IP-ranges-only and bare
                            // MagicDNS names (`http://ai/`) would load DIRECT
                            // and fail. No-op when the rules are unchanged.
                            self.refreshProxyPolicyIfNeeded()
                        }
                    } catch {
                        await MainActor.run {
                            logger.log("Status poll failed: \(error)")
                            if Self.isLocalLoopbackConnectionFailure(error) {
                                self.recoverLoopbackAfterFailure(error)
                            }
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
            }
        }
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

    /// Builds the SOCKS5 `ProxyConfiguration` for WebKit, scoped by
    /// `TailnetProxyPolicy` so ONLY tailnet destinations are proxied and the
    /// public internet loads DIRECT.
    ///
    /// The scoping is what fixes the iPad `-1000` ("invalid URL") bug. Measured
    /// fact: `-1000` is what WebKit/CFNetwork report for ANY SOCKS5 CONNECT
    /// failure, so it means "the proxy could not connect" — not "bad URL".
    /// Public hosts therefore must not depend on the tsnet proxy at all. See
    /// the file comment in `TailnetProxyPolicy.swift` for the candidate
    /// mechanisms and the verified `matchDomains` semantics.
    ///
    /// `-ProxyEverything` restores the old proxy-everything behaviour, so the
    /// two modes can be A/B'd on a real device with no rebuild (the iPad in
    /// the bug report can't be attached to a Mac).
    func proxyConfig(_ loopbackConfig: TailscaleNode.LoopbackConfig) -> ProxyConfiguration? {
        guard let ip = loopbackConfig.ip, let port = loopbackConfig.port else {
            return nil
        }

        // Route WebKit through the logging relay (Settings → Logs) so every
        // connection attempt that reaches the tailnet proxy is recorded with
        // its outcome. tsnet's own SOCKS server logs only failures and not the
        // reply code, so without this the absence of a log line is ambiguous:
        // it could mean "iOS never sent it to us" OR "it succeeded".
        var proxyHost = ip
        var proxyPort = port
        if SocksLogProxy.isEnabled() {
            if socksLogProxy == nil,
               let upstreamPort = UInt16(exactly: port) {
                let relay = SocksLogProxy(upstreamHost: ip, upstreamPort: upstreamPort)
                if let localPort = relay.start() {
                    socksLogProxy = relay
                    socksLogProxyPort = localPort
                }
            }
            if let localPort = socksLogProxyPort {
                proxyHost = "127.0.0.1"
                proxyPort = Int(localPort)
            }
        }

        let proxy = NWEndpoint.hostPort(host: NWEndpoint.Host(proxyHost),
                                        port: NWEndpoint.Port("\(proxyPort)")!)

        var proxyConfig = ProxyConfiguration(socksv5Proxy: proxy)
        proxyConfig.applyCredential(username: "tsnet",
                                    password: loopbackConfig.proxyCredential)

        let policy = TailnetProxyPolicy.make(from: model.localStatus,
                                             exitNodeEnabled: proxyEverythingRequested())
        if policy.proxiesEverything {
            model.proxyPolicy = policy
            logger.log("proxyConfig: proxying ALL hosts (exit node on, or -ProxyEverything). Public traffic egresses via the exit node; with no working exit node it will fail.")
            return proxyConfig
        }
        proxyConfig.matchDomains = policy.matchDomains
        model.proxyPolicy = policy
        logger.log("proxyConfig: split tunnel, proxying \(policy.matchDomains.count) rule(s): \(policy.matchDomains.joined(separator: ", "))")
        if !policy.shortNamesWithheldAsPublicTLD.isEmpty {
            logger.log("proxyConfig: short names withheld (public-TLD collision), reachable via FQDN: \(policy.shortNamesWithheldAsPublicTLD.joined(separator: ", "))")
        }
        return proxyConfig
    }

    /// Re-derives the proxy's `matchDomains` from the latest peer status and
    /// republishes it if the rule set changed.
    ///
    /// The proxy is published as soon as the node starts — before the first
    /// `/status` poll — so the initial rule set is only the tailnet IP ranges.
    /// Once peers are known (and whenever they change: a peer joins, or
    /// MagicDNS arrives) the short names and MagicDNS suffix must be folded in,
    /// or bare names like `http://ai/` would load DIRECT and fail.
    @MainActor
    func refreshProxyPolicyIfNeeded() {
        guard model.proxyConfiguration != nil else { return }
        let policy = TailnetProxyPolicy.make(from: model.localStatus,
                                             exitNodeEnabled: proxyEverythingRequested())
        guard policy != model.proxyPolicy else { return }
        guard var updated = model.proxyConfiguration else { return }
        updated.matchDomains = policy.matchDomains
        model.proxyPolicy = policy
        model.proxyConfiguration = updated
        logger.log("proxyConfig: policy updated — \(policy.matchDomains.joined(separator: ", "))")
        if !policy.shortNamesWithheldAsPublicTLD.isEmpty {
            logger.log("proxyConfig: short names withheld (public-TLD collision), reachable via FQDN: \(policy.shortNamesWithheldAsPublicTLD.joined(separator: ", "))")
        }
    }

    /// Whether ALL traffic (not just tailnet) should go through the proxy.
    ///
    /// True when an **exit node is enabled** — the only legitimate reason to send
    /// public traffic through the tailnet, since that's how it egresses. This is
    /// why the Exit Node toggle doubles as the routing control: with no exit
    /// node, proxied public traffic simply fails.
    ///
    /// Also true for the `-ProxyEverything` launch override (simulator/CI only;
    /// launch args can't be set on a physical device — use the toggle there).
    @MainActor
    func proxyEverythingRequested() -> Bool {
        if Self.proxyEverythingOverride() { return true }
        return !(model.prefs?.ExitNodeID ?? "").isEmpty
    }

    /// Debug/diagnostic escape hatch: `-ProxyEverything` (launch arg) or
    /// `APERTURE_PROXY_EVERYTHING=1` restores the pre-fix behaviour of routing
    /// every request through the tsnet proxy. Used to demonstrate the -1000 bug
    /// and to verify the split tunnel is what fixes it. Not settable on a real
    /// device — the Exit Node toggle is the on-device equivalent.
    nonisolated static func proxyEverythingOverride() -> Bool {
        if ProcessInfo.processInfo.environment["APERTURE_PROXY_EVERYTHING"] == "1" {
            return true
        }
        return ProcessInfo.processInfo.arguments.contains("-ProxyEverything")
    }

    @MainActor
    private func runTCPChaosTestIfNeeded() {
        guard Self.tcpChaosTestRequested(), !didRunTCPChaosTest else { return }
        didRunTCPChaosTest = true
        Task { [weak self] in
            guard let self, let node = self.node else { return }
            // Let the first document and SOCKS diagnostics establish themselves
            // before damaging all TCP sockets in the process.
            try? await Task.sleep(for: .seconds(2))
            self.model.tcpChaosTestStatus = "damaging"
            logger.log("TCP chaos test: defuncting the tsnet loopback listener")
            do {
                if ProcessInfo.processInfo.arguments.contains("-UITestDefunctLoopback") {
                    try await node.debugDefunctLoopback()
                } else {
                    try await node.debugShutdownTCPConnections()
                }
                self.model.tcpChaosTestStatus = "damaged"
                logger.log("TCP chaos test: socket shutdown complete; awaiting reactive recovery")
            } catch {
                self.model.tcpChaosTestStatus = "failed: \(error)"
                logger.log("TCP chaos test failed: \(error)")
            }
        }
    }

    /// Permanently tears down this manager when its workspace is deleted.
    /// Unlike scene backgrounding, deletion must release the node and all
    /// observers so its state directory can be removed safely.
    func shutdown() async {
        statusPollTask?.cancel()
        statusPollTask = nil
        busRestartTask?.cancel()
        busRestartTask = nil
        loopbackRecoveryTask?.cancel()
        loopbackRecoveryTask = nil
        loopbackRecoveryGeneration &+= 1
        busErrorWatcher?.cancel()
        busErrorWatcher = nil
        prefsWatcher?.cancel()
        prefsWatcher = nil
        processor?.cancel()
        processor = nil
        socksLogProxy?.stop()
        socksLogProxy = nil
        socksLogProxyPort = nil
        localAPIClient = nil
        model.proxyConfiguration = nil
        model.proxyPolicy = nil

        guard let node else { return }
        self.node = nil
        do {
            try await node.close()
            logger.log("Delete session: closed tsnet node")
        } catch {
            logger.log("Delete session: failed to close tsnet node: \(error)")
        }
    }

    func willEnterBackground() {
        logger.log("Background: leaving tsnet, proxy, and observers unchanged")
    }

    func willEnterForeground() {
        // Recovery is driven by an actual loopback connection failure, not by
        // scene lifecycle: iOS can defunct sockets for reasons other than lock.
        logger.log("Foreground: no lifecycle recovery; awaiting actual socket errors")
        if node == nil { startTailscaleIfNeeded() }
    }

    func setExitNodeEnabled(_ enabled: Bool) {
        // Prefer a concrete advertised peer. `auto:any` is useful as a managed
        // policy placeholder, but patching it directly into ordinary prefs can
        // remain unresolved even when status already knows usable exit nodes,
        // leaving public traffic on the local egress. Stable sorting keeps the
        // choice deterministic across status dictionary iterations.
        let availableExitNodes = model.localStatus?.Peer?.values
            .filter { $0.ExitNodeOption }
            .sorted {
                if $0.Online != $1.Online { return $0.Online && !$1.Online }
                return $0.ID < $1.ID
            } ?? []
        let id = enabled ? (availableExitNodes.first?.ID ?? "auto:any") : ""
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

    /// Maps the polled `IpnState.Status.BackendState` string ("Running",
    /// "NeedsLogin", …) to `Ipn.State`. Used by `startStatusPolling` as a
    /// fallback state signal so the UI isn't blind when the IPN bus watcher
    /// is mid-restart (or has died). `nonisolated` so it's callable from the
    /// polling Task off the main actor.
    nonisolated static func ipnState(fromBackendState s: String) -> Ipn.State? {
        switch s {
        case "NoState":          return .NoState
        case "InUseOtherUser":   return .InUseOtherUser
        case "NeedsLogin":       return .NeedsLogin
        case "NeedsMachineAuth": return .NeedsMachineAuth
        case "Stopped":          return .Stopped
        case "Starting":         return .Starting
        case "Running":          return .Running
        default:                 return nil
        }
    }
}

