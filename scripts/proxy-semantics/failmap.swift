// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

import Cocoa
import WebKit
import Network

// Map each SOCKS5 CONNECT failure reply -> the NSURLError WebKit reports.
// Goal: find which one yields -1000 (NSURLErrorBadURL), the reported symptom.
let names = [1: "general failure", 2: "connection not allowed",
             3: "network unreachable", 4: "host unreachable", 5: "connection refused"]

func mk(_ port: UInt16) -> ProxyConfiguration {
    let ep = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"),
                                 port: NWEndpoint.Port(rawValue: port)!)
    return ProxyConfiguration(socksv5Proxy: ep)
}
final class Nav: NSObject, WKNavigationDelegate {
    var done: ((String) -> Void)?
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done?("LOADED") }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        done?("\((e as NSError).domain) \((e as NSError).code)") }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        done?("\((e as NSError).domain) \((e as NSError).code)") }
}
@MainActor func load(_ u: String, _ port: UInt16) async -> String {
    let store = WKWebsiteDataStore.nonPersistent()
    store.proxyConfigurations = [mk(port)]
    let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = store
    let wv = WKWebView(frame: .init(x: 0, y: 0, width: 200, height: 200), configuration: cfg)
    let nav = Nav(); wv.navigationDelegate = nav
    let r: String = await withCheckedContinuation { c in
        var done = false
        nav.done = { s in if !done { done = true; c.resume(returning: s) } }
        wv.load(URLRequest(url: URL(string: u)!))
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if !done { done = true; c.resume(returning: "TIMEOUT") } }
    }
    _ = wv; return r
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    print("SOCKS5 CONNECT failure reply -> what WebKit reports\n")
    for code in [1,2,3,4,5] {
        let byName = await load("http://nas/", UInt16(18200+code))
        let byPublic = await load("http://captive.apple.com/", UInt16(18200+code))
        print("  reply \(code) (\(names[code]!)) | short-name: \(byName) | public-name: \(byPublic)")
    }
    exit(0)
}
app.run()
