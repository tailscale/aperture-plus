# Login completion and TailscaleKit netmap decoding

Captured 2026-07-29 against the `libtailscale` submodule revision in this
checkout.

## Raw Go event ordering

`timing/go` now has a real interactive mode:

```sh
cd timing/go
go run . -interactive
# open the printed URL and authorize the node
```

It watches the raw Go IPN bus with `NotifyInitialState|NotifyInitialNetMap` and
prints receipt times for `NeedsLogin`, `BrowseToURL`, `LoginFinished`, netmaps,
`Starting`, and `Running`. In particular it reports:

- signed first-netmap minus `LoginFinished` (negative means a netmap was already
  observed first),
- `LoginFinished` to the first subsequent netmap,
- `LoginFinished` to `Starting`,
- `LoginFinished` to `Running`, and
- `NeedsLogin` to `Running` (includes human/browser time).

Three real null-ID runs produced:

| run | LoginFinished -> netmap | -> Starting | -> Running |
|---|---:|---:|---:|
| 1 | 140ms | 140ms | 400ms |
| 2 | 150ms | 150ms | 420ms |
| 3 | 140ms | 140ms | 400ms |

The backend is therefore behaving normally and very quickly. It emits
`LoginFinished`, then the full netmap and `Starting` about 140–150ms later, then
`Running` about 400–420ms after login completion. `LoginFinished` remains the
right auth-UI dismissal event, but it had indeed hidden a separate Swift
frontend problem: the following netmap was received and discarded.

Auth-key lifecycle mode also displays these fields, but correctly reports no
`LoginFinished`: keyed registration is not interactive authentication and Go
does not emit that event for it. Use `-interactive` for this measurement.

Raw captures are under `build/login-investigation/go-interactive-*.log` and are
gitignored.

## Exact decoding failure

TailscaleKit's `MessageProcessor` previously logged only the complete failed JSON
payload, not the `DecodingError`. After adding coding-path diagnostics, the first
failure was unambiguous:

```
Failed to decode IPN message at NetMap.SelfNode.KeyExpiry:
keyNotFound(KeyExpiry): No value associated with key "KeyExpiry".
```

The wire payload was valid. The mismatch was in TailscaleKit's handwritten
Swift mirror of Go's protocol:

- Current Go `tailcfg.Node.KeyExpiry` has `json:",omitzero"`; no-expiry nodes
  omit the key entirely.
- `tailcfg.Node.Machine` also has `omitzero` and can be absent.
- Current Go `netmap.NetworkMap` no longer has the legacy `Expiry` field.
- TailscaleKit declared all three as mandatory Swift `String` properties, so
  synthesized `Decodable` rejected valid current Go JSON.

The failure was especially reproducible in the timing harness because tagged
or ephemeral auth-key nodes commonly have no key expiry. The entire notify was
then dropped, including its netmap, and Aperture learned peer/routing data later
only through `/status` polling.

## Fix and verification

TailscaleKit now models those omitted/removed fields as optional and treats an
absent `KeyExpiry` as "does not expire". `MessageProcessor` logs the precise
`DecodingError` category and coding path before retaining the raw payload as a
second diagnostic line.

A regression test decodes a minimal current-Go netmap whose self node omits
`KeyExpiry` and `Machine`.

End-to-end iOS simulator verification after rebuilding the xcframework:

```
IPN notify: NetMap
State: Starting
State: Running
```

This occurred for both keyed starts in the Swift lifecycle harness, with zero
`Failed to decode IPN` lines. Before the fix, both starts failed exactly at
`NetMap.SelfNode.KeyExpiry`.

A subsequent full interactive Swift/Aperture run measured the same sequence at
the GUI boundary:

| Swift-observed transition | latency from LoginFinished |
|---|---:|
| decoded NetMap | 215ms |
| Starting | 306ms |
| Running | 616ms |

The roughly 75ms Go-to-Swift netmap difference is consistent with
`MessageProcessor`'s 100ms queue polling interval. There is no multi-second
libtailscale/TailscaleKit delay after authentication once decoding succeeds.

Validation performed:

- `go test ./...` in `timing/go`: passes.
- `make ios-fat`: passes, including Swift 6/library-evolution compilation.
- Aperture iOS simulator Debug build: passes.
- One-run Swift lifecycle harness: two netmaps decoded, no protocol errors.
- Focused TailscaleKit XCTest was added. Running the macOS test suite is
  currently blocked before tests execute by a pre-existing submodule test
  infrastructure mismatch: `tstestcontrol.go` references removed
  `derp.NewServer` / `derphttp.Handler` APIs. This is unrelated to the decoder;
  the same sources compile successfully into both iOS framework slices.

## Scope

This fixes the concrete incompatibilities encountered in the current netmap
shape rather than making the entire protocol permissive. Required identity and
routing fields remain required, so a genuinely malformed backend message still
fails loudly. Optionality follows Go's actual `omitzero`/removed-field contract.
