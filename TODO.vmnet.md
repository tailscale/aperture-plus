# VM networking

## Current decision

The native Mac GUI temporarily uses Apple's standard
`VZNATNetworkDeviceAttachment` rather than Aperture's custom TailscaleKit
`VMNetworkBridge`.

This gives the Thundersnap guest normal outbound Internet access through the
Mac using Virtualization.framework's DHCP/NAT implementation. The guest keeps
its own Tailscale identity and can establish Tailscale connections through that
NAT. It does not route guest packets through the owning Aperture workspace's
embedded tsnet node and does not provide the eventual AI-containment boundary.

Keep the custom attachment implementation available for the sandboxed VM
command-line integration test and for future isolation work; it should not be
restored as the GUI default until the UDP design below is fixed and tested.

## Observed custom-vmnet failure

`thundersnap-1.bopp-minor.ts.net` showed a characteristic split between dense
and sparse traffic:

- continuous one-second pings quickly settled around 1–12 ms;
- pings spaced ten seconds apart returned samples around 2042 ms and 5052 ms;
- after leaving the bridge idle for seven seconds, a single ping was lost while
  an AperturePlus UDP socket's receive queue grew from 298 to 458 bytes;
- the app accumulated dozens of UDP sockets, including VM/Tailscale endpoint
  sockets with unread receive queues.

This strongly indicates that packets reach the host promptly but are not read
and delivered to the guest until later outgoing traffic happens to install a
reader.

## Probable root cause

`ThirdParty/libtailscale/vmnet/proxy.go` incorrectly models UDP as paired
request/response traffic:

1. Every guest datagram launches `handleUDP` in a new goroutine from
   `vmnet/server.go`.
2. `handleUDP` writes one datagram to a connected UDP socket.
3. It launches `readUDPResponse` for that write.
4. `readUDPResponse` reads exactly one datagram and exits, using a five-second
   read deadline.

UDP, and Tailscale/WireGuard traffic in particular, is asynchronous. Incoming
peer, disco, STUN, and keepalive packets do not correspond one-for-one with a
preceding outgoing datagram. While no `readUDPResponse` goroutine is active,
received packets remain queued in the host socket. A later outgoing packet can
start a reader that drains an old response. This explains:

- latency in multiples of seconds;
- the suspicious approximately five-second delays;
- apparently random packet loss;
- direct-path negotiation fluctuating between healthy and unhealthy;
- dense pings working much better than sparse pings.

This does not look like an MTU failure: tiny ICMP packets reproduce it, and the
growing host receive queues directly identify a receive-lifecycle problem.

## Additional correctness problems

- Concurrent first packets can each dial a new socket. `LoadOrStore` retains
  one session, but losing goroutines continue using rather than closing their
  newly-created sockets. This leaks sockets and creates extra NAT mappings.
- `udpSession.lastUsed` is read and written by multiple goroutines without
  synchronization.
- Launching each guest packet in an independent goroutine can reorder UDP
  datagrams.
- Sessions are keyed by guest source port plus remote destination and use one
  connected host socket per destination. This behaves like symmetric NAT and
  can expose different external mappings for STUN, DERP, and peer traffic.

## Required repair

Each UDP session should have:

- exactly one upstream socket;
- one persistent receive loop for the session's entire lifetime;
- continuous forwarding of every received datagram to the guest;
- serialized creation, writes, and teardown;
- synchronized activity and lifecycle state;
- no per-write receive goroutine and no five-second response deadline;
- deterministic idle eviction that stops the receive loop and closes the
  socket exactly once.

The preferred longer-term model is one unconnected host `PacketConn` per guest
UDP source socket, using `ReadFrom`/`WriteTo`, so all destinations share a stable
NAT mapping. If tsnet cannot expose that semantic directly, document and test
the limitations of connected per-destination sessions.

## Test matrix before restoring custom vmnet

- [ ] Sparse ping/UDP traffic remains low-latency after 10, 30, and 60 seconds
      idle.
- [ ] Dense and sparse UDP have no unexplained loss or receive-queue growth.
- [ ] Tailscale STUN, disco, DERP, and direct peer paths remain stable.
- [ ] Concurrent first datagrams create exactly one session/socket.
- [ ] Repeated session expiry does not leak sockets or goroutines.
- [ ] UDP datagram order is preserved within a guest flow.
- [ ] DNS over UDP and TCP works.
- [ ] TCP throughput and reconnect behavior work.
- [ ] MTU and large-packet behavior work at 1500 and reduced MTUs.
- [ ] Bridge teardown/restart does not leave blocked reads or stale sessions.
- [ ] Multiple simultaneous VMs cannot collide on UDP session keys.
