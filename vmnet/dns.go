package vmnet

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"time"

	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
)

// upstreamDNS is the resolver the guest's non-tailnet DNS queries are
// forwarded to. We dial it via tsnet so the query inherits the active exit
// node, and we use TCP rather than UDP because some commercial VPNs
// (Mullvad in particular) silently drop UDP/53 to non-VPN resolvers to
// force clients onto their own DNS — TCP/53 still flows. We deliberately
// don't use the host's /etc/resolv.conf: that would dial via the host
// network namespace, bypassing tsnet (and the exit node) entirely.
const upstreamDNS = "1.1.1.1:53"

// isDNSRequest reports whether pkt is a DNS query to our gateway.
func (s *Server) isDNSRequest(pkt gopacket.Packet) bool {
	udp, ok := pkt.Layer(layers.LayerTypeUDP).(*layers.UDP)
	if !ok || udp.DstPort != 53 {
		return false
	}
	fl, ok := flow(pkt)
	if !ok {
		return false
	}
	return fl.dst == s.gatewayIP
}

// handleDNS forwards every query through the owning workspace's tsnet dialer.
// MagicDNS and peer-name resolution are therefore scoped to that identity;
// no host resolver or second LocalClient is involved.
func (s *Server) handleDNS(pkt gopacket.Packet) error {
	ethLayer := pkt.Layer(layers.LayerTypeEthernet).(*layers.Ethernet)
	ipLayer := pkt.Layer(layers.LayerTypeIPv4).(*layers.IPv4)
	udpLayer := pkt.Layer(layers.LayerTypeUDP).(*layers.UDP)

	dnsPayload := udpLayer.Payload
	if len(dnsPayload) < 12 {
		return nil
	}

	queryName := parseDNSQueryName(dnsPayload)
	queryType := parseDNSQueryType(dnsPayload)
	log.Printf("[dns] query: %s (type %s)", queryName, dnsQTypeName(queryType))

	var resp []byte
	if queryType == 1 {
		if ip, ok := s.dialer.LookupPeer(s.ctx, queryName); ok {
			resp = buildDNSResponse(dnsPayload, queryName, ip.As4())
			log.Printf("[dns] resolved %s -> %s (workspace tailnet peer)", queryName, ip)
		}
	}
	if resp == nil {
		var err error
		resp, err = s.forwardDNSThroughTsnet(dnsPayload)
		if err != nil {
			log.Printf("[dns] upstream %s for %q: %v", upstreamDNS, queryName, err)
			return nil
		}
		log.Printf("[dns] resolved %s via workspace tsnet (%d bytes)", queryName, len(resp))
	}

	eth := &layers.Ethernet{
		SrcMAC:       s.routerMAC.HWAddr(),
		DstMAC:       ethLayer.SrcMAC,
		EthernetType: layers.EthernetTypeIPv4,
	}
	ip := &layers.IPv4{
		Protocol: layers.IPProtocolUDP,
		SrcIP:    ipLayer.DstIP,
		DstIP:    ipLayer.SrcIP,
	}
	udp := &layers.UDP{
		SrcPort: udpLayer.DstPort,
		DstPort: udpLayer.SrcPort,
	}

	respFrame, err := mkPacket(eth, ip, udp, gopacket.Payload(resp))
	if err != nil {
		return err
	}
	return s.writeToVM(respFrame)
}

// forwardDNSThroughTsnet sends a raw DNS query to upstreamDNS over a TCP
// connection dialled through tsnet, so the query egresses through whatever
// exit node is currently active rather than the host's own resolver path.
// TCP-DNS frames the message with a 2-byte big-endian length prefix
// (RFC 1035 §4.2.2).
func (s *Server) forwardDNSThroughTsnet(query []byte) ([]byte, error) {
	if len(query) > 0xffff {
		return nil, fmt.Errorf("dns query too large (%d bytes)", len(query))
	}
	dialCtx, cancel := context.WithTimeout(s.ctx, 5*time.Second)
	defer cancel()
	conn, err := s.dialer.Dial(dialCtx, "tcp", upstreamDNS)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))

	var lenBuf [2]byte
	binary.BigEndian.PutUint16(lenBuf[:], uint16(len(query)))
	if _, err := conn.Write(lenBuf[:]); err != nil {
		return nil, err
	}
	if _, err := conn.Write(query); err != nil {
		return nil, err
	}

	if _, err := io.ReadFull(conn, lenBuf[:]); err != nil {
		return nil, err
	}
	respLen := int(binary.BigEndian.Uint16(lenBuf[:]))
	resp := make([]byte, respLen)
	if _, err := io.ReadFull(conn, resp); err != nil {
		return nil, err
	}
	return resp, nil
}

// buildDNSResponse constructs a minimal DNS A-record response from a query.
func buildDNSResponse(query []byte, name string, ip [4]byte) []byte {
	// Copy the query header and flip it to a response.
	resp := make([]byte, len(query))
	copy(resp, query)

	// Set QR=1 (response), AA=1 (authoritative), RA=1 (recursion available).
	resp[2] = 0x84 // QR=1, Opcode=0, AA=1
	resp[3] = 0x80 // RA=1, RCODE=0
	// ANCOUNT = 1
	resp[6] = 0
	resp[7] = 1

	// Append answer: pointer to query name + A record.
	answer := []byte{
		0xc0, 0x0c, // pointer to name at offset 12
		0x00, 0x01, // TYPE A
		0x00, 0x01, // CLASS IN
		0x00, 0x00, 0x00, 0x3c, // TTL 60
		0x00, 0x04, // RDLENGTH 4
	}
	answer = append(answer, ip[:]...)
	resp = append(resp, answer...)
	return resp
}

// parseDNSQueryName extracts the first question name from a raw DNS payload.
func parseDNSQueryName(payload []byte) string {
	if len(payload) < 13 {
		return "?"
	}
	var name []byte
	off := 12
	for off < len(payload) {
		labelLen := int(payload[off])
		if labelLen == 0 {
			break
		}
		off++
		if off+labelLen > len(payload) {
			return "?"
		}
		if len(name) > 0 {
			name = append(name, '.')
		}
		name = append(name, payload[off:off+labelLen]...)
		off += labelLen
	}
	if len(name) == 0 {
		return "?"
	}
	return string(name)
}

// parseDNSQueryType extracts the QTYPE from the first question.
func parseDNSQueryType(payload []byte) uint16 {
	if len(payload) < 13 {
		return 0
	}
	// Skip header (12 bytes) then skip QNAME.
	off := 12
	for off < len(payload) {
		labelLen := int(payload[off])
		if labelLen == 0 {
			off++ // skip the zero-length label
			break
		}
		off += 1 + labelLen
	}
	if off+2 > len(payload) {
		return 0
	}
	return binary.BigEndian.Uint16(payload[off : off+2])
}

func dnsQTypeName(t uint16) string {
	switch t {
	case 1:
		return "A"
	case 28:
		return "AAAA"
	case 12:
		return "PTR"
	case 5:
		return "CNAME"
	case 15:
		return "MX"
	case 33:
		return "SRV"
	case 65:
		return "HTTPS"
	default:
		return fmt.Sprintf("type%d", t)
	}
}
