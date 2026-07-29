//  Created by Jonathan Nobels on 2025-12-18.
//

import Darwin
import Foundation
import TailscaleKit
import os

/// Unified-logging subsystem used for all Aperture/libtailscale messages.
/// Filter for these in Console.app or with:
///
///   xcrun simctl spawn booted log stream \
///     --predicate 'subsystem == "io.tailscale.Aperture"'
///
/// The members are `nonisolated` (and `OSLog` is `Sendable`) so they can be
/// read from `Logger.log`'s nonisolated context — libtailscale calls `log`
/// from its Go-backed threads, off the main actor.
enum ApertureLog {
    nonisolated static let subsystem = "io.tailscale.Aperture"
    /// libtailscale / tsnet messages.
    nonisolated static let tsnet = OSLog(subsystem: subsystem, category: "tsnet")
}

// The fd tsnet's own `s.s.Logf` output is written to (via `tailscale_set_logfd`),
// or nil to discard. Set once at launch by `CrashCapture.start()` before any Go
// thread exists; read once by `TailscaleNode.init` (also before concurrency
// starts). `nonisolated(unsafe)` because `Logger.log` is called from Go-backed
// (nonisolated) threads — but `log()` never reads this; only `TailscaleNode.init`
// does, so the set-once-then-read ordering is safe even though the compiler
// can't verify it. See TSNet/CrashCapture.swift.
nonisolated(unsafe) var tsnetLogFileHandle: Int32?

// `nonisolated` (and `let`) so this Sendable global is callable from the
// `nonisolated` contexts that use it (notably TSNetManager.startTailscale, which
// runs off the main actor). The fd it vends is mutated through
// `tsnetLogFileHandle` above, not through this binding.
nonisolated let logger = Logger()

struct Logger: TailscaleKit.LogSink {
    // Computed so `Logger` can stay a value-type `let` global while CrashCapture
    // swaps the fd behind it. Satisfies `LogSink.logFileHandle { get }`.
    var logFileHandle: Int32? { tsnetLogFileHandle }

    /// `LogSink.log` is called from libtailscale's (Go-backed) threads, which
    /// are off the main actor, so this must be `nonisolated`. It touches only
    /// `nonisolated` `Sendable` globals and the free `print`/`os_log`
    /// functions, so it is concurrency-safe.
    nonisolated func log(_ message: String) {
        // Keep the pre-existing stdout behaviour — `xcodebuild test` captures
        // the app's stdout, so these `tsnet:` lines show up in the test log.
        print("tsnet: \(message)")

        // Also route into the unified logging system so the messages are
        // captured by `log stream` / Console.app / `log show` during UI tests
        // (where the app's stdout isn't always easy to read in real time).
        os_log("%{public}@", log: ApertureLog.tsnet, type: .default, message)

        // And keep a copy in memory so the in-app log viewer can show it. This
        // is the ONLY way to read these messages on a device that can't be
        // attached to a Mac (no `log stream`, no Console.app).
        LogRing.shared.append(message)
    }
}

/// A bounded in-memory ring buffer of the most recent log lines, so the app can
/// show its own logs (Settings → Logs). Every libtailscale/tsnet message and
/// every `logger.log(…)` call in the app funnels through `Logger.log`, so this
/// captures both.
///
/// Exists because the iPad that reported the "invalid URL" bug has a broken USB
/// port: `log stream`/Console.app aren't available, so on-device inspection is
/// the only diagnostic channel.
///
/// Thread-safety: `Logger.log` is called from libtailscale's Go-backed threads
/// as well as the main actor, so this is a `final class` guarded by an
/// `NSLock` rather than actor-isolated (callers are `nonisolated` and can't
/// await). Lock hold times are a few pointer writes.
nonisolated final class LogRing: @unchecked Sendable {
    nonisolated static let shared = LogRing()

    /// Stable identity lets SwiftUI retain existing rows when a live snapshot
    /// adds a line, instead of rebuilding every selectable Text view.
    nonisolated struct Entry: Identifiable, Equatable, Sendable {
        let id: UInt64
        let line: String
    }

    /// Lines and their counters must come from one lock acquisition. Besides
    /// being consistent, this keeps the UI from synchronously taking this lock
    /// twice for every refresh.
    nonisolated struct Snapshot: Sendable {
        let entries: [Entry]
        let total: Int
        let version: UInt64
    }

    /// Keep well over the 1000 lines needed to see a full connect + browse
    /// cycle; each entry is short, so a few thousand costs little memory.
    private let capacity = 4000
    private let lock = NSLock()
    private var entries: [Entry] = []
    /// Index of the oldest entry once the buffer has wrapped.
    private var start = 0
    /// Total lines ever logged (so the UI can show how many were dropped).
    private var total = 0
    private var nextID: UInt64 = 0
    private var version: UInt64 = 0

    nonisolated func append(_ message: String) {
        // DateFormatter is both relatively expensive and unsafe to call
        // concurrently. Logger.log arrives on multiple Go-backed threads, so a
        // shared formatter could serialize or stall those threads (including
        // the main actor). localtime_r is cheap and explicitly thread-safe.
        var now = timeval()
        gettimeofday(&now, nil)
        var seconds = now.tv_sec
        var local = tm()
        localtime_r(&seconds, &local)
        let timestamp = String(
            format: "%02d:%02d:%02d.%03d",
            local.tm_hour,
            local.tm_min,
            local.tm_sec,
            Int(now.tv_usec / 1_000)
        )
        let line = "\(timestamp) \(message)"

        lock.lock()
        defer { lock.unlock() }
        let entry = Entry(id: nextID, line: line)
        nextID &+= 1
        version &+= 1
        total += 1
        if entries.count < capacity {
            entries.append(entry)
        } else {
            entries[start] = entry
            start = (start + 1) % capacity
        }
    }

    /// A consistent copy of the buffered lines and counters, oldest first.
    nonisolated func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let ordered: [Entry]
        if entries.count == capacity {
            ordered = Array(entries[start...] + entries[..<start])
        } else {
            ordered = entries
        }
        return Snapshot(entries: ordered, total: total, version: version)
    }

    nonisolated func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
        start = 0
        total = 0
        version &+= 1
    }
}
