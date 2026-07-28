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

struct RawWebView: UIViewRepresentable {
    @ObservedObject var model: BrowserViewModel

    func makeUIView(context: Context) -> WKWebView {
        model.makeWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        model.attach(webView)
    }
}
