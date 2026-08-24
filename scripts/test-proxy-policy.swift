// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

// Unit tests for TailnetProxyPolicy — the split-tunnel rule builder that fixes
// the iPad -1000 ("invalid URL") bug. See TSNet/TailnetProxyPolicy.swift.
//
// Run:  make test-policy       (or: scripts/test-proxy-policy.sh)
//
// This compiles the REAL TSNet/TailnetProxyPolicy.swift against a minimal stub
// of the two TailscaleKit types it reads, so the tests exercise shipping code
// without needing the xcframework, a simulator, or a signed build.
//
// The expectations encode `matchDomains` semantics that were verified
// empirically against a logging SOCKS5 proxy (via both URLSession and
// WKWebsiteDataStore) — see the file comment in TailnetProxyPolicy.swift.

import Foundation

var failures = 0
var checks = 0

func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL: \(what)") }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ what: String) {
    checks += 1
    if a != b { failures += 1; print("  FAIL: \(what)\n        got:      \(a)\n        expected: \(b)") }
}

func section(_ s: String) { print("\n== \(s)") }

func peer(host: String, dns: String, ips: [String] = []) -> IpnState.PeerStatus {
    IpnState.PeerStatus(HostName: host, DNSName: dns, TailscaleIPs: ips)
}

func status(suffix: String?, peers: [IpnState.PeerStatus], selfPeer: IpnState.PeerStatus? = nil) -> IpnState.Status {
    var dict: [String: IpnState.PeerStatus] = [:]
    for (i, p) in peers.enumerated() { dict["node\(i)"] = p }
    return IpnState.Status(
        SelfStatus: selfPeer,
        CurrentTailnet: suffix.map { IpnState.TailnetStatus(MagicDNSSuffix: $0) },
        Peer: dict)
}

// ---------------------------------------------------------------- baseline

section("The tailnet IP ranges are ALWAYS present")
// These are what make tailnet-by-raw-IP work, and they are the entire policy
// before the first /status poll. 100.64.0.0/10 is also the range iOS 26
// classifies as IPAddressSpace::Local, which is why proxied tailnet loads pass
// the Local Network Access check while proxied public loads fail closed.
for (label, p) in [("nil status", TailnetProxyPolicy.make(from: nil)),
                   ("ipRangesOnly", TailnetProxyPolicy.ipRangesOnly)] {
    expect(p.matchDomains.contains("100.64.0.0/10"), "\(label): has CGNAT v4 range")
    expect(p.matchDomains.contains("fd7a:115c:a1e0::/48"), "\(label): has Tailscale v6 ULA range")
}

section("hasPeerData distinguishes the bootstrap policy from a real one")
// The proxy is published before the first /status poll, so the first policy is
// IP-ranges-only. Bare single-label URLs (the default home page is
// http://ai/chat) can't be routed under it — they are neither a rule nor
// expandable without a MagicDNS suffix — so BrowserViewModel.loadInitial holds
// them until hasPeerData is true. Getting this flag wrong means the home page
// loads DIRECT and fails.
expect(!TailnetProxyPolicy.ipRangesOnly.hasPeerData, "bootstrap policy: no peer data")
expect(!TailnetProxyPolicy.make(from: nil).hasPeerData, "nil status: no peer data")
expect(!TailnetProxyPolicy.make(from: status(suffix: nil, peers: [])).hasPeerData,
       "empty status: no peer data")
expect(TailnetProxyPolicy.make(from: status(suffix: "tailfoo.ts.net", peers: [])).hasPeerData,
       "a MagicDNS suffix alone counts as peer data")
expect(TailnetProxyPolicy.make(from: status(suffix: nil, peers: [peer(host: "nas", dns: "nas.x.ts.net.")])).hasPeerData,
       "a peer alone counts as peer data")
expect(TailnetProxyPolicy.make(from: status(suffix: nil, peers: [peer(host: "ai", dns: "")])).hasPeerData,
       "a withheld-only peer still counts as peer data")

section("An empty match list is NEVER produced")
// Critical: matchDomains == [] means "proxy EVERYTHING", which is exactly the
// broken pre-fix behaviour. Even the degenerate inputs must keep the IP rules.
expect(!TailnetProxyPolicy.make(from: nil).matchDomains.isEmpty,
       "nil status still yields a non-empty rule set")
expect(!TailnetProxyPolicy.make(from: status(suffix: nil, peers: [])).matchDomains.isEmpty,
       "empty tailnet still yields a non-empty rule set")

// ------------------------------------------------------------ rule building

section("MagicDNS suffix and peer names are folded in")
let s1 = status(suffix: "tailfoo.ts.net",
                peers: [peer(host: "webserver", dns: "webserver.tailfoo.ts.net."),
                        peer(host: "nas", dns: "nas.tailfoo.ts.net.")],
                selfPeer: peer(host: "ipad", dns: "ipad.tailfoo.ts.net."))
let p1 = TailnetProxyPolicy.make(from: s1)
expect(p1.matchDomains.contains("tailfoo.ts.net"), "MagicDNS suffix included")
expect(p1.matchDomains.contains("webserver"), "peer short name included")
expect(p1.matchDomains.contains("nas"), "second peer short name included")
expect(p1.matchDomains.contains("ipad"), "self short name included")
expect(p1.matchDomains.contains("webserver.tailfoo.ts.net"),
       "peer FQDN included with trailing dot stripped")
expect(!p1.matchDomains.contains(""), "no empty entry (would match every host)")
expectEqual(Set(p1.matchDomains).count, p1.matchDomains.count, "no duplicate entries")

section("The public internet is NOT matched by the produced rules")
// A rule set that accidentally covers public hosts would re-trigger the bug.
// matchDomains is a label-wise suffix match, so we replicate that here.
func matches(_ host: String, _ rules: [String]) -> Bool {
    for r in rules where !r.contains("/") {
        if host == r || host.hasSuffix("." + r) { return true }
    }
    return false
}
for host in ["google.com", "www.google.com", "example.com", "apple.com"] {
    expect(!matches(host, p1.matchDomains), "\(host) is NOT proxied (loads DIRECT)")
}
for host in ["webserver", "webserver.tailfoo.ts.net", "other.tailfoo.ts.net"] {
    expect(matches(host, p1.matchDomains), "\(host) IS proxied")
}

// --------------------------------------------- the public-TLD collision case

section("Short names colliding with a public TLD are withheld")
// Verified behaviour: a single-label entry `ai` matches host `ai` AND
// `openai.ai`, because matching is label-wise suffix. Adding such a peer name
// blindly would route part of the public web through the proxy.
let s2 = status(suffix: "tailfoo.ts.net",
                peers: [peer(host: "ai", dns: "ai.tailfoo.ts.net."),
                        peer(host: "tv", dns: "tv.tailfoo.ts.net."),
                        peer(host: "nas", dns: "nas.tailfoo.ts.net.")])
let p2 = TailnetProxyPolicy.make(from: s2)
expect(!p2.matchDomains.contains("ai"), "'ai' withheld (would capture the .ai TLD)")
expect(!p2.matchDomains.contains("tv"), "'tv' withheld (would capture the .tv TLD)")
expect(p2.matchDomains.contains("nas"), "'nas' kept (not a TLD)")
expect(p2.shortNamesWithheldAsPublicTLD.contains("ai"), "'ai' reported as withheld")
expect(p2.shortNamesWithheldAsPublicTLD.contains("tv"), "'tv' reported as withheld")
expect(!matches("openai.ai", p2.matchDomains), "openai.ai is NOT proxied")
expect(!matches("plex.tv", p2.matchDomains), "plex.tv is NOT proxied")
// ...but the peer is still reachable, because its FQDN matches the suffix rule.
expect(matches("ai.tailfoo.ts.net", p2.matchDomains), "the 'ai' peer's FQDN IS proxied")

section("Withheld short names are expanded to their FQDN before loading")
let expanded = p2.expandWithheldShortName(in: URL(string: "http://ai/path?q=1")!,
                                          magicDNSSuffix: "tailfoo.ts.net")
expectEqual(expanded.absoluteString, "http://ai.tailfoo.ts.net/path?q=1",
            "bare 'ai' expands to the FQDN, preserving path and query")
expectEqual(p2.expandWithheldShortName(in: URL(string: "https://ai/")!,
                                       magicDNSSuffix: "tailfoo.ts.net").absoluteString,
            "https://ai.tailfoo.ts.net/", "https scheme preserved")
// Everything else must pass through untouched.
for u in ["http://nas/", "https://google.com/", "http://ai.tailfoo.ts.net/",
          "https://openai.ai/", "http://100.101.102.103/"] {
    expectEqual(p2.expandWithheldShortName(in: URL(string: u)!,
                                           magicDNSSuffix: "tailfoo.ts.net").absoluteString,
                u, "\(u) unchanged")
}
expectEqual(p2.expandWithheldShortName(in: URL(string: "http://ai/")!,
                                       magicDNSSuffix: nil).absoluteString,
            "http://ai/", "no suffix known => left alone (cannot invent an FQDN)")

// ------------------------------------------------------------- sanitisation

section("Malformed peer data cannot create a wildcard rule")
let s3 = status(suffix: "  ",
                peers: [peer(host: "", dns: ""),
                        peer(host: "  ", dns: "  "),
                        peer(host: "bad host", dns: "bad host.ts.net"),
                        peer(host: "good", dns: "good.tailfoo.ts.net.")])
let p3 = TailnetProxyPolicy.make(from: s3)
expect(!p3.matchDomains.contains(""), "no empty rule from blank peer names")
expect(!p3.matchDomains.contains(where: { $0.contains(" ") }), "no rule containing a space")
expect(p3.matchDomains.contains("good"), "the valid peer still made it in")

section("normalizeDomain")
expectEqual(TailnetProxyPolicy.normalizeDomain("Ai.TailFoo.TS.Net."), "ai.tailfoo.ts.net", "lowercase + strip trailing dot")
expectEqual(TailnetProxyPolicy.normalizeDomain(".ts.net"), "ts.net", "strip leading dot")
expectEqual(TailnetProxyPolicy.normalizeDomain("  nas  "), "nas", "trim whitespace")
expectEqual(TailnetProxyPolicy.normalizeDomain(""), "", "empty stays empty (dropped by callers)")
expectEqual(TailnetProxyPolicy.normalizeDomain("   "), "", "blank stays empty")
expectEqual(TailnetProxyPolicy.normalizeDomain("evil.com/path"), "", "path-bearing junk rejected")
expectEqual(TailnetProxyPolicy.normalizeDomain("100.64.0.0/10"), "100.64.0.0/10", "CIDR preserved")

section("labelIsLikelyPublicTLD")
for tld in ["ai", "io", "co", "tv", "me", "com", "net", "org", "dev", "app", "xyz"] {
    expect(TailnetProxyPolicy.labelIsLikelyPublicTLD(tld), "'\(tld)' flagged as a public TLD")
}
for name in ["nas", "webserver", "printer", "pihole", "jellyfin", "ai2"] {
    expect(!TailnetProxyPolicy.labelIsLikelyPublicTLD(name), "'\(name)' not flagged")
}

section("Exit Node on => proxy everything (the ONLY case public traffic is proxied)")
// With an exit node the tailnet legitimately carries all traffic, and public
// hosts must be proxied to egress through it. matchDomains == [] is how "proxy
// everything" is expressed to the OS (verified). Without an exit node this same
// config is the pre-fix behaviour that broke every non-tailnet URL, so the flag
// must be the only thing that produces it.
let exitOn = TailnetProxyPolicy.make(from: s1, exitNodeEnabled: true)
expect(exitOn.proxiesEverything, "exit node on => proxiesEverything")
expect(exitOn.matchDomains.isEmpty, "exit node on => empty matchDomains (proxy all)")
let exitOff = TailnetProxyPolicy.make(from: s1, exitNodeEnabled: false)
expect(!exitOff.proxiesEverything, "exit node off => scoped to the tailnet")
expect(!exitOff.matchDomains.isEmpty, "exit node off => non-empty rules")
expect(!TailnetProxyPolicy.make(from: nil, exitNodeEnabled: false).proxiesEverything,
       "no status + no exit node must NOT proxy everything")
expect(!TailnetProxyPolicy.ipRangesOnly.proxiesEverything,
       "the bootstrap policy must NOT proxy everything")

// ------------------------------------------- stability & reserved names

section("The rule set is stable across polls (no needless republish)")
// status.Peer is a dictionary, so iteration order varies between polls. If the
// rule order varied too, the policy would compare unequal every 5s status poll
// and reset the live proxy configuration under loading pages. Building the
// same tailnet twice (with the dictionary populated in a different order) must
// produce an identical policy.
let manyPeers = (1...25).map { peer(host: "node\($0)", dns: "node\($0).tailfoo.ts.net.") }
let buildA = TailnetProxyPolicy.make(from: status(suffix: "tailfoo.ts.net", peers: manyPeers))
let buildB = TailnetProxyPolicy.make(from: status(suffix: "tailfoo.ts.net", peers: manyPeers.reversed()))
expectEqual(buildA, buildB, "same tailnet in a different dict order => identical policy")
expectEqual(buildA.matchDomains.first, "100.64.0.0/10", "IP rules stay pinned first")

section("A peer named 'localhost' cannot hijack loopback")
// Observed on a real tailnet. Turning this into a proxy rule would route the
// app's own loopback traffic (tsnet localAPI, the SOCKS proxy itself) through
// the proxy.
let s4 = status(suffix: "tailfoo.ts.net",
                peers: [peer(host: "localhost", dns: "localhost.tailfoo.ts.net."),
                        peer(host: "nas", dns: "nas.tailfoo.ts.net.")])
let p4 = TailnetProxyPolicy.make(from: s4)
expect(!p4.matchDomains.contains("localhost"), "'localhost' is not a proxy rule")
expectEqual(p4.matchingRule(for: "localhost"), nil, "localhost resolves DIRECT")
expectEqual(p4.matchingRule(for: "127.0.0.1"), nil, "127.0.0.1 resolves DIRECT")
expect(p4.matchDomains.contains("nas"), "other peers unaffected")

// ---------------------------------------------------- routing explanation

section("matchingRule reproduces the OS's CIDR boundaries")
// These exact boundaries were observed against a real SOCKS proxy: the OS
// proxied 100.101.102.103 and 100.127.255.254 under 100.64.0.0/10, but sent
// 100.5.5.5 and 142.250.80.46 DIRECT. The on-device explainer must agree.
let ipPolicy = TailnetProxyPolicy.ipRangesOnly
for ip in ["100.101.102.103", "100.127.255.254", "100.64.0.0", "100.64.0.1"] {
    expectEqual(ipPolicy.matchingRule(for: ip), "100.64.0.0/10", "\(ip) is inside CGNAT")
}
for ip in ["100.5.5.5", "100.63.255.255", "100.128.0.0", "142.250.80.46",
           "192.168.1.1", "10.0.0.1", "8.8.8.8"] {
    expectEqual(ipPolicy.matchingRule(for: ip), nil, "\(ip) is outside CGNAT (DIRECT)")
}
expectEqual(ipPolicy.matchingRule(for: "fd7a:115c:a1e0::1"), "fd7a:115c:a1e0::/48",
            "tailnet IPv6 inside ULA range")
expectEqual(ipPolicy.matchingRule(for: "2606:4700::1"), nil, "public IPv6 is DIRECT")
expectEqual(ipPolicy.matchingRule(for: "[fd7a:115c:a1e0::1]"), "fd7a:115c:a1e0::/48",
            "bracketed IPv6 literal handled")

section("matchingRule reproduces label-wise suffix matching")
// Verified: `example.com` matches `www.example.com` but NOT `notexample.com`.
expectEqual(p1.matchingRule(for: "webserver.tailfoo.ts.net"), "tailfoo.ts.net",
            "peer FQDN matches the suffix rule")
expectEqual(p1.matchingRule(for: "deep.sub.tailfoo.ts.net"), "tailfoo.ts.net",
            "deep subdomain matches")
expectEqual(p1.matchingRule(for: "webserver"), "webserver", "short name matches exactly")
expectEqual(p1.matchingRule(for: "WEBSERVER"), "webserver", "matching is case-insensitive")
expectEqual(p1.matchingRule(for: "evil-tailfoo.ts.net"), nil,
            "a lookalike host does NOT match (suffix is label-wise, not substring)")
expectEqual(p1.matchingRule(for: "google.com"), nil, "public host is DIRECT")
expectEqual(p2.matchingRule(for: "openai.ai"), nil,
            "public .ai host is DIRECT (the withheld-short-name protection)")

// ------------------------------------------------------------------ summary

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ok")
