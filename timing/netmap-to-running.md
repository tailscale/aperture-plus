# Why NetMap → Running takes about 400ms

Investigated 2026-07-29 against the pinned `tailscale.com` source.

## Conclusion

`Running` intentionally does **not** mean merely “an authorized netmap exists.”
It means the userspace data plane has applied the netmap and has at least one
live path: either a peer WireGuard handshake or an active DERP connection.

On a newly-authorized tsnet node there is normally no peer handshake yet, so the
gate is its home-DERP connection. A follow-up spike showed that the measured
~260–270ms after netmap is **not** principally the DERP TCP/TLS connection:
most of it is the initial netcheck required to choose a home DERP. The actual
full DERP connection takes only ~35–40ms on this network.

## Source path

1. Control login succeeds. `LocalBackend.setControlClientStatusLocked` calls
   `authReconfigLocked()` and emits `LoginFinished`.
2. The next control status carries the netmap. The backend stores it and enters
   `Starting`.
3. `enterStateLocked(Starting)` calls `authReconfigLocked()` to build WireGuard,
   router, and DNS configurations and pass them to `wgengine.Reconfig`. It then
   calls `wgengine.RequestStatus` asynchronously.
4. `nextStateLocked` deliberately remains in `Starting` until:

   ```go
   if st.NumLive > 0 || st.LiveDERPs > 0 {
       return ipn.Running
   }
   ```

   `NumLive` counts peers with a non-zero last handshake. `LiveDERPs` is the
   number of active magicsock DERP connections.
5. At this point magicsock does not necessarily know which DERP is nearest.
   Initial netcheck probes the DERP map, determines the preferred region, and
   publishes the node's STUN endpoint. In the instrumented run it tested 28
   regions before selecting Miami at about 13ms RTT.
6. Magicsock then establishes that home DERP asynchronously. Only after
   `derphttp.Client.Connect` completes and its start gate opens does it invoke
   `DERPActiveFunc`.
7. `DERPActiveFunc` is wired to `userspaceEngine.RequestStatus`. That status now
   reports `DERPs > 0`; `LocalBackend.setWgengineStatusLocked` reruns the state
   machine and transitions `Starting → Running`.

The source's own tests encode this contract explicitly: after supplying an
authorized netmap they expect `Starting`; they then fake a DERP connection with
`wgengine.Status{DERPs: 1}` and expect `Running`.

## Measurements

Raw Go interactive runs previously measured:

| LoginFinished → NetMap/Starting | LoginFinished → Running | inferred Starting → Running |
|---:|---:|---:|
| 140ms | 400ms | 260ms |
| 150ms | 420ms | 270ms |
| 140ms | 400ms | 260ms |

The full Swift run measured decoded netmap at 215ms and Running at 616ms from
LoginFinished. Some of that larger apparent difference is frontend observation:
TailscaleKit polls its message queue every 100ms and independently dispatches
each notification to the consumer actor. The raw Go timing is the authoritative
backend number.

`timing/go -interactive` now also subscribes to engine updates and prints
`NumLive`/`LiveDERPs`, making the exact gate visible on future runs.

## DERP connection spike

`timing/go` now has a direct DERP spike:

```sh
cd timing/go
go run . -derp-spike https://derp16b.tailscale.com/derp -derp-runs 10
```

Against the selected Miami region, ICMP RTT was ~13ms. Ten fresh
`derphttp.Client.Connect` calls—which include TCP, TLS 1.3, HTTP/DERP upgrade,
and DERP's authenticated client/server handshake—took:

```text
35, 36, 36, 37, 37, 38, 39, 39, 39, 40ms
```

None used TLS session resumption. A plain HTTPS probe took ~49ms to first byte.
Thus the DERP protocol is only about three RTTs here, not 20+.

A verbose real login (`go run . -interactive -v`) exposed the missing interval:

```text
NetMap / Starting
wgengine Reconfig done
Engine NumLive=0 LiveDERPs=0
successful lite map update in 112ms
netcheck report: udp=true, derp=16, derp16 RTT=14ms (28 regions reported)
home is now derp-16
adding connection to derp-16
derphttp.Client.Connect
Running
```

So the timeline is approximately:

- ~112ms for a lite control-map update occurring alongside endpoint discovery,
- initial netcheck/STUN and multi-region DERP selection,
- ~35–40ms for the selected DERP connection,
- then an engine status callback and `Running`.

The apparently expensive “nearest DERP connect” was mostly *finding* the nearest
DERP and the node's endpoint. This also explains why preconnecting is not
straightforward: before initial netcheck, `myDerp` is zero. Caching or predicting
a prior home DERP could be explored separately.

## Is the delay a bug?

At ~260–270ms from `Starting` to `Running`, no. It includes endpoint discovery,
home-DERP selection, and one network handshake, and is useful: clients that
treat `Running` as proof that traffic can leave the node avoid racing the first
DERP connection. A netmap alone provides topology and keys but does not prove
the data plane has any working path.

Possible future questions, separate from correctness:

- Whether tsnet needs the daemon-oriented `Running` semantic, or could expose an
  additional “configured/netmap-ready” signal for callers that can tolerate a
  not-yet-live path.
- Whether the DERP connection can be prefetched earlier during interactive auth.
- Whether the state machine should count successful local engine reconfiguration
  separately from relay/peer liveness.

Changing `Running` to fire on netmap receipt would weaken a long-standing
backend invariant and would make `tsnet.Up` return before connectivity is known.
That should not be done as a latency workaround.
