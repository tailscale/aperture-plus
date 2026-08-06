//
//  RawWebView.swift
//  Aperture
//
//  SwiftUI bridge for the tab's owned WKWebView. Keeping the actual UIKit view
//  gives WebKit the exact frame SwiftUI assigns to the browser region and lets
//  its native keyboard, viewport, and safe-area handling work together.
//

import SwiftUI
import WebKit

#if canImport(UIKit)
struct RawWebView: UIViewRepresentable {
    @ObservedObject var model: BrowserViewModel
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> WKWebView {
        let webView = model.makeWebView()
        applyThemeBackground(to: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        model.attach(webView)
        applyThemeBackground(to: webView)
    }

    /// WKWebView otherwise flashes its default white backing store before the
    /// first document paints. Set both the view and under-page colors so fresh
    /// startup and later new tabs match the active appearance consistently.
    private func applyThemeBackground(to webView: WKWebView) {
        let color: UIColor = colorScheme == .dark ? .black : .white
        webView.isOpaque = true
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
        webView.underPageBackgroundColor = color
    }
}
#else
struct RawWebView: NSViewRepresentable {
    @ObservedObject var model: BrowserViewModel

    func makeNSView(context: Context) -> WKWebView {
        model.makeWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        model.attach(webView)
    }
}
#endif
