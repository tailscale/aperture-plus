# Interactive-login completion timing investigation

Captured 2026-07-29 against the `libtailscale` revision embedded by this checkout.
This supplements the cold-start/keyed-node measurements in `README.md`; those
measure backend startup, while this document follows the interactive web-login
completion signal all the way to `ASWebAuthenticationSession` dismissal.

## Question

Why can the Tailscale login sheet/window remain open for many seconds after the
user has authorized the node, and why does manually closing it leave Aperture's
Login button spinning?

## Event contract (pure Go)

The backend has an explicit completion event; callers are not supposed to infer
interactive-auth completion from `Running`:

- `control/controlclient.Client.Login` documents that its callback eventually
  carries either `LoginFinished` or another auth URL.
- `ipn.Notify.LoginFinished` is documented as non-nil when login succeeds.
- `ipn/ipnlocal.LocalBackend.SetControlClientStatus` emits
  `Notify{LoginFinished: ...}` as soon as control reports the login complete,
  before the engine's later `Starting`/`Running` transitions.

The ordinary Tailscale Apple app follows that contract. Its `Notifier` publishes
`LoginFinished`; `HomeViewModel` observes it and immediately cancels its
`ASWebAuthenticationSession`. `UsersSwitcherViewModel` does the same for adding
or reauthenticating accounts.

Aperture's Swift `Ipn.Notify` type already decoded `LoginFinished`, but
`TSNetConsumer` ignored it. `StatusViewModel` instead cancelled auth whenever
state ceased to be `NeedsLogin`. In practice that meant waiting for `Starting`
(and its fallback was the 5-second `/status` poll if the bus missed an event).
This was the missing-notification suspicion in the bug report.

## Baselines

### Pure Go cold lifecycle

`cd timing/go && go run . -runs 3`:

| phase | result |
|---|---|
| key start -> Running | avg 1.32s (1.30–1.34s) |
| logout -> idle | avg 172ms |
| second key start -> Running | avg 1.28s (1.27–1.29s) |

The no-key start -> first URL phase was control-plane-variable in this sample
(5.43s, 8.38s, and a 61.26s outlier). This does not measure post-authorization
sheet dismissal, but confirms that connected startup itself is stable and
short. Raw output: `build/login-investigation/go-baseline.txt` (gitignored).

### UI-less TailscaleKit/Swift harness

`-TimingHarness -TimingRuns 3` on the iOS simulator:

| phase | result |
|---|---|
| key start -> Running | avg 1.42s (1.42–1.43s) |
| logout -> idle | avg 300ms |
| second key start -> Running | avg 1.39s (1.22–1.53s) |

Again, connected startup adds only roughly 0.1–0.2s over Go. The no-key URL
phase was variable (4.99–26.24s), matching the control-plane variability seen
in Go rather than a fixed Swift delay. Raw OSLog:
`build/login-investigation/swift-harness.log` (gitignored).

## Full interactive GUI measurement

The existing null-ID XCUITest (`testInteractiveLoginLogoutRelogin`) was run
before and after instrumenting every relevant bus/auth event. It performs a
real login, logout, and re-login through `ASWebAuthenticationSession`.

A representative post-fix first login was:

```
11:32:43.111  ASWebAuthenticationSession started
11:32:52.361  IPN notify: LoginFinished
11:32:52.363  auth session cancelled for LoginFinished
11:32:52.674  IPN notify: State (Starting)
11:32:52.989  IPN notify: State (Running)
```

The re-login in the same process was:

```
11:33:23.299  ASWebAuthenticationSession started
11:33:30.834  IPN notify: LoginFinished; auth session cancelled
11:33:31.246  State: Starting
11:33:31.353  State: Running
```

Thus `LoginFinished` crossed Go -> local API -> TailscaleKit -> Aperture without
material delay. Aperture now dismisses synchronously on the main actor in the
same log millisecond. `Starting` followed 0.31–0.41s later and `Running` followed
0.52–0.63s later in these samples. Those sub-second differences do not explain
a 10+ second case by themselves, but waiting for state was still the wrong
contract and becomes much worse if state delivery is delayed or the bus watcher
is restarting. The regular Tailscale app's explicit `LoginFinished` handling is
why it is more robust and predictably closes earlier.

Raw logs (gitignored):

- `build/login-investigation/baseline-unified.log`
- `build/login-investigation/fixed-unified.log`
- corresponding `*-xcodebuild.log` files

## Changes

- `TSNetModel` publishes a monotonically increasing
  `loginFinishedGeneration`; a generation is used instead of a Bool so re-login
  in the same process produces another observable event.
- `TSNetConsumer` logs the fields present in each relevant IPN notification and
  forwards `LoginFinished`.
- `StatusViewModel` handles that event exactly like the regular Tailscale app:
  clear stale auth state and cancel the system auth session immediately.
- `AuthManager` now logs session duration and cancellation reason and uses the
  same `ipnauth` callback scheme as the regular app. Backend `LoginFinished`
  remains authoritative because this flow normally completes out-of-band.
- If a user closes/cancels the system auth UI, its completion handler now tells
  both Login-button variants to clear their local spinner immediately. It does
  not pretend authentication succeeded; `needsAuth` remains true and Login is
  retryable.

## Separate finding — resolved

Both interactive runs received a large netmap notification that TailscaleKit
failed to decode, followed by separately decoded `Starting` and `Running`
notifications. This did **not** drop `LoginFinished`—it arrived in its own prior
message—but it was a real wrapper protocol bug: TailscaleKit required
`NetMap.SelfNode.KeyExpiry` even though current Go omits that zero-valued field.
The decoder and protocol mirror are fixed and measured in
[`netmap-decoding.md`](netmap-decoding.md).

## Validation

- Simulator Debug build succeeds under Swift 6 strict concurrency.
- `testInteractiveLoginLogoutRelogin` passes after the change, exercising both
  first login and same-process re-login.
- Captured logs prove two `LoginFinished` generations were observed and both
  auth sessions were cancelled immediately on those events.
