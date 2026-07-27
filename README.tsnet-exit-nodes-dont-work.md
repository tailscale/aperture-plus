# tsnet exit nodes don't work (and subnet routers via SOCKS proxy)

The Exit Node toggle in Aperture's Settings appears to work (it sets
`ExitNodeID = "auto:any"` and the UI shows it as enabled), but toggling it on
does **not** change the egress IP — `whatismyip.com` (and our diagnostic fetch
of `https://api.ipify.org` through the tsnet SOCKS proxy) shows the same IP
whether the exit node is on or off. This is a **known bug in tsnet**, not an
Aperture bug. This document traces the full root cause.

## Summary

tsnet's SOCKS5 proxy dials via `Dialer.UserDial` (`tsnet.go`). `UserDial` has
three branches for choosing how to dial a resolved IP:

1. **`UseNetstackForIP(ip) == true`** → `NetstackDialTCP` → gVisor userspace →
   WireGuard → the peer. **This is the only path that goes through WireGuard.**
2. **`routes.Lookup(ip) == isTailscaleRoute`** → `getPeerDialer()` → **direct
   OS dial** (bypasses WireGuard).
3. **Neither** → `SystemDial()` → `netns` dialer (binds to default interface,
   deliberately bypasses WireGuard) → direct OS dial.

Exit nodes and subnet routers should go through branch 1 (`NetstackDialTCP` →
WireGuard → exit node peer → internet). And they **do** — *when `PeerForIP`
finds a peer in the route manager's outbound table*. But there's a gap:

### When it works

When an actual exit-node peer is advertising `0.0.0.0/0` (or a subnet router is
advertising `192.168.1.0/24`), the route manager's **outbound table**
(`routeMgr.Outbound()`) has an entry mapping that prefix to the peer.
`PeerForIP(ip)` checks this table (its second branch, after the direct-tailnet-
IP check) and returns the peer → `UseNetstackForIP` returns true →
`NetstackDialTCP` → WireGuard → **works**.

### When it doesn't (the bug we're hitting)

When `ExitNodeID = "auto:any"` is set but **no exit node has been selected yet**
(unresolved auto, or the selected exit node's routes haven't propagated to the
outbound table), `PeerForIP` can't find a peer → `UseNetstackForIP` returns
false → falls through to branch 2 → `routes.Lookup(ip)` matches `0.0.0.0/0`
(the blackhole route) → `getPeerDialer()` → **direct OS dial** → reaches the
internet directly, bypassing WireGuard entirely. The egress IP doesn't change.

Even when an exit node peer **is** available and `PeerForIP` *should* find it,
the route propagation from the route manager to `PeerForIP` may not be happening
in the tsnet/userspace-engine configuration Aperture uses. Our test confirms
the IP doesn't change even with 2 exit-node-capable peers visible in the
netmap — so the `PeerForIP` → `UseNetstackForIP` → `NetstackDialTCP` path is
not being reached for exit-node-routed traffic in practice.

### The `getPeerDialer()` branch is wrong for tsnet

`getPeerDialer()` is a plain `net.Dialer`. On **tailscaled** (the daemon, with a
real TUN device), this works: the OS routing table routes `0.0.0.0/0` →
`tailscale0` (TUN) → WireGuard. But on **tsnet** (userspace, netstack mode, no
TUN), there's no `tailscale0` in the OS routing table — `getPeerDialer()` just
dials directly through the default interface, completely bypassing WireGuard.

The fix would be: in the `routes.Lookup` branch, use `NetstackDialTCP` instead
of `getPeerDialer()`:

```go
// Current (broken in tsnet):
if isTailscaleRoute, _ := routes.Lookup(ipp.Addr()); isTailscaleRoute {
    return d.getPeerDialer().DialContext(ctx, network, ipp.String())
}

// Fixed:
if isTailscaleRoute, _ := routes.Lookup(ipp.Addr()); isTailscaleRoute {
    if strings.HasPrefix(network, "udp") {
        return d.NetstackDialUDP(ctx, ipp)
    }
    return d.NetstackDialTCP(ctx, ipp)
}
```

`NetstackDialTCP` binds the source IP to the node's Tailscale IP
(`s.TailscaleIPs()`), which is correct for exit-node traffic (the exit node
needs to see it coming from the tailnet IP).

## The three dialers explained

| dialer | what it does | netns? | goes through WireGuard? |
| --- | --- | --- | --- |
| `NetstackDialTCP` | gVisor userspace → WireGuard | n/a | **yes** |
| `getPeerDialer()` | plain `net.Dialer` (no netns) | no | only via OS routing table (needs TUN) |
| `SystemDial()` | `net.Dialer` + `netns` (binds to default interface) | yes | **no** — explicitly bypasses |

On tailscaled-with-TUN, `getPeerDialer()` works because the OS routing table
routes tailnet/subnet/exit IPs through `tailscale0`. On tsnet (no TUN),
`getPeerDialer()` is just a direct dial — the OS has no idea these IPs should
go through Tailscale.

## Why `SystemDial` has `netns`

`netns` (network namespace) binds sockets to the **default (non-Tailscale)
interface** — its entire purpose is to prevent traffic from accidentally
routing back through Tailscale. This is correct for tailscaled's own
control-plane traffic (DERP, control server) which should go direct, not
through the tunnel. But it means `SystemDial` actively bypasses WireGuard,
which is the opposite of what exit-node routing needs.

## The TODO age

- **2021-11-30** (3.5 years): `// TODO(bradfitz): netns, etc` — the original
  `tsdial` package commit (`d5405c66b`).
- **2024-04-07** (2 years): `// TODO(bradfitz): fix dialing subnet routers,
  public IPs via exit nodes, etc. This is a temporary partial for macOS.` —
  commit `b0fbd8559`.
- **2024-05-02** (2 years): the `routes.Lookup` → `getPeerDialer()` branch —
  commit `caa3d7594` by Nick Khyl, added for **DNS-over-TCP** to internal DNS
  servers on subnet routes (not for exit nodes or user traffic through the
  SOCKS proxy).
- **2026-05-20** (latest): happy-eyeballs refactor split `UserDial` into
  `dialOneUser`, but **did not change** the route-table branch's dialer choice.

No fix in 2+ years. The TODO's "for macOS" qualifier is misleading — the core
issue (route-table-matched IPs going to `getPeerDialer()` instead of
`NetstackDialTCP`) affects **all tsnet platforms** (Linux, macOS, iOS), because
none of them have a TUN device in netstack mode.

## Why it's been stale so long

The combination of tsnet + SOCKS proxy + exit node is not a common Tailscale
use case:

- **tailscaled** (the daemon): user traffic goes through the **TUN**, not
  `UserDial`. `UserDial` is only for tailscaled's own connections (DNS-over-TCP,
  the optional SOCKS/HTTP proxy, SSH recording, etc.).
- **tsnet**: primarily used for *servers* (listening on the tailnet), not as a
  general-purpose proxy client that routes internet through exit nodes.
- **The real Tailscale iOS app**: uses a NetworkExtension (TUN), so the kernel
  handles routing — `UserDial`/SOCKS is never in the user-traffic path.

Aperture is the first app to rely on tsnet's SOCKS proxy for all browser
traffic, including exit-node-routed internet. The gap went unnoticed because
nobody else was using this combination.

## The diagnostic UI

Aperture's Settings → Exit Node section now shows a live diagnostic:
- **Availability**: how many exit-node-capable peers are in the tailnet (from
  polled `/status`).
- **Egress IP**: fetches `https://api.ipify.org` through the tsnet SOCKS proxy,
  showing the egress IP (or error) with the toggle on and off.

When the bug is present, the egress IP is the same whether the toggle is on or
off — confirming the exit node is not routing. When the upstream fix lands, the
IP should change when toggling on (showing the exit node's egress IP instead of
the local ISP).

## The UI test

`testExitNodeChangesEgressIP` (in `UITests/ApertureUITests.swift`) verifies
that toggling the exit node on changes the egress IP. It **currently fails** —
the IP doesn't change — documenting the bug. It will start passing when the
upstream tsnet fix lands. See the TODO in the test code for details.

## Related: does this affect the iPad -1000 bug?

No. The exit-node toggle being a no-op means it can't be the cause of the iPad
internet-URL -1000 failures — the toggle does nothing to routing either way.
The -1000 investigation is documented in `timing/README.md` (the iOS-26 Local
Network Access / IPAddressSpace hypothesis).
