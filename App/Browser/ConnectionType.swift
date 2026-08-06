//
//  ConnectionType.swift
//  Aperture
//
//  Classifies a browser tab's current page for its URL-bar status indicator, so
//  we can show a small per-tab indicator (see the URL pill on iPhone, the tab
//  chips on iPad, and the tab-overview cards):
//
//    .direct   — tailnet peer, connected peer-to-peer (no relay)
//    .derped   — tailnet peer, connected via a DERP relay
//    .unknownTailnetHost — a *.ts.net name absent from the signed peer list
//    .internet — not a tailnet peer (e.g. a public site, reached via an exit
//                node or not in the netmap at all)
//
//  The direct/derped distinction matters for diagnostics but should look
//  harmless to end users (a couple of green dots, not a warning). "Internet"
//  uses an external-link-style icon to signal "this leaves the tailnet".
//

import Foundation
import TailscaleKit

enum ConnectionType: Equatable, Sendable {
    case direct
    case derped
    /// A *.ts.net destination absent from the signed peer list.
    case unknownTailnetHost
    case internet

    var accessibilityDescription: String {
        switch self {
        case .direct: "Direct tailnet connection"
        case .derped: "Tailnet connection via relay"
        case .unknownTailnetHost: "Unknown tailnet host"
        case .internet: "Internet (off tailnet)"
        }
    }
}

enum ConnectionTypeResolver {
    /// Classify `host` (the URL bar's host — a MagicDNS short name, a tailnet
    /// FQDN, a tailnet IP, or an arbitrary internet host) using the live peer
    /// status (`IpnState.Status`, which carries `Relay`/`CurAddr` per peer) and
    /// the netmap (for the self node / fallback). Returns `.internet` if the
    /// host isn't a known tailnet peer.
    static func resolve(host: String?, status: IpnState.Status?,
                        proxyPolicy: TailnetProxyPolicy? = nil) -> ConnectionType {
        guard let host, !host.isEmpty else { return .internet }

        // Find the matching peer status. `IpnState.Status.Peer` is keyed by
        // StableNodeID; we scan values and match by DNSName / HostName / IPs.
        if let status, let peer = peerStatus(forHost: host, in: status) {
            // CurAddr non-empty => a direct path is established (p2p).
            // Otherwise the path goes via the DERP `Relay` (or is still
            // negotiating — treat as derped, since it's not direct).
            if let addr = peer.CurAddr, !addr.isEmpty {
                return .direct
            }
            return .derped
        }

        // A *.ts.net URL is visibly inside the tailnet namespace, but an FQDN
        // absent from the complete signed status list is a clear bad target.
        if let status, TailnetHostnameQualifier.isTailnetFQDN(host),
           !TailnetHostnameQualifier.isKnownFQDN(host, hosts: hostRecords(from: status)) {
            return .unknownTailnetHost
        }

        // A status response can transiently omit a peer while the independently
        // maintained split-tunnel policy still knows the destination belongs to
        // the tailnet. The policy is authoritative for routing; conservatively
        // report relay rather than incorrectly labeling proxied traffic as
        // Internet until a later status poll supplies CurAddr.
        if let proxyPolicy {
            if proxyPolicy.matchingRule(for: host) != nil {
                return .derped
            }
            // Short names that collide with public TLDs (notably the `ai`
            // home-page peer) are intentionally absent from matchDomains and
            // rewritten to their FQDN at load time. The URL model can still
            // briefly retain the user-entered short name, so classify that
            // known tailnet peer conservatively instead of calling it Internet.
            let normalizedHost = TailnetProxyPolicy.normalizeDomain(host)
            if proxyPolicy.shortNamesWithheldAsPublicTLD.contains(normalizedHost) {
                return .derped
            }
        }

        return .internet
    }

    private static func hostRecords(from status: IpnState.Status) -> [TailnetHostRecord] {
        var peers: [IpnState.PeerStatus] = Array(status.Peer?.values ?? [:].values)
        if let selfStatus = status.SelfStatus { peers.append(selfStatus) }
        return peers.map { TailnetHostRecord(shortName: $0.HostName, fullName: $0.DNSName) }
    }

    /// Matches a host against a peer's `DNSName` (FQDN, often with a trailing
    /// dot), `HostName` (MagicDNS short name), first label of the DNSName, or
    /// any `TailscaleIPs`.
    ///
    /// Internal (not private) so the timing harness can reuse the app's exact
    /// host→peer matching when watching a peer's path upgrade.
    static func peerStatus(forHost host: String, in status: IpnState.Status) -> IpnState.PeerStatus? {
        let lowered = host.lowercased()
        // Also consider the self node (e.g. loading the node's own peerapi).
        var candidates: [IpnState.PeerStatus] = Array(status.Peer?.values ?? [:].values)
        if let selfStatus = status.SelfStatus { candidates.append(selfStatus) }

        for peer in candidates {
            if peer.HostName.lowercased() == lowered {
                return peer
            }
            let dns = peer.DNSName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if dns == lowered {
                return peer
            }
            // MagicDNS short name = first label of the DNSName.
            if let firstLabel = dns.split(separator: ".").first, String(firstLabel) == lowered {
                return peer
            }
            if let ips = peer.TailscaleIPs {
                for ip in ips {
                    if String(describing: ip).lowercased() == lowered {
                        return peer
                    }
                }
            }
        }
        return nil
    }
}
