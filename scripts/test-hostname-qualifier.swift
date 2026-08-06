import Foundation

var failures = 0
var checks = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ description: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(description)\n  actual:   \(actual)\n  expected: \(expected)")
    }
}

func qualified(_ input: String, domains: [String], hosts: [TailnetHostRecord]) -> String {
    switch TailnetHostnameQualifier.qualify(URL(string: input)!, searchDomains: domains, hosts: hosts) {
    case .qualified(let url): return url.absoluteString
    case .unchanged(let url): return "unchanged:\(url.absoluteString)"
    case .unknown(let label): return "unknown:\(label)"
    case .ambiguous(let label, let candidates): return "ambiguous:\(label):\(candidates.joined(separator: ","))"
    }
}

let domains = ["corp.ts.net"]

// Exact primary FQDN wins and preserves all URL components.
expectEqual(
    qualified("http://ai:8080/chat?q=1#answer", domains: domains,
              hosts: [.init(shortName: "ai", fullName: "ai.corp.ts.net.")]),
    "http://ai.corp.ts.net:8080/chat?q=1#answer",
    "primary peer qualification preserves scheme, port, path, query, and fragment")

// The reported shared-in case: there is no tsx.corp.ts.net, so use the exact
// first-label FQDN supplied in the signed peer list immediately (no failed load).
expectEqual(
    qualified("http://tsx/path", domains: domains,
              hosts: [.init(shortName: "tsx", fullName: "tsx.bopp-minor.ts.net.")]),
    "http://tsx.bopp-minor.ts.net/path",
    "shared peer uses its advertised foreign-tailnet FQDN")

// Regression for the prior bug: HostName and DNSName may be independently
// named. Never turn ai into benson-1243-test.
expectEqual(
    qualified("http://ai/chat", domains: domains,
              hosts: [.init(shortName: "ai", fullName: "benson-1243-test.corp.ts.net.")]),
    "http://ai.corp.ts.net/chat",
    "short-name evidence never substitutes a differently labeled DNSName")

// Exact-label advertised data beats an unrelated record sharing HostName.
expectEqual(
    qualified("http://ai/chat", domains: domains,
              hosts: [
                .init(shortName: "ai", fullName: "benson-1243-test.corp.ts.net."),
                .init(shortName: "other", fullName: "ai.shared.ts.net."),
              ]),
    "http://ai.shared.ts.net/chat",
    "exact DNS first-label match beats unrelated HostName record")

expectEqual(
    qualified("http://slork/path", domains: domains,
              hosts: [.init(shortName: "ai", fullName: "ai.corp.ts.net")]),
    "http://slork.corp.ts.net/path",
    "unknown bare label is pinned to primary tailnet DNS")
expectEqual(
    qualified("http://slork/", domains: [], hosts: []),
    "unknown:slork",
    "bare label is rejected rather than leaked when no primary domain exists")

expectEqual(
    qualified("http://tsx/", domains: domains,
              hosts: [
                .init(shortName: "tsx", fullName: "tsx.one.ts.net"),
                .init(shortName: "tsx", fullName: "tsx.two.ts.net"),
              ]),
    "ambiguous:tsx:tsx.one.ts.net,tsx.two.ts.net",
    "multiple shared FQDNs are rejected as ambiguous")

expectEqual(
    qualified("https://example.com/path", domains: domains, hosts: []),
    "unchanged:https://example.com/path",
    "multi-label internet URL is unchanged")
expectEqual(
    qualified("http://100.101.102.103/", domains: domains, hosts: []),
    "unchanged:http://100.101.102.103/",
    "IP URL is unchanged")

expectEqual(TailnetHostnameQualifier.defaultScheme(forSchemeLessInput: "ai"), "http",
            "bareword defaults to HTTP")
expectEqual(TailnetHostnameQualifier.defaultScheme(forSchemeLessInput: "ai/chat"), "http",
            "bareword with path defaults to HTTP")
expectEqual(TailnetHostnameQualifier.defaultScheme(forSchemeLessInput: "ai:8080/chat"), "http",
            "bareword with port defaults to HTTP")
expectEqual(TailnetHostnameQualifier.defaultScheme(forSchemeLessInput: "example.com"), "https",
            "internet domain defaults to HTTPS")

let records = [TailnetHostRecord(shortName: "tsx", fullName: "tsx.bopp-minor.ts.net.")]
expectEqual(TailnetHostnameQualifier.isKnownFQDN("tsx.bopp-minor.ts.net", hosts: records), true,
            "advertised FQDN is known")
expectEqual(TailnetHostnameQualifier.isKnownFQDN("tsx.corp.ts.net", hosts: records), false,
            "invented primary FQDN is not known")
expectEqual(TailnetHostnameQualifier.isTailnetFQDN("tsx.corp.ts.net"), true,
            "unknown ts.net FQDN is still in tailnet namespace")
expectEqual(TailnetHostnameQualifier.isTailnetFQDN("example.com"), false,
            "public host is outside tailnet namespace")

if failures == 0 {
    print("\(checks)/\(checks) hostname qualifier checks passed")
} else {
    print("\(failures) of \(checks) hostname qualifier checks failed")
    exit(1)
}
