# Proxy-semantics measurement harness

The tools that turned the iPad "invalid URL" (`-1000`) investigation from
hypothesis into measurement. They run on **macOS** (host), need no device, no
simulator and no signing, and they exercise the same two APIs the app uses:
`URLSession.proxyConfigurations` and `WKWebsiteDataStore.proxyConfigurations`.

Findings are written up in [`../../timing/README.md`](../../timing/README.md)
("RESOLVED: measured `matchDomains` semantics…") and encoded as unit tests in
[`../test-proxy-policy.sh`](../test-proxy-policy.sh).

## `socks.py` — logging SOCKS5 proxy

A real SOCKS5 server that **logs every CONNECT** and then relays. This is the
instrument: whether a request appears in its log is ground truth for "did the
OS route this host through the proxy, or send it DIRECT?"

```sh
python3 socks.py 18099          # listens on 127.0.0.1:18099, logs to /tmp/pxprobe/socks.log
```

Used to establish the `matchDomains` semantics table (suffix matching, CIDR
support and boundaries, the single-label/TLD collision, empty-entry wildcard,
WebKit ≡ URLSession).

## `failsocks.py` — SOCKS5 proxy that always fails CONNECT

Accepts the handshake, then answers CONNECT with a chosen reply code
(1=general, 2=not-allowed, 3=net-unreachable, 4=host-unreachable, 5=refused).

```sh
python3 failsocks.py 18201 1    # port, reply code
```

## `failmap.swift` — which NSURLError does each SOCKS failure produce?

Drives `failsocks.py` on five ports through **WebKit** and prints the error the
navigation delegate reports.

```sh
for c in 1 2 3 4 5; do python3 failsocks.py $((18200+c)) $c & done
xcrun swiftc -O failmap.swift -o failmap && ./failmap
```

**Result — the key finding:** *every* SOCKS CONNECT failure code surfaces as
`NSURLErrorDomain -1000` (`NSURLErrorBadURL`, shown to users as "invalid URL"),
for both short names and public hostnames. So `-1000` means **"the proxy could
not establish this connection"** — not "the URL is malformed", and not
necessarily Local Network Access. This invalidated the earlier reasoning that
`-1000` proved the request never reached tsnet.

## `e2e.swift` — the fix, end to end

Loads a public host and tailnet destinations through WebKit twice: once with an
unscoped proxy (the old behaviour) and once with the tailnet-scoped rule set
`TailnetProxyPolicy` produces. Confirms the public host stops traversing the
proxy while tailnet destinations still do.

```sh
python3 socks.py 18099 &
xcrun swiftc -O e2e.swift -o e2e && ./e2e
```

Note it also reproduces the user-visible `-1000` locally: a tailnet name the
stand-in proxy can't resolve fails exactly the way the iPad does.
