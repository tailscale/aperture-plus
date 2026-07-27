// Minimal stand-ins for the TailscaleKit types TailnetProxyPolicy reads, so
// the real policy source can be compiled and unit-tested on the host without
// the TailscaleKit.xcframework (which requires a Go toolchain to build) or a
// simulator. Field names/shapes mirror TailscaleKit's LocalAPI/Types.swift.

import Foundation

enum IpnState {
    struct PeerStatus {
        var HostName: String
        var DNSName: String
        var TailscaleIPs: [String]?

        init(HostName: String, DNSName: String, TailscaleIPs: [String]? = nil) {
            self.HostName = HostName
            self.DNSName = DNSName
            self.TailscaleIPs = TailscaleIPs
        }
    }

    struct TailnetStatus {
        var Name: String
        var MagicDNSSuffix: String
        var MagicDNSEnabled: Bool

        init(Name: String = "tailfoo", MagicDNSSuffix: String, MagicDNSEnabled: Bool = true) {
            self.Name = Name
            self.MagicDNSSuffix = MagicDNSSuffix
            self.MagicDNSEnabled = MagicDNSEnabled
        }
    }

    struct Status {
        var SelfStatus: PeerStatus?
        var CurrentTailnet: TailnetStatus?
        var Peer: [String: PeerStatus]?

        init(SelfStatus: PeerStatus? = nil,
             CurrentTailnet: TailnetStatus? = nil,
             Peer: [String: PeerStatus]? = nil) {
            self.SelfStatus = SelfStatus
            self.CurrentTailnet = CurrentTailnet
            self.Peer = Peer
        }
    }
}
