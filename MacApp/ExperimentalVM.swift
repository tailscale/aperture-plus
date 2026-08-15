import AppKit
import Combine
import Foundation
import SwiftUI
import TailscaleKit
import Virtualization

/// Value carried by a VM window. Retaining the owning workspace ID now makes
/// the ownership decision explicit and gives the future TailscaleKit Ethernet
/// bridge the exact existing node it must use, rather than creating a second
/// tsnet identity. The VM UUID keeps every disposable window independent.
struct ExperimentalVMRequest: Codable, Hashable {
    let id: UUID
    let workspaceID: UUID
}

/// Disposable Linux VM prototype. Each window owns one controller and all of
/// its files live under a unique temporary directory. Closing the window stops
/// the VM and removes that directory; there is intentionally no saved state or
/// persistent disk yet.
@MainActor
final class ExperimentalVMController: NSObject, ObservableObject, VZVirtualMachineDelegate {
    enum Phase: Equatable {
        case downloading(Double)
        case preparing
        case starting
        case running
        case stopped
        case failed(String)
    }

    @Published var phase: Phase = .preparing
    @Published var virtualMachine: VZVirtualMachine?
    @Published var consoleText = ""

    fileprivate let id: UUID
    private let workspace: Workspace?
    private let directory: URL
    private var downloadTask: Task<Void, Never>?
    private var consoleOutput: Pipe?
    private var networkBridge: TailscaleKit.VMNetworkBridge?
    private var networkFileHandle: FileHandle?
    private var networkClientURL: URL?

    // Small ARM64 EFI-bootable Linux image. It is cached once outside the
    // disposable per-VM directory; VM state and disks are never retained.
    private static let isoURL = URL(string: "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/alpine-virt-3.22.2-aarch64.iso")!
    private static let isoName = "alpine-virt-3.22.2-aarch64.iso"
    private static var cacheDirectory: URL {
        // Use a stable, bundle-scoped cache location. `URLSession.download`
        // writes to a temporary file, then this survives subsequent VMs.
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "io.tailscale.Aperture/ExperimentalVM",
                       directoryHint: .isDirectory)
    }

    init(id: UUID, workspace: Workspace?) {
        self.id = id
        self.workspace = workspace
        directory = FileManager.default.temporaryDirectory
            .appending(path: "ApertureVM-\(id.uuidString)", directoryHint: .isDirectory)
        super.init()
    }

    func start() {
        guard downloadTask == nil, virtualMachine == nil else { return }
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let iso = try await Self.cachedISO { [weak self] progress in
                    self?.phase = .downloading(progress)
                }
                guard !Task.isCancelled else { return }
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)
                phase = .preparing
                try await startNetworkBridge()
                let configuration = try makeConfiguration(iso: iso)
                let vm = VZVirtualMachine(configuration: configuration)
                vm.delegate = self
                virtualMachine = vm
                phase = .starting
                try await vm.start()
                phase = .running
            } catch is CancellationError {
                cleanup()
            } catch {
                phase = .failed(error.localizedDescription)
                cleanup()
            }
        }
    }

    func stop() {
        downloadTask?.cancel()
        downloadTask = nil
        guard let vm = virtualMachine else {
            cleanup()
            return
        }
        virtualMachine = nil
        phase = .stopped
        Task {
            if vm.state == .running || vm.state == .paused {
                try? await vm.stop()
            }
            cleanup()
        }
    }

    private func makeConfiguration(iso: URL) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = min(max(2, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                              VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        config.memorySize = min(max(1 * 1024 * 1024 * 1024,
                                    VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                                VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let platform = VZGenericPlatformConfiguration()
        config.platform = platform

        let variables = directory.appending(path: "EFIVariableStore")
        let variableStore = try VZEFIVariableStore(creatingVariableStoreAt: variables)
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = variableStore
        config.bootLoader = bootLoader

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(
            widthInPixels: 1280, heightInPixels: 800)]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: iso, readOnly: true)
        config.storageDevices = [VZUSBMassStorageDeviceConfiguration(attachment: isoAttachment)]

        // The attachment carries raw Ethernet frames to tailvisor's bridge,
        // now compiled into TailscaleKit and borrowing this VM window's owning
        // workspace node. It does not create a second tsnet identity/runtime.
        guard let networkFileHandle else {
            throw VMNetworkError.bridgeUnavailable
        }
        let network = VZVirtioNetworkDeviceConfiguration()
        network.macAddress = VZMACAddress(string: Self.macAddress(for: id))!
        network.attachment = VZFileHandleNetworkDeviceAttachment(
            fileHandle: networkFileHandle
        )
        config.networkDevices = [network]

        let output = Pipe()
        consoleOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.consoleText.append(text)
                if let count = self?.consoleText.count, count > 40_000 {
                    self?.consoleText.removeFirst(count - 40_000)
                }
            }
        }
        let serialInput = Pipe()
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: serialInput.fileHandleForReading,
            fileHandleForWriting: output.fileHandleForWriting)
        config.serialPorts = [serial]

        try config.validate()
        return config
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor [weak self] in
            self?.phase = .stopped
            self?.virtualMachine = nil
            self?.cleanup()
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine,
                                didStopWithError error: any Error) {
        Task { @MainActor [weak self] in
            self?.phase = .failed(error.localizedDescription)
            self?.virtualMachine = nil
            self?.cleanupFilesOnly()
        }
    }

    private func cleanup() {
        virtualMachine = nil
        consoleOutput?.fileHandleForReading.readabilityHandler = nil
        consoleOutput = nil
        let bridge = networkBridge
        networkBridge = nil
        Task {
            try? await bridge?.close()
            networkFileHandle?.closeFile()
            networkFileHandle = nil
            if let networkClientURL {
                unlink(networkClientURL.path)
                self.networkClientURL = nil
            }
            cleanupFilesOnly()
        }
    }

    private func cleanupFilesOnly() {
        try? FileManager.default.removeItem(at: directory)
    }

    private enum VMNetworkError: LocalizedError {
        case noWorkspace
        case bridgeUnavailable
        case socketFailure(String)

        var errorDescription: String? {
            switch self {
            case .noWorkspace:
                "The owning workspace is no longer available."
            case .bridgeUnavailable:
                "The workspace VM network bridge is unavailable."
            case .socketFailure(let detail):
                "Could not attach the VM network socket: \(detail)"
            }
        }
    }

    private func startNetworkBridge() async throws {
        guard let workspace else { throw VMNetworkError.noWorkspace }
        // sockaddr_un.sun_path is only 104 bytes on Darwin. The sandbox temp
        // root is already long, so keep both endpoint leaf names compact.
        let token = String(id.uuidString.prefix(12)).lowercased()
        let temporary = FileManager.default.temporaryDirectory
        let serverURL = temporary.appending(path: "avm-\(token)-s")
        let clientURL = temporary.appending(path: "avm-\(token)-c")
        let bridge = try await workspace.manager.startVMNetworkBridge(socketURL: serverURL)
        do {
            networkFileHandle = try Self.connectedUnixDatagram(
                clientURL: clientURL,
                serverURL: serverURL
            )
            networkClientURL = clientURL
            networkBridge = bridge
        } catch {
            try? await bridge.close()
            throw error
        }
    }

    private static func connectedUnixDatagram(clientURL: URL,
                                               serverURL: URL) throws -> FileHandle {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw VMNetworkError.socketFailure(String(cString: strerror(errno)))
        }
        var shouldClose = true
        defer { if shouldClose { Darwin.close(descriptor) } }
        unlink(clientURL.path)

        func address(for path: String) throws -> sockaddr_un {
            guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
                throw VMNetworkError.socketFailure("Unix socket path is too long")
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            path.withCString { source in
                withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                    _ = strcpy(destination, source)
                }
            }
            return address
        }

        var client = try address(for: clientURL.path)
        let bound = withUnsafePointer(to: &client) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            throw VMNetworkError.socketFailure("bind: \(String(cString: strerror(errno)))")
        }

        var server = try address(for: serverURL.path)
        let connected = withUnsafePointer(to: &server) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw VMNetworkError.socketFailure("connect: \(String(cString: strerror(errno)))")
        }
        shouldClose = false
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func macAddress(for id: UUID) -> String {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0.prefix(5)) }
        return ([0x02] + bytes).map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private static func cachedISO(progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let cache = cacheDirectory
        let destination = cache.appending(path: isoName)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        progress(0)
        let (temporary, response) = try await URLSession.shared.download(from: isoURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
        return destination
    }
}

struct ExperimentalVMView: View {
    let id: UUID
    /// Retains the owning workspace (and therefore its existing tsnet node)
    /// for the VM window's lifetime. The NAT prototype does not consume it yet;
    /// the userspace bridge will be handed `workspace.manager`/its node.
    let workspace: Workspace?
    @StateObject private var controller: ExperimentalVMController

    init(id: UUID, workspace: Workspace?) {
        self.id = id
        self.workspace = workspace
        _controller = StateObject(
            wrappedValue: ExperimentalVMController(id: id, workspace: workspace)
        )
    }

    var body: some View {
        ZStack {
            Color.black
            if let vm = controller.virtualMachine {
                VirtualMachineView(virtualMachine: vm)
            }
            statusOverlay
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle(vmTitle)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
        .accessibilityIdentifier("experimental-vm-view")
    }

    private var vmTitle: String {
        guard let workspace else { return "Linux VM (Experimental)" }
        return "Linux VM — \(workspace.identifier) (Experimental)"
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch controller.phase {
        case .downloading(let fraction):
            VStack(spacing: 12) {
                ProgressView(value: fraction)
                    .frame(width: 280)
                Text("Downloading Alpine Linux…")
            }
            .foregroundStyle(.white)
        case .preparing:
            ProgressView("Preparing disposable VM…")
                .foregroundStyle(.white)
        case .starting:
            ProgressView("Booting Linux…")
                .foregroundStyle(.white)
        case .running:
            EmptyView()
        case .stopped:
            ContentUnavailableView("VM Stopped", systemImage: "stop.circle")
                .foregroundStyle(.white)
        case .failed(let message):
            ContentUnavailableView("VM Failed", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
                .foregroundStyle(.white)
        }
    }
}

private struct VirtualMachineView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = true
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        view.virtualMachine = virtualMachine
    }
}
