//
//  SocksLogProxy.swift
//  Aperture
//
//  A tiny SOCKS5 pass-through relay that sits between WebKit and tsnet's real
//  SOCKS5 proxy, logging **every** connection attempt and its outcome.
//
//  ## Why this exists
//
//  When chasing the "invalid URL" (-1000) failures, the single most valuable
//  fact is: *for a given URL, did the request reach the proxy at all, and if so
//  what did tsnet say?* That distinguishes the two candidate mechanisms:
//
//   * **iOS never sent it to us** \u2014 the OS matched `matchDomains`, decided the
//     host wasn't ours, and resolved/dialed it itself. Nothing appears here.
//   * **It reached us and tsnet couldn't dial it** \u2014 a CONNECT appears here with
//     a non-zero SOCKS reply code. (Measured: WebKit reports -1000 for *every*
//     SOCKS failure reply, so the error code alone can't tell you which.)
//
//  tsnet's own SOCKS server (`net/socks5`) only logs *failures*, and not the
//  reply code, so absence of its log lines proves nothing. This relay logs both
//  directions explicitly.
//
//  It is also the only diagnostic channel on a device that can't be attached to
//  a Mac (no `log stream`, no Console.app) \u2014 pair it with Settings \u2192 Logs.
//
//  ## How it works
//
//  Listens on 127.0.0.1 (an OS-assigned port) and relays bytes verbatim to
//  tsnet's loopback SOCKS5 address. It does not modify the stream: it *parses a
//  copy* of the first few messages in each direction to recover the requested
//  host/port and the reply code, then gets out of the way and pumps bytes.
//  Credentials pass through untouched, so tsnet's auth is unaffected.
//
//  Enabled by default (the logging is cheap and the diagnostic value is high);
//  set `APERTURE_NO_SOCKS_LOG=1` / `-NoSocksLog` to bypass it and point WebKit
//  straight at tsnet.
//

import Foundation
import Network

/// Relays SOCKS5 traffic to tsnet's proxy, logging each attempt + outcome.
///
/// `@unchecked Sendable`: state is confined to `queue`, a serial dispatch queue
/// (Network.framework hands callbacks there), not to an actor \u2014 `NWListener`'s
/// callback API isn't async, and the relay must be usable from the nonisolated
/// contexts that start the node.
nonisolated final class SocksLogProxy: @unchecked Sendable {

    /// Whether the relay should be used at all. On by default; the logging is a
    /// few lines per navigation. Disable with `-NoSocksLog` /
    /// `APERTURE_NO_SOCKS_LOG=1` to point WebKit directly at tsnet (useful to
    /// rule the relay itself out of any investigation).
    nonisolated static func isEnabled() -> Bool {
        if ProcessInfo.processInfo.environment["APERTURE_NO_SOCKS_LOG"] == "1" { return false }
        return !ProcessInfo.processInfo.arguments.contains("-NoSocksLog")
    }

    private let upstreamHost: String
    private let upstreamPort: UInt16
    private let queue = DispatchQueue(label: "io.tailscale.Aperture.sockslog")
    private var listener: NWListener?
    /// Whether tsnet currently has a usable tailnet. New SOCKS connections are
    /// accepted while false, but deliberately left unread: TCP backpressure
    /// holds WebKit's request without returning a SOCKS failure. Existing
    /// relays are never touched by a state bounce.
    private var upstreamAvailable = false
    private var waitingClients: [UInt64: NWConnection] = [:]
    /// Monotonic id so a CONNECT and its reply can be correlated in the log.
    private var nextID: UInt64 = 1

    init(upstreamHost: String, upstreamPort: UInt16) {
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
    }

    /// Starts listening and returns the local port WebKit should point at, or
    /// nil if the listener couldn't start (caller then uses tsnet directly).
    func start() -> UInt16? {
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(client: conn)
            }

            // The OS assigns the port asynchronously: `listener.port` is 0 (or
            // nil) until the listener actually reaches `.ready`, so we must wait
            // for that state rather than polling `.port` — otherwise WebKit gets
            // pointed at port 0 and every load fails.
            let ready = DispatchSemaphore(value: 0)
            l.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    ready.signal()
                default:
                    break
                }
            }
            l.start(queue: queue)
            _ = ready.wait(timeout: .now() + 3)

            guard case .ready = l.state, let port = l.port?.rawValue, port != 0 else {
                logger.log("sockslog: listener not ready (state=\(l.state), port=\(l.port?.rawValue.description ?? "nil")); using tsnet proxy directly")
                l.cancel()
                return nil
            }
            listener = l
            logger.log("sockslog: relay listening on 127.0.0.1:\(port) -> tsnet \(upstreamHost):\(upstreamPort)")
            return port
        } catch {
            logger.log("sockslog: failed to start (\(error)); using tsnet proxy directly")
            return nil
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            for client in self.waitingClients.values { client.cancel() }
            self.waitingClients.removeAll()
        }
    }

    /// Opens or closes the gate for *new* proxy connections. Closing the gate
    /// never cancels an established relay: tsnet keeps the same tailnet IP and
    /// its live TCP sessions can survive a transient control/DERP reconnect.
    /// Clients arriving while closed stay connected to this loopback listener
    /// and are released when Running returns.
    func setUpstreamAvailable(_ available: Bool) {
        queue.async { [weak self] in
            guard let self, self.upstreamAvailable != available else { return }
            self.upstreamAvailable = available
            logger.log("sockslog: connection gate \(available ? "OPEN" : "CLOSED")")
            guard available else { return }
            let waiting = self.waitingClients.sorted { $0.key < $1.key }
            self.waitingClients.removeAll()
            for (id, client) in waiting { self.beginRelay(client: client, id: id) }
        }
    }

    // MARK: - Relay

    private func handle(client: NWConnection) {
        let id = nextID
        nextID += 1
        client.start(queue: queue)

        guard upstreamAvailable else {
            waitingClients[id] = client
            client.stateUpdateHandler = { [weak self, weak client] state in
                guard case .cancelled = state else {
                    if case .failed = state { self?.waitingClients.removeValue(forKey: id) }
                    return
                }
                if self?.waitingClients[id] === client {
                    self?.waitingClients.removeValue(forKey: id)
                }
            }
            logger.log("socks[\(id)] held — tailnet is reconnecting")
            return
        }
        beginRelay(client: client, id: id)
    }

    private func beginRelay(client: NWConnection, id: UInt64) {
        client.stateUpdateHandler = nil
        let upstream = NWConnection(
            host: NWEndpoint.Host(upstreamHost),
            port: NWEndpoint.Port(rawValue: upstreamPort) ?? .any,
            using: .tcp)
        let session = Session(id: id)
        upstream.start(queue: queue)

        // client -> upstream (parse the CONNECT request out of a copy)
        pump(from: client, to: upstream, id: id) { [weak self] data in
            self?.inspectClientBytes(data, session: session)
        }
        // upstream -> client (parse the reply code out of a copy)
        pump(from: upstream, to: client, id: id) { [weak self] data in
            self?.inspectServerBytes(data, session: session)
        }
    }

    /// Copies bytes one direction, handing each chunk to `observe` first.
    private func pump(from: NWConnection,
                      to: NWConnection,
                      id: UInt64,
                      observe: @escaping (Data) -> Void) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                observe(data)
                to.send(content: data, completion: .contentProcessed { _ in
                    self?.pump(from: from, to: to, id: id, observe: observe)
                })
                return
            }
            if isComplete || error != nil {
                from.cancel()
                to.cancel()
                return
            }
            self?.pump(from: from, to: to, id: id, observe: observe)
        }
    }

    // MARK: - Parsing (read-only; the stream itself is untouched)

    /// Per-connection parse state. Only the handshake is parsed; once the
    /// CONNECT reply is seen the relay stops looking at payload bytes.
    private final class Session {
        let id: UInt64
        var clientPhase: ClientPhase = .greeting
        var serverPhase: ServerPhase = .methodSelect
        var pendingClient = Data()
        var pendingServer = Data()
        var target = "?"
        var requestedAt = Date()

        init(id: UInt64) { self.id = id }

        enum ClientPhase { case greeting, auth, request, done }
        enum ServerPhase { case methodSelect, authReply, connectReply, done }
    }

    private func inspectClientBytes(_ data: Data, session s: Session) {
        guard s.clientPhase != .done else { return }
        s.pendingClient.append(data)

        // Walk as far through the handshake as the buffered bytes allow.
        while true {
            switch s.clientPhase {
            case .greeting:
                // VER | NMETHODS | METHODS...
                guard s.pendingClient.count >= 2 else { return }
                let n = Int(s.pendingClient[s.pendingClient.startIndex + 1])
                let need = 2 + n
                guard s.pendingClient.count >= need else { return }
                let methods = Array(s.pendingClient.dropFirst(2).prefix(n))
                s.pendingClient.removeFirst(need)
                // 0x02 = username/password. tsnet requires it.
                s.clientPhase = methods.contains(0x02) ? .auth : .request
            case .auth:
                // VER | ULEN | UNAME | PLEN | PASSWD
                guard s.pendingClient.count >= 2 else { return }
                let ulen = Int(s.pendingClient[s.pendingClient.startIndex + 1])
                guard s.pendingClient.count >= 2 + ulen + 1 else { return }
                let plen = Int(s.pendingClient[s.pendingClient.startIndex + 2 + ulen])
                let need = 2 + ulen + 1 + plen
                guard s.pendingClient.count >= need else { return }
                s.pendingClient.removeFirst(need)
                s.clientPhase = .request
            case .request:
                // VER | CMD | RSV | ATYP | ADDR | PORT
                guard s.pendingClient.count >= 4 else { return }
                let base = s.pendingClient.startIndex
                let cmd = s.pendingClient[base + 1]
                let atyp = s.pendingClient[base + 3]
                var host = "?"
                var consumed = 4
                switch atyp {
                case 0x01: // IPv4
                    guard s.pendingClient.count >= consumed + 4 else { return }
                    let b = Array(s.pendingClient.dropFirst(consumed).prefix(4))
                    host = b.map(String.init).joined(separator: ".")
                    consumed += 4
                case 0x03: // domain name
                    guard s.pendingClient.count >= consumed + 1 else { return }
                    let len = Int(s.pendingClient[base + consumed])
                    consumed += 1
                    guard s.pendingClient.count >= consumed + len else { return }
                    host = String(decoding: Array(s.pendingClient.dropFirst(consumed).prefix(len)))
                    consumed += len
                case 0x04: // IPv6
                    guard s.pendingClient.count >= consumed + 16 else { return }
                    let b = Array(s.pendingClient.dropFirst(consumed).prefix(16))
                    host = Self.formatIPv6(b)
                    consumed += 16
                default:
                    s.clientPhase = .done
                    return
                }
                guard s.pendingClient.count >= consumed + 2 else { return }
                let pb = Array(s.pendingClient.dropFirst(consumed).prefix(2))
                let port = (UInt16(pb[0]) << 8) | UInt16(pb[1])
                s.pendingClient.removeAll(keepingCapacity: false)
                s.target = "\(host):\(port)"
                s.requestedAt = Date()
                s.clientPhase = .done
                let kind = Self.addrKind(atyp)
                let cmdName = cmd == 0x01 ? "CONNECT" : "cmd=\(cmd)"
                logger.log("socks[\(s.id)] \(cmdName) \(kind) \(s.target) — request reached the tailnet proxy")
                return
            case .done:
                return
            }
        }
    }

    private func inspectServerBytes(_ data: Data, session s: Session) {
        guard s.serverPhase != .done else { return }
        s.pendingServer.append(data)

        while true {
            switch s.serverPhase {
            case .methodSelect:
                guard s.pendingServer.count >= 2 else { return }
                let method = s.pendingServer[s.pendingServer.startIndex + 1]
                s.pendingServer.removeFirst(2)
                s.serverPhase = (method == 0x02) ? .authReply : .connectReply
            case .authReply:
                guard s.pendingServer.count >= 2 else { return }
                let status = s.pendingServer[s.pendingServer.startIndex + 1]
                s.pendingServer.removeFirst(2)
                if status != 0 {
                    logger.log("socks[\(s.id)] proxy auth FAILED (status \(status))")
                    s.serverPhase = .done
                    return
                }
                s.serverPhase = .connectReply
            case .connectReply:
                // VER | REP | RSV | ATYP | BND.ADDR | BND.PORT
                guard s.pendingServer.count >= 2 else { return }
                let rep = s.pendingServer[s.pendingServer.startIndex + 1]
                let ms = Int(Date().timeIntervalSince(s.requestedAt) * 1000)
                if rep == 0 {
                    logger.log("socks[\(s.id)] OK \(s.target) — tailnet proxy connected (\(ms)ms)")
                } else {
                    logger.log("socks[\(s.id)] FAILED \(s.target) — tailnet proxy could not connect: \(Self.replyName(rep)) (reply \(rep), \(ms)ms). WebKit will report this as \"invalid URL\" (-1000).")
                }
                s.pendingServer.removeAll(keepingCapacity: false)
                s.serverPhase = .done
                return
            case .done:
                return
            }
        }
    }

    // MARK: - Formatting

    private static func addrKind(_ atyp: UInt8) -> String {
        switch atyp {
        case 0x01: return "ipv4"
        case 0x03: return "name"
        case 0x04: return "ipv6"
        default:   return "atyp=\(atyp)"
        }
    }

    /// RFC 1928 reply codes. These are what tsnet's dial failure turns into,
    /// and every one of them is reported by WebKit as -1000.
    private static func replyName(_ rep: UInt8) -> String {
        switch rep {
        case 1: return "general failure"
        case 2: return "connection not allowed"
        case 3: return "network unreachable"
        case 4: return "host unreachable"
        case 5: return "connection refused"
        case 6: return "TTL expired"
        case 7: return "command not supported"
        case 8: return "address type not supported"
        default: return "unknown"
        }
    }

    private static func formatIPv6(_ b: [UInt8]) -> String {
        guard b.count == 16 else { return "?" }
        var parts: [String] = []
        for i in stride(from: 0, to: 16, by: 2) {
            parts.append(String(format: "%x", (Int(b[i]) << 8) | Int(b[i + 1])))
        }
        return parts.joined(separator: ":")
    }
}

private extension String {
    /// Lossy UTF-8 decode of raw SOCKS address bytes (a malformed name must not
    /// crash the relay).
    nonisolated init(decoding bytes: [UInt8]) {
        self = String(bytes: bytes, encoding: .utf8) ?? "?"
    }
}
