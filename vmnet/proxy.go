package vmnet

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"time"

	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/waiter"
)

func netaddrIPFromNetstackIP(s tcpip.Address) netip.Addr {
	switch s.Len() {
	case 4:
		return netip.AddrFrom4(s.As4())
	case 16:
		return netip.AddrFrom16(s.As16())
	}
	return netip.Addr{}
}

// acceptTCP is called by the gVisor TCP forwarder for every new TCP connection
// from the VM. It dials the real destination via tsnet and proxies bidirectionally.
func (s *Server) acceptTCP(r *tcp.ForwarderRequest) {
	reqDetails := r.ID()
	destIP := netaddrIPFromNetstackIP(reqDetails.LocalAddress)
	destPort := reqDetails.LocalPort
	clientIP := netaddrIPFromNetstackIP(reqDetails.RemoteAddress)

	if !clientIP.IsValid() {
		r.Complete(true) // RST
		return
	}

	// Drop attempts to reach other IPs inside our own guest subnet — those
	// are fabricated by us (only the gateway and the guest itself exist),
	// so anything the guest addresses to a sibling IP would loop or bounce.
	// Every other destination — including RFC1918 addresses like the exit
	// node's WG-internal gateway (10.2.0.1 for Proton) — is forwarded to
	// tsnet and routed by the active exit node's AllowedIPs.
	if s.subnet.Contains(destIP) {
		log.Printf("[tcp] BLOCKED %s -> %s:%d (guest subnet)", clientIP, destIP, destPort)
		r.Complete(true) // RST
		return
	}

	dest := fmt.Sprintf("%s:%d", destIP, destPort)
	log.Printf("[tcp] %s -> %s", clientIP, dest)

	var wq waiter.Queue
	ep, tcpErr := r.CreateEndpoint(&wq)
	if tcpErr != nil {
		metricTCPForwarderFailed.Add(1)
		log.Printf("tcp-proxy: CreateEndpoint %s: %v", dest, tcpErr)
		r.Complete(true) // RST
		return
	}
	ep.SocketOptions().SetKeepAlive(true)
	r.Complete(false) // SYN-ACK

	tc := gonet.NewTCPConn(&wq, ep)
	defer tc.Close()

	// Dial through tsnet.
	ctx, cancel := context.WithTimeout(s.ctx, 10*time.Second)
	defer cancel()
	remote, err := s.dialer.Dial(ctx, "tcp", dest)
	if err != nil {
		metricTCPForwarderFailed.Add(1)
		log.Printf("[tcp] dial %s FAILED: %v", dest, err)
		return
	}
	defer remote.Close()
	metricTCPForwarderTotal.Add(1)
	metricTCPForwarderOpen.Add(1)
	defer metricTCPForwarderOpen.Add(-1)
	log.Printf("[tcp] connected %s -> %s", clientIP, dest)

	// Bidirectional copy with proper half-close.
	biCopy(tc, remote)
	log.Printf("[tcp] closed %s -> %s", clientIP, dest)
}

// biCopy copies data bidirectionally between two connections with proper
// half-close handling. When one direction reaches EOF, it signals the other
// side via CloseWrite so the remote knows no more data is coming, then waits
// up to 5 seconds for the other direction to finish gracefully. If the
// second direction is stuck (unresponsive remote, broken CloseWrite), both
// connections are force-closed to unblock it. Both goroutines are guaranteed
// to have exited before biCopy returns.
func biCopy(a, b net.Conn) {
	errc := make(chan error, 2)

	cp := func(dst, src net.Conn) {
		_, err := io.Copy(dst, src)
		// Signal the other end that no more data is coming.
		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			cw.CloseWrite()
		}
		errc <- err
	}

	go cp(a, b)
	go cp(b, a)

	// Wait for the first direction to finish.
	<-errc

	// Give the other direction a bounded window to drain gracefully after
	// the half-close. If it doesn't finish, force-close both connections
	// to break the io.Copy out of its Read/Write. gVisor's *gonet.TCPConn
	// is unreliable at waking a blocked Read on Close alone — the Read
	// registers a waiter.Queue entry that Close doesn't always signal,
	// producing hung goroutines that hold the gVisor endpoint forever.
	// Setting a past read deadline forces the Read to return with a
	// timeout error and drops the waiter, which unblocks the second
	// copy goroutine so we don't leak endpoints on every stalled peer.
	t := time.NewTimer(5 * time.Second)
	defer t.Stop()
	select {
	case <-errc:
	case <-t.C:
		if sd, ok := a.(interface{ SetReadDeadline(time.Time) error }); ok {
			sd.SetReadDeadline(time.Unix(1, 0))
		}
		if sd, ok := b.(interface{ SetReadDeadline(time.Time) error }); ok {
			sd.SetReadDeadline(time.Unix(1, 0))
		}
		a.Close()
		b.Close()
		<-errc
	}
}

// udpSession tracks an active UDP "connection" through tsnet.
type udpSession struct {
	conn interface {
		Write([]byte) (int, error)
		Read([]byte) (int, error)
		Close() error
	}
	lastUsed time.Time
}

// handleUDP proxies a single UDP packet through tsnet.
func (s *Server) handleUDP(srcPort, dstPort uint16, srcIP, dstIP netip.Addr, payload []byte) error {
	if s.subnet.Contains(dstIP) {
		log.Printf("[udp] BLOCKED %s:%d -> %s:%d (guest subnet)", srcIP, srcPort, dstIP, dstPort)
		return nil
	}

	dest := netip.AddrPortFrom(dstIP, dstPort)
	key := fmt.Sprintf("%d-%s", srcPort, dest)

	// Start cleanup goroutine on first use.
	s.udpCleanupRun.Do(func() {
		go s.udpSessionCleaner()
	})

	// Reuse existing session if available.
	if val, ok := s.udpSessions.Load(key); ok {
		sess := val.(*udpSession)
		sess.lastUsed = time.Now()
		if _, err := sess.conn.Write(payload); err != nil {
			// Session stale, remove and re-dial.
			sess.conn.Close()
			if _, loaded := s.udpSessions.LoadAndDelete(key); loaded {
				metricUDPSessionsOpen.Add(-1)
			}
		} else {
			go s.readUDPResponse(sess, srcPort, dstPort, srcIP, dstIP)
			return nil
		}
	}

	// Dial new UDP session through tsnet.
	log.Printf("[udp] %s:%d -> %s", srcIP, srcPort, dest)
	ctx, cancel := context.WithTimeout(s.ctx, 5*time.Second)
	defer cancel()
	conn, err := s.dialer.Dial(ctx, "udp", dest.String())
	if err != nil {
		log.Printf("[udp] dial %s FAILED: %v", dest, err)
		return nil
	}

	sess := &udpSession{conn: conn, lastUsed: time.Now()}
	if _, loaded := s.udpSessions.LoadOrStore(key, sess); !loaded {
		metricUDPSessionsOpen.Add(1)
		metricUDPSessionsTotal.Add(1)
	}

	if _, err := conn.Write(payload); err != nil {
		log.Printf("udp-proxy: write %s: %v", dest, err)
		conn.Close()
		if _, loaded := s.udpSessions.LoadAndDelete(key); loaded {
			metricUDPSessionsOpen.Add(-1)
		}
		return nil
	}

	go s.readUDPResponse(sess, srcPort, dstPort, srcIP, dstIP)
	return nil
}

// readUDPResponse reads a single response from the tsnet UDP conn and sends it
// back to the VM as an ethernet frame.
func (s *Server) readUDPResponse(sess *udpSession, origSrcPort, origDstPort uint16, vmIP, remoteIP netip.Addr) {
	buf := make([]byte, 4096)
	sess.conn.(interface{ SetReadDeadline(time.Time) error }).SetReadDeadline(time.Now().Add(5 * time.Second))
	n, err := sess.conn.Read(buf)
	if err != nil {
		return // timeout or closed, fine
	}
	resp := buf[:n]

	eth := &layers.Ethernet{
		SrcMAC:       s.routerMAC.HWAddr(),
		DstMAC:       s.vmMAC.HWAddr(),
		EthernetType: layers.EthernetTypeIPv4,
	}
	ip := &layers.IPv4{
		Protocol: layers.IPProtocolUDP,
		SrcIP:    remoteIP.AsSlice(),
		DstIP:    vmIP.AsSlice(),
	}
	udp := &layers.UDP{
		SrcPort: layers.UDPPort(origDstPort),
		DstPort: layers.UDPPort(origSrcPort),
	}
	frame, err := mkPacket(eth, ip, udp, gopacket.Payload(resp))
	if err != nil {
		return
	}
	s.writeToVM(frame)
}

func (s *Server) udpSessionCleaner() {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			s.udpSessions.Range(func(key, val any) bool {
				sess := val.(*udpSession)
				if time.Since(sess.lastUsed) > 30*time.Second {
					sess.conn.Close()
					if _, loaded := s.udpSessions.LoadAndDelete(key); loaded {
						metricUDPSessionsOpen.Add(-1)
						metricUDPSessionsEvicted.Add(1)
					}
				}
				return true
			})
		}
	}
}
