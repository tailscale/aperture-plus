//  TimingHarness.swift
//  Aperture
//
//  A text-mode (no-UI) timing harness that drives the SAME libtailscale-Swift
//  integration the app uses (TailscaleNode + LocalAPIClient + TSNetModel via
//  the IPN bus), mirroring the pure-Go `build/timing-go` harness so the two
//  can be compared. Gated by the `-TimingHarness` launch arg (see ApertureApp);
//  in that mode the app skips WorkspaceManager entirely and just runs this.
//
//  Launch on the sim:
//
//    xcrun simctl launch booted io.tailscale.Aperture \
//        -TimingHarness -TimingRuns 5 -AuthKey tskey-auth-...
//
//  Output is written both to `print()` and to OSLog (subsystem
//  io.tailscale.Aperture, category "timing"), so `log stream` captures it:
//
//    xcrun simctl spawn booted log stream \
//        --predicate 'subsystem == "io.tailscale.Aperture"' --style compact
//
//  Each iteration measures the 5 phases (cold, fresh state dir per server):
//    1. Up() with NO auth key  → first login URL (BrowseToURL)
//    2. tear down + restart    → Up() with an auth key begins
//    3. Up() with auth key     → Running (truly connected)
//    4. Logout                 → idle (NeedsLogin / Stopped / NoState)
//    5. second Up() with key   → Running (fresh node)
//
//  Peer path-upgrade mode (`-TimingPeer <host>`, mirroring `timing-go -peer`):
//  skips the lifecycle test and instead watches a tailnet peer's CurAddr/Relay
//  upgrade from DERP to direct, classifying with the app's own
//  ConnectionTypeResolver. See `runPeerMode` and timing/README.md.
//    -TimingPeer ai [-TimingPeerWatch 30] [-TimingPeerTraffic 12] [-TimingPeerUseUp]
//

import Foundation
import OSLog
import SwiftUI
import WebKit
import TailscaleKit

private let timingLog = OSLog(subsystem: "io.tailscale.Aperture", category: "timing")
private let harnessDefaultControlURL = "https://controlplane.tailscale.com"

@MainActor
private struct TimingRow {
    var t1: Double = -1  // Up(no key) → login URL
    var t2: Double = -1  // login URL → key Up begins (restart overhead)
    var t3: Double = -1  // key Up → Running
    var t4: Double = -1  // Logout → idle
    var t5: Double = -1  // second key Up → Running
}

/// Root view shown when `-TimingHarness` is set. Renders the live table; the
/// real work runs in `.task`.
struct TimingHarnessView: View {
    @State private var lines: [String] = ["timing-swift: starting…"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)) }
            }
            .padding()
        }
        .task { await runHarness() }
    }

    private func emit(_ s: String) {
        lines.append(s)
        print(s)
        os_log("%{public}@", log: timingLog, type: .default, s)
    }

    private func runHarness() async {
        guard let key = TSNetManager.launchAuthKey() else {
            emit("timing-swift: NO AUTH KEY (pass -AuthKey ... or APERTURE_AUTHKEY)")
            return
        }
        let runs = Self.parseRuns(defaultValue: 5)

        // Peer path-upgrade mode (-TimingPeer <host>): skip the lifecycle test
        // and instead watch a tailnet peer's CurAddr/Relay upgrade from DERP
        // to direct, mirroring the Go `timing-go -peer` harness.
        if let peer = Self.parseArg("-TimingPeer") {
            let watch = Self.parseArgDouble("-TimingPeerWatch", defaultValue: 30)
            let traffic = Self.parseArgDouble("-TimingPeerTraffic", defaultValue: 12)
            let useUp = ProcessInfo.processInfo.arguments.contains("-TimingPeerUseUp")
            await runPeerMode(runs: runs, peer: peer, watch: watch, traffic: traffic,
                             useUp: useUp, authKey: key)
            return
        }

        // Internet-via-proxy mode (-TimingInternet [url]): fetch a NON-tailnet
        // URL through the tsnet SOCKS5 proxy and log the HTTP status / error.
        // With no url arg, runs a built-in battery (tailnet vs internet,
        // by-name vs by-IP, https vs http). Diagnoses the reported bug where
        // internet URLs fail with a connection error on real iPad /
        // macOS-Designed-for-iPad but work on real iPhone.
        //
        // By default fetches via URLSession + the CFNetwork SOCKS proxy
        // dictionary. Add `-TimingWeb` to fetch via the app's actual raw
        // WKWebView path (BrowserViewModel + WKWebsiteDataStore.
        // proxyConfigurations + Network.ProxyConfiguration) — a different
        // proxy mechanism than URLSession, and the one the reported bug
        // reproduces through. Run on a real iPad with `-TimingWeb` to capture
        // the exact NSError domain+code.
        if ProcessInfo.processInfo.arguments.contains("-TimingInternet") {
            let url = Self.parseArg("-TimingInternet")  // nil -> built-in battery
            let useWeb = ProcessInfo.processInfo.arguments.contains("-TimingWeb")
            await runInternetMode(runs: runs, url: url, useWeb: useWeb, authKey: key)
            return
        }

        emit("timing-swift: \(runs) runs, control=\(harnessDefaultControlURL), key=\(key.prefix(14))…")
        emit("")
        emit("run | 1:Up→URL | 2:URL→KeyUp | 3:KeyUp→Running | 4:Logout→idle | 5:KeyUp2→Running")

        var rows: [TimingRow] = []
        for i in 1...runs {
            let r = await runOnce(i, key)
            rows.append(r)
            emit(String(format: "%3d | %8@ | %9@ | %12@ | %11@ | %12@",
                        i, fmt(r.t1), fmt(r.t2), fmt(r.t3), fmt(r.t4), fmt(r.t5)))
        }

        // Summary
        emit("")
        emit("summary (successful runs only):")
        let labels: [(String, (TimingRow) -> Double)] = [
            ("1:Up→URL       ", { $0.t1 }),
            ("2:URL→KeyUp    ", { $0.t2 }),
            ("3:KeyUp→Running", { $0.t3 }),
            ("4:Logout→idle  ", { $0.t4 }),
            ("5:KeyUp2→Run   ", { $0.t5 }),
        ]
        for (name, get) in labels {
            var sum = 0.0, n = 0, first = true
            var mn = 0.0, mx = 0.0
            for r in rows {
                let v = get(r)
                guard v > 0 else { continue }
                sum += v; n += 1
                if first || v < mn { mn = v }
                if first || v > mx { mx = v }
                first = false
            }
            if n == 0 { emit("  \(name)  n=0 (all failed)"); continue }
            emit(String(format: "  %@  n=%d  avg=%@  min=%@  max=%@",
                        name, n, fmt(sum / Double(n)), fmt(mn), fmt(mx)))
        }
        emit("timing-swift: DONE")
    }

    /// -TimingRuns <n> launch arg, else `defaultValue`.
    private static func parseRuns(defaultValue: Int) -> Int {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-TimingRuns"), i + 1 < args.count,
           let n = Int(args[i + 1]) {
            return n
        }
        return defaultValue
    }

    /// The string value following `-<name>` in the launch args, if present.
    /// Returns nil if the arg is absent OR the following token starts with `-`
    /// (treated as another flag, not a value) — so a flag that takes an
    /// OPTIONAL value (e.g. `-TimingInternet` with a built-in battery when no
    /// url is given) works even when other flags follow.
    private static func parseArg(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        if v.isEmpty || v.hasPrefix("-") { return nil }
        return v
    }

    /// The Double value following `-<name>` in the launch args, else `defaultValue`.
    private static func parseArgDouble(_ name: String, defaultValue: Double) -> Double {
        if let s = parseArg(name), let d = Double(s) { return d }
        return defaultValue
    }

    // MARK: - Peer path-upgrade mode (-TimingPeer)

    /// Peer mode: for each run, start a keyed ephemeral node, send a little
    /// HTTP traffic to `http://<peer>/`, and watch the peer's path upgrade from
    /// DERP to direct — mirroring the Go `timing-go -peer` harness and the
    /// app's `ConnectionTypeResolver` (direct iff peer.CurAddr is non-empty).
    /// A path that flips direct→DERP quickly here would explain the URL bar
    /// showing "mostly one green dot, briefly two".
    @MainActor
    private func runPeerMode(runs: Int, peer: String, watch: TimeInterval,
                             traffic: TimeInterval, useUp: Bool, authKey: String) async {
        emit("timing-swift peer: \(runs) runs, peer=\(peer), watch=\(fmt(watch)), traffic=\(fmt(traffic)), useUp=\(useUp), key=\(authKey.prefix(14))…")
        emit("")
        emit("run |   up | toDirect | flips | totalDirect | longestDirect | >=10s | direct@end | gets/ok | found")

        var reps: [PeerReport] = []
        for i in 1...runs {
            let r = await runPeerOnce(i, peer: peer, watch: watch, traffic: traffic,
                                       useUp: useUp, authKey: authKey)
            reps.append(r)
            emit(String(format: "%3d | %4@ | %8@ | %5d | %11@ | %13@ | %5@ | %10@ | %7@ | %@",
                        i, fmt(r.upSeconds), fmt(r.timeToDirect), r.directFlips,
                        fmt(r.totalDirect), fmt(r.longestDirect),
                        r.stayedDirect10 ? "yes" : "no",
                        r.directAtEnd ? "yes" : "no",
                        "\(r.trafficOK)/\(r.trafficGets)",
                        r.peerFound ? "yes" : "no"))
            if let e = r.trafficErr {
                emit("    traffic err (non-fatal): \(e)")
            }
        }

        // Summary over the runs that found the peer.
        var n = 0, directCount = 0, stayed10 = 0, directAtEndCount = 0
        var sumToDirect: Double = 0
        for r in reps where r.peerFound {
            n += 1
            if r.timeToDirect > 0 { sumToDirect += r.timeToDirect; directCount += 1 }
            if r.stayedDirect10 { stayed10 += 1 }
            if r.directAtEnd { directAtEndCount += 1 }
        }
        emit("")
        emit("summary (runs that found the peer):")
        if n == 0 {
            emit("  n=0 — peer \(peer) never matched in /status (see the peer dump above).")
            emit("  (This itself is a clue: the app's host→peer matching may be the bug.)")
        } else {
            if directCount > 0 {
                emit("  reached direct:    \(directCount)/\(n)   avg time-to-direct=\(fmt(sumToDirect / Double(directCount)))")
            } else {
                emit("  reached direct:    0/\(n)   (never went direct)")
            }
            emit("  stayed direct ≥10s: \(stayed10)/\(n)")
            emit("  direct at end:      \(directAtEndCount)/\(n)")
        }
        emit("timing-swift: DONE")
    }

    /// One peer-upgrade run: start a keyed ephemeral node, send 1 GET/s to
    /// http://<peer>/ for `traffic` seconds (then idle), and poll the local-API
    /// /status every 200ms for `watch` seconds, classifying the peer's path
    /// exactly as the app does (direct iff peer.CurAddr is non-empty, using the
    /// app's own `ConnectionTypeResolver.peerStatus(forHost:in:)`). Logs every
    /// direct↔derped transition with a timestamp.
    @MainActor
    private func runPeerOnce(_ run: Int, peer: String, watch: TimeInterval,
                             traffic: TimeInterval, useUp: Bool, authKey: String) async -> PeerReport {
        var rep = PeerReport()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("timing-swift-peer\(run)").path
        try? FileManager.default.removeItem(atPath: base)

        let cfg = Configuration(hostName: "timing-swift-peer-\(run)",
                                path: base,
                                authKey: authKey,
                                controlURL: harnessDefaultControlURL,
                                ephemeral: true)
        let tStart = Date()
        guard let (node, lc, model, proc) = try? await startNode(cfg) else {
            emit("  [r\(run)] startNode FAILED")
            return rep
        }
        if useUp {
            // Mirror the Go harness: tailscale_up → srv.Up() (Start + wait for
            // Running + a Status call + serve-config reset). The app deliberately
            // does NOT call up(); this flag tests whether that's the difference.
            do {
                try await node.up()
            } catch {
                emit("  [r\(run)] node.up() FAILED: \(error)")
                await teardown(node, proc)
                return rep
            }
            guard await waitForRunning(model, timeout: 90) else {
                emit("  [r\(run)] did not reach Running after up()")
                await teardown(node, proc)
                return rep
            }
        } else {
            guard await waitForRunning(model, timeout: 90) else {
                emit("  [r\(run)] did not reach Running")
                await teardown(node, proc)
                return rep
            }
        }
        rep.upSeconds = Date().timeIntervalSince(tStart)
        emit("  [r\(run)] up → Running in \(fmt(rep.upSeconds)); starting traffic + path watch")

        // HTTP traffic through the tailnet SOCKS proxy — the same path WebKit
        // uses to load http://<peer>/.
        let sessionConfig: URLSessionConfiguration
        do {
            let (cfg, _) = try await URLSessionConfiguration.tailscaleSession(node)
            sessionConfig = cfg
        } catch {
            emit("  [r\(run)] tailscaleSession FAILED: \(error)")
            await teardown(node, proc)
            return rep
        }
        let session = URLSession(configuration: sessionConfig)
        guard let url = URL(string: "http://\(peer)/") else {
            emit("  [r\(run)] bad URL http://\(peer)/")
            await teardown(node, proc)
            return rep
        }

        // Traffic runs concurrently for `traffic` seconds; the result is
        // collected after the watch loop (no shared mutable state — the watch
        // loop and runTraffic each touch only their own locals).
        let trafficDeadline = Date().addingTimeInterval(traffic)
        async let trafficResult = runTraffic(session: session, url: url, until: trafficDeadline)

        // Path watcher: poll /status every 200ms. The app polls every 5s; we
        // poll fast to catch quick direct→DERP flips the app's coarse poll
        // would miss.
        let pollInterval: UInt64 = 200_000_000
        let deadline = Date().addingTimeInterval(watch)
        var prevClass: ConnectionType?
        var directSince: Date?
        var firstDirectAt: Date?
        var dumpedPeers = false
        var dumpedDetail = false

        while Date() < deadline {
            guard let sts = try? await lc.backendStatus() else {
                try? await Task.sleep(nanoseconds: pollInterval)
                continue
            }
            // Reuse the app's exact host→peer matching (now internal).
            guard let peerPS = ConnectionTypeResolver.peerStatus(forHost: peer, in: sts) else {
                if !dumpedPeers {
                    dumpedPeers = true
                    emit("  [r\(run)] peer \(peer) not found in /status; known peers:")
                    if let s = sts.SelfStatus {
                        emit("        self: HostName=\(s.HostName) DNSName=\(s.DNSName)")
                    }
                    if let peers = sts.Peer {
                        for p in peers.values {
                            emit("        peer: HostName=\(p.HostName) DNSName=\(p.DNSName)")
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: pollInterval)
                continue
            }
            rep.peerFound = true
            // Classify exactly as ConnectionTypeResolver.resolve does.
            let cls: ConnectionType = (peerPS.CurAddr?.isEmpty == false) ? .direct : .derped

            if !dumpedDetail {
                dumpedDetail = true
                let selfAddrs = sts.SelfStatus?.Addrs ?? []
                let selfCur = sts.SelfStatus?.CurAddr ?? "(nil)"
                emit("  [r\(run)] detail: self.Addrs=\(selfAddrs) self.CurAddr=\(selfCur)")
                emit("  [r\(run)] detail: peer.Addrs=\(peerPS.Addrs ?? []) peer.Online=\(peerPS.Online)")
            }

            if cls != prevClass {
                let t = Date().timeIntervalSince(tStart)
                let cur = peerPS.CurAddr ?? ""
                let rel = peerPS.Relay.flatMap { $0.isEmpty ? nil : $0 } ?? "-"
                emit("  [r\(run)] \(String(format: "%7.2f", t))s  → \(cls)  (CurAddr=\(cur) Relay=\(rel))")
                if cls == .direct {
                    if firstDirectAt == nil {
                        firstDirectAt = Date()
                        rep.timeToDirect = t
                    }
                    directSince = Date()
                } else {  // .derped
                    if let ds = directSince {
                        let d = Date().timeIntervalSince(ds)
                        rep.totalDirect += d
                        if d > rep.longestDirect { rep.longestDirect = d }
                        rep.directFlips += 1
                    }
                    directSince = nil
                }
                prevClass = cls
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }

        // Close out any direct stretch still open at the end of the window.
        if let ds = directSince {
            let d = Date().timeIntervalSince(ds)
            rep.totalDirect += d
            if d > rep.longestDirect { rep.longestDirect = d }
            rep.directAtEnd = true
        }
        rep.stayedDirect10 = rep.longestDirect >= 10

        let (gets, ok, terr) = await trafficResult
        rep.trafficGets = gets
        rep.trafficOK = ok
        rep.trafficErr = terr

        await teardown(node, proc)
        return rep
    }

    // MARK: - Internet-via-proxy mode (-TimingInternet)

    /// Fetches a non-tailnet URL through the tsnet SOCKS5 proxy `runs` times,
    /// logging the HTTP status / error for each. Diagnoses whether non-tailnet
    /// traffic works on this platform — the reported bug where internet URLs
    /// fail with a connection error on real iPad / macOS-Designed-for-iPad but
    /// work on a real iPhone / the simulator.
    ///
    /// `useWeb=false` (default) fetches via URLSession + the CFNetwork SOCKS
    /// proxy dictionary. `useWeb=true` fetches via the app's actual raw
    /// WKWebView path (`BrowserViewModel` + `WKWebsiteDataStore` proxy
    /// configurations) — a different proxy mechanism, and the one the reported
    /// bug reproduces through. Run on a real iPad with `-TimingWeb` to capture
    /// the exact NSError.
    ///
    /// With no `-TimingInternet` url arg, runs a built-in battery that
    /// distinguishes the failure modes in ONE launch: a tailnet host (should
    /// always work), an internet host by name (the bug), an internet host by
    /// IP (bypasses DNS), and an internet host over plain HTTP (isolates TLS).
    @MainActor
    private func runInternetMode(runs: Int, url: String?, useWeb: Bool, authKey: String) async {
        emit("timing-swift internet: \(runs) runs, via=\(useWeb ? "WKWebView" : "URLSession/SOCKS"), key=\(authKey.prefix(14))…")
        emit("")
        var okCount = 0, total = 0
        if let urlStr = url, let url = URL(string: urlStr) {
            total = runs
            for i in 1...runs {
                if await runInternetOnce(i, url: url, useWeb: useWeb, authKey: authKey) { okCount += 1 }
            }
        } else {
            // Built-in battery: distinguishes tailnet vs internet, by-name vs
            // by-IP (DNS isolation), https vs http (TLS isolation). One launch
            // gives the full picture on a real device.
            let battery: [(label: String, url: String)] = [
                ("tailnet (http://ai/)",            "http://ai/"),
                ("internet https by-name",          "https://www.google.com/"),
                ("internet https by-IP (142.250.80.46)", "https://142.250.80.46/"),
                ("internet http by-name",           "http://example.com/"),
            ]
            total = battery.count * runs
            for i in 1...runs {
                for b in battery {
                    emit("--- [r\(i)] \(b.label) ---")
                    if await runInternetOnce(i, url: URL(string: b.url)!, useWeb: useWeb, authKey: authKey) {
                        okCount += 1
                    }
                }
            }
        }
        emit("")
        emit("summary: \(okCount)/\(total) succeeded")
        emit("timing-swift: DONE")
    }

    @MainActor
    private func runInternetOnce(_ run: Int, url: URL, useWeb: Bool, authKey: String) async -> Bool {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("timing-swift-inet\(run)").path
        try? FileManager.default.removeItem(atPath: base)
        let cfg = Configuration(hostName: "timing-swift-inet-\(run)",
                                path: base, authKey: authKey,
                                controlURL: harnessDefaultControlURL, ephemeral: true)
        guard let (node, _, model, proc) = try? await startNode(cfg) else {
            emit("  [r\(run)] startNode FAILED")
            return false
        }
        guard await waitForRunning(model, timeout: 90) else {
            emit("  [r\(run)] did not reach Running")
            await teardown(node, proc)
            return false
        }
        defer { Task { await teardown(node, proc) } }
        if useWeb {
            return await fetchViaWebKit(run, url: url, model: model)
        }
        let sessionConfig: URLSessionConfiguration
        do {
            let (cfg, _) = try await URLSessionConfiguration.tailscaleSession(node)
            sessionConfig = cfg
        } catch {
            emit("  [r\(run)] tailscaleSession FAILED: \(error)")
            return false
        }
        let session = URLSession(configuration: sessionConfig)
        emit("  [r\(run)] fetching \(url.absoluteString) via URLSession/SOCKS…")
        let req = URLRequest(url: url, timeoutInterval: 15)
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let bytes = data.count
            emit("  [r\(run)]   OK: HTTP \(code), \(bytes) bytes")
            return true
        } catch {
            let ns = error as NSError
            emit("  [r\(run)]   FAIL: \(ns.localizedDescription) [\(ns.domain) \(ns.code)]")
            return false
        }
    }

    /// Fetches `url` via the app's actual raw-WKWebView path, distinct from
    /// URLSession/CFNetwork SOCKS. The view is created off-screen so navigation
    /// can run, then this waits for a committed URL or navigation error and logs
    /// its NSError domain/code plus the app's NavErrorKind category.
    @MainActor
    private func fetchViaWebKit(_ run: Int, url: URL, model: TSNetModel) async -> Bool {
        emit("  [r\(run)] loading \(url.absoluteString) via WKWebView…")
        // Per-fetch data store so each fetch is isolated (matches the app's
        // per-workspace WKWebsiteDataStore(forIdentifier:)).
        let ds = WKWebsiteDataStore(forIdentifier: UUID())
        let vm = BrowserViewModel(model: model, initialURL: url, dataStore: ds)
        // Apply the proxy (the ViewModel does this itself on init if the proxy
        // is already up, but be explicit so a not-yet-up proxy is applied when
        // it arrives — mirroring the app).
        if let proxy = model.proxyConfiguration {
            vm.applyProxy(proxy)
        }
        _ = vm.makeWebView()
        vm.load(url: url)
        // Wait up to 30s for either a committed URL or a navigation error.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let err = vm.navError {
                let kind = vm.navErrorKind.map(String.init(describing:)) ?? "(nil)"
                let msg = vm.navErrorMessage ?? "(nil)"
                let ns = err.err as NSError
                emit("  [r\(run)]   FAIL: kind=\(kind) msg=\(msg) [\(ns.domain) \(ns.code)]")
                vm.clearNavError()
                return false
            }
            // Success heuristic: a committed URL or non-empty page title.
            let title = vm.title
            let loadedURL = vm.url?.absoluteString ?? ""
            if !title.isEmpty || (!loadedURL.isEmpty && loadedURL != url.absoluteString) {
                emit("  [r\(run)]   OK: loaded title=\(title.prefix(40)) url=\(loadedURL.prefix(60))")
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        emit("  [r\(run)]   TIMEOUT (30s, no finish/error; title=\(vm.title) url=\(vm.url?.absoluteString ?? ""))")
        return false
    }
}

// MARK: - One iteration

@MainActor
private func runOnce(_ run: Int, _ authKey: String) async -> TimingRow {
    var r = TimingRow()
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("timing-swift-run\(run)").path
    try? FileManager.default.removeItem(atPath: base)

    // --- Phase 1: Start() with NO auth key → first login URL ---
    //   (We don't call node.up(): TailscaleNode.init calls tailscale_start,
    //   whose doInit sets WantRunning + StartLoginInteractive, so the bus
    //   emits NeedsLogin + BrowseToURL on its own. up() would just block the
    //   actor until Running — and for a no-key node that's forever, which
    //   deadlocks close() on the same actor. Start→URL ≈ Up→URL; the up()
    //   wrapper only adds a bus watcher.)
    let cfg1 = Configuration(hostName: "timing-swift-\(run)",
                             path: base + "/nokey",
                             authKey: nil,
                             controlURL: harnessDefaultControlURL,
                             ephemeral: false)
    let tUpStart = Date()
    guard let (node1, _, model1, proc1) = try? await startNode(cfg1) else {
        return r
    }
    if await waitForBrowseToURL(model1, timeout: 90) {
        r.t1 = Date().timeIntervalSince(tUpStart)
    } else {
        await teardown(node1, proc1)
        return r
    }
    let tURL = Date()

    // --- Phase 2: tear down + restart with an auth key (measured from tURL) ---
    await teardown(node1, proc1)   // Close latency is part of t2 (restart overhead)

    let cfg2 = Configuration(hostName: "timing-swift-\(run)-key",
                             path: base + "/key1",
                             authKey: authKey,
                             controlURL: harnessDefaultControlURL,
                             ephemeral: true)
    guard let (node2, lc2, model2, proc2) = try? await startNode(cfg2) else {
        return r
    }
    let tKeyUpStart = Date()
    r.t2 = tKeyUpStart.timeIntervalSince(tURL)

    // --- Phase 3: Start() with auth key → Running (bus-emitted; no up() needed) ---
    if await waitForRunning(model2, timeout: 90) {
        r.t3 = Date().timeIntervalSince(tKeyUpStart)
    } else {
        await teardown(node2, proc2)
        return r
    }

    // --- Phase 4: Logout → idle (the app's exact path: currentProfile +
    //     deleteProfile — what the app's Logout button actually calls) ---
    let tLogoutStart = Date()
    if let cur = try? await lc2.currentProfile() {
        try? await lc2.deleteProfile(profileID: cur.id)
    }
    if await waitForIdle(model2, timeout: 90) {
        r.t4 = Date().timeIntervalSince(tLogoutStart)
    }
    await teardown(node2, proc2)

    // --- Phase 5: second Start() with auth key → Running (fresh node) ---
    let cfg3 = Configuration(hostName: "timing-swift-\(run)-key2",
                             path: base + "/key2",
                             authKey: authKey,
                             controlURL: harnessDefaultControlURL,
                             ephemeral: true)
    guard let (node3, _, model3, proc3) = try? await startNode(cfg3) else {
        return r
    }
    let tKeyUp2Start = Date()
    if await waitForRunning(model3, timeout: 90) {
        r.t5 = Date().timeIntervalSince(tKeyUp2Start)
    }
    await teardown(node3, proc3)
    return r
}

// MARK: - Node lifecycle helpers

/// Creates a TailscaleNode (which calls tailscale_start, kicking off the login
/// attempt), opens a LocalAPIClient, and starts an IPN-bus watcher feeding a
/// fresh TSNetModel. Returns the pieces the caller needs to observe + tear down.
@MainActor
private func startNode(_ cfg: Configuration) async throws
-> (TailscaleNode, LocalAPIClient, TSNetModel, MessageProcessor) {
    let node = try TailscaleNode(config: cfg, logger: logger)
    let lc = LocalAPIClient(localNode: node, logger: logger)
    let model = TSNetModel()
    let consumer = TSNetConsumer(logger: logger, model: model)
    let proc = try await lc.watchIPNBus(mask: .initialState, consumer: consumer)
    return (node, lc, model, proc)
}

/// Stops the bus watcher and closes the node (cancelling any in-flight up()).
@MainActor
private func teardown(_ node: TailscaleNode, _ proc: MessageProcessor) async {
    proc.cancel()
    try? await node.close()
}

// MARK: - Bus polling (records when the @Published model first satisfies a state)

@MainActor
private func waitForBrowseToURL(_ model: TSNetModel, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let u = model.browseToURL, !u.isEmpty { return true }
        try? await Task.sleep(nanoseconds: 2_000_000) // 2ms poll
    }
    return false
}

@MainActor
private func waitForRunning(_ model: TSNetModel, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if model.state == .Running { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return false
}

@MainActor
private func waitForIdle(_ model: TSNetModel, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let s = model.state, s == .NeedsLogin || s == .Stopped || s == .NoState {
            return true
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return false
}

// MARK: - Formatting

private func fmt(_ d: Double) -> String {
    if d <= 0 { return "-" }
    if d < 0.1 { return String(format: "%.0fms", d * 1000) }
    return String(format: "%.2fs", d)
}

// MARK: - Peer path-upgrade helpers

@MainActor
private struct PeerReport {
    var upSeconds: Double = -1       // time to reach Running
    var peerFound = false            // did the host match a peer in /status?
    var timeToDirect: Double = -1    // <0 if it never went direct
    var directFlips = 0             // direct→derped transitions observed
    var totalDirect: Double = 0      // cumulative time spent direct
    var longestDirect: Double = 0    // longest single direct stretch
    var stayedDirect10 = false       // longestDirect >= 10s
    var directAtEnd = false          // still direct at last sample
    var trafficGets = 0              // GET attempts
    var trafficOK = 0                // GETs that returned a response
    var trafficErr: String?          // first traffic error (non-fatal)
}

/// Sends 1 GET/s to `url` (via a tailnet-proxied URLSession) until `deadline`.
/// Even a refused connection sends a SYN through the tailnet, which is enough
/// to trigger endpoint discovery / a direct-path upgrade. Returns
/// (attempts, responses, firstError).
@MainActor
private func runTraffic(session: URLSession, url: URL, until deadline: Date) async -> (Int, Int, String?) {
    var gets = 0, ok = 0
    var firstErr: String?
    while Date() < deadline {
        gets += 1
        let req = URLRequest(url: url, timeoutInterval: 8)
        do {
            _ = try await session.data(for: req)
            ok += 1
        } catch {
            if firstErr == nil { firstErr = "\(error)" }
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    return (gets, ok, firstErr)
}
