// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  WorkspaceVMProtocol.swift
//  Aperture
//
//  Versioned newline-delimited JSON exchanged over the appliance's virtio-vsock
//  control connection. The host accepts unknown event names so a newer guest
//  can report diagnostics without taking down an older host; unsupported
//  protocol versions are rejected explicitly.
//

import Foundation

enum WorkspaceVMProtocolError: LocalizedError, Equatable {
    case malformedLogData

    var errorDescription: String? {
        switch self {
        case .malformedLogData: return "The appliance sent malformed log data."
        }
    }
}

enum WorkspaceVMProtocol {
    /// Guest log stream port. The guest sends ordinary newline-delimited
    /// stdout/stderr; there is deliberately no second guest protocol.
    static let logPort: UInt32 = 5230
}

/// The current guest integration deliberately transports ordinary log lines,
/// not a new guest protocol. The parser is still bounded and line-oriented so
/// a noisy or malicious guest cannot grow host memory without limit.
struct WorkspaceVMLogParser: Sendable {
    private var partial = Data()
    private let maxLineBytes = 64 * 1024

    mutating func append(_ data: Data) -> Result<[String], WorkspaceVMProtocolError> {
        partial.append(data)
        guard partial.count <= maxLineBytes * 2 else { return .failure(.malformedLogData) }
        var lines: [String] = []
        while let newline = partial.firstIndex(of: 0x0a) {
            let line = partial[..<newline]
            partial.removeSubrange(...newline)
            guard line.count <= maxLineBytes,
                  let text = String(data: line, encoding: .utf8) else {
                return .failure(.malformedLogData)
            }
            if !text.isEmpty { lines.append(text) }
        }
        return .success(lines)
    }
}
