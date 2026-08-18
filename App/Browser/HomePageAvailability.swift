//
//  HomePageAvailability.swift
//  Aperture
//
//  Checks the configured home-page host against the live tailnet peer list
//  before WebKit gets a chance to turn a missing Aperture instance into a
//  generic navigation error.
//

import Foundation
import TailscaleKit

/// The state needed by the browser UI while the localAPI status is settling.
enum HomePageAvailability: Equatable {
    case checking
    case available
    case unavailable
}

enum HomePageInitialLoadDecision {
    case wait
    case load(URL)
}

enum HomePageAvailabilityChecker {
    static let onboardingURL = URL(string: "https://aperture.tailscale.com")!

    /// Checks whether the configured hostname names one of the nodes in the
    /// current tailnet. Bare names go through the exact same qualification
    /// rules as browser navigation; importantly, a primary MagicDNS suffix is
    /// not treated as proof that a peer exists there.
    static func check(urlString: String,
                      status: IpnState.Status?) -> HomePageAvailability {
        guard let url = URL(string: urlString),
              let host = url.host(), !host.isEmpty
        else { return .unavailable }

        // A fully-qualified public/ordinary hostname is not a tailnet peer
        // lookup. It is a valid user-configured home page and should load
        // directly, just as any other non-tailnet browser navigation does.
        // Only ts.net names need to be confirmed against the peer list before
        // we decide that the configured Aperture instance is missing.
        if !isBareHostname(host), !TailnetHostnameQualifier.isTailnetFQDN(host) {
            return .available
        }

        guard let status else { return .checking }
        let records = hostRecords(from: status)
        let targetHost: String
        if isBareHostname(host) {
            let qualification = TailnetHostnameQualifier.qualify(
                url,
                searchDomains: status.CurrentTailnet.map { [$0.MagicDNSSuffix] } ?? [],
                hosts: records
            )
            guard case .qualified(let qualified) = qualification,
                  let qualifiedHost = qualified.host()
            else { return .unavailable }
            // The qualifier deliberately pins unknown bare names to the
            // primary suffix to prevent DNS leakage. That is not evidence of
            // an instance, so require the resulting FQDN to be advertised.
            targetHost = qualifiedHost
        } else {
            targetHost = host
        }

        return contains(host: targetHost, in: records) ? .available : .unavailable
    }

    /// The first home-page tab uses this decision so a missing instance is
    /// never requested by WebKit. Waiting is important: the node can publish
    /// `Running` just before the first complete `/status` response arrives.
    static func initialLoadDecision(urlString: String,
                                    status: IpnState.Status?) -> HomePageInitialLoadDecision {
        switch check(urlString: urlString, status: status) {
        case .checking:
            return .wait
        case .available:
            guard let url = URL(string: urlString) else { return .load(onboardingURL) }
            return .load(url)
        case .unavailable:
            return .load(onboardingURL)
        }
    }

    private static func hostRecords(from status: IpnState.Status) -> [TailnetHostRecord] {
        var peers: [IpnState.PeerStatus] = Array(status.Peer?.values ?? [:].values)
        if let selfStatus = status.SelfStatus { peers.append(selfStatus) }
        return peers.map {
            TailnetHostRecord(shortName: $0.HostName, fullName: $0.DNSName)
        }
    }

    private static func contains(host: String, in records: [TailnetHostRecord]) -> Bool {
        let normalized = normalize(host)
        return records.contains {
            normalize($0.fullName) == normalized
                || (isBareHostname(host) && normalize($0.shortName) == normalized)
        }
    }

    private static func isBareHostname(_ host: String) -> Bool {
        let normalized = normalize(host)
        return !normalized.isEmpty && !normalized.contains(".") && !normalized.contains(":")
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
