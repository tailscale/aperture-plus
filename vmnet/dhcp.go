package vmnet

import (
	"encoding/binary"
	"log"
	"net"
	"strings"

	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
)

// isDHCPRequest reports whether pkt is a DHCPv4 request.
func isDHCPRequest(pkt gopacket.Packet) bool {
	v4, ok := pkt.Layer(layers.LayerTypeIPv4).(*layers.IPv4)
	if !ok || v4.Protocol != layers.IPProtocolUDP {
		return false
	}
	udp, ok := pkt.Layer(layers.LayerTypeUDP).(*layers.UDP)
	return ok && udp.DstPort == 67 && udp.SrcPort == 68
}

// handleDHCP responds to DHCP Discover/Request with a fixed IP assignment.
// This is also where we learn the guest's MAC address — the DHCP request is
// the canonical "I am the VM" signal, and pinning vmMAC here keeps us from
// latching onto bridge chatter (STP, IPv6 SLAAC, the bridge's own MAC) on
// shared Linux bridges before the guest comes up.
func (s *Server) handleDHCP(pkt gopacket.Packet) error {
	ethLayer := pkt.Layer(layers.LayerTypeEthernet).(*layers.Ethernet)
	ipLayer := pkt.Layer(layers.LayerTypeIPv4).(*layers.IPv4)
	udpLayer := pkt.Layer(layers.LayerTypeUDP).(*layers.UDP)
	dhcpLayer, ok := pkt.Layer(layers.LayerTypeDHCPv4).(*layers.DHCPv4)
	if !ok {
		log.Printf("dhcp: could not parse DHCPv4 layer from packet")
		return nil
	}

	if len(ethLayer.SrcMAC) == 6 {
		var guestMAC MAC
		copy(guestMAC[:], ethLayer.SrcMAC)
		if guestMAC != (MAC{}) && s.vmMAC != guestMAC {
			s.vmMAC = guestMAC
			log.Printf("Learned VM MAC: %s (from DHCP)", guestMAC)
		}
	}

	response := &layers.DHCPv4{
		Operation:    layers.DHCPOpReply,
		HardwareType: layers.LinkTypeEthernet,
		HardwareLen:  6,
		Xid:          dhcpLayer.Xid,
		ClientHWAddr: dhcpLayer.ClientHWAddr,
		Flags:        dhcpLayer.Flags,
		YourClientIP: s.vmIP.AsSlice(),
		Options: []layers.DHCPOption{
			{
				Type:   layers.DHCPOptServerID,
				Data:   s.gatewayIP.AsSlice(),
				Length: 4,
			},
		},
	}

	var msgType layers.DHCPMsgType
	for _, opt := range dhcpLayer.Options {
		if opt.Type == layers.DHCPOptMessageType && opt.Length > 0 {
			msgType = layers.DHCPMsgType(opt.Data[0])
		}
	}
	switch msgType {
	case layers.DHCPMsgTypeDiscover:
		response.Options = append(response.Options, layers.DHCPOption{
			Type:   layers.DHCPOptMessageType,
			Data:   []byte{byte(layers.DHCPMsgTypeOffer)},
			Length: 1,
		})
	case layers.DHCPMsgTypeRequest:
		response.Options = append(response.Options,
			layers.DHCPOption{
				Type:   layers.DHCPOptMessageType,
				Data:   []byte{byte(layers.DHCPMsgTypeAck)},
				Length: 1,
			},
			layers.DHCPOption{
				Type:   layers.DHCPOptLeaseTime,
				Data:   binary.BigEndian.AppendUint32(nil, 86400),
				Length: 4,
			},
			layers.DHCPOption{
				Type:   layers.DHCPOptRouter,
				Data:   s.gatewayIP.AsSlice(),
				Length: 4,
			},
			layers.DHCPOption{
				Type:   layers.DHCPOptDNS,
				Data:   s.gatewayIP.AsSlice(), // DNS is our gateway
				Length: 4,
			},
			layers.DHCPOption{
				Type:   layers.DHCPOptSubnetMask,
				Data:   net.CIDRMask(s.subnet.Bits(), 32),
				Length: 4,
			},
		)
		// Advertise the link MTU (Option 26) if we were configured with a
		// non-default value. Guests that DHCP will pick this up and set their
		// interface MTU accordingly, which is what we need when routing via
		// an exit node whose WG tunnel adds header overhead beneath us.
		if s.linkMTU != 0 && s.linkMTU != 1500 {
			mtuBytes := make([]byte, 2)
			binary.BigEndian.PutUint16(mtuBytes, uint16(s.linkMTU))
			response.Options = append(response.Options,
				layers.DHCPOption{
					Type:   layers.DHCPOptInterfaceMTU,
					Data:   mtuBytes,
					Length: 2,
				},
			)
		}
		// Add DNS domain search list (Option 119, RFC 3397) if we have a MagicDNS suffix.
		if s.magicDNSSuffix != "" {
			searchData := encodeDNSSearchDomain(s.magicDNSSuffix)
			response.Options = append(response.Options,
				layers.DHCPOption{
					Type:   119, // Domain Search Option (RFC 3397)
					Data:   searchData,
					Length: uint8(len(searchData)),
				},
			)
		}
	default:
		log.Printf("dhcp: ignoring message type %d", msgType)
		return nil
	}

	log.Printf("dhcp: sending %s -> assigning %s (gw %s, dns %s)",
		msgType, s.vmIP, s.gatewayIP, s.gatewayIP)

	// DHCP response: server IP as source, broadcast as dest (client has no IP yet).
	_ = ipLayer
	_ = udpLayer
	eth := &layers.Ethernet{
		SrcMAC:       s.routerMAC.HWAddr(),
		DstMAC:       ethLayer.SrcMAC,
		EthernetType: layers.EthernetTypeIPv4,
	}
	ip := &layers.IPv4{
		Protocol: layers.IPProtocolUDP,
		SrcIP:    s.gatewayIP.AsSlice(),
		DstIP:    net.IPv4bcast,
	}
	udp := &layers.UDP{
		SrcPort: 67,
		DstPort: 68,
	}
	respBytes, err := mkPacket(eth, ip, udp, response)
	if err != nil {
		return err
	}
	log.Printf("dhcp: sending %d byte response", len(respBytes))
	return s.writeToVM(respBytes)
}

// encodeDNSSearchDomain encodes a domain name in DNS wire format (RFC 1035)
// as required by DHCP option 119 (RFC 3397).
// e.g. "corp.ts.net" -> [4]corp[2]ts[3]net[0]
func encodeDNSSearchDomain(domain string) []byte {
	var buf []byte
	for _, label := range strings.Split(domain, ".") {
		buf = append(buf, byte(len(label)))
		buf = append(buf, []byte(label)...)
	}
	buf = append(buf, 0) // root label
	return buf
}
