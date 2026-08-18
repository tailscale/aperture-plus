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

struct WorkspaceVMEvent: Codable, Equatable, Sendable {
    static let supportedVersion = 1

    let version: Int
    let event: String
    let device: String?
    let authURL: String?
    let hostname: String?
    let ips: [String]?
    let stage: String?
    let message: String?

    var isSupported: Bool { version == Self.supportedVersion }

    init(version: Int = Self.supportedVersion,
         event: String,
         device: String? = nil,
         authURL: String? = nil,
         hostname: String? = nil,
         ips: [String]? = nil,
         stage: String? = nil,
         message: String? = nil) {
        self.version = version
        self.event = event
        self.device = device
        self.authURL = authURL
        self.hostname = hostname
        self.ips = ips
        self.stage = stage
        self.message = message
    }
}

enum WorkspaceVMProtocolError: LocalizedError, Equatable {
    case malformedJSON
    case unsupportedVersion(Int)
    case missingEvent

    var errorDescription: String? {
        switch self {
        case .malformedJSON: return "The appliance sent malformed control data."
        case .unsupportedVersion(let version):
            return "The appliance uses unsupported control protocol version \(version)."
        case .missingEvent: return "The appliance control message has no event."
        }
    }
}

struct WorkspaceVMProtocolParser: Sendable {
    private var partial = Data()
    private let maxLineBytes = 64 * 1024

    mutating func append(_ data: Data) -> Result<[WorkspaceVMEvent], WorkspaceVMProtocolError> {
        partial.append(data)
        guard partial.count <= maxLineBytes * 2 else { return .failure(.malformedJSON) }
        var events: [WorkspaceVMEvent] = []
        while let newline = partial.firstIndex(of: 0x0a) {
            let line = partial[..<newline]
            partial.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let event = try? JSONDecoder().decode(WorkspaceVMEvent.self, from: line) else {
                return .failure(.malformedJSON)
            }
            guard !event.event.isEmpty else { return .failure(.missingEvent) }
            guard event.isSupported else { return .failure(.unsupportedVersion(event.version)) }
            events.append(event)
        }
        return .success(events)
    }
}
