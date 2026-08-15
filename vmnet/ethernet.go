package vmnet

import (
	"encoding/binary"
	"fmt"
	"net"
	"net/netip"

	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
)

// MAC is a 6-byte hardware address.
type MAC [6]byte

func (m MAC) IsBroadcast() bool {
	return m == MAC{0xff, 0xff, 0xff, 0xff, 0xff, 0xff}
}

func (m MAC) HWAddr() net.HardwareAddr {
	return net.HardwareAddr(m[:])
}

func (m MAC) String() string {
	return fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x", m[0], m[1], m[2], m[3], m[4], m[5])
}

// parseEthernet parses the raw ethernet frame header.
func parseEthernet(pkt []byte) (dst, src MAC, ethType layers.EthernetType, payload []byte, ok bool) {
	const headerLen = 14
	if len(pkt) < headerLen {
		return
	}
	dst = MAC(pkt[0:6])
	src = MAC(pkt[6:12])
	ethType = layers.EthernetType(binary.BigEndian.Uint16(pkt[12:14]))
	payload = pkt[headerLen:]
	ok = true
	return
}

// mkPacket serializes gopacket layers into a byte slice, automatically setting:
//   - Ethernet.EthernetType to IPv4 or IPv6 if not already set
//   - IPv4/IPv6 Version and TTL/HopLimit defaults
//   - TCP/UDP checksums based on the network layer
func mkPacket(ll ...gopacket.SerializableLayer) ([]byte, error) {
	var el *layers.Ethernet
	var nl gopacket.NetworkLayer
	for _, la := range ll {
		switch la := la.(type) {
		case *layers.IPv4:
			nl = la
			if el != nil && el.EthernetType == 0 {
				el.EthernetType = layers.EthernetTypeIPv4
			}
			if la.Version == 0 {
				la.Version = 4
			}
			if la.TTL == 0 {
				la.TTL = 64
			}
		case *layers.IPv6:
			nl = la
			if el != nil && el.EthernetType == 0 {
				el.EthernetType = layers.EthernetTypeIPv6
			}
			if la.Version == 0 {
				la.Version = 6
			}
			if la.HopLimit == 0 {
				la.HopLimit = 64
			}
		case *layers.Ethernet:
			el = la
		}
	}
	for _, la := range ll {
		switch la := la.(type) {
		case *layers.TCP:
			la.SetNetworkLayerForChecksum(nl)
		case *layers.UDP:
			la.SetNetworkLayerForChecksum(nl)
		}
	}
	buf := gopacket.NewSerializeBuffer()
	opts := gopacket.SerializeOptions{FixLengths: true, ComputeChecksums: true}
	if err := gopacket.SerializeLayers(buf, opts, ll...); err != nil {
		return nil, fmt.Errorf("serializing packet: %v", err)
	}
	return buf.Bytes(), nil
}

type ipSrcDst struct {
	src netip.Addr
	dst netip.Addr
}

func flow(gp gopacket.Packet) (f ipSrcDst, ok bool) {
	if gp == nil {
		return f, false
	}
	n := gp.NetworkLayer()
	if n == nil {
		return f, false
	}
	sb, db := n.NetworkFlow().Endpoints()
	src, _ := netip.AddrFromSlice(sb.Raw())
	dst, _ := netip.AddrFromSlice(db.Raw())
	return ipSrcDst{src: src, dst: dst}, src.IsValid() && dst.IsValid()
}
