//  Created by Jonathan Nobels on 2025-12-18.
//

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
    }
}
