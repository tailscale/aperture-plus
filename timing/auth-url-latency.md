# Auth URL issuance latency

Captured 2026-07-29 against `https://controlplane.tailscale.com` using pure Go
tsnet, a fresh state directory and hostname per run, no auth key, and no browser
interaction.

Run with:

```sh
cd timing/go
go run . -auth-url-only -runs 10
```

The focused mode separates cold local startup through `NeedsLogin` from the wait
for `BrowseToURL`:

| run | Start → NeedsLogin | NeedsLogin → URL | Start → URL |
|---:|---:|---:|---:|
| 1 | 140ms | 7.89s | 8.03s |
| 2 | 110ms | 10.68s | 10.79s |
| 3 | 98ms | 1.55s | 1.65s |
| 4 | 100ms | 7.25s | 7.36s |
| 5 | 110ms | 3.50s | 3.61s |
| 6 | 110ms | 7.08s | 7.19s |
| 7 | 100ms | 2.63s | 2.73s |
| 8 | 100ms | 5.89s | 5.99s |
| 9 | 110ms | 3.51s | 3.62s |
| 10 | 110ms | 5.97s | 6.08s |

Summary:

- Start → NeedsLogin: average 110ms, maximum 140ms.
- NeedsLogin → BrowseToURL: average 5.60s, median 5.89s, p90 7.89s,
  range 1.55–10.68s.
- Start → BrowseToURL: average 5.70s, median 5.99s, range 1.65–10.79s.

Therefore the several-second delay before Aperture can present its login window
is reproduced in pure Go. It is not caused by the app, TailscaleKit, Swift
message polling, `ASWebAuthenticationSession`, or an auth key bypass: the node
reaches `NeedsLogin` in about a tenth of a second and then waits seconds for the
control path to provide the URL.

The existing five-phase lifecycle harness did technically measure Start/Up to
URL, but mixed the two intervals and its auth-key phases naturally skipped
interactive URL issuance. `-auth-url-only` is the clearer diagnostic.

Raw output: `build/login-investigation/go-auth-url-10.txt` (gitignored).
