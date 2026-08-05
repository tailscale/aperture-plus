// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

import Foundation

/// Process-wide persistent logging shared by every TailscaleNode in this app.
/// Setup must run before the first node is created. Go runtime panic output,
/// backend logs, and messages written with `log` all use the same filch/logtail.
public enum TailscaleLogging {
    public static func setup(directory: String) throws {
        let result = tailscale_setup_logs(directory)
        guard result == 0 else {
            throw TailscaleError.fromPosixErrCode(result, "process log setup failed")
        }
    }

    public static func log(_ message: String) {
        message.withCString { _ = tailscale_log($0) }
    }

    /// Waits for any current upload, starts one subsequent upload, and waits
    /// for that request. This is an ordering probe, not a content barrier.
    public static func flush(timeout: Duration = .seconds(30)) async throws {
        let components = timeout.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        let bounded = max(1, min(milliseconds, Int64(Int32.max)))
        let result = tailscale_flush_logs(Int32(bounded))
        guard result == 0 else {
            throw TailscaleError.fromPosixErrCode(result, "process log flush failed")
        }
    }
}
