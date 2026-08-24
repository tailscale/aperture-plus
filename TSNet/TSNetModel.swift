// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  Created by Jonathan Nobels on 2025-12-09.
//

import TailscaleKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class TSNetModel: ObservableObject {
    @Published var browseToURL: String? = nil
    /// Incremented for every `Notify.LoginFinished` event. This is deliberately
    /// a generation rather than a Bool: interactive reauthentication can
    /// succeed more than once during one process lifetime, and each event must
    /// be observable by the UI so it can dismiss its auth session immediately.
    @Published var loginFinishedGeneration: UInt64 = 0
    @Published var state: Ipn.State? = nil
    @Published var prefs: Ipn.Prefs? = nil
    @Published var netmap: Netmap.NetworkMap? = nil
    @Published var proxyConfiguration: ProxyConfiguration?
    @Published var tailnetName: String?
    /// Live peer status from the localAPI `/status` endpoint (polled). Carries
    /// per-peer `Relay` (DERP) and `CurAddr` (direct) used to classify a tab's
    /// connection as derped vs direct. Nil until the first successful poll.
    @Published var localStatus: IpnState.Status?
    /// The split-tunnel rule set currently applied to `proxyConfiguration`
    /// (which hosts go through the tsnet SOCKS proxy vs. load DIRECT). Kept on
    /// the model so the Settings diagnostic can display it and so
    /// `TSNetManager.refreshProxyPolicyIfNeeded` can tell when the rules
    /// actually changed. See `TailnetProxyPolicy`.
    @Published var proxyPolicy: TailnetProxyPolicy?
    /// Test-only state for the TCP-shutdown chaos recovery XCUITest.
    @Published var tcpChaosTestStatus: String?

    var exitNodeId: String? {
        if let prefs = prefs {
            return prefs.ExitNodeID
        }
        return nil
    }

    var wantRunning: Bool {
        if let prefs = prefs {
            return prefs.WantRunning
        }
        return false
    }

    var currentUserId: Int64? {
        if let netmap {
            return netmap.currentUserProfile()?.id
        }
        return nil
    }
}

actor TSNetConsumer: MessageConsumer {
    private let logger: LogSink
    private let model: TSNetModel
    private var needsLoginAt: ContinuousClock.Instant?
    private var loginFinishedAt: ContinuousClock.Instant?

    @MainActor @Published var error: Error? = nil

    init(logger: LogSink, model: TSNetModel) {
        self.logger = logger
        self.model = model
    }

    // MARK: - Message Consumer

    func notify(_ notify: TailscaleKit.Ipn.Notify) {
        let now = ContinuousClock.now
        if notify.State == .NeedsLogin {
            needsLoginAt = now
            loginFinishedAt = nil
        }
        if notify.LoginFinished != nil {
            loginFinishedAt = now
        }
        if notify.NetMap != nil, let loginFinishedAt {
            logger.log("Login metric: LoginFinished→NetMap \(Self.elapsed(loginFinishedAt, now))")
        }
        if let state = notify.State, state == .Starting || state == .Running {
            if let loginFinishedAt {
                logger.log("Login metric: LoginFinished→\(state) \(Self.elapsed(loginFinishedAt, now))")
            }
            if state == .Running, let needsLoginAt {
                logger.log("Login metric: NeedsLogin→Running \(Self.elapsed(needsLoginAt, now))")
            }
        }

        let fields = [
            notify.LoginFinished != nil ? "LoginFinished" : nil,
            notify.State != nil ? "State" : nil,
            notify.BrowseToURL != nil ? "BrowseToURL" : nil,
            notify.Prefs != nil ? "Prefs" : nil,
            notify.NetMap != nil ? "NetMap" : nil,
        ].compactMap { $0 }.joined(separator: ",")
        if !fields.isEmpty {
            logger.log("IPN notify: \(fields)")
        }

        Task { @MainActor in
            if notify.LoginFinished != nil {
                logger.log("LoginFinished: IPN bus notification received")
                self.model.loginFinishedGeneration &+= 1
            }
            if let b = notify.BrowseToURL {
                logger.log("Authenticate at: \(b)")
                self.model.browseToURL = b
            }
            if let s = notify.State {
                logger.log("State: \(s)")
                self.model.state = s
            }
            if let p = notify.Prefs { self.model.prefs = p }
            if let n = notify.NetMap {
                self.model.netmap = n
                // 1.82 doesn't support tailnet names
                self.model.tailnetName = n.Domain
            }
        }
    }

    private static func elapsed(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> String {
        let duration = start.duration(to: end)
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.3fs", seconds)
    }

    func error(_ error: any Error) {
        logger.log("\(error)")
        Task { @MainActor in
            self.error = error
        }
    }
}
