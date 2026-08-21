import AppKit
import Combine
import Foundation
import SwiftUI
import Virtualization
import ApertureVM

/// Adapts the reusable package controller to the app's workspace lifecycle
/// protocol. The package owns the actual VZ machine, disk, serial stream, and
/// guest log state. The GUI currently uses Virtualization.framework's standard
/// NAT rather than the experimental workspace-owned vmnet bridge.
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
        let config = VMConfiguration(
            workspaceID: workspace.id,
            workspaceDirectory: WorkspaceStore.workspaceDir(workspace.id),
            artifactRoots: ApplianceArtifacts.defaultRoots(),
            networkMode: .nat
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
