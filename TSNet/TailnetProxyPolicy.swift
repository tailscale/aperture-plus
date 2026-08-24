// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  TailnetProxyPolicy.swift
//  Aperture
//
//  Decides WHICH hosts go through the tsnet SOCKS5 proxy and which load
//  DIRECT — split tunnelling for the browser.
//
//  ## Why (the iPad "invalid URL" / -1000 bug)
//
//  Aperture used to apply the SOCKS5 proxy to EVERY WebKit request (a
//  `ProxyConfiguration` with no match rules proxies everything). Tailnet hosts
//  need that; the public internet does not — and on real hardware the
//  over-broad proxying made every non-tailnet URL fail with an "invalid URL"
//  popup (`NSURLErrorDomain -1000`).
//
//  **What -1000 actually means (measured, not inferred).** Driving WebKit
//  through a SOCKS5 proxy that accepts the connection and then fails the
//  CONNECT produces `NSURLErrorBadURL` (-1000) for *every* SOCKS failure reply
//  (1–5: general, not-allowed, net-unreachable, host-unreachable, refused), for
//  both hostnames and IP literals. So -1000 is CFNetwork's generic "the proxy
//  could not establish this connection" — it says nothing about the URL. See
//  `scripts/proxy-semantics/` for the harness that establishes this.
//
//  That matters because it means we do NOT need to know the exact upstream
//  cause to fix this correctly — and it retires the earlier reasoning that
//  "-1000 is a pre-dial URL rejection, so the request never reached tsnet".
//  Two candidate mechanisms remain consistent with the evidence:
//
//   * **tsnet can't dial public hosts on real iOS** — Go's cgo `getaddrinfo` is
//     unreliable there, while MagicDNS names resolve in-memory. The proxy then
//     fails the CONNECT and WebKit reports -1000.
//   * **iOS 26 Local Network Access** — iOS 26 classifies the *resolved
//     connection IP* into an `IPAddressSpace` (WebKit PR #69886, bug 319906,
//     merged 2026-07-24): *"When the connection address cannot be classified
//     (no resolved address …) the space is left as `IPAddressSpace::Unknown`,
//     which ranks as the least public space so the local network access check
//     fails closed instead of defaulting to Public."* tsnet's SOCKS5 resolves
//     proxy-side (`addrType: domainName`), denying WebKit a resolved address.
//     Tailnet hosts survive because Tailscale uses `100.64.0.0/10` (RFC 6598
//     CGNAT), which that code classifies as `Local` (explicit
//     `IPv4CarrierGradeNAT` test case).
//
//  Both predict exactly what was observed — tailnet works, internet fails, same
//  binary, independent of scheme or hostname shape, not reproducible in the
//  simulator. Both are fixed by not sending public traffic through the proxy.
//  (`-ProxyEverything` re-enables the old behaviour to A/B this on hardware.)
//
//  ## The fix
//
//  Restrict the proxy to tailnet destinations via `matchDomains`. Public hosts
//  then load DIRECT — WebKit resolves and connects to them itself, so they no
//  longer depend on the tsnet proxy being able to dial them, and (under the LNA
//  story) they carry a real resolved public IP instead of classifying as
//  `Unknown` and failing closed. Tailnet hosts still go via the proxy.
//
//  This is the right fix under either candidate mechanism, and it is correct
//  least-privilege design regardless: internet traffic has no business
//  traversing the tsnet node. It matches Safari-on-a-tailnet semantics.
//
//  ## `matchDomains` semantics — verified empirically, not guessed
//
//  Probed against a logging SOCKS5 proxy on macOS 26, via both `URLSession`
//  and `WKWebsiteDataStore.proxyConfigurations` (WebKit behaves identically):
//
//  * **No entries ⇒ proxy everything.** Adding entries switches to "proxy only
//    these, everything else DIRECT". The fix rests on this property.
//  * **Label-wise suffix match:** `example.com` matches `example.com`,
//    `www.example.com`, `a.b.example.com` — but NOT `notexample.com`.
//  * **CIDR entries work, with correct boundaries:** `100.64.0.0/10` proxies
//    `100.101.102.103` and `100.127.255.254`, but not `100.5.5.5` or
//    `142.250.80.46`. IPv6 CIDR (`fd7a:115c:a1e0::/48`) works too.
//  * **A single-label entry also captures that TLD:** entry `ai` matches host
//    `ai` AND `openai.ai`. Hence `labelIsLikelyPublicTLD` below.
//  * **Case-insensitive**; a leading dot (`.ts.net`) is tolerated.
//  * **An empty-string entry matches everything** — never emit one.
//  * **`excludedDomains` is deliberately unused:** its getter is broken on this
//    OS (reads back `matchDomains`) and its matching fires in surprising
//    directions. `matchDomains` alone is well-behaved, so this is an allow-list.
//

import Foundation
import TailscaleKit

/// The set of destinations routed through the tsnet SOCKS5 proxy. Anything not
/// covered loads DIRECT. Pure value type (no WebKit/Network deps) so it is
/// trivially testable.
struct TailnetProxyPolicy: Equatable, Sendable {

    /// Tailscale's IPv4 range — RFC 6598 shared address space (CGNAT).
    static let tailscaleIPv4CIDR = "100.64.0.0/10"
    /// Tailscale's IPv6 ULA range.
    static let tailscaleIPv6CIDR = "fd7a:115c:a1e0::/48"

    /// Entries handed to `ProxyConfiguration.matchDomains`.
    let matchDomains: [String]

    /// Whether this policy was built from real peer/tailnet data (a MagicDNS
    /// suffix or at least one peer), as opposed to being the IP-ranges-only
    /// bootstrap policy published before the first `/status` poll.
    ///
    /// Bare single-label URLs (`http://ai/`, `http://nas/`) can only be routed
    /// once peer data is known — either as a `matchDomains` entry or by
    /// expansion to the tailnet FQDN — so callers use this to avoid loading
    /// such a URL too early and having it go DIRECT and fail. See
    /// `BrowserViewModel.loadInitial`.
    let hasPeerData: Bool

    /// Short MagicDNS names deliberately withheld because the label collides
    /// with a public TLD (a peer named `ai` would capture all of `*.ai`).
    /// Still reachable — `BrowserNavigator` expands them to their FQDN, which
    /// matches the MagicDNS suffix rule. Exposed for diagnostics.
    let shortNamesWithheldAsPublicTLD: [String]

    /// Proxies only the tailnet IP ranges — the safe state before any status
    /// has been polled. Always correct: tailnet-by-IP works and the public
    /// internet is never proxied.
    static let ipRangesOnly = TailnetProxyPolicy(
        matchDomains: [tailscaleIPv4CIDR, tailscaleIPv6CIDR],
        hasPeerData: false,
        shortNamesWithheldAsPublicTLD: [])

    /// Builds the policy from live localAPI status: the tailnet IP ranges, the
    /// MagicDNS suffix (covers every peer FQDN at once), each peer's `DNSName`,
    /// and each peer's short `HostName` unless that label looks like a public
    /// TLD.
    /// Proxies **everything**, including the public internet.
    ///
    /// Only correct when an exit node is enabled: then the tailnet legitimately
    /// carries all traffic, and public hosts must go through the proxy to egress
    /// via the exit node. With no exit node this is the pre-fix behaviour that
    /// made every non-tailnet URL fail ("invalid URL" / -1000), so it must never
    /// be used otherwise.
    ///
    /// An empty `matchDomains` is what "proxy everything" means to the OS
    /// (verified) — the one place an empty list is intentional.
    static let everything = TailnetProxyPolicy(
        matchDomains: [],
        hasPeerData: true,
        shortNamesWithheldAsPublicTLD: [])

    /// Whether this policy routes all traffic (exit-node mode) rather than just
    /// tailnet destinations.
    var proxiesEverything: Bool { matchDomains.isEmpty }

    /// Builds the policy for the current tailnet + routing mode.
    ///
    /// - parameter exitNodeEnabled: When true the policy proxies everything, so
    ///   public traffic can egress through the exit node. When false only
    ///   tailnet destinations are proxied and the internet loads DIRECT.
    static func make(from status: IpnState.Status?,
                     exitNodeEnabled: Bool = false) -> TailnetProxyPolicy {
        if exitNodeEnabled { return .everything }
        var domains = [tailscaleIPv4CIDR, tailscaleIPv6CIDR]
        var withheld: [String] = []
        guard let status else {
            return TailnetProxyPolicy(matchDomains: domains,
                                      hasPeerData: false,
                                      shortNamesWithheldAsPublicTLD: [])
        }

        var seen = Set(domains)
        func add(_ raw: String) {
            let d = normalizeDomain(raw)
            guard !d.isEmpty, !seen.contains(d) else { return }
            seen.insert(d)
            domains.append(d)
        }

        if let suffix = status.CurrentTailnet?.MagicDNSSuffix { add(suffix) }

        var peers: [IpnState.PeerStatus] = Array(status.Peer?.values ?? [:].values)
        if let selfStatus = status.SelfStatus { peers.append(selfStatus) }

        for peer in peers {
            add(peer.DNSName)
            let short = normalizeDomain(peer.HostName)
            guard !short.isEmpty, !short.contains(".") else { continue }
            if labelIsLikelyPublicTLD(short) {
                if !withheld.contains(short) { withheld.append(short) }
            } else {
                add(short)
            }
        }

        // Canonical order. `status.Peer` is a dictionary, so iteration order
        // varies between polls; without sorting, two semantically identical
        // rule sets compare unequal and `refreshProxyPolicyIfNeeded` would
        // republish `proxyConfiguration` on EVERY 5s status poll — resetting
        // `dataStore.proxyConfigurations` under live page loads for no reason.
        // The IP ranges are pinned first purely for readable logs/UI.
        let ipRules = [tailscaleIPv4CIDR, tailscaleIPv6CIDR]
        let named = domains.filter { !ipRules.contains($0) }.sorted()
        // "Peer data" = we learned at least one name (a MagicDNS suffix, a peer
        // FQDN/short name) or withheld one. Either means the status carried
        // real tailnet information.
        let learnedNames = !named.isEmpty || !withheld.isEmpty
        return TailnetProxyPolicy(matchDomains: ipRules + named,
                                  hasPeerData: learnedNames,
                                  shortNamesWithheldAsPublicTLD: withheld.sorted())
    }

    /// Lowercases, trims whitespace and leading/trailing dots. Returns "" for
    /// anything unusable — callers MUST drop those: an empty `matchDomains`
    /// entry matches every host (verified), silently restoring the
    /// proxy-everything behaviour this policy exists to prevent.
    static func normalizeDomain(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stripped = lowered.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !stripped.isEmpty,
              stripped.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !reservedNames.contains(stripped)
        else { return "" }
        // Only CIDR entries may contain "/" — reject stray paths/garbage.
        if stripped.contains("/"), !isCIDR(stripped) { return "" }
        return stripped
    }

    /// Names that must never become proxy rules, no matter what a peer calls
    /// itself. A tailnet peer named `localhost` is real (one showed up in
    /// testing); adding it as a rule would route the app's own loopback
    /// traffic — including the tsnet localAPI and the SOCKS proxy itself —
    /// through the proxy, which is both wrong and potentially a loop.
    private static let reservedNames: Set<String> = [
        "localhost", "localhost.localdomain", "local",
        "127.0.0.1", "::1", "0.0.0.0",
    ]

    private static func isCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/")
        return parts.count == 2 && Int(parts[1]) != nil
    }

    /// The rule that causes `host` to be proxied, or nil if `host` loads
    /// DIRECT. Reimplements the `matchDomains` semantics verified against a
    /// real SOCKS proxy (label-wise suffix for names; range membership for
    /// CIDR entries) so the app can explain its own routing on-device.
    ///
    /// This is a diagnostic mirror of what the OS does, not the mechanism
    /// itself — the OS remains the authority on actual routing.
    func matchingRule(for rawHost: String) -> String? {
        let host = Self.normalizeDomain(rawHost)
        guard !host.isEmpty else { return nil }
        for rule in matchDomains {
            if rule.contains("/") {
                if Self.ipLiteral(host, isInCIDR: rule) { return rule }
            } else if host == rule || host.hasSuffix("." + rule) {
                return rule
            }
        }
        return nil
    }

    /// Whether `host` is an IP literal inside `cidr`. Returns false for
    /// hostnames (a name is only resolved by the OS/proxy, never here).
    static func ipLiteral(_ host: String, isInCIDR cidr: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]) else { return false }
        let network = String(parts[0])
        let stripped = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast()) : host
        guard let a = ipBytes(stripped), let b = ipBytes(network),
              a.count == b.count, bits >= 0, bits <= a.count * 8 else { return false }
        var remaining = bits
        for i in 0..<a.count {
            if remaining >= 8 {
                if a[i] != b[i] { return false }
                remaining -= 8
            } else if remaining > 0 {
                let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - remaining))
                if (a[i] & mask) != (b[i] & mask) { return false }
                remaining = 0
            } else {
                break
            }
        }
        return true
    }

    /// Parses an IPv4/IPv6 literal into raw bytes (4 or 16), or nil if `s` is
    /// not an IP literal.
    private static func ipBytes(_ s: String) -> [UInt8]? {
        var v4 = in_addr()
        if s.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return withUnsafeBytes(of: v4.s_addr) { Array($0) }
        }
        var v6 = in6_addr()
        if s.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return withUnsafeBytes(of: v6) { Array($0) }
        }
        return nil
    }

    /// Rewrites `url` to its tailnet FQDN when its host is a short MagicDNS
    /// name that had to be withheld from `matchDomains` (public-TLD collision,
    /// e.g. a peer literally named `ai`).
    ///
    /// Without this, `http://ai/` would load DIRECT — the public DNS for the
    /// bare label doesn't resolve to the peer — so the name would break. With
    /// it the URL becomes `http://ai.<magicdns-suffix>/`, which matches the
    /// suffix rule and is proxied. Returns `url` unchanged when it doesn't
    /// apply, so it is safe to call on every navigation.
    ///
    /// Note this changes the host WebKit sees, which is correct for TLS: the
    /// peer's cert is issued for the FQDN, not the bare label.
    func expandWithheldShortName(in url: URL, magicDNSSuffix: String?) -> URL {
        guard let host = url.host()?.lowercased(),
              !host.contains("."),
              shortNamesWithheldAsPublicTLD.contains(host),
              let suffix = magicDNSSuffix.map(Self.normalizeDomain), !suffix.isEmpty,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        parts.host = "\(host).\(suffix)"
        return parts.url ?? url
    }

    /// Would using `label` as a `matchDomains` entry also capture a public TLD?
    ///
    /// Every 2-letter TLD is a ccTLD (`.ai`, `.io`, `.co`, `.tv`, `.me`) and
    /// those double as popular machine names — the common collision. A short
    /// list of gTLDs that are also plausible hostnames covers the rest. False
    /// positives are cheap (the name still works via FQDN expansion); a false
    /// negative would route a slice of the public web through the proxy, so
    /// this errs toward withholding.
    static func labelIsLikelyPublicTLD(_ label: String) -> Bool {
        label.count == 2 || riskyGTLDs.contains(label)
    }

    private static let riskyGTLDs: Set<String> = [
        "app", "art", "bar", "bio", "bot", "box", "cam", "car", "chat", "cloud",
        "club", "com", "dev", "edu", "email", "fit", "fun", "fyi", "gov", "guru",
        "help", "home", "host", "info", "ink", "life", "link", "live", "lol",
        "ltd", "media", "mobi", "net", "new", "news", "now", "one", "org",
        "page", "pro", "pub", "rest", "run", "shop", "show", "site", "space",
        "store", "stream", "studio", "style", "tech", "top", "tube", "vip",
        "wiki", "win", "work", "world", "wtf", "xyz", "zone",
    ]
}
