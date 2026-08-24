// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  ProxyBounceTestHarness.swift
//  Aperture
//
//  Hermetic in-app integration harness used by XCUITest. It runs a real
//  WKWebView against an app-provided WKURLSchemeHandler, then simulates tsnet
//  Running -> Starting -> Running publishes. The page owns JS state and an
//  in-flight fetch. Accessibility labels make an unexpected document reload or
//  a lost fetch observable without a real tailnet/auth key.
//

import SwiftUI
import Combine
import WebKit
import TailscaleKit

private nonisolated final class BounceSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.tailscale.Aperture.bounce-test")
    private var delayedTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        logger.log("bounce harness: scheme request \(url)")
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        if url.path == "/slow" {
            let task = Task { [weak self, weak urlSchemeTask] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let urlSchemeTask else { return }
                let data = Data("fetch-completed".utf8)
                let response = HTTPURLResponse(url: url, statusCode: 200,
                                               httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "text/plain"])!
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                guard let handler = self else { return }
                handler.queue.async { [weak handler] in
                    handler?.delayedTasks.removeValue(forKey: id)
                }
            }
            queue.async { [weak self] in self?.delayedTasks[id] = task }
            return
        }

        let html = """
        <!doctype html><meta name='viewport' content='width=device-width'>
        <title>Proxy bounce test</title>
        <body>
          <p id='loads'>loads: 0</p>
          <p id='fetch'>fetch: pending</p>
          <script>
            let loads = Number(sessionStorage.getItem('bounce-loads') || '0') + 1;
            sessionStorage.setItem('bounce-loads', String(loads));
            document.getElementById('loads').textContent = 'loads: ' + loads;
            webkit.messageHandlers.bounce.postMessage({loads: loads, fetch: 'pending'});
            fetch('bounce-test://page/slow').then(r => r.text()).then(text => {
              document.getElementById('fetch').textContent = 'fetch: ' + text;
              webkit.messageHandlers.bounce.postMessage({loads: loads, fetch: text});
            }).catch(e => {
              document.getElementById('fetch').textContent = 'fetch: ERROR ' + e;
              webkit.messageHandlers.bounce.postMessage({loads: loads, fetch: 'ERROR'});
            });
          </script>
        </body>
        """
        let data = Data(html.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        queue.async { [weak self] in
            self?.delayedTasks.removeValue(forKey: id)?.cancel()
        }
    }
}

@MainActor
private final class BounceMessageBridge: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published var loadCount = 0
    @Published var fetchStatus = "not-started"

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        logger.log("bounce harness: script message \(body)")
        if let loads = body["loads"] as? Int { loadCount = loads }
        if let fetch = body["fetch"] as? String { fetchStatus = fetch }
    }
}

@MainActor
private final class ProxyBounceHarnessModel: ObservableObject {
    let browser: BrowserViewModel
    let bridge = BounceMessageBridge()
    @Published var connectionLabel = "Connected"
    private let tsnet = TSNetModel()
    private let schemeHandler = BounceSchemeHandler()

    init() {
        tsnet.state = .Running
        browser = BrowserViewModel(
            model: tsnet,
            initialURL: URL(string: "bounce-test://page/")!,
            dataStore: .nonPersistent(),
            configureWebView: { [schemeHandler, bridge] configuration in
                configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "bounce-test")
                configuration.userContentController.add(bridge, name: "bounce")
            })
    }

    func bounce() {
        connectionLabel = "Reconnecting"
        tsnet.state = .Starting
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.tsnet.state = .Running
            self?.connectionLabel = "Connected"
        }
    }
}

private struct BounceBridgeStatus: View {
    @ObservedObject var bridge: BounceMessageBridge

    var body: some View {
        Group {
            Text(bridge.loadCount == 1 ? "ONE LOAD" : "LOADS \(bridge.loadCount)")
                .accessibilityIdentifier("bounce-load-count")
            Text(bridge.fetchStatus == "fetch-completed" ? "FETCH COMPLETE" : "FETCH PENDING")
                .accessibilityIdentifier("bounce-fetch-status")
        }
    }
}

struct ProxyBounceTestHarnessView: View {
    @StateObject private var model = ProxyBounceHarnessModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.connectionLabel)
                    .accessibilityIdentifier("bounce-connection-status")
                BounceBridgeStatus(bridge: model.bridge)
                Spacer()
                Button("Simulate connection bounce") { model.bounce() }
                    .accessibilityIdentifier("simulate-connection-bounce")
            }
            .padding()
            Divider()
            BrowserView(model: model.browser)
        }
    }
}
