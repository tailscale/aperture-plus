package vmnet

import (
	"context"
	"log"
	"net"
	"net/netip"
	"sync"

	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
)

// Dialer is the workspace-owned tsnet transport used by the guest bridge.
// It deliberately has no lifecycle methods: the embedding TailscaleNode owns
// startup/login/shutdown, and a VM bridge only borrows Dial while that node is
// alive. This is what prevents a second Go runtime or tsnet identity.
type Dialer interface {
	Dial(context.Context, string, string) (net.Conn, error)
}

// FrameLink is the transport that carries raw ethernet frames between the
// Server and a guest VM. The unix-datagram link used by the macOS Swift host
// satisfies this.
//
// ReadFrame returns one ethernet frame per call; the buffer must be large
// enough to hold any frame the underlying transport can deliver (16 KiB is
// safe). WriteFrame sends one frame to the guest.
type FrameLink interface {
	ReadFrame(buf []byte) (int, error)
	WriteFrame(frame []byte) error
	Close() error
}

// Server handles ethernet frames from the VM via a FrameLink and dispatches
// them to the appropriate handler (ARP, DHCP, DNS, TCP via gVisor, UDP).
type Server struct {
	link   FrameLink
	dialer Dialer
	stack  *NetStack

	routerMAC MAC
	vmMAC     MAC
	vmIP      netip.Addr
	gatewayIP netip.Addr
	subnet    netip.Prefix

	verbose        bool
	magicDNSSuffix string
	linkMTU        uint32 // MTU advertised by the gVisor NIC; 0 = default 1500

	ctx    context.Context
	cancel context.CancelFunc
	mu     sync.Mutex

	// UDP sessions are bridge-local. Aperture can run several VM windows
	// against one workspace concurrently; process-global sessions would collide
	// when two guests chose the same ephemeral source port and destination.
	udpSessions   sync.Map
	udpCleanupRun sync.Once
}

// NewServer constructs a bridge around an already-running tsnet dialer.
// magicDNSSuffix supplies DHCP option 119. mtu controls the gVisor NIC; zero
// means the normal Ethernet MTU of 1500.
func NewServer(link FrameLink, dialer Dialer, magicDNSSuffix string, ctx context.Context, verbose bool, mtu uint32) *Server {
	ctx, cancel := context.WithCancel(ctx)
	return &Server{
		link:           link,
		dialer:         dialer,
		routerMAC:      MAC{0x52, 0xee, 0xee, 0xee, 0xee, 0x01},
		vmIP:           netip.MustParseAddr("192.168.72.2"),
		gatewayIP:      netip.MustParseAddr("192.168.72.1"),
		subnet:         netip.MustParsePrefix("192.168.72.0/24"),
		verbose:        verbose,
		magicDNSSuffix: magicDNSSuffix,
		linkMTU:        mtu,
		ctx:            ctx,
		cancel:         cancel,
	}
}

// Serve initializes the gVisor stack, starts port forwarders, and enters the
// main frame-reading loop. It blocks until the FrameLink returns an error or
// the context is canceled.
func (s *Server) Serve() error {
	// Initialize gVisor stack.
	nst, err := NewNetStack(s)
	if err != nil {
		return err
	}
	s.stack = nst

	buf := make([]byte, 16<<10)
	for {
		n, err := s.link.ReadFrame(buf)
		if err != nil {
			if s.ctx.Err() != nil {
				return nil
			}
			log.Printf("ReadFrame: %v", err)
			continue
		}
		raw := make([]byte, n)
		copy(raw, buf[:n])

		// Drop unparseable frames. vmMAC is learned from any unicast frame
		// addressed to our router MAC (handleDHCP also does this explicitly
		// for the DHCP case). Frames addressed to our router MAC are by
		// definition guest-originated traffic targeting our gateway; bridge
		// chatter (IPv6 SLAAC, STP, the bridge's own MAC) is broadcast or
		// multicast and won't match.
		dst, src, _, _, ok := parseEthernet(raw)
		if !ok {
			continue
		}
		if dst == s.routerMAC && s.vmMAC != src {
			if s.vmMAC == (MAC{}) {
				log.Printf("Learned VM MAC: %s (from unicast to gateway)", src)
			}
			s.vmMAC = src
		}

		s.handleFrame(raw)
	}
}

func (s *Server) handleFrame(raw []byte) {
	dst, src, ethType, _, ok := parseEthernet(raw)
	if !ok {
		return
	}

	if s.verbose {
		log.Printf("frame: %s -> %s, type=0x%04x, len=%d", src, dst, uint16(ethType), len(raw))
	}

	switch ethType {
	case layers.EthernetTypeARP:
		if s.verbose {
			log.Printf("  -> ARP")
		}
		pkt := gopacket.NewPacket(raw, layers.LayerTypeEthernet, gopacket.Default)
		if err := s.handleARP(pkt); err != nil {
			log.Printf("arp: %v", err)
		}
		return

	case layers.EthernetTypeIPv4:
		pkt := gopacket.NewPacket(raw, layers.LayerTypeEthernet, gopacket.Default)

		// DHCP
		if isDHCPRequest(pkt) {
			log.Printf("  -> DHCP request from %s", src)
			if err := s.handleDHCP(pkt); err != nil {
				log.Printf("dhcp: %v", err)
			}
			return
		}

		// DNS -- handle async so it doesn't block the frame read loop.
		if s.isDNSRequest(pkt) {
			go func() {
				if err := s.handleDNS(pkt); err != nil {
					log.Printf("dns: %v", err)
				}
			}()
			return
		}

		// Extract the IP-layer bytes from the ethernet frame.
		v4, ok := pkt.Layer(layers.LayerTypeIPv4).(*layers.IPv4)
		if !ok {
			return
		}
		ipBytes := append([]byte(nil), v4.BaseLayer.Contents...)
		ipBytes = append(ipBytes, v4.BaseLayer.Payload...)

		// Check if this is UDP (not DHCP/DNS, already handled above).
		if v4.Protocol == layers.IPProtocolUDP {
			udpLayer, ok := pkt.Layer(layers.LayerTypeUDP).(*layers.UDP)
			if ok {
				fl, ok := flow(pkt)
				if ok {
					payload := make([]byte, len(udpLayer.Payload))
					copy(payload, udpLayer.Payload)
					go s.handleUDP(uint16(udpLayer.SrcPort), uint16(udpLayer.DstPort),
						fl.src, fl.dst, payload)
				}
			}
			return
		}

		// TCP and everything else: inject into gVisor.
		if s.stack != nil {
			s.stack.InjectInbound(ipBytes)
		}

	case layers.EthernetTypeIPv6:
		// IPv6 not supported in v1; drop silently.

	default:
		// Unknown ethertype; drop.
	}
}

// writeToVM sends a raw ethernet frame back to the VM via the link.
func (s *Server) writeToVM(frame []byte) error {
	return s.link.WriteFrame(frame)
}
