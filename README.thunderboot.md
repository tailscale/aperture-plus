# Thunderboot appliance integration

This document describes the current Aperture+ / Thundersnap appliance
architecture, the diagnostic path that is working today, and the remaining
plan. The detailed checklist and historical decisions remain in
[`TODO.thunderboot.md`](TODO.thunderboot.md).

## Goal

A native macOS Aperture+ workspace may own zero or one persistent Thundersnap
appliance VM. The appliance is an ARM64 Linux guest booted directly by Apple's
`Virtualization.framework`. It has:

- its own persistent raw btrfs disk;
- its own guest Tailscale identity and state;
- a host-supplied Ethernet bridge using the owning workspace's TailscaleKit
  node for transport;
- a host/guest diagnostic channel over virtio-vsock;
- no runtime download requirement for the kernel, initramfs, or appliance
  userspace.

The parent workspace's Tailscale node is transport and bootstrap infrastructure,
not the guest's identity. The guest enrolls separately and appears as a
separate node on the tailnet.

The first version targets native Apple-silicon macOS only. It is not Catalyst.
The Mac target is sandboxed and has the virtualization entitlement.

## Bundled appliance

Thundersnap owns the canonical ARM64 appliance build. The verified import unit
is produced in the pinned Lima ARM64 builder in the Thundersnap repository:

```text
thunderboot-out/
  Image
  initramfs.cpio
  kernel.config
  manifest.json
  thunderboot-appliance-linux-arm64.tar.zst
```

Aperture+ ships the immutable runtime inputs in the Mac app resources:

```text
MacApp/Thunderboot/
  Image
  initramfs.cpio
  manifest.json
```

The `.tar.zst` is build/import transport and is not needed at runtime. The
manifest is schema 1 and records architecture, source revision, kernel version,
artifact sizes, and SHA-256 hashes.

Import and verify artifacts with:

```bash
make import-thunderboot-appliance \
  THUNDERBOOT_SOURCE=../thundersnap/thunderboot-out
```

`make mac-artifacts` stages the verified files into `MacApp/Thunderboot`.
Normal application runtime is download-free.

The guest initramfs contains `thunderboot-init`, `thundersnapd`, `ts`, `vshd`,
BusyBox, btrfs and storage tools, the policy, dynamic libraries, and the CA
bundle. It intentionally does not contain nested Cloud Hypervisor or a nested
kernel in the first ARM64 appliance.

## Guest boot flow

The current guest boot path is:

1. `VZLinuxBootLoader` loads the uncompressed ARM64 `Image` and external
   `initramfs.cpio`.
2. The first virtio block device appears as `/dev/vda`.
3. The kernel uses `console=hvc0`.
4. `thunderboot-init` mounts early filesystems and realizes the declared disk
   layout.
5. The raw disk is formatted/reused as btrfs and mounted at `/newroot`.
6. The appliance payload is copied from the initramfs onto the persistent root.
7. `switch_root` is performed.
8. `thundersnapd` is launched as the guest service.
9. A small `thunderboot-logrelay` wrapper mirrors the daemon's ordinary
   stdout/stderr to the host over virtio-vsock while preserving serial output.

The guest does not implement a new structured control protocol. The initial
host integration deliberately consumes existing log messages instead. The host
recognizes messages such as:

```text
or go to: https://login.tailscale.com/...
tsnet server is up! Tailscale IP: [...]
tsnet hostname: thundersnap-....ts.net
Waiting for SSH connections...
```

This keeps the guest changes small and preserves its normal logs and CLI
behavior.

For automated enrollment, the host passes an auth key as a kernel command-line
parameter:

```text
thunderboot.authkey=...
```

`thunderboot-init` converts it into `TS_AUTHKEY` for `thundersnapd` only. It is
not written to persistent metadata or ordinary logs. Interactive enrollment
remains the eventual product UX; auth-key injection is for development and
headless diagnostics.

## Persistent host state

Each workspace VM is represented by the existence of its VM directory and
metadata, rather than a separate Boolean:

```text
Workspaces/<workspace-id>/
  VM/
    metadata.json
    disk.raw
```

Metadata is versioned and contains:

- VM UUID;
- desired state (`running` or `stopped`);
- creation time;
- appliance/data format version;
- logical disk size.

The initial disk is one sparse 64 GiB raw image attached read/write as one
virtio block device. Creation is staged through a temporary file, uses
`ftruncate`, and atomically renames the completed disk into place.

For a fresh diagnostic test, remove both layers of state:

- the CLI parent node's state directory in its sandbox container;
- the VM workspace directory, which removes the guest's persistent Tailscale
  state along with its data disk.

A reusable auth key is ignored by tsnet when valid state already exists. That
is expected behavior, not an auth-key failure.

## Networking

The intended packet path is:

```text
Guest virtio-net
  -> VZFileHandleNetworkDeviceAttachment
  -> Unix datagram Ethernet socket
  -> TailscaleKit VMNetworkBridge
  -> owning workspace Tailscale node
  -> tailnet/public transport
```

The bridge supplies DHCP, DNS, TCP, and UDP handling. The guest currently
receives a private address from the bridge and uses the bridge for both
bootstrap traffic and tailnet traffic. The parent node's MagicDNS information
is supplied to the bridge.

The public bootstrap requirement is important: before the guest has its own
identity, it must reach Tailscale control/DERP and external identity providers.
The final bridge policy must keep the split-routing distinction clear:

- tailnet destinations use the owning workspace's Tailscale transport;
- public destinations use direct host networking;
- public traffic follows the owning workspace's exit-node policy only when an
  exit node is deliberately enabled;
- DNS resolves both public and tailnet names.

The current TailscaleKit bridge path is proven to carry guest DNS, TCP, UDP,
Tailscale control traffic, DERP/STUN traffic, and public HTTPS bootstrap. A
formal direct-host dial seam and complete MTU/reconnect test matrix remain.

## Reusable Swift package

The platform-neutral VM implementation is being factored into the local Swift
package:

```text
Packages/ApertureVM/
```

It contains:

- `ApplianceArtifacts`: manifest lookup and hash/size validation;
- `VMMetadata`, `VMConfiguration`, `VMStatus`, and lifecycle phases;
- `VMController`: direct Linux boot, sparse disk creation, serial capture,
  bounded log parsing, guest log state detection, and lifecycle management;
- `VMNetworkAttachment`: the dependency-injection seam for the TailscaleKit
  bridge owned by the GUI or diagnostic CLI.

The GUI's existing `WorkspaceVMSupervisor` is still the current app-level owner
and has parallel implementation code. The next refactoring step is to make it
use `ApertureVM.VMController` directly, then remove the duplicate controller
logic from `MacApp/WorkspaceVMSupervisor.swift`.

## Sandboxed diagnostic CLI

`Tools/aperture-vm-cli` builds a proper sandboxed app bundle rather than a bare
executable. It contains the same appliance resources as the GUI app and is
signed with:

```text
com.apple.security.app-sandbox = true
com.apple.security.network.client = true
com.apple.security.network.server = true
com.apple.security.virtualization = true
```

Build it with:

```bash
make aperture-vm-cli
```

Run a storage-only smoke test with a fresh workspace ID:

```bash
build/aperture-vm-cli.app/Contents/MacOS/aperture-vm \
  --auth-key "$(cat ~/.aperture-ios-authkey)" \
  --workspace-id "$(uuidgen)" \
  --storage-only \
  --timeout 15
```

The CLI currently:

1. creates a fresh parent TailscaleKit node in its sandbox container;
2. waits for the parent LocalAPI state to become `Running`;
3. starts the existing VM network bridge;
4. creates a fresh guest disk and metadata directory;
5. passes the auth key to the guest;
6. boots the bundled appliance;
7. consumes serial and vsock logs;
8. detects guest enrollment and hostname;
9. verifies the guest's HTTP metrics endpoint over the parent's Tailscale
   transport in the full non-storage-only mode;
10. exits nonzero on timeout, boot failure, or network-check failure.

The storage-only form is currently passing and reliably observes:

```text
THUNDERBOOT STORAGE OK: /dev/vda
```

The full form now passes guest enrollment and the host-side HTTP reachability
check. The CLI uses a small raw SOCKS5 diagnostic for the plain-HTTP metrics
request, avoiding URLSession/App Transport Security policy differences. It
handles SOCKS authentication, chunked Prometheus responses, transient startup
failures, and bounded retries.

## GUI integration

The native Mac app owns one `WorkspaceVMSupervisor` for all workspaces. The
supervisor is independent of browser and console windows, so closing a window
does not stop a running VM.

Workspace Settings exposes:

- Create & Start;
- Start;
- Stop;
- Restart;
- Open Console;
- Sign in to Tailscale;
- Delete VM with confirmation.

These controls have stable accessibility identifiers, labels, and hints. The
native serial console is bounded and can be reopened without changing VM
lifetime.

The GUI still needs to be migrated onto `ApertureVM.VMController` and its
network attachment adapter. That migration should preserve the existing app
supervisor behavior and make CLI and GUI execution use the same code path.

## Remaining plan

### Immediate

1. [DONE] Make the full CLI test pass consistently, including the guest HTTP metrics
   request through the parent Tailscale node.
2. [DONE] Add a dedicated Makefile target, `make test-aperture-vm`, that:
   - requires/stages the auth key;
   - uses a fresh UUID and sandbox state;
   - builds the signed CLI;
   - runs a bounded full boot/enrollment/network test;
   - prints the guest and bridge logs on failure.
3. [DONE] Make that target a required pre-commit milestone for VM changes.
4. [ ] Add a clean two-boot persistence test: first boot initializes btrfs and guest
   Tailscale state; second boot reuses the same disk without reauthentication.

### Refactor

1. [ ] Adapt the GUI workspace supervisor to use `ApertureVM.VMController`.
2. [ ] Implement the GUI's `VMNetworkAttachment` using the owning workspace's
   `TSNetManager.startVMNetworkBridge`.
3. [ ] Move the shared workspace VM metadata/path persistence into the package or a
   small shared persistence layer without importing SwiftUI into the package.
4. [ ] Remove the duplicate controller and artifact-validation implementations.
5. [ ] Keep all GUI lifecycle operations idempotent and test them independently of
   real enrollment where possible.

### Networking and enrollment

1. [DONE] Finish the guest HTTP/MCP/SSH reachability check from the CLI.
2. [ ] Verify TCP, UDP, DNS, MTU/large packets, and bridge reconnect behavior.
3. [ ] Verify the parent workspace can lose/recover tsnet while the VM reports a
   useful state.
4. [ ] Add interactive enrollment UI using the auth URL detected from guest logs.
5. [ ] Show the guest hostname and addresses distinctly from the parent workspace
   identity.
6. [ ] Confirm restart reuses the guest disk and guest Tailscale identity.

### Product hardening

1. [ ] Add installed-appliance version markers and migration/downgrade checks.
2. [ ] Preserve `/var/lib/thundersnap` and guest Tailscale state across appliance
   upgrades.
3. [ ] Disable the development root/debug console in distribution builds once
   structured diagnostics are sufficient.
4. [ ] Add bounded diagnostic log persistence and avoid retaining auth URLs in
   ordinary persistent logs.
5. [ ] Decide whether release artifacts remain checked into this repository, are
   attached to a Thundersnap release, or are imported only by a release build.
6. [ ] Add storage-only, two-boot, CLI network, and Mac UI coverage to the required
   test suite.

## Useful commands

```bash
# Fast existing policy checks
make test-policy

# Build and sign the native Mac app with bundled artifacts
make mac-app-signed

# Build the standalone sandboxed VM diagnostic
make aperture-vm-cli

# Storage-only CLI boot
build/aperture-vm-cli.app/Contents/MacOS/aperture-vm \
  --auth-key "$(cat ~/.aperture-ios-authkey)" \
  --workspace-id "$(uuidgen)" \
  --storage-only --timeout 15

# Native Mac smoke check
make test-mac

# Inspect live app logs
log stream --style compact --level debug \
  --predicate 'subsystem == "io.tailscale.Aperture"'
```

Every top-level commit must be followed by:

```bash
make subtrac
```

Changes to the Thundersnap submodule are committed there first, then the
Aperture repository records the updated submodule pointer and refreshed bundled
artifact manifest.
