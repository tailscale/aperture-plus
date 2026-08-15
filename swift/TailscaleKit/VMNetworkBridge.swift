// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

import Foundation

/// One disposable VM Ethernet bridge borrowing a `TailscaleNode`'s existing
/// tsnet identity. Closing this object stops the Go packet bridge and removes
/// its Unix socket; it never starts or closes a Tailscale server.
public final class VMNetworkBridge: @unchecked Sendable {
    public let socketURL: URL

    private let node: TailscaleNode
    private let handle: Int32
    private let lock = NSLock()
    private var stopped = false

    init(node: TailscaleNode, handle: Int32, socketURL: URL) {
        self.node = node
        self.handle = handle
        self.socketURL = socketURL
    }

    public func close() async throws {
        let shouldStop = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        try await node.stopVMNetworkBridge(handle: handle)
    }
}

extension TailscaleNode {
    /// Starts tailvisor's Ethernet/DHCP/DNS/gVisor bridge inside the same Go
    /// archive and against this node's already-running `tsnet.Server`.
    /// `magicDNSSuffix` is advertised to the guest via DHCP option 119.
    public func startVMNetworkBridge(socketURL: URL,
                                     magicDNSSuffix: String = "") throws -> VMNetworkBridge {
        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }
        var bridge: Int32 = 0
        let result = socketURL.path.withCString { socketPath in
            magicDNSSuffix.withCString { suffix in
                tailscale_vm_bridge_start(tailscale, socketPath, suffix, &bridge)
            }
        }
        guard result == 0 else {
            throw TailscaleError.fromPosixErrCode(result, tailscale.getErrorMessage())
        }
        guard tailscale_vm_bridge_ready(tailscale, bridge) == 1 else {
            _ = tailscale_vm_bridge_stop(tailscale, bridge)
            throw TailscaleError.fromPosixErrCode(-1, "VM network bridge did not become ready")
        }
        return VMNetworkBridge(node: self, handle: bridge, socketURL: socketURL)
    }

    fileprivate func stopVMNetworkBridge(handle: Int32) throws {
        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }
        let result = tailscale_vm_bridge_stop(tailscale, handle)
        guard result == 0 else {
            throw TailscaleError.fromPosixErrCode(result, tailscale.getErrorMessage())
        }
    }
}
