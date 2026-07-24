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

import Foundation
import OSLog
import SwiftUI
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
