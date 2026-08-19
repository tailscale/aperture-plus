import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI
import TailscaleKit
import Virtualization

/// Native-macOS owner of all workspace appliances. It is intentionally kept
/// above any SwiftUI window: closing a browser or console window cannot stop a
/// VM, and the same controller is reused when a console is reopened.
@MainActor
final class WorkspaceVMSupervisor: NSObject, ObservableObject, WorkspaceVMManaging {
    @Published private(set) var revision = 0
    var changes: AnyPublisher<Void, Never> {
        $revision.map { _ in () }.eraseToAnyPublisher()
    }

    private weak var workspaceManager: WorkspaceManager?
    private var controllers: [UUID: WorkspaceVMController] = [:]
    private var launchTask: Task<Void, Never>?

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        super.init()
        discover()
    }

    deinit { launchTask?.cancel() }

    func discover() {
        guard let workspaceManager else { return }
        for workspace in workspaceManager.workspaces {
            if WorkspaceStore.loadVMMetadata(workspace.id) != nil {
                _ = controller(for: workspace)
            }
        }
        revision += 1
    }

    func startDesiredVMs() {
        launchTask?.cancel()
        launchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // The workspace node must be alive before the VM bridge is created.
            // Controllers themselves wait for that node and report a useful
            // failure if the workspace has not reached a usable state.
            for workspace in workspaceManager?.workspaces ?? [] {
                guard let metadata = WorkspaceStore.loadVMMetadata(workspace.id),
                      metadata.desiredState == .running else { continue }
                controller(for: workspace).start()
            }
        }
    }

    func vmStatus(for workspaceID: UUID) -> WorkspaceVMStatus {
        guard workspaceManager?.workspace(id: workspaceID) != nil else {
            return .absent
        }
        if let controller = controllers[workspaceID] {
            return controller.status
        }
        guard let metadata = WorkspaceStore.loadVMMetadata(workspaceID) else {
            return .absent
        }
        return WorkspaceVMStatus(phase: .stopped,
                                 desiredState: metadata.desiredState,
                                 hasPersistentDisk: FileManager.default.fileExists(
                                    atPath: WorkspaceStore.vmDiskURL(workspaceID).path))
    }

    func createAndStartVM(for workspace: Workspace) {
        let metadata = WorkspaceStore.loadVMMetadata(workspace.id)
            ?? WorkspaceVMMetadata(desiredState: .running)
        WorkspaceStore.saveVMMetadata(metadata.withDesiredState(.running), workspaceID: workspace.id)
        controller(for: workspace).start()
        revision += 1
    }

    func startVM(for workspace: Workspace) {
        guard var metadata = WorkspaceStore.loadVMMetadata(workspace.id) else {
            createAndStartVM(for: workspace)
            return
        }
        metadata.desiredState = .running
        WorkspaceStore.saveVMMetadata(metadata, workspaceID: workspace.id)
        controller(for: workspace).start()
        revision += 1
    }

    func stopVM(for workspace: Workspace) {
        guard var metadata = WorkspaceStore.loadVMMetadata(workspace.id) else { return }
        metadata.desiredState = .stopped
        WorkspaceStore.saveVMMetadata(metadata, workspaceID: workspace.id)
        controller(for: workspace).stop()
        revision += 1
    }

    func restartVM(for workspace: Workspace) {
        guard var metadata = WorkspaceStore.loadVMMetadata(workspace.id) else { return }
        metadata.desiredState = .running
        WorkspaceStore.saveVMMetadata(metadata, workspaceID: workspace.id)
        controller(for: workspace).restart()
        revision += 1
    }

    func deleteVM(for workspace: Workspace) {
        guard let controller = controllers[workspace.id] else {
            WorkspaceStore.removeVM(workspace.id)
            revision += 1
            return
        }
        controller.delete { [weak self] in
            WorkspaceStore.removeVM(workspace.id)
            self?.controllers.removeValue(forKey: workspace.id)
            self?.revision += 1
        }
    }

    func deleteVMAndWait(for workspace: Workspace) async {
        guard let controller = controllers[workspace.id] else {
            WorkspaceStore.removeVM(workspace.id)
            revision += 1
            return
        }
        await controller.deleteAndWait()
        WorkspaceStore.removeVM(workspace.id)
        controllers.removeValue(forKey: workspace.id)
        revision += 1
    }

    func openVMConsole(for workspace: Workspace) {
        controller(for: workspace).openConsole()
    }

    func signInToVM(for workspace: Workspace) {
        guard case .waitingForLogin(let url) = vmStatus(for: workspace.id).phase,
              let parsed = URL(string: url),
              ["https", "http"].contains(parsed.scheme?.lowercased()) else { return }
        NSWorkspace.shared.open(parsed)
    }

    private func controller(for workspace: Workspace) -> WorkspaceVMController {
        if let existing = controllers[workspace.id] { return existing }
        let created = WorkspaceVMController(workspace: workspace) { [weak self] in
            self?.revision += 1
        }
        controllers[workspace.id] = created
        return created
    }
}

private extension WorkspaceVMMetadata {
    func withDesiredState(_ state: WorkspaceVMDesiredState) -> WorkspaceVMMetadata {
        var copy = self
        copy.desiredState = state
        return copy
    }
}

@MainActor
private final class WorkspaceVMController: NSObject, ObservableObject, VZVirtualMachineDelegate {
    let workspace: Workspace
    let workspaceID: UUID
    private let changed: () -> Void

    @Published private(set) var status: WorkspaceVMStatus
    @Published private(set) var consoleText = ""

    private var metadata: WorkspaceVMMetadata?
    private var virtualMachine: VZVirtualMachine?
    private var startTask: Task<Void, Never>?
    private var networkBridge: TailscaleKit.VMNetworkBridge?
    private var networkFileHandle: FileHandle?
    private var networkClientURL: URL?
    private var consoleOutput: Pipe?
    private var consoleInput: FileHandle?
    private var consoleWindow: NSWindow?
    private var controlListener: VZVirtioSocketListener?
    private var controlDelegate: WorkspaceVMVsockDelegate?
    private var controlConnection: VZVirtioSocketConnection?
    private var controlHandle: FileHandle?
    private var controlParser = WorkspaceVMLogParser()

    init(workspace: Workspace, changed: @escaping () -> Void) {
        self.workspace = workspace
        workspaceID = workspace.id
        self.changed = changed
        metadata = WorkspaceStore.loadVMMetadata(workspace.id)
        status = Self.status(for: metadata, workspaceID: workspace.id)
        super.init()
    }

    deinit { startTask?.cancel() }

    func start() {
        guard startTask == nil else { return }
        if virtualMachine?.state == .running || virtualMachine?.state == .starting { return }
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { startTask = nil }
            do {
                try ensureMetadataAndDisk()
                status = WorkspaceVMStatus(phase: .creating,
                                           desiredState: metadata?.desiredState,
                                           hasPersistentDisk: true)
                changed()
                let artifacts = try ApplianceArtifacts.locateAndValidate()
                try await waitForWorkspaceNode()
                try await startNetworkBridge()
                let configuration = try makeConfiguration(artifacts: artifacts)
                let vm = VZVirtualMachine(configuration: configuration)
                vm.delegate = self
                installControlListener(on: vm)
                virtualMachine = vm
                status = WorkspaceVMStatus(phase: .starting,
                                           desiredState: metadata?.desiredState,
                                           hasPersistentDisk: true)
                changed()
                try await vm.start()
                // The guest's structured status will refine this to login or
                // running once the vsock listener is connected. Until then the
                // VM is demonstrably alive and the serial console is available.
                status = WorkspaceVMStatus(phase: .starting,
                                           desiredState: metadata?.desiredState,
                                           hasPersistentDisk: true)
                changed()
            } catch is CancellationError {
                status = Self.status(for: metadata, workspaceID: workspaceID)
                cleanupTransport()
                changed()
            } catch {
                status = WorkspaceVMStatus(phase: .failed(stage: "start",
                                                           message: error.localizedDescription),
                                           desiredState: metadata?.desiredState,
                                           hasPersistentDisk: FileManager.default.fileExists(
                                            atPath: WorkspaceStore.vmDiskURL(workspaceID).path))
                cleanupTransport()
                changed()
            }
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        guard let vm = virtualMachine else {
            status = Self.status(for: metadata, workspaceID: workspaceID)
            cleanupTransport()
            changed()
            return
        }
        status = WorkspaceVMStatus(phase: .stopping,
                                   desiredState: metadata?.desiredState,
                                   hasPersistentDisk: true)
        changed()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if vm.state == .running || vm.state == .paused {
                try? await vm.stop()
            }
            virtualMachine = nil
            cleanupTransport()
            status = Self.status(for: metadata, workspaceID: workspaceID)
            changed()
        }
    }

    func restart() {
        if virtualMachine != nil {
            // The first guest integration intentionally has no command
            // endpoint: stopping the VZ machine is the reliable fallback while
            // the appliance's ordinary logs are streamed over vsock.
            stop()
            Task { @MainActor [weak self] in
                guard let self else { return }
                // stop() is asynchronous; wait for the controller to settle.
                while virtualMachine != nil { try? await Task.sleep(for: .milliseconds(50)) }
                start()
            }
        } else {
            start()
        }
    }

    func delete(completion: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            await self?.deleteAndWait()
            completion()
        }
    }

    func deleteAndWait() async {
        stop()
        while virtualMachine != nil || startTask != nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func openConsole() {
        if let consoleWindow {
            consoleWindow.makeKeyAndOrderFront(nil)
            return
        }
        let view = VMConsoleView(controller: self)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Thundersnap Console — \(workspace.identifier)"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        consoleWindow = window
    }

    func sendConsoleInput(_ text: String) {
        guard let consoleInput, let data = text.data(using: .utf8) else { return }
        try? consoleInput.write(contentsOf: data)
    }

    private static func status(for metadata: WorkspaceVMMetadata?, workspaceID: UUID) -> WorkspaceVMStatus {
        guard let metadata else { return .absent }
        return WorkspaceVMStatus(
            phase: .stopped,
            desiredState: metadata.desiredState,
            hasPersistentDisk: FileManager.default.fileExists(
                atPath: WorkspaceStore.vmDiskURL(workspaceID).path))
    }

    private func ensureMetadataAndDisk() throws {
        var record = metadata ?? WorkspaceVMMetadata(desiredState: .running)
        guard record.formatVersion <= WorkspaceVMMetadata.currentVersion else {
            throw VMControllerError.unsupportedMetadataVersion(record.formatVersion)
        }
        let dir = WorkspaceStore.vmDir(workspaceID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let disk = WorkspaceStore.vmDiskURL(workspaceID)
        if !FileManager.default.fileExists(atPath: disk.path) {
            let temporary = dir.appending(path: "disk.raw.\(UUID().uuidString).tmp")
            let fd = open(temporary.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
            guard fd >= 0 else { throw VMControllerError.diskCreation(String(cString: strerror(errno))) }
            guard ftruncate(fd, off_t(record.diskSize)) == 0 else {
                let message = String(cString: strerror(errno)); close(fd)
                try? FileManager.default.removeItem(at: temporary)
                throw VMControllerError.diskCreation(message)
            }
            fsync(fd)
            close(fd)
            do {
                try FileManager.default.moveItem(at: temporary, to: disk)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
        record.desiredState = .running
        metadata = record
        WorkspaceStore.saveVMMetadata(record, workspaceID: workspaceID)
    }

    private func makeConfiguration(artifacts: ApplianceArtifacts) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = max(2, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        config.memorySize = max(2 * 1024 * 1024 * 1024,
                                VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        config.platform = VZGenericPlatformConfiguration()

        let loader = VZLinuxBootLoader(kernelURL: artifacts.kernel)
        loader.initialRamdiskURL = artifacts.initramfs
        loader.commandLine = "console=hvc0 panic=1 thunderboot.disk=/dev/vda thunderboot.debug-console=1 ip=dhcp"
        config.bootLoader = loader
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: WorkspaceStore.vmDiskURL(workspaceID), readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]

        guard let networkFileHandle else { throw VMControllerError.networkUnavailable }
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: networkFileHandle)
        config.networkDevices = [network]

        let output = Pipe()
        let input = Pipe()
        consoleOutput = output
        consoleInput = input.fileHandleForWriting
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, let text = String(data: data, encoding: .utf8) else { return }
                consoleText.append(text)
                if consoleText.count > 60_000 { consoleText.removeFirst(consoleText.count - 60_000) }
            }
        }
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: input.fileHandleForReading,
            fileHandleForWriting: output.fileHandleForWriting)
        config.serialPorts = [serial]

        // The guest initiates this listener connection after PID 1 starts.
        // Structured events are added incrementally without coupling lifecycle
        // to serial log parsing; an absent listener is harmless during the
        // storage-only bring-up phase.
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        try config.validate()
        return config
    }

    private func waitForWorkspaceNode() async throws {
        for _ in 0..<120 {
            if workspace.manager.node != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw VMControllerError.networkUnavailable
    }

    private func startNetworkBridge() async throws {
        let token = String(workspaceID.uuidString.prefix(12)).lowercased()
        let temporary = FileManager.default.temporaryDirectory
        let server = temporary.appending(path: "ap-vm-\(token)-s")
        let client = temporary.appending(path: "ap-vm-\(token)-c")
        let bridge = try await workspace.manager.startVMNetworkBridge(socketURL: server)
        do {
            networkFileHandle = try Self.connectedUnixDatagram(clientURL: client, serverURL: server)
            networkClientURL = client
            networkBridge = bridge
        } catch {
            try? await bridge.close()
            throw error
        }
    }

    private func installControlListener(on vm: VZVirtualMachine) {
        guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else { return }
        let listener = VZVirtioSocketListener()
        let delegate = WorkspaceVMVsockDelegate { [weak self] box in
            Task { @MainActor [weak self] in
                self?.acceptControlConnection(box.value)
            }
        }
        listener.delegate = delegate
        socketDevice.setSocketListener(listener, forPort: WorkspaceVMProtocol.logPort)
        controlListener = listener
        controlDelegate = delegate
    }

    private func acceptControlConnection(_ connection: VZVirtioSocketConnection) {
        controlConnection?.close()
        controlConnection = connection
        controlParser = WorkspaceVMLogParser()
        let handle = FileHandle(fileDescriptor: connection.fileDescriptor, closeOnDealloc: false)
        controlHandle = handle
        handle.readabilityHandler = { [weak self, weak handle] _ in
            guard let data = try? handle?.read(upToCount: 64 * 1024),
                  !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.handleControlData(data) }
        }
    }

    private func handleControlData(_ data: Data) {
        switch controlParser.append(data) {
        case .failure(let error):
            logger.log("VM log stream error for \(workspaceID): \(error.localizedDescription)")
        case .success(let lines):
            for line in lines { applyLogLine(line) }
        }
    }

    private func applyLogLine(_ line: String) {
        logger.log("VM[\(workspaceID)] \(line)")
        let lower = line.lowercased()
        if let range = line.range(of: "or go to: ", options: .caseInsensitive) {
            let url = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isSafeAuthURL(url) {
                status = WorkspaceVMStatus(phase: .waitingForLogin(authURL: url),
                                           desiredState: metadata?.desiredState, hasPersistentDisk: true)
                changed()
                return
            }
        }
        if lower.contains("tsnet server is up") || lower.contains("waiting for ssh connections") {
            let hostname = value(after: "tsnet hostname:", in: line)
            let addresses = addresses(after: "tailscale ip:", in: line)
            status = WorkspaceVMStatus(phase: .running(hostname: hostname, addresses: addresses),
                                       desiredState: metadata?.desiredState, hasPersistentDisk: true)
            changed()
            return
        }
        if lower.contains("boot failed") || lower.contains("failed to start tsnet") {
            status = WorkspaceVMStatus(phase: .failed(stage: "guest", message: line),
                                       desiredState: metadata?.desiredState, hasPersistentDisk: true)
            changed()
        }
    }

    private func isSafeAuthURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              ["https", "http"].contains(url.scheme?.lowercased()),
              url.host != nil else { return false }
        return true
    }

    private func value(after prefix: String, in line: String) -> String? {
        guard let range = line.lowercased().range(of: prefix) else { return nil }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func addresses(after prefix: String, in line: String) -> [String] {
        guard let value = value(after: prefix, in: line) else { return [] }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func cleanupTransport() {
        controlHandle?.readabilityHandler = nil
        controlHandle = nil
        controlConnection?.close()
        controlConnection = nil
        controlListener = nil
        controlDelegate = nil
        consoleOutput?.fileHandleForReading.readabilityHandler = nil
        consoleOutput = nil
        consoleInput = nil
        networkFileHandle?.closeFile()
        networkFileHandle = nil
        if let networkClientURL { unlink(networkClientURL.path) }
        self.networkClientURL = nil
        let bridge = networkBridge
        networkBridge = nil
        Task { try? await bridge?.close() }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.virtualMachine = nil
            self.cleanupTransport()
            self.status = Self.status(for: self.metadata, workspaceID: self.workspaceID)
            self.changed()
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.virtualMachine = nil
            self.cleanupTransport()
            self.status = WorkspaceVMStatus(phase: .failed(stage: "runtime",
                                                             message: error.localizedDescription),
                                             desiredState: self.metadata?.desiredState,
                                             hasPersistentDisk: true)
            self.changed()
        }
    }

    private static func connectedUnixDatagram(clientURL: URL, serverURL: URL) throws -> FileHandle {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw VMControllerError.socket(String(cString: strerror(errno))) }
        var closeDescriptor = true
        defer { if closeDescriptor { Darwin.close(descriptor) } }
        unlink(clientURL.path)
        func address(_ path: String) throws -> sockaddr_un {
            guard path.utf8.count < MemoryLayout<sockaddr_un>.size - 1 else {
                throw VMControllerError.socket("Unix socket path is too long")
            }
            var result = sockaddr_un(); result.sun_family = sa_family_t(AF_UNIX)
            path.withCString { source in
                withUnsafeMutablePointer(to: &result.sun_path.0) { destination in _ = strcpy(destination, source) }
            }
            return result
        }
        var local = try address(clientURL.path)
        let localResult = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard localResult == 0 else { throw VMControllerError.socket("bind: \(String(cString: strerror(errno)))") }
        var remote = try address(serverURL.path)
        let remoteResult = withUnsafePointer(to: &remote) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard remoteResult == 0 else { throw VMControllerError.socket("connect: \(String(cString: strerror(errno)))") }
        closeDescriptor = false
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

private enum VMControllerError: LocalizedError {
    case unsupportedMetadataVersion(Int)
    case diskCreation(String)
    case networkUnavailable
    case socket(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedMetadataVersion(let v): return "Workspace VM metadata version \(v) is newer than this app."
        case .diskCreation(let message): return "Could not create persistent VM disk: \(message)"
        case .networkUnavailable: return "The workspace network bridge is unavailable."
        case .socket(let message): return "Could not attach VM network socket: \(message)"
        }
    }
}

private struct ApplianceArtifacts {
    let kernel: URL
    let initramfs: URL
    let manifest: Manifest

    struct Manifest: Decodable {
        let schemaVersion: Int
        let architecture: String
        let operatingSystem: String
        let artifacts: [String: Artifact]
    }
    struct Artifact: Decodable { let sha256: String; let size: UInt64 }

    static func locateAndValidate() throws -> ApplianceArtifacts {
        let roots: [URL] = {
            var result: [URL] = []
            if let path = ProcessInfo.processInfo.environment["APERTURE_THUNDERBOOT_ARTIFACTS"] {
                result.append(URL(fileURLWithPath: path))
            }
            if let manifest = Bundle.main.url(forResource: "manifest", withExtension: "json") {
                result.append(manifest.deletingLastPathComponent())
            }
            let localBuild = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: "build/Thunderboot", directoryHint: .isDirectory)
            result.append(localBuild)
            result.append(URL(fileURLWithPath: "../thundersnap/thunderboot-out",
                              relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
            return result
        }()
        for root in roots {
            let kernel = root.appending(path: "Image")
            let initramfs = root.appending(path: "initramfs.cpio")
            let manifestURL = root.appending(path: "manifest.json")
            guard FileManager.default.fileExists(atPath: kernel.path),
                  FileManager.default.fileExists(atPath: initramfs.path),
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                  manifest.schemaVersion == 1,
                  manifest.architecture == "arm64",
                  manifest.operatingSystem == "linux" else { continue }
            try verify(kernel, named: "Image", manifest: manifest)
            try verify(initramfs, named: "initramfs.cpio", manifest: manifest)
            return ApplianceArtifacts(kernel: kernel, initramfs: initramfs, manifest: manifest)
        }
        throw VMControllerError.diskCreation("No verified ARM64 Thunderboot appliance found. Set APERTURE_THUNDERBOOT_ARTIFACTS or bundle Thunderboot artifacts.")
    }

    private static func verify(_ url: URL, named name: String, manifest: Manifest) throws {
        guard let expected = manifest.artifacts[name] else {
            throw VMControllerError.diskCreation("Artifact manifest does not contain \(name).")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.uint64Value == expected.size else {
            throw VMControllerError.diskCreation("Artifact size mismatch for \(name).")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == expected.sha256 else {
            throw VMControllerError.diskCreation("Artifact hash mismatch for \(name).")
        }
    }
}

private struct VMConsoleView: View {
    @ObservedObject var controller: WorkspaceVMController
    @State private var input = ""

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(controller.consoleText.isEmpty ? "Waiting for serial output…" : controller.consoleText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("console")
                }
                .background(.black)
                .onChange(of: controller.consoleText) { _, _ in
                    proxy.scrollTo("console", anchor: .bottom)
                }
            }
            HStack {
                TextField("Send to serial console", text: $input)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { send() }
                Button("Send") { send() }
            }
            .padding(.horizontal, 10)
        }
        .background(.black)
    }

    private func send() {
        controller.sendConsoleInput(input + "\n")
        input = ""
    }
}
