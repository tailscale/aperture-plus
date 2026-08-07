import AppKit
import Combine
import Foundation
import SwiftUI
import Virtualization

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
        private let directory: URL
        private var downloadTask: Task<Void, Never>?
        private var consoleOutput: Pipe?

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

        init(id: UUID) {
            self.id = id
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
                    cleanupFilesOnly()
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

            // Tailvisor uses a VZFileHandleNetworkDeviceAttachment connected to
            // its Go Ethernet/DHCP/gVisor bridge and gives that bridge a separate
            // tsnet identity. Aperture already embeds a Go runtime in
            // TailscaleKit, so linking tailvisor's second 59 MB Go c-archive into
            // this process would duplicate the Go runtime and tsnet state. Keep
            // this first bootable prototype on Apple's disposable NAT attachment;
            // the follow-up integration should move the Ethernet bridge into
            // libtailscale/TailscaleKit and share this workspace's node/dialer.
            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZNATNetworkDeviceAttachment()
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
            cleanupFilesOnly()
        }

        private func cleanupFilesOnly() {
            try? FileManager.default.removeItem(at: directory)
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
    @StateObject private var controller: ExperimentalVMController

    init(id: UUID) {
        self.id = id
        _controller = StateObject(wrappedValue: ExperimentalVMController(id: id))
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
        .navigationTitle("Linux VM (Experimental)")
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
        .accessibilityIdentifier("experimental-vm-view")
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
