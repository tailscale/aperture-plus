//
//  ApertureNavigationDecider.swift
//  Aperture
//
//  A `WebPage.NavigationDecider` for the embedded browser.
//
//  The key behaviour: it **trusts the TLS certificate of every server reached
//  through the userspace Tailscale SOCKS5 proxy**. All browser traffic rides
//  the Tailscale wire, which is already authenticated and encrypted at the
//  transport layer, so the endpoint's TLS cert is redundant for trust purposes.
//  Without this, tailnet nodes that serve HTTPS with internal/self-signed or
//  hostname-mismatched certs fail with `NSURLErrorServerCertificateUntrusted`
//  (-1202) — e.g. the Aperture `ai` chat node, reachable as `http://ai/`,
//  redirects to HTTPS whose cert doesn't match the short MagicDNS name "ai".
//  That made both the home page and user-typed http:// URLs fail (silently,
//  before the error plumbing was fixed).
//
//  Caveat: if an exit node is enabled, public-internet traffic also flows
//  through this proxy and its certs would be accepted too. That's a tradeoff
//  for the Aperture single-purpose browser; a future refinement could scope
//  trust to tailnet hosts only.
//

import Foundation
import WebKit

struct ApertureNavigationDecider: WebPage.NavigationDeciding, Sendable {
    mutating func decidePolicy(for action: WebPage.NavigationAction,
                               preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        .allow
    }

    mutating func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        // Allow the response to show. `canShowMimeType` is honoured by WebKit
        // regardless; returning .allow here avoids cancelling valid responses.
        .allow
    }

    mutating func decideAuthenticationChallengeDisposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Trust the server's certificate for server-trust challenges (see the
        // file header for why this is safe in this app).
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        // Everything else (e.g. HTTP basic/digest auth): let the system handle
        // it with the default disposition.
        return (.performDefaultHandling, nil)
    }
}
