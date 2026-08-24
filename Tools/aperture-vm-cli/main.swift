// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

import ApertureVM
import Foundation
import TailscaleKit

@main
struct ApertureVMCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let authKey = try requiredValue(for: "--auth-key", in: arguments)
            let workspaceID = UUID(uuidString: try value(for: "--workspace-id", in: arguments) ?? "") ?? UUID()
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "ApertureVM", directoryHint: .isDirectory)
            let workspace = base.appending(path: "Workspaces/\(workspaceID.uuidString)", directoryHint: .isDirectory)
            let state = workspace.appending(path: "ParentState", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)

            try TailscaleLogging.setup(directory: state.appending(path: "logs", directoryHint: .isDirectory).path)
            let parent = try TailscaleNode(config: Configuration(
                hostName: "aperture-vm-cli-\(workspaceID.uuidString.prefix(8))",
                path: state.path,
                authKey: authKey,
                controlURL: kDefaultControlURL,
                ephemeral: true
            ), logger: nil)
            defer { Task { try? await parent.close() } }
            print("starting parent workspace Tailscale node")
            // TailscaleNode.init starts the node and intentionally does not
            // call up(): up() blocks at NeedsLogin and would prevent the
            // diagnostic from observing the same lifecycle as the GUI.
            let localAPI = LocalAPIClient(localNode: parent, logger: nil)
            var parentRunning = false
            for _ in 0..<60 {
                let parentStatus = try? await localAPI.backendStatus()
                let state = parentStatus?.BackendState
                print("parent state: \(state ?? "unknown")")
                if state == "Running" { parentRunning = true; break }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard parentRunning else { throw CLIError.parentNotRunning }
            let attachment = try await CLIWorkspaceNetworkAttachment(node: parent, id: workspaceID).opened()
            let storageOnly = arguments.contains("--storage-only")
            let timeout = TimeInterval(try value(for: "--timeout", in: arguments) ?? "120") ?? 120
            let controller = VMController(configuration: VMConfiguration(
                workspaceID: workspaceID,
                workspaceDirectory: workspace,
                artifactRoots: ApplianceArtifacts.defaultRoots(bundle: Bundle.main),
                storageOnly: storageOnly,
                guestAuthKey: authKey,
                networkMode: .custom(attachment)
            ))
            print("workspace container: \(workspace.path)")
            print("bundled appliance: app bundle Contents/Resources")
            print("parent workspace node and VM network bridge are ready")
            print("starting guest VM")
            controller.start()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                fputs("aperture-vm: timed out after \(timeout)s\n", stderr)
                controller.stop()
                exit(124)
            }
            var serial = ""
            var guestIPv4: String?
            var guestHostname: String?
            var guestHTTPReady = false
            var guestNetworkChecked = false
            for await event in controller.events {
                switch event {
                case .parentStatus(let status): print("parent status: \(status)")
                case .log(let line):
                    serial.append(line)
                    if serial.count > 128_000 { serial.removeFirst(serial.count - 128_000) }
                    print("guest: \(line)")
                    if let ips = Self.extractIPv4s(from: line), let ip = ips.first {
                        guestIPv4 = ip
                    }
                    if let hostname = Self.value(after: "tsnet hostname:", in: line) {
                        guestHostname = hostname
                    }
                    if line.localizedCaseInsensitiveContains("HTTP server listening on port 7575") {
                        guestHTTPReady = true
                    }
                    if !storageOnly && guestHTTPReady && !guestNetworkChecked,
                       let target = guestIPv4 ?? guestHostname {
                        guestNetworkChecked = true
                        try await verifyGuestNetwork(host: target, parent: parent)
                        print("guest tailnet HTTP check passed: \(target):7575/metrics")
                        await controller.stopAndWait()
                        exit(0)
                    }
                    if storageOnly && serial.contains("THUNDERBOOT STORAGE OK:") {
                        print("storage check passed")
                        await controller.stopAndWait()
                        exit(0)
                    }
                case .phase(let phase):
                    print("phase: \(phase.description)")
                    if case .running(let hostname, let addresses) = phase,
                       !storageOnly, let hostname {
                        print("guest enrolled: hostname=\(hostname), addresses=\(addresses.joined(separator: ","))")
                    }
                    if case .failed(let stage, let message) = phase {
                        fputs("VM failed at \(stage): \(message)\n", stderr)
                        await controller.stopAndWait()
                        exit(1)
                    }
                }
            }
        } catch {
            fputs("aperture-vm: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func decodeChunked(_ body: String) -> String {
        var output = ""
        var remainder = body
        while let lineEnd = remainder.range(of: "\r\n") {
            guard let size = Int(remainder[..<lineEnd.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines), radix: 16), size > 0 else { break }
            let contentStart = lineEnd.upperBound
            guard remainder.distance(from: contentStart, to: remainder.endIndex) >= size else { break }
            let contentEnd = remainder.index(contentStart, offsetBy: size)
            output.append(contentsOf: remainder[contentStart..<contentEnd])
            remainder = String(remainder[remainder.index(contentEnd, offsetBy: min(2, remainder.distance(from: contentEnd, to: remainder.endIndex)))...])
        }
        return output
    }

    private static func extractIPv4s(from line: String) -> [String]? {
        let values = line.replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
            .filter { $0.split(separator: ".").count == 4 && $0.allSatisfy { $0.isNumber || $0 == "." } }
        return values.isEmpty ? nil : values
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard let range = line.lowercased().range(of: prefix) else { return nil }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func verifyGuestNetwork(host: String, parent: TailscaleNode) async throws {
        guard !host.contains(":") else {
            throw CLIError.guestNetwork("IPv6 HTTP target requires a separate IPv6 SOCKS test")
        }
        let proxy = try await parent.loopback()
        guard let proxyHost = proxy.ip, let proxyPort = proxy.port else {
            throw CLIError.guestNetwork("parent loopback proxy unavailable")
        }
        print("guest HTTP target: http://\(host):7575/metrics via parent SOCKS \(proxyHost):\(proxyPort)")
        var lastError = "no response"
        for attempt in 1...12 {
            do {
                let body = try rawSOCKSHTTP(proxyHost: proxyHost,
                                            proxyPort: proxyPort,
                                            username: "tsnet",
                                            password: proxy.proxyCredential,
                                            targetHost: host,
                                            targetPort: 7575)
                guard body.contains("go_gc_duration_seconds") else {
                    let preview = body.prefix(240).replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
                    throw CLIError.guestNetwork("metrics response missing expected Prometheus metric: \(preview)")
                }
                return
            } catch {
                lastError = error.localizedDescription
            }
            print("guest HTTP attempt \(attempt)/12: \(lastError)")
            try await Task.sleep(for: .seconds(1))
        }
        throw CLIError.guestNetwork(lastError)
    }

    private static func rawSOCKSHTTP(proxyHost: String, proxyPort: Int,
                                     username: String, password: String,
                                     targetHost: String, targetPort: Int) throws -> String {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError.guestNetwork("socket: \(String(cString: strerror(errno)))") }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(proxyPort).bigEndian)
        guard inet_pton(AF_INET, proxyHost, &address.sin_addr) == 1 else {
            throw CLIError.guestNetwork("invalid SOCKS address \(proxyHost)")
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw CLIError.guestNetwork("SOCKS connect: \(String(cString: strerror(errno)))") }
        func send(_ data: Data) throws {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < data.count {
                    let n = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset, 0)
                    guard n > 0 else { throw CLIError.guestNetwork("SOCKS write failed") }
                    offset += n
                }
            }
        }
        func receive(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                var chunk = Data(repeating: 0, count: count - data.count)
                let chunkSize = chunk.count
                let n = chunk.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, chunkSize, 0) }
                guard n > 0 else { throw CLIError.guestNetwork("SOCKS read failed") }
                data.append(chunk.prefix(n))
            }
            return data
        }
        try send(Data([5, 1, 2]))
        let greeting = try receive(2)
        guard greeting[0] == 5 else { throw CLIError.guestNetwork("SOCKS auth negotiation failed") }
        if greeting[1] == 2 {
            let user = Array(username.utf8), pass = Array(password.utf8)
            try send(Data([1, UInt8(user.count)]) + Data(user) + Data([UInt8(pass.count)]) + Data(pass))
            let auth = try receive(2)
            guard auth[1] == 0 else { throw CLIError.guestNetwork("SOCKS authentication rejected") }
        } else if greeting[1] == 0 {
            // Some SOCKS implementations do not require credentials.
        } else {
            throw CLIError.guestNetwork("SOCKS server selected unsupported auth method \(greeting[1])")
        }
        print("SOCKS request target: \(targetHost):\(targetPort)")
        var targetAddress = in_addr()
        guard inet_pton(AF_INET, targetHost, &targetAddress) == 1 else {
            throw CLIError.guestNetwork("guest address is not IPv4")
        }
        var request = Data([5, 1, 0, 1])
        withUnsafeBytes(of: targetAddress.s_addr) { request.append(contentsOf: $0) }
        request.append(contentsOf: [UInt8(targetPort >> 8), UInt8(targetPort & 255)])
        try send(request)
        let response = try receive(4)
        print("SOCKS CONNECT reply: version=\(response[0]) code=\(response[1])")
        guard response[1] == 0 else { throw CLIError.guestNetwork("SOCKS CONNECT reply \(response[1])") }
        let addressLength: Int
        switch response[3] {
        case 1: addressLength = 4
        case 3: addressLength = Int(try receive(1)[0])
        case 4: addressLength = 16
        default: throw CLIError.guestNetwork("unknown SOCKS address type")
        }
        _ = try receive(addressLength + 2)
        try send(Data("GET /metrics HTTP/1.1\r\nHost: \(targetHost):\(targetPort)\r\nConnection: close\r\n\r\n".utf8))
        var result = Data()
        var buffer = Data(repeating: 0, count: 4096)
        let bufferSize = buffer.count
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, bufferSize, 0) }
            if n <= 0 { break }
            result.append(buffer.prefix(n))
            guard result.count < 1_000_000 else { throw CLIError.guestNetwork("HTTP response too large") }
        }
        guard let text = String(data: result, encoding: .utf8),
              (text.hasPrefix("HTTP/1.0 200") || text.hasPrefix("HTTP/1.1 200")) else {
            let prefix = String(data: result.prefix(80), encoding: .utf8) ?? result.prefix(20).map { String(format: "%02x", $0) }.joined()
            throw CLIError.guestNetwork("unexpected HTTP response: \(prefix)")
        }
        // thundersnapd's metrics endpoint uses HTTP chunked transfer coding.
        // Decode the body before checking for the daemon's own metric names.
        if let separator = text.range(of: "\r\n\r\n") {
            let headers = String(text[..<separator.lowerBound])
            let body = String(text[separator.upperBound...])
            if headers.localizedCaseInsensitiveContains("transfer-encoding: chunked") {
                return Self.decodeChunked(body)
            }
        }
        return text
    }

    private static func value(for name: String, in arguments: [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        guard arguments.index(after: index) != arguments.endIndex else {
            throw CLIError.missingValue(name)
        }
        return arguments[arguments.index(after: index)]
    }

    private static func requiredValue(for name: String, in arguments: [String]) throws -> String {
        guard let value = try value(for: name, in: arguments), !value.isEmpty else {
            throw CLIError.missingValue(name)
        }
        return value
    }
}

@MainActor
private final class CLIWorkspaceNetworkAttachment: VMNetworkAttachment {
    private let node: TailscaleNode
    private let id: UUID
    private var bridge: VMNetworkBridge?
    private var client: FileHandle?
    private var clientURL: URL?
    private var serverURL: URL?

    init(node: TailscaleNode, id: UUID) {
        self.node = node
        self.id = id
    }

    func opened() async throws -> CLIWorkspaceNetworkAttachment {
        let token = String(id.uuidString.prefix(12)).lowercased()
        let temporary = FileManager.default.temporaryDirectory
        let server = temporary.appending(path: "ap-cli-vm-\(token)-s")
        let clientURL = temporary.appending(path: "ap-cli-vm-\(token)-c")
        let bridge = try await node.startVMNetworkBridge(socketURL: server)
        do {
            let client = try Self.connectedUnixDatagram(clientURL: clientURL, serverURL: server)
            self.bridge = bridge
            self.client = client
            self.clientURL = clientURL
            self.serverURL = server
            return self
        } catch {
            try? await bridge.close()
            throw error
        }
    }

    func open() async throws -> (FileHandle, AnyObject) {
        guard let client else { throw CLIError.socket("network attachment was not opened") }
        return (client, self)
    }

    func close() async {
        client?.closeFile(); client = nil
        if let clientURL { unlink(clientURL.path) }
        if let serverURL { unlink(serverURL.path) }
        try? await bridge?.close(); bridge = nil
    }

    private static func connectedUnixDatagram(clientURL: URL, serverURL: URL) throws -> FileHandle {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw CLIError.socket(String(cString: strerror(errno))) }
        var closeDescriptor = true
        defer { if closeDescriptor { Darwin.close(descriptor) } }
        unlink(clientURL.path)
        func address(_ path: String) throws -> sockaddr_un {
            guard path.utf8.count < MemoryLayout<sockaddr_un>.size - 1 else { throw CLIError.socket("socket path too long") }
            var result = sockaddr_un(); result.sun_family = sa_family_t(AF_UNIX)
            path.withCString { source in withUnsafeMutablePointer(to: &result.sun_path.0) { _ = strcpy($0, source) } }
            return result
        }
        var local = try address(clientURL.path)
        let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { throw CLIError.socket("bind: \(String(cString: strerror(errno)))") }
        var remote = try address(serverURL.path)
        let connected = withUnsafePointer(to: &remote) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw CLIError.socket("connect: \(String(cString: strerror(errno)))") }
        closeDescriptor = false
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

private enum CLIError: LocalizedError {
    case missingValue(String)
    case socket(String)
    case parentNotRunning
    case guestNetwork(String)
    var errorDescription: String? {
        switch self {
        case .missingValue(let name): return "missing value for \(name)"
        case .socket(let message): return "network socket: \(message)"
        case .parentNotRunning: return "parent Tailscale node did not reach Running"
        case .guestNetwork(let message): return "guest network check failed: \(message)"
        }
    }
}
