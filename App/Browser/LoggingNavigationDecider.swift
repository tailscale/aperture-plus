//
//  LoggingNavigationDecider.swift
//  Aperture
//
//  A `WebPage.NavigationDecider` that behaves exactly like the default (allows
//  every navigation/response, default auth disposition) but, when the launch
//  arg `-UITestLogResponses` is set, logs each navigation action and response's
//  HTTP status code + URL + MIME type. Keep attached: it's a zero-cost (when
//  the arg is absent) debug flag for investigating load issues — e.g. it's how
//  we found that the flaky `http://ai/chat` 404 was actually `http://ai/chat<8-
//  hex-marker>` (a UserDefaults-corruption bug from the persistence test).
//
//  Run with: `simctl launch ... -- -UITestLogResponses` (or add to a test's
//  launchArguments) and `xcrun simctl spawn booted log stream --predicate
//  'subsystem == "io.tailscale.Aperture"'`, then grep `RESP-LOG` / `LOADED-
//  PAGE`.
//

import Foundation
import WebKit

struct LoggingNavigationDecider: WebPage.NavigationDeciding, Sendable {
    private static let enabled: Bool = ProcessInfo.processInfo.arguments.contains("-UITestLogResponses")

    mutating func decidePolicy(for action: WebPage.NavigationAction,
                               preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        if Self.enabled {
            logger.log("RESP-LOG action: \(action.request.url?.absoluteString ?? "(nil)") type=\(action.navigationType)")
        }
        return .allow
    }

    mutating func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        if Self.enabled {
            let url = response.response.url?.absoluteString ?? "(nil)"
            if let http = response.response as? HTTPURLResponse {
                logger.log("RESP-LOG response: \(http.statusCode) \(url) mime=\(response.response.mimeType ?? "?")")
            } else {
                logger.log("RESP-LOG response: (non-HTTP) \(url) mime=\(response.response.mimeType ?? "?")")
            }
        }
        return .allow
    }

    mutating func decideAuthenticationChallengeDisposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Default disposition — same as not providing a decider.
        (.performDefaultHandling, nil)
    }
}
