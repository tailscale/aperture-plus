import Cocoa
import WebKit
import Network

// End-to-end check of the actual fix: with a tailnet-scoped matchDomains list
// (exactly what TailnetProxyPolicy produces), a PUBLIC host must load DIRECT
// (never touching the proxy), while tailnet destinations still go through it.
//
// The proxy here is a logging SOCKS5 server that deliberately CANNOT reach the
// internet on the tailnet rules' behalf, standing in for the tsnet proxy.

let proxyPort: UInt16 = 18099

// The rule set TailnetProxyPolicy.make() emits for a tailnet named
// "tailfoo.ts.net" with a peer "nas".
let tailnetRules = ["100.64.0.0/10", "fd7a:115c:a1e0::/48", "tailfoo.ts.net", "nas"]

func mk(_ m: [String]) -> ProxyConfiguration {
    let ep = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"),
                                 port: NWEndpoint.Port(rawValue: proxyPort)!)
    var p = ProxyConfiguration(socksv5Proxy: ep)
    if !m.isEmpty { p.matchDomains = m }
    return p
}

func marker(_ s: String) {
    if let fh = FileHandle(forWritingAtPath: "/tmp/pxprobe/socks.log") {
        fh.seekToEndOfFile(); fh.write(("--- \(s)\n").data(using: .utf8)!); try? fh.close()
    }
    print("### \(s)")
}

final class Nav: NSObject, WKNavigationDelegate {
    var done: ((String) -> Void)?
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done?("LOADED") }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        done?("FAILED [\((e as NSError).domain) \((e as NSError).code)]")
    }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        done?("FAILED [\((e as NSError).domain) \((e as NSError).code)]")
    }
}

@MainActor
func load(_ urlStr: String, match: [String]) async -> String {
    let store = WKWebsiteDataStore.nonPersistent()
    store.proxyConfigurations = [mk(match)]
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = store
    let wv = WKWebView(frame: .init(x: 0, y: 0, width: 300, height: 300), configuration: cfg)
    let nav = Nav()
    wv.navigationDelegate = nav
    let result: String = await withCheckedContinuation { c in
        var resumed = false
        nav.done = { r in if !resumed { resumed = true; c.resume(returning: r) } }
        wv.load(URLRequest(url: URL(string: urlStr)!))
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            if !resumed { resumed = true; c.resume(returning: "TIMEOUT") }
        }
    }
    _ = wv
    return result
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task { @MainActor in
    var bad = 0

    marker("E2E-1: BEFORE the fix (proxy everything) -- public host through the proxy")
    let before = await load("http://captive.apple.com/", match: [])
    print("    result: \(before)   (goes through the tsnet-stand-in proxy)")

    marker("E2E-2: AFTER the fix (tailnet-scoped rules) -- public host must load DIRECT")
    let after = await load("http://captive.apple.com/", match: tailnetRules)
    print("    result: \(after)")
    if after != "LOADED" { print("    !! expected LOADED"); bad += 1 }

    marker("E2E-3: tailnet IP still routed through the proxy")
    let tailnet = await load("http://100.101.102.103/", match: tailnetRules)
    print("    result: \(tailnet)  (expect a proxy line in the log above)")

    marker("E2E-4: tailnet name still routed through the proxy")
    let byName = await load("http://nas/", match: tailnetRules)
    print("    result: \(byName)  (expect a proxy line in the log above)")

    print(bad == 0 ? "\nE2E OK" : "\nE2E PROBLEMS: \(bad)")
    exit(bad == 0 ? 0 : 1)
}
app.run()
