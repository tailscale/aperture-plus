//  Created by Jonathan Nobels on 2025-12-09.
//

import TailscaleKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class TSNetModel: ObservableObject {
    @Published var browseToURL: String? = nil
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

    @MainActor @Published var error: Error? = nil

    init(logger: LogSink, model: TSNetModel) {
        self.logger = logger
        self.model = model
    }

    // MARK: - Message Consumer

    func notify(_ notify: TailscaleKit.Ipn.Notify) {
        if let b = notify.BrowseToURL {
            Task { @MainActor in
                logger.log("Authenticate at: \(b)")
                self.model.browseToURL = b
            }
        }

        if let s = notify.State {
            Task { @MainActor in
                logger.log("State: \(s)")
                self.model.state = s
            }
        }

        if let p = notify.Prefs {
            Task { @MainActor in
                self.model.prefs = p
            }
        }

        if let n = notify.NetMap {
            Task { @MainActor in
                self.model.netmap = n
                // 1.82 doesn't support tailnet names
                self.model.tailnetName = n.Domain
            }
        }
    }

    func error(_ error: any Error) {
        logger.log("\(error)")
        Task { @MainActor in
            self.error = error
        }
    }
}
