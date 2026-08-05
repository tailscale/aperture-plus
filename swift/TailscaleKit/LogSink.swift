// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

import Foundation

/// A generic interface for sinking log messages from the Swift wrapper
/// and go
public protocol LogSink: Sendable {
    /// Called for Swift wrapper logs. Go backend logs use the process-wide
    /// logtail configured by TailscaleLogging.setup.
    func log(_ message: String)
}

/// Dumps all internal logs to NSLog and go logs to stdout
public struct DefaultLogger: LogSink {
    public func log(_ message: String) {
        NSLog(message)
    }
}

/// Discards all logs
public struct BlackholeLogger: LogSink {
    public func log(_ message: String) {
        // Go back to the Shadow!
    }
}
