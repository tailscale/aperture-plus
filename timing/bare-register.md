# Bare control registration / auth-URL benchmark

This removes everything above the control client. The program at
`timing/go/register/main.go` constructs only a `controlclient.Direct` and calls:

```go
direct.TryLogin(ctx, controlclient.LoginInteractive)
```

It has no tsnet Server, LocalBackend, wgengine, netstack, magicsock, LocalAPI,
IPN bus, state machine, state directory, Swift, or UI. The remaining Tailscale
code is protocol-essential: machine/node key generation, fetching the control
server's public key, establishing the Noise transport, encoding a
`tailcfg.RegisterRequest`, and posting it to:

```text
POST https://controlplane.tailscale.com/machine/register
```

A raw `curl` cannot replace this last layer because the registration endpoint
uses Tailscale's authenticated Noise transport and typed request encoding.

Run:

```sh
cd timing/go
go run ./register -runs 10
```

## Results

Ten fresh requests produced:

```text
run 1   >90s timeout
run 2    57.02s
run 3    20.80s
run 4    10.21s
run 5     8.46s
run 6     1.39s
run 7     7.78s
run 8     0.80s
run 9     8.58s
run 10    0.82s
```

Successful-run summary: average 12.87s, median 8.46s, p90 20.80s, range
0.80–57.02s, plus one request that did not return within 90 seconds.

A subsequent three-run verbose sample showed exactly where it waited:

```text
control server key ...
Generating a new nodekey.
RegisterReq ...
creating new noise client
                 [18 seconds pass]
RegisterReq: got response ... authURL=true
```

The first and third requests returned in 18.08s and 17.28s. The second timed out
at 60s after `creating new noise client`, before any registration response.

For comparison, ordinary HTTPS/TCP/TLS requests to nearby Tailscale
infrastructure complete in tens of milliseconds. Even allowing several RTTs for
the initial Noise connection, the observed seconds-to-minute variance cannot be
local key generation or protocol framing. It is in the control registration
request/response path (server processing, load balancing, or the Noise HTTP
request upstream of the response), below tsnet.

## Caveat

Each cold run intentionally generates a new machine/node identity and asks for a
new pending auth path. A tight benchmark can itself exercise abuse prevention,
queueing, or per-source registration controls. That is still the same operation
a fresh Aperture workspace performs, but these numbers should not be interpreted
as generic control-plane latency for already-registered nodes. Avoid running
large batches unnecessarily; the ten-run result is already conclusive.

Raw captures (gitignored):

- `build/login-investigation/go-bare-register-10.txt`
- `build/login-investigation/go-bare-register-verbose.txt`
