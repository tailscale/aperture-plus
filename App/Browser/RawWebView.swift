//
//  RawWebView.swift
//  Aperture
//
//  Temporary spike: render the browser with an owned WKWebView instead of the
//  iOS 26 SwiftUI WebView/WebPage wrapper. This gives WebKit an ordinary UIKit
//  view whose frame exactly matches the SwiftUI slot we assign it.
//

import SwiftUI
import WebKit

struct RawWebView: UIViewRepresentable {
    @ObservedObject var model: BrowserViewModel

    func makeUIView(context: Context) -> WKWebView {
        model.makeWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        model.attach(webView)
    }
}
