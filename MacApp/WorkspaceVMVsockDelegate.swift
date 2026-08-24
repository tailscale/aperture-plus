// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

import Virtualization

@MainActor
struct WorkspaceVMConnectionBox: @unchecked Sendable {
    let value: VZVirtioSocketConnection
}

/// NSObject adapter for Virtualization.framework's delegate callback. The
/// connection is retained by the controller after acceptance.
final class WorkspaceVMVsockDelegate: NSObject, VZVirtioSocketListenerDelegate {
    private let accepted: @Sendable (WorkspaceVMConnectionBox) -> Void

    init(accepted: @escaping @Sendable (WorkspaceVMConnectionBox) -> Void) {
        self.accepted = accepted
    }

    func listener(_ listener: VZVirtioSocketListener,
                             shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                             from socketDevice: VZVirtioSocketDevice) -> Bool {
        accepted(WorkspaceVMConnectionBox(value: connection))
        return true
    }
}
