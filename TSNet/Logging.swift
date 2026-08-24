// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

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

// `nonisolated` (and `let`) so this Sendable global is callable from the
// nonisolated contexts that use it, including Go-backed callback threads.
nonisolated let logger = Logger()

struct Logger: TailscaleKit.LogSink {

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

        // Mirror Swift/application diagnostics into the same persistent
        // process-wide logtail as every tsnet backend and Go runtime stderr.
        TailscaleLogging.log(message)
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
        /// Entries appended since the most recent explicit clear.
        let total: Int
        let version: UInt64
        /// Identity of this in-memory ring object. It changes only if the
        /// process creates a new LogRing singleton.
        let incarnation: UUID
        /// Process-lifetime counters; unlike `total`, clear() does not reset them.
        let lifetimeAppends: UInt64
        let lifetimeWraps: UInt64
        let lifetimeClears: UInt64
        let lifetimeSocksLines: UInt64
        let lifetimeStatusRequests: UInt64
        let lifetimeBusErrors: UInt64
        let maxAppendsPerSecond: UInt64
        let spinTrips: UInt64
        let oldestID: UInt64?
        let newestID: UInt64?
    }

    /// Keep well over the 1000 lines needed to see a full connect + browse
    /// cycle; each entry is short, so a few thousand costs little memory.
    private let capacity = 4000
    private let lock = NSLock()
    private let incarnation = UUID()
    private var entries: [Entry] = []
    /// Index of the oldest entry once the buffer has wrapped.
    private var start = 0
    /// Total lines ever logged (so the UI can show how many were dropped).
    private var total = 0
    private var nextID: UInt64 = 0
    private var version: UInt64 = 0
    private var lifetimeAppends: UInt64 = 0
    private var lifetimeWraps: UInt64 = 0
    private var lifetimeClears: UInt64 = 0
    private var lifetimeSocksLines: UInt64 = 0
    private var lifetimeStatusRequests: UInt64 = 0
    private var lifetimeBusErrors: UInt64 = 0
    private var rateSecond: Int64 = 0
    private var appendsThisSecond: UInt64 = 0
    private var maxAppendsPerSecond: UInt64 = 0
    private var spinTrips: UInt64 = 0
    private var spinTripArmed = true

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
        lifetimeAppends &+= 1
        if message.contains("socks[") || message.contains("sockslog:") {
            lifetimeSocksLines &+= 1
        }
        if message.hasPrefix("Requesting status via ") { lifetimeStatusRequests &+= 1 }
        if message.hasPrefix("Bus watcher error:") { lifetimeBusErrors &+= 1 }
        let secondBucket = Int64(seconds)
        if secondBucket == rateSecond {
            appendsThisSecond &+= 1
        } else {
            maxAppendsPerSecond = max(maxAppendsPerSecond, appendsThisSecond)
            rateSecond = secondBucket
            appendsThisSecond = 1
        }
        maxAppendsPerSecond = max(maxAppendsPerSecond, appendsThisSecond)
        if appendsThisSecond >= 1_000, spinTripArmed {
            spinTripArmed = false
            spinTrips &+= 1
            let recent: String
            if entries.isEmpty {
                recent = "<ring empty>"
            } else {
                let ordered = entries.count == capacity
                    ? Array(entries[start...] + entries[..<start])
                    : entries
                recent = ordered.suffix(80).map(\.line).joined(separator: "\n")
            }
            TailscaleLogging.log("fatal error: Aperture detected log spin loop rate=\(appendsThisSecond)/s appends=\(lifetimeAppends) wraps=\(lifetimeWraps) busErrors=\(lifetimeBusErrors)\n\(recent)")
            Darwin.abort()
        }
        if entries.count < capacity {
            entries.append(entry)
        } else {
            entries[start] = entry
            start = (start + 1) % capacity
            lifetimeWraps &+= 1
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
        return Snapshot(
            entries: ordered,
            total: total,
            version: version,
            incarnation: incarnation,
            lifetimeAppends: lifetimeAppends,
            lifetimeWraps: lifetimeWraps,
            lifetimeClears: lifetimeClears,
            lifetimeSocksLines: lifetimeSocksLines,
            lifetimeStatusRequests: lifetimeStatusRequests,
            lifetimeBusErrors: lifetimeBusErrors,
            maxAppendsPerSecond: maxAppendsPerSecond,
            spinTrips: spinTrips,
            oldestID: ordered.first?.id,
            newestID: ordered.last?.id
        )
    }

    nonisolated func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
        start = 0
        total = 0
        lifetimeClears &+= 1
        version &+= 1
    }
}
