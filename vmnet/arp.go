package vmnet

import (
	"net/netip"

	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
)

// handleARP responds to ARP requests. For any IP in our subnet, we respond
// with the router MAC since we are the gateway for everything.
func (s *Server) handleARP(pkt gopacket.Packet) error {
	ethLayer, ok := pkt.Layer(layers.LayerTypeEthernet).(*layers.Ethernet)
	if !ok {
		return nil
	}
	arpLayer, ok := pkt.Layer(layers.LayerTypeARP).(*layers.ARP)
	if !ok ||
		arpLayer.Operation != layers.ARPRequest ||
		arpLayer.AddrType != layers.LinkTypeEthernet ||
		arpLayer.Protocol != layers.EthernetTypeIPv4 ||
		arpLayer.HwAddressSize != 6 ||
		arpLayer.ProtAddressSize != 4 ||
		len(arpLayer.DstProtAddress) != 4 {
		return nil
	}

	wantIP := netip.AddrFrom4([4]byte(arpLayer.DstProtAddress))

	// Only respond for the gateway IP. Do NOT respond for the VM's own IP
	// or any other IP -- that would trigger macOS duplicate address detection.
	if wantIP != s.gatewayIP {
		return nil
	}
	eth := &layers.Ethernet{
		SrcMAC:       s.routerMAC.HWAddr(),
		DstMAC:       ethLayer.SrcMAC,
		EthernetType: layers.EthernetTypeARP,
	}
	reply := &layers.ARP{
		AddrType:          layers.LinkTypeEthernet,
		Protocol:          layers.EthernetTypeIPv4,
		HwAddressSize:     6,
		ProtAddressSize:   4,
		Operation:         layers.ARPReply,
		SourceHwAddress:   s.routerMAC.HWAddr(),
		SourceProtAddress: arpLayer.DstProtAddress,
		DstHwAddress:      ethLayer.SrcMAC,
		DstProtAddress:    arpLayer.SourceProtAddress,
	}

	buf := gopacket.NewSerializeBuffer()
	opts := gopacket.SerializeOptions{FixLengths: true, ComputeChecksums: true}
	if err := gopacket.SerializeLayers(buf, opts, eth, reply); err != nil {
		return err
	}
	return s.writeToVM(buf.Bytes())
}
