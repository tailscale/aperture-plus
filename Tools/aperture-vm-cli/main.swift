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
                let state = try? await localAPI.backendStatus().BackendState
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
                networkAttachment: attachment
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
            for await event in controller.events {
                switch event {
                case .parentStatus(let status): print("parent status: \(status)")
                case .log(let line):
                    serial.append(line)
                    if serial.count > 128_000 { serial.removeFirst(serial.count - 128_000) }
                    print("guest: \(line)")
                    if storageOnly && serial.contains("THUNDERBOOT STORAGE OK:") {
                        print("storage check passed")
                        await controller.stopAndWait()
                        exit(0)
                    }
                case .phase(let phase):
                    print("phase: \(phase.description)")
                    if case .running(let hostname, let addresses) = phase,
                       !storageOnly {
                        let target = addresses.first ?? hostname
                        guard let target, !target.isEmpty else { continue }
                        try await verifyGuestNetwork(host: target, parent: parent)
                        print("guest tailnet HTTP check passed: \(target):7575/metrics")
                        await controller.stopAndWait()
                        exit(0)
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

    private static func verifyGuestNetwork(host: String, parent: TailscaleNode) async throws {
        if host.contains(":") {
            throw CLIError.guestNetwork("IPv6 HTTP target requires URLSession IPv6 proxy support; use the guest IPv4 address")
        }
        let (configuration, proxy) = try await URLSessionConfiguration.tailscaleSession(parent)
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        let requestHost = host.contains(":") ? "[\(host)]" : host
        print("guest HTTP target: http://\(requestHost):7575/metrics via parent SOCKS \(proxy.address)")
        guard let url = URL(string: "http://\(requestHost):7575/metrics") else {
            throw CLIError.guestNetwork("invalid guest hostname")
        }
        var lastError = "no response"
        for attempt in 1...12 {
            do {
                let request = URLRequest(url: url, timeoutInterval: 5)
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastError = "non-HTTP response"
                    continue
                }
                if http.statusCode == 200 {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    guard body.contains("thundersnap") else {
                        throw CLIError.guestNetwork("metrics response did not contain thundersnap")
                    }
                    return
                }
                lastError = "HTTP \(http.statusCode)"
            } catch {
                lastError = error.localizedDescription
            }
            print("guest HTTP attempt \(attempt)/12: \(lastError)")
            try await Task.sleep(for: .seconds(1))
        }
        throw CLIError.guestNetwork(lastError)
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
