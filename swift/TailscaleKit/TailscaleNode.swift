// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

public let kDefaultControlURL = "https://controlplane.tailscale.com"


/// Configuration for a tailscale application node
public struct Configuration: Sendable {
    public let hostName: String    ///< The hostname of the node/application instance
    public let path: String
    public let authKey: String?    ///< An auth key.  Leave empty to use web auth
    public let controlURL: String  ///< URL for Tailscale control
    public let ephemeral: Bool

    public init(hostName: String,
                path: String,
                authKey: String?,
                controlURL: String,
                ephemeral: Bool = false)
    {
        self.hostName = hostName
        self.path = path
        self.authKey = authKey
        self.controlURL = controlURL
        self.ephemeral = ephemeral
    }

}

/// The layer 3 protocol to use
public enum NetProtocol: String {
    case tcp = "tcp"
    case udp = "udp"
}

public typealias IPAddresses = (ip4: String?, ip6: String?)

/// TSInterface creates and manages a single userspace Tailscale application
/// node.  You may instantiate several "nodes" in a single application.  Each
/// will get a unique IP address on the Tailnet.
///
/// The provided wrapper abstract away the C code and allow the writing of proper,
/// compiler checked thread-safe Swift 6.
public actor TailscaleNode {

    /// Handle to the underlying Tailscale server.  Use this when instantiating
    /// new IncomingConnections or OutgoingConnections
    public let tailscale: TailscaleHandle?

    private let logger: LogSink?

    /// Instantiate a new TailscaleNode with the given configuration and
    /// and optional LogSink.  If no LogSink is provided, logs will be
    /// discarded.
    ///
    /// @See tailscale_set_* in Tailscale.h
    /// @See tailscale_start in Tailscale.h
    ///
    /// @throws TailscaleError on failure
    public init(config: Configuration, logger: LogSink?) throws {
        self.logger = logger ?? BlackholeLogger()

        tailscale = tailscale_new()

        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }
        
        logger?.log("Tailscale starting: \(tailscale)")

        if let fd = logger?.logFileHandle {
            tailscale_set_logfd(tailscale, fd)
        }

        if let authKey = config.authKey {
            tailscale_set_authkey(tailscale, authKey)
        }

        tailscale_set_hostname(tailscale, config.hostName)
        tailscale_set_dir(tailscale, config.path)
        tailscale_set_control_url(tailscale, config.controlURL)
        tailscale_set_ephemeral(tailscale, config.ephemeral ? 1 : 0)

        let res = tailscale_start(tailscale)

        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }

        logger?.log("Tailscale started... \(tailscale)")
    }

    deinit {
        if let tailscale {
            tailscale_close(tailscale)
        }
    }

    /// Closes/stops the Tailscale server
    ///
    /// @See tailscale_close in Tailscale.h
    ///
    /// @Throws TailscaleError on failure
    public func close() async throws {
        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        logger?.log("Closing Tailscale: \(tailscale)")
        let res = tailscale_close(tailscale)

        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }
        logger?.log("Closed Tailscale:\(tailscale)")
    }

    /// Repairs transports that iOS may silently invalidate while this process
    /// is suspended. Rebinds magicsock UDP and breaks stale DERP TCP sessions
    /// without closing the server, loopback proxy, netstack, or web sessions.
    /// The Go side applies a deadline so foreground recovery cannot wedge here.
    public func repairConnectionsAfterResume() throws {
        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }
        let res = tailscale_debug_reset_connections(tailscale)
        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }
    }

    /// Test compatibility name for the transport-damage integration hook.
    public func debugResetConnections() throws {
        try repairConnectionsAfterResume()
    }

    /// Defuncts only the owned tsnet loopback listener while retaining its
    /// stale endpoint. TEST/DEBUG ONLY: deterministic -1004 recovery test.
    public func debugDefunctLoopback() throws {
        guard let tailscale else { throw TailscaleError.badInterfaceHandle }
        let res = tailscale_debug_defunct_loopback(tailscale)
        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }
    }

    /// Calls shutdown(SHUT_RDWR) on every TCP socket in this process without
    /// closing descriptors. TEST/DEBUG ONLY: destructive chaos injection used
    /// to reproduce iOS socket defuncting and verify recovery.
    public func debugShutdownTCPConnections() throws {
        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }
        let res = tailscale_debug_shutdown_tcp_connections(tailscale)
        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }
    }

    /// Deliberately crashes the Go runtime. TEST/DEBUG ONLY — never call from
    /// normal app flow. Used by the crash-capture UI test (via the `-CrashTest`
    /// launch arg in TSNetManager) to verify that Go runtime panics — and the
    /// goroutine stack dump Go prints to stderr (fd 2) before aborting — are
    /// captured by Aperture's stderr redirect (TSNet/CrashCapture.swift) and
    /// surfaced on the next launch.
    ///
    /// Reproduces the exact mechanism of the overnight TestFlight crash: the
    /// Go runtime prints "panic: ..." + a stack trace to fd 2, then raises
    /// SIGABRT, so in the crash log it shows up as `__kill` from a
    /// TailscaleKit thread (see `TsnetCrashTest` in tailscale.go).
    ///
    /// mode 0 (default): panic immediately in the calling goroutine. Does not
    /// return — the process aborts.
    /// mode 1: panic in a background goroutine; returns 0, then the process
    /// aborts a moment later.
    //
    // `async` (and actor-isolated, since TailscaleNode is an actor) to match
    // up()/close(); callers `await` it across the actor boundary. The panic
    // itself aborts the process before the `await` can resume (mode 0).
    public func crashTest(mode: Int = 0) async {
        guard let tailscale else {
            return
        }
        tailscale_crash_test(tailscale, Int32(mode))
    }

    /// Brings up the Tailscale server
    ///
    /// @See tailscale_up in Tailscale.h
    ///
    /// @throws TailscaleError on failure
    public func up() async throws {
        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        logger?.log("Bringing Tailscale up :\(tailscale)")
        let res = tailscale_up(tailscale)

        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }
        logger?.log("Brought Tailscale up:\(tailscale)")
    }

    /// Returns the addresses on the Tailscale server
    ///
    /// @See tailscale_getips in Tailscale.h
    ///
    /// @returns An ipV4 and ipV5 address tuple
    /// @throws TailscaleError on failure
    public func addrs() async throws -> IPAddresses {
        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        let buf = UnsafeMutablePointer<Int8>.allocate(capacity: 128)
        defer {
            buf.deallocate()
        }
        let res = tailscale_getips(tailscale, buf, 128)

        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }

        let ipList = String(cString: buf)
        return ipList.toIPPair()
    }

    public struct LoopbackConfig: Sendable {
        public let address: String
        public let proxyCredential: String
        public let localAPIKey: String

        public var ip: String? {
            let parts = address.split(separator: ":")
            let addr = parts.first
            guard parts.count == 2, let addr else {
                return nil
            }
            return String(addr)
        }

        public var port: Int? {
            let parts = address.split(separator: ":")
            let port = parts.last
            guard parts.count == 2, let port else {
                return nil
            }
            return Int(port)
        }
    }

    private var loopbackConfig: LoopbackConfig?

    /// Starts and returns the address and credentials of a SOCKS5 proxy which can also
    /// be used to query the localAPI.
    public func loopback() throws -> LoopbackConfig {
        if let loopbackConfig { return loopbackConfig }
        return try loadLoopback(restart: false)
    }

    /// Replaces a defunct loopback LocalAPI/SOCKS listener without rebuilding
    /// the tsnet node, and updates the configuration cached by future LocalAPI
    /// requests. Intended for reactive recovery after a local connection error.
    public func restartLoopback() throws -> LoopbackConfig {
        try loadLoopback(restart: true)
    }

    private func loadLoopback(restart: Bool) throws -> LoopbackConfig {
        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        let addrBuf = UnsafeMutablePointer<Int8>.allocate(capacity: 64)
        let proxyCredBuf = UnsafeMutablePointer<Int8>.allocate(capacity: 33)
        let apiCredBuf = UnsafeMutablePointer<Int8>.allocate(capacity: 33)
        defer {
            addrBuf.deallocate()
            proxyCredBuf.deallocate()
            apiCredBuf.deallocate()
        }

        let res = restart
            ? tailscale_restart_loopback(tailscale, addrBuf, 64, proxyCredBuf, apiCredBuf)
            : tailscale_loopback(tailscale, addrBuf, 64, proxyCredBuf, apiCredBuf)
        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }

        let config = LoopbackConfig(address: String(cString: addrBuf),
                                    proxyCredential: String(cString: proxyCredBuf),
                                    localAPIKey: String(cString: apiCredBuf))
        loopbackConfig = config
        return config

    }
}

// MARK: - IP String list to IPAddresses tuple

enum IPAddrType {
    case v4
    case v6
    case none
}

extension String {
    // tailscale.go sends us the tailnetIPs as a comma separated list.  This will
    // turn them into an IPAddresses tuple
    func toIPPair() -> IPAddresses {
        let ips = self.split(separator: ",").map { String($0) }
        var result: IPAddresses = (nil, nil)
        for ip in ips {
            let type = ip.tsNetIPAddrType()
            switch type {
            case .v4:
                result.ip4 = ip
            case .v6:
                result.ip6 = ip
            case .none:
                break
            }
        }
        return result
    }


    // This can be naive since the backend is only vending well
    // formed IPs to us.
    func tsNetIPAddrType() -> IPAddrType {
        if self.contains(".") {
            return .v4
        } else if self.contains(":") {
            return .v6
        }
        return .none
    }
}


