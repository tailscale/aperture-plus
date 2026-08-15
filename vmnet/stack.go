package vmnet

import (
	"fmt"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/icmp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
)

const nicID = 1

// NetStack wraps a gVisor userspace TCP/IP stack that intercepts all TCP
// traffic from the VM and hands accepted connections to the proxy.
type NetStack struct {
	ns     *stack.Stack
	linkEP *channel.Endpoint
	server *Server
}

func NewNetStack(s *Server) (*NetStack, error) {
	ns := stack.New(stack.Options{
		NetworkProtocols: []stack.NetworkProtocolFactory{
			ipv4.NewProtocol,
		},
		TransportProtocols: []stack.TransportProtocolFactory{
			tcp.NewProtocol,
			icmp.NewProtocol4,
		},
	})

	sackOpt := tcpip.TCPSACKEnabled(true)
	if err := ns.SetTransportProtocolOption(tcp.ProtocolNumber, &sackOpt); err != nil {
		return nil, fmt.Errorf("enable TCP SACK: %v", err)
	}

	mtu := uint32(1500)
	if s.linkMTU != 0 {
		mtu = s.linkMTU
	}
	linkEP := channel.New(4096, mtu, tcpip.LinkAddress(s.routerMAC.HWAddr()))
	if prob := ns.CreateNIC(nicID, linkEP); prob != nil {
		return nil, fmt.Errorf("CreateNIC: %v", prob)
	}
	ns.SetPromiscuousMode(nicID, true)
	ns.SetSpoofing(nicID, true)

	// Add our gateway IP to the stack.
	prefix := tcpip.AddrFrom4Slice(s.gatewayIP.AsSlice()).WithPrefix()
	prefix.PrefixLen = s.subnet.Bits()
	if prob := ns.AddProtocolAddress(nicID, tcpip.ProtocolAddress{
		Protocol:          ipv4.ProtocolNumber,
		AddressWithPrefix: prefix,
	}, stack.AddressProperties{}); prob != nil {
		return nil, fmt.Errorf("AddProtocolAddress: %v", prob)
	}

	// Default route: all IPv4 via this NIC.
	ipv4Subnet, err := tcpip.NewSubnet(
		tcpip.AddrFromSlice(make([]byte, 4)),
		tcpip.MaskFromBytes(make([]byte, 4)),
	)
	if err != nil {
		return nil, fmt.Errorf("create IPv4 subnet: %v", err)
	}
	ns.SetRouteTable([]tcpip.Route{{
		Destination: ipv4Subnet,
		NIC:         nicID,
	}})

	nst := &NetStack{
		ns:     ns,
		linkEP: linkEP,
		server: s,
	}

	// Publish gVisor stack stats via expvar so a /debug/vars scrape can see
	// per-protocol counters (segments sent/received, retransmits, dropped
	// packets, etc.) without requiring code changes to inspect a specific
	// hang. First stack wins; a Server is only expected to have one anyway.
	publishStackStatsOnce.Do(func() {
		publishStackStats(ns)
	})

	// TCP forwarder: accept all TCP connections and proxy them via tsnet.
	const tcpReceiveBufferSize = 0 // default
	const maxInFlight = 8192
	tcpFwd := tcp.NewForwarder(ns, tcpReceiveBufferSize, maxInFlight, s.acceptTCP)
	ns.SetTransportProtocolHandler(tcp.ProtocolNumber, func(tei stack.TransportEndpointID, pb *stack.PacketBuffer) bool {
		return tcpFwd.HandlePacket(tei, pb)
	})

	// Goroutine to read outbound packets from gVisor and send to VM.
	go nst.readFromGvisor()

	return nst, nil
}

// readFromGvisor reads IP packets produced by gVisor (e.g., SYN-ACK, response
// data) and wraps them in ethernet frames addressed to the VM.
func (nst *NetStack) readFromGvisor() {
	for {
		pkt := nst.linkEP.ReadContext(nst.server.ctx)
		if pkt == nil {
			return
		}
		ipRaw := pkt.ToView().AsSlice()
		nst.handleIPPacketFromGvisor(ipRaw)
		pkt.DecRef()
	}
}

func (nst *NetStack) handleIPPacketFromGvisor(ipRaw []byte) {
	if len(ipRaw) == 0 {
		return
	}

	// Prepend a 14-byte Ethernet header directly instead of re-parsing and
	// re-serializing the IP packet through gopacket. gVisor has already
	// computed correct checksums; re-serialization is slow and can corrupt
	// packets under high throughput.
	const ethLen = 14
	frame := make([]byte, ethLen+len(ipRaw))
	copy(frame[0:6], nst.server.vmMAC.HWAddr())      // dst MAC
	copy(frame[6:12], nst.server.routerMAC.HWAddr()) // src MAC
	frame[12] = 0x08                                 // EtherType IPv4 (0x0800)
	frame[13] = 0x00
	copy(frame[ethLen:], ipRaw)

	nst.server.writeToVM(frame)
}

// InjectInbound injects a raw IP packet (extracted from an ethernet frame)
// into the gVisor stack for TCP processing.
func (nst *NetStack) InjectInbound(ipRaw []byte) {
	pktCopy := make([]byte, len(ipRaw))
	copy(pktCopy, ipRaw)
	pb := stack.NewPacketBuffer(stack.PacketBufferOptions{
		Payload: buffer.MakeWithData(pktCopy),
	})
	nst.linkEP.InjectInbound(header.IPv4ProtocolNumber, pb)
	pb.DecRef()
}
