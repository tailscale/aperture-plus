//
//  TailnetHostnameQualifier.swift
//  Aperture
//
//  Pure MagicDNS short-name qualification. This file deliberately depends only
//  on Foundation so its shipping implementation can be compiled and tested on
//  the host without WebKit, TailscaleKit, a simulator, or an xcframework.
//

import Foundation

struct TailnetHostRecord: Equatable, Sendable {
    /// PeerStatus.HostName (the short/machine name).
    let shortName: String
    /// PeerStatus.DNSName (the peer's advertised MagicDNS FQDN).
    let fullName: String
}

enum TailnetHostnameQualification: Equatable, Sendable {
    /// Not an http(s) URL with a single-label host; no qualification applies.
    case unchanged(URL)
    /// The bare label is not present in the signed peer list.
    case unknown(label: String)
    /// More than one non-primary advertised FQDN has this exact first label.
    case ambiguous(label: String, candidates: [String])
    /// A deterministic destination from the peer list/search-domain data.
    case qualified(URL)
}

enum TailnetHostnameQualifier {
    /// Qualifies a single-label URL using status data, without DNS or network
    /// guesses. Inputs map directly to tsnet status fields:
    ///
    /// - `searchDomains`: ordered MagicDNS search suffixes, primary first.
    /// - `hosts`: PeerStatus `{ HostName, DNSName }` records (including self).
    ///
    /// Resolution rules:
    /// 1. An advertised FQDN whose first label equals the input and whose suffix
    ///    is the primary search domain wins.
    /// 2. Otherwise, a unique advertised FQDN whose first label equals the input
    ///    wins, including a shared-in peer from another `*.ts.net` tailnet.
    /// 3. A matching shortName with no same-label advertised FQDN may use the
    ///    primary suffix. Critically, it never adopts that record's differently
    ///    named FQDN (the historical `ai` -> `benson-…` bug).
    /// 4. Unknown and ambiguous labels are explicit errors.
    static func qualify(_ url: URL,
                        searchDomains: [String],
                        hosts: [TailnetHostRecord]) -> TailnetHostnameQualification {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let rawHost = url.host(),
              isBareHostname(rawHost)
        else { return .unchanged(url) }

        let label = normalizeName(rawHost)
        let domains = searchDomains.map(normalizeName).filter { !$0.isEmpty }
        let records = hosts.map {
            TailnetHostRecord(shortName: normalizeName($0.shortName),
                              fullName: normalizeName($0.fullName))
        }

        let exactFQDNs = Set(records.compactMap { record -> String? in
            guard let first = firstLabel(of: record.fullName), first == label,
                  record.fullName.contains(".")
            else { return nil }
            return record.fullName
        })

        if let primaryDomain = domains.first {
            let primary = "\(label).\(primaryDomain)"
            if exactFQDNs.contains(primary), let result = replacingHost(in: url, with: primary) {
                return .qualified(result)
            }
        }

        let advertised = exactFQDNs.sorted()
        if advertised.count == 1, let only = advertised.first,
           let result = replacingHost(in: url, with: only) {
            return .qualified(result)
        }
        if advertised.count > 1 {
            return .ambiguous(label: label, candidates: advertised)
        }

        // HostName can be useful when DNSName is empty or independently named,
        // but it is only evidence that the input label exists. It is never
        // permission to substitute the unrelated DNSName.
        let hasShortName = records.contains { $0.shortName == label }
        if hasShortName, let primaryDomain = domains.first,
           let result = replacingHost(in: url, with: "\(label).\(primaryDomain)") {
            return .qualified(result)
        }

        return .unknown(label: label)
    }

    /// Scheme default for URL-bar input. A bare word is tailnet intent and uses
    /// HTTP (the Tailscale transport is already encrypted); ordinary domain
    /// names default to HTTPS. Explicit schemes are handled by the caller first.
    static func defaultScheme(forSchemeLessInput input: String) -> String {
        let authority = input.split(separator: "/", maxSplits: 1,
                                    omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let host = authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? authority
        return isBareHostname(host) ? "http" : "https"
    }

    static func isKnownFQDN(_ host: String, hosts: [TailnetHostRecord]) -> Bool {
        let normalized = normalizeName(host)
        return hosts.contains { normalizeName($0.fullName) == normalized }
    }

    static func isTailnetFQDN(_ host: String) -> Bool {
        let normalized = normalizeName(host)
        return normalized.hasSuffix(".ts.net") && normalized != "ts.net"
    }

    private static func isBareHostname(_ host: String) -> Bool {
        let normalized = normalizeName(host)
        return !normalized.isEmpty && !normalized.contains(".") && !normalized.contains(":")
    }

    private static func firstLabel(of name: String) -> String? {
        name.split(separator: ".", omittingEmptySubsequences: true).first.map(String.init)
    }

    private static func normalizeName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func replacingHost(in url: URL, with host: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.host = host
        return components.url
    }
}
