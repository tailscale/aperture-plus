import Foundation
import Virtualization

@MainActor
public final class VMController: NSObject, ObservableObject, VZVirtualMachineDelegate {
    public let configuration: VMConfiguration
    @Published public private(set) var status: VMStatus

    private var metadata: VMMetadata?
    private var virtualMachine: VZVirtualMachine?
    private var startTask: Task<Void, Never>?
    private var consoleOutput: Pipe?
    private var consoleInput: FileHandle?
    private var logConnection: VZVirtioSocketConnection?
    private var logHandle: FileHandle?
    private var logListener: VZVirtioSocketListener?
    private var logDelegate: LogSocketDelegate?
    private var logParser = LogParser()
    private var networkAttachmentObject: AnyObject?
    private var eventContinuation: AsyncStream<VMEvent>.Continuation?

    public init(configuration: VMConfiguration) {
        self.configuration = configuration
        let metadataURL = configuration.workspaceDirectory.appending(path: "VM/metadata.json")
        metadata = Self.loadMetadata(at: metadataURL)
        let disk = configuration.workspaceDirectory.appending(path: "VM/disk.raw")
        status = VMStatus(phase: metadata == nil ? .absent : .stopped,
                          desiredState: metadata?.desiredState,
                          diskURL: FileManager.default.fileExists(atPath: disk.path) ? disk : nil,
                          console: "")
        super.init()
    }

    public var events: AsyncStream<VMEvent> {
        AsyncStream { continuation in
            eventContinuation = continuation
            continuation.yield(.phase(status.phase))
        }
    }

    public func start() {
        guard startTask == nil else { return }
        if virtualMachine?.state == .running || virtualMachine?.state == .starting { return }
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { startTask = nil }
            do {
                let metadata = try ensureMetadataAndDisk()
                self.metadata = metadata
                update(.creating)
                let artifacts = try ApplianceArtifacts.locate(in: configuration.artifactRoots)
                let machineConfiguration = try await makeConfiguration(artifacts: artifacts)
                let vm = VZVirtualMachine(configuration: machineConfiguration)
                vm.delegate = self
                installLogListener(on: vm)
                virtualMachine = vm
                update(.starting)
                try await vm.start()
                update(.starting)
            } catch is CancellationError {
                cleanup()
                update(metadata == nil ? .absent : .stopped)
            } catch {
                cleanup()
                status = VMStatus(phase: .failed(stage: "start", message: error.localizedDescription),
                                  desiredState: metadata?.desiredState,
                                  diskURL: diskURL,
                                  console: status.console)
                eventContinuation?.yield(.phase(status.phase))
            }
        }
    }

    public func runUntilStopped() async {
        for await _ in events { }
    }

    public func stop() {
        startTask?.cancel()
        startTask = nil
        guard let vm = virtualMachine else { cleanup(); update(metadata == nil ? .absent : .stopped); return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if vm.canStop { try? await vm.stop() }
            virtualMachine = nil
            cleanup()
            update(metadata == nil ? .absent : .stopped)
        }
    }

    public func sendConsoleInput(_ text: String) {
        guard let consoleInput, let data = text.data(using: .utf8) else { return }
        try? consoleInput.write(contentsOf: data)
    }

    private var diskURL: URL { configuration.workspaceDirectory.appending(path: "VM/disk.raw") }
    private var vmDirectory: URL { configuration.workspaceDirectory.appending(path: "VM", directoryHint: .isDirectory) }

    private func ensureMetadataAndDisk() throws -> VMMetadata {
        try FileManager.default.createDirectory(at: vmDirectory, withIntermediateDirectories: true)
        var record = metadata ?? VMMetadata(desiredState: .running, diskSize: configuration.diskSize)
        guard record.formatVersion <= VMMetadata.currentVersion else {
            throw VMError.unsupportedMetadata(record.formatVersion)
        }
        if !FileManager.default.fileExists(atPath: diskURL.path) {
            let temporary = vmDirectory.appending(path: "disk.raw.\(UUID().uuidString).tmp")
            let fd = open(temporary.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
            guard fd >= 0 else { throw VMError.disk(String(cString: strerror(errno))) }
            guard ftruncate(fd, off_t(record.diskSize)) == 0 else {
                let message = String(cString: strerror(errno)); close(fd)
                try? FileManager.default.removeItem(at: temporary)
                throw VMError.disk(message)
            }
            fsync(fd); close(fd)
            try FileManager.default.moveItem(at: temporary, to: diskURL)
        }
        record.desiredState = .running
        saveMetadata(record)
        return record
    }

    private func makeConfiguration(artifacts: ApplianceArtifacts) async throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = max(configuration.cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        config.memorySize = max(configuration.memory, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        config.platform = VZGenericPlatformConfiguration()
        let loader = VZLinuxBootLoader(kernelURL: artifacts.kernel)
        loader.initialRamdiskURL = artifacts.initramfs
        loader.commandLine = configuration.storageOnly
            ? "console=hvc0 panic=-1 reboot=t thunderboot.disk=/dev/vda thundersnap.testonly=storage"
            : "console=hvc0 panic=-1 reboot=t thunderboot.disk=/dev/vda thunderboot.debug-console=1 ip=dhcp"
        config.bootLoader = loader
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        if let networkAttachment = configuration.networkAttachment {
            let (fileHandle, owner) = try await networkAttachment.open()
            networkAttachmentObject = owner
            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: fileHandle)
            config.networkDevices = [network]
        }
        let output = Pipe(); let input = Pipe()
        consoleOutput = output; consoleInput = input.fileHandleForWriting
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, let text = String(data: data, encoding: .utf8) else { return }
                status.console.append(text)
                if status.console.count > 60_000 { status.console.removeFirst(status.console.count - 60_000) }
                eventContinuation?.yield(.log(text))
            }
        }
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: input.fileHandleForReading,
                                                              fileHandleForWriting: output.fileHandleForWriting)
        config.serialPorts = [serial]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        try config.validate()
        return config
    }

    private func installLogListener(on vm: VZVirtualMachine) {
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else { return }
        let listener = VZVirtioSocketListener()
        let delegate = LogSocketDelegate { [weak self] box in
            Task { @MainActor [weak self] in self?.acceptLogConnection(box.value) }
        }
        listener.delegate = delegate
        device.setSocketListener(listener, forPort: 5230)
        logListener = listener; logDelegate = delegate
    }

    private func acceptLogConnection(_ connection: VZVirtioSocketConnection) {
        logConnection?.close(); logConnection = connection; logParser = LogParser()
        let handle = FileHandle(fileDescriptor: connection.fileDescriptor, closeOnDealloc: false)
        logHandle = handle
        handle.readabilityHandler = { [weak self, weak handle] _ in
            guard let data = try? handle?.read(upToCount: 64 * 1024), !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in logParser.append(data) {
                    eventContinuation?.yield(.log(line))
                    applyGuestLog(line)
                }
            }
        }
    }

    private func applyGuestLog(_ line: String) {
        let lower = line.lowercased()
        if let range = line.range(of: "or go to: ", options: .caseInsensitive) {
            let url = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = URL(string: url),
               ["https", "http"].contains(parsed.scheme?.lowercased()), parsed.host != nil {
                update(.waitingForLogin(url))
                return
            }
        }
        if lower.contains("tsnet server is up") || lower.contains("waiting for ssh connections") {
            let hostname = value(after: "tsnet hostname:", in: line)
            update(.running(hostname: hostname, addresses: []))
        } else if lower.contains("boot failed") || lower.contains("failed to start tsnet") {
            status.phase = .failed(stage: "guest", message: line)
            eventContinuation?.yield(.phase(status.phase))
        }
    }

    private func value(after prefix: String, in line: String) -> String? {
        guard let range = line.lowercased().range(of: prefix) else { return nil }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func update(_ phase: VMPhase) {
        status.phase = phase; status.desiredState = metadata?.desiredState; status.diskURL = diskURL
        eventContinuation?.yield(.phase(phase))
        objectWillChange.send()
    }

    private func saveMetadata(_ value: VMMetadata) {
        let url = vmDirectory.appending(path: "metadata.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
        metadata = value
    }

    private func cleanup() {
        logHandle?.readabilityHandler = nil; logHandle = nil; logConnection?.close(); logConnection = nil
        logListener = nil; logDelegate = nil
        consoleOutput?.fileHandleForReading.readabilityHandler = nil; consoleOutput = nil; consoleInput = nil
    }

    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor [weak self] in self?.virtualMachine = nil; self?.cleanup(); self?.update(.stopped) }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        Task { @MainActor [weak self] in
            self?.virtualMachine = nil; self?.cleanup()
            self?.status.phase = .failed(stage: "runtime", message: error.localizedDescription)
            if let phase = self?.status.phase { self?.eventContinuation?.yield(.phase(phase)) }
        }
    }

    private static func loadMetadata(at url: URL) -> VMMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VMMetadata.self, from: data)
    }
}

private struct LogParser {
    private var partial = Data()
    mutating func append(_ data: Data) -> [String] {
        partial.append(data); guard partial.count <= 128 * 1024 else { partial.removeAll(); return [] }
        var result: [String] = []
        while let newline = partial.firstIndex(of: 0x0a) {
            let line = partial[..<newline]; partial.removeSubrange(...newline)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty { result.append(text) }
        }
        return result
    }
}

private struct LogConnectionBox: @unchecked Sendable { let value: VZVirtioSocketConnection }

private final class LogSocketDelegate: NSObject, VZVirtioSocketListenerDelegate {
    private let accepted: @Sendable (LogConnectionBox) -> Void
    init(accepted: @escaping @Sendable (LogConnectionBox) -> Void) { self.accepted = accepted }
    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection, from socketDevice: VZVirtioSocketDevice) -> Bool {
        accepted(LogConnectionBox(value: connection)); return true
    }
}

private enum VMError: LocalizedError {
    case unsupportedMetadata(Int); case disk(String)
    var errorDescription: String? {
        switch self { case .unsupportedMetadata(let v): return "Unsupported VM metadata version \(v)."; case .disk(let e): return "Could not create VM disk: \(e)" }
    }
}
