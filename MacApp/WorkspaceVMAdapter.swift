import AppKit
import Combine
import Foundation
import SwiftUI
import TailscaleKit
import Virtualization
import ApertureVM

/// Adapts the reusable package controller to the app's workspace lifecycle
/// protocol. The GUI owns the workspace and its parent tsnet node; the package
/// owns the actual VZ machine, disk, serial stream, and guest log state.
@MainActor
final class ManagedWorkspaceVMController: NSObject, ObservableObject {
    let workspace: Workspace
    private let changed: () -> Void
    private let core: ApertureVM.VMController
    private var cancellables: Set<AnyCancellable> = []

    @Published private(set) var status: WorkspaceVMStatus
    @Published private(set) var consoleText = ""

    init(workspace: Workspace, changed: @escaping () -> Void) {
        self.workspace = workspace
        self.changed = changed
        let network = WorkspaceVMNetworkAttachment(workspace: workspace)
        let config = VMConfiguration(
            workspaceID: workspace.id,
            workspaceDirectory: WorkspaceStore.workspaceDir(workspace.id),
            artifactRoots: ApplianceArtifacts.defaultRoots(),
            networkAttachment: network
        )
        core = ApertureVM.VMController(configuration: config)
        status = Self.map(core.status)
        super.init()
        core.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                status = Self.map(value)
                consoleText = value.console
                changed()
            }
            .store(in: &cancellables)
    }

    func start() { core.start() }
    func stop() { core.stop() }

    func restart() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await core.stopAndWait()
            core.start()
        }
    }

    func deleteAndWait() async {
        await core.stopAndWait()
    }

    func openConsole() {
        ManagedVMConsoleWindow.show(controller: self)
    }

    func sendConsoleInput(_ text: String) {
        core.sendConsoleInput(text)
    }

    private static func map(_ status: ApertureVM.VMStatus) -> WorkspaceVMStatus {
        WorkspaceVMStatus(
            phase: map(status.phase),
            desiredState: status.desiredState.map { $0 == .running ? .running : .stopped },
            hasPersistentDisk: status.diskURL != nil
        )
    }

    private static func map(_ phase: ApertureVM.VMPhase) -> WorkspaceVMPhase {
        switch phase {
        case .absent: return .absent
        case .creating: return .creating
        case .starting: return .starting
        case .waitingForLogin(let url): return .waitingForLogin(authURL: url)
        case .running(let hostname, let addresses): return .running(hostname: hostname, addresses: addresses)
        case .stopped: return .stopped
        case .failed(let stage, let message): return .failed(stage: stage, message: message)
        }
    }
}

/// The GUI-side owner of the existing workspace network bridge. It creates no
/// Tailscale identity of its own; the workspace's TSNetManager remains the
/// single owner of the parent node.
@MainActor
private final class WorkspaceVMNetworkAttachment: VMNetworkAttachment {
    private let workspace: Workspace
    private let token: String
    private var bridge: TailscaleKit.VMNetworkBridge?
    private var client: FileHandle?
    private var clientURL: URL?

    init(workspace: Workspace) {
        self.workspace = workspace
        token = String(workspace.id.uuidString.prefix(12)).lowercased()
    }

    func open() async throws -> (FileHandle, AnyObject) {
        if let client, let bridge { return (client, bridge) }
        let temporary = FileManager.default.temporaryDirectory
        let serverURL = temporary.appending(path: "ap-gui-vm-\(token)-s")
        let clientURL = temporary.appending(path: "ap-gui-vm-\(token)-c")
        let bridge = try await workspace.manager.startVMNetworkBridge(socketURL: serverURL)
        do {
            let client = try Self.connectedUnixDatagram(clientURL: clientURL, serverURL: serverURL)
            self.bridge = bridge
            self.client = client
            self.clientURL = clientURL
            return (client, bridge)
        } catch {
            try? await bridge.close()
            throw error
        }
    }

    func close() async {
        client?.closeFile()
        client = nil
        if let clientURL { unlink(clientURL.path) }
        clientURL = nil
        try? await bridge?.close()
        bridge = nil
    }

    private static func connectedUnixDatagram(clientURL: URL, serverURL: URL) throws -> FileHandle {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw VMNetworkAttachmentError.socket(String(cString: strerror(errno)))
        }
        var closeDescriptor = true
        defer { if closeDescriptor { Darwin.close(descriptor) } }
        unlink(clientURL.path)

        func address(_ path: String) throws -> sockaddr_un {
            guard path.utf8.count < MemoryLayout<sockaddr_un>.size - 1 else {
                throw VMNetworkAttachmentError.socket("Unix socket path is too long")
            }
            var result = sockaddr_un()
            result.sun_family = sa_family_t(AF_UNIX)
            path.withCString { source in
                withUnsafeMutablePointer(to: &result.sun_path.0) {
                    _ = strcpy($0, source)
                }
            }
            return result
        }

        var local = try address(clientURL.path)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            throw VMNetworkAttachmentError.socket("bind: \(String(cString: strerror(errno)))")
        }

        var remote = try address(serverURL.path)
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw VMNetworkAttachmentError.socket("connect: \(String(cString: strerror(errno)))")
        }
        closeDescriptor = false
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

private enum VMNetworkAttachmentError: LocalizedError {
    case socket(String)
    var errorDescription: String? {
        switch self { case .socket(let message): return "VM network socket: \(message)" }
    }
}

@MainActor
private enum ManagedVMConsoleWindow {
    static var windows: [UUID: NSWindow] = [:]

    static func show(controller: ManagedWorkspaceVMController) {
        if let existing = windows[controller.workspace.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = ManagedVMConsoleView(controller: controller)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Thundersnap Console — \(controller.workspace.identifier)"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows[controller.workspace.id] = window
    }
}

private struct ManagedVMConsoleView: View {
    @ObservedObject var controller: ManagedWorkspaceVMController
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
                    .accessibilityIdentifier("thundersnap-console-send")
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
