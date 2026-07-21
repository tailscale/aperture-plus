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

let logger = Logger()

struct Logger: TailscaleKit.LogSink {
    var logFileHandle: Int32?

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
