# Thunderboot appliance integration

Working plan for replacing Aperture+'s disposable Alpine VM prototype with a
persistent, workspace-owned Thundersnap appliance booted from thunderboot
artifacts. Keep this document updated as the implementation progresses.

## Goal

A native macOS Aperture+ workspace may own exactly one optional Thundersnap VM.
The VM boots without downloading its appliance, enrolls as its own Tailscale
node, and persists its Thundersnap data and Tailscale identity across restarts.
It is a background service owned by the workspace, not by a console window.

The first version should boot a headless ARM64 appliance using Apple's
`Virtualization.framework`, the workspace's existing TailscaleKit VM network
bridge, one persistent raw disk, and a host/guest control protocol over
virtio-vsock. During early development, opening/creating the VM should also
show an interactive serial debug console.

## Status notation

- `[x]` records a settled design decision; it does not imply that the product
  code has been implemented.
- `[DONE]` means the implementation or verification work described by that
  checklist item is complete.
- `[ ]` is remaining work.

## Decisions and constraints

- [x] Native macOS and Apple silicon only; keep the existing virtualization
  entitlement and do not convert the target to Catalyst.
- [x] Zero VMs by default.
- [x] Each workspace may have zero or one VM.
- [x] A VM is permanently bound to the workspace that created it for now.
- [x] The VM has its own Tailscale identity. The owning workspace's embedded
  tsnet node supplies the outer network transport but is not the guest's
  identity.
- [x] A running VM remains running while Aperture+ is running, even if all
  windows for its workspace and the VM console are closed.
- [x] A manual stop persists across app launches. A stopped VM does not restart
  merely because Aperture+ is relaunched.
- [x] On app launch, restart each existing VM whose desired state is running.
- [x] Provide create/start, stop, restart, open-console, and delete operations as
  appropriate for the VM's state.
- [x] Deleting a workspace must stop its VM and, after confirmation, delete its
  VM data.
- [x] Persist one sparse raw btrfs disk in the first version. Do not expose
  bcache, RAID, or NBD configuration yet.
- [x] Preserve thunderboot's inner support for bcache, RAID, and NBD for future
  use; the first host configuration simply selects one raw disk.
- [x] Nested virtualization and nested Cloud Hypervisor VMs are out of scope for
  the first version.
- [x] Bundle the complete boot appliance. Aperture+ must not download a kernel,
  initramfs, ISO, or root filesystem in order to boot it.
- [x] Downloading a user-selected Thundersnap frame after boot is allowed and is
  not part of the bundled-appliance requirement.
- [x] Use interactive Tailscale enrollment and surface the guest's `auth_url` to
  the user. Do not make auth-key entry the primary design.
- [x] The eventual product is headless. Keep an interactive serial console and
  root debug shell during early development for diagnosis.

## Terminology

The item bundled by Aperture+ is the **guest Thundersnap appliance**, not the
Linux host-side `cmd/thunderboot` executable. The existing `cmd/thunderboot`
program remains a reference implementation and Linux test harness. Aperture+
reimplements its outer VM orchestration using `Virtualization.framework`.

## Current thunderboot design being adopted

The relevant work is on `../thundersnap`'s `boot` branch:

- `cc5ee90`: appliance PID 1 and initramfs builder
- `2fff7fd`: persistent Thundersnap appliance VM
- `abca54c`: install appliance onto disk and switch root
- `0a1aca1`: package btrfs-progs runtime
- `7e1da68`: guest DNS forwarding
- `d7c0309`: cgroup v2 mount
- `6b379e0`: appliance CA bundle
- `fea4746`: explicit cache/disk specifications
- `aab4c18`: kernel RAID0/RAID1 support
- `4961d14`: guest storage initialization
- `e0a4532` and `4535e62`: raw, RAID, bcache, and NBD end-to-end tests
- `7de4237`: pinned native ARM64 Lima builder and generated x86 KVM artifacts
- `ed8ed00`: reproducible ARM64 kernel/initramfs package and verifier

The appliance flow to preserve is:

1. Boot a kernel and initramfs with one or more block devices.
2. Run `thunderboot-init` as guest PID 1.
3. Realize the declared storage layout and create btrfs when needed.
4. Mount the persistent root at `/newroot`.
5. Install/update the appliance payload from the initramfs onto that root.
6. Switch root.
7. Run and supervise `thundersnapd` using the persistent data/state directory.

## Artifact architecture

### Bundled immutable artifacts

Thundersnap now produces the following verified import unit:

```text
thunderboot-out/
  Image
  initramfs.cpio
  kernel.config
  manifest.json
  thunderboot-appliance-linux-arm64.tar.zst
```

`Image` is the uncompressed ARM64 Linux boot image expected by
`VZLinuxBootLoader`; it is not the ELF `vmlinux` used by the x86 Cloud
Hypervisor harness. `initialRamdiskURL` accepts the external uncompressed cpio,
so there is no need to add a second compression layer merely for boot.

The schema-1 manifest currently records:

- architecture and operating system
- clean or dirty Thundersnap source revision
- kernel release
- source-derived build timestamp
- artifact sizes and SHA-256 hashes

Aperture+'s signed bundle should contain `Image`, `initramfs.cpio`, and
`manifest.json` in a versioned resource directory. It may also retain
`kernel.config` for diagnostics. The `.tar.zst` is the build/import transport,
not something the app needs to unpack at runtime. The bundle signature supplies
distribution integrity; manifest hashes provide import validation and useful
diagnostics.

- [ ] Extend the manifest if Aperture+ needs an explicit compatibility version
  distinct from `schemaVersion`, or exact compiler/package provenance.

### Initramfs contents

The ARM64 initramfs should contain:

- `thunderboot-init`
- `thundersnapd`
- `ts`
- `vshd`
- BusyBox
- btrfs tools and runtime libraries
- `mdadm`
- bcache tools
- NBD client tools
- Thundersnap policy
- CA certificate bundle
- any required ELF interpreter and shared libraries

Do **not** include nested Cloud Hypervisor or a second nested-VM kernel in the
first artifact. Keep the source-level and guest-kernel support needed to add
those later.

### Persistent per-workspace state

Use a per-workspace VM directory, conceptually:

```text
Workspaces/<workspace-id>/VM/
  metadata.json
  disk.raw
```

The on-disk directory is the source of truth for whether the workspace has a
VM; do not rely on a standalone Boolean that can become inconsistent with the
VM files. Metadata should include a stable VM ID, desired state, appliance/data
format version, creation time, and disk configuration.

Initial storage defaults:

- one sparse raw image
- a conservative initial logical size, tentatively 32–64 GB
- attached read/write as one virtio block device (`/dev/vda`)
- kernel parameter `thunderboot.disk=/dev/vda`
- no cache parameter
- excluded from Time Machine/backups where appropriate

Do not use thunderboot's current 2 TB test/development default without an
explicit product decision.

## ARM64 artifact build environment

The old checked-in `vm/cloud-hypervisor` and `vm/vmlinux` artifacts were
x86-64 and could not boot on Aperture+'s Apple-silicon VM. They have been
removed from the current Thundersnap tree and are now fetched/built with pinned
checksums for Linux/KVM tests. Their old objects remain in git history unless
that history is rewritten separately. The initramfs builder still correctly
runs on Linux because it gathers Linux dynamic dependencies with `ldd`.

Use a standard, pinned ARM64 Linux build VM rather than building the complete
appliance with ad hoc macOS cross-tools or turning Aperture+'s product VM into a
builder.

Recommended build arrangement:

- Lima using Apple Virtualization.framework
- pinned Debian ARM64 image and checksum
- scripted, pinned package/toolchain setup
- persistent builder disk
- development source-tree mount
- deterministic artifact output directory
- artifact architecture and hash verification

Thundersnap should own the canonical kernel/initramfs production recipe because
it owns the guest requirements. Aperture+ should consume artifacts tied to a
specific Thundersnap revision.

- [DONE] Add a pinned Lima ARM64 builder definition.
- [DONE] Document how to create, enter, stop, verify, and destroy the builder.
- [DONE] Script installation of the kernel and appliance build dependencies.
- [DONE] Pin Linux 6.12.8 source and verify its SHA-256 before use.
- [DONE] Check in a reviewable ARM64 Kconfig fragment layered onto Linux's
  maintained `arm64_defconfig`; fail if Kconfig drops a required setting.
- [DONE] Build all guest Go binaries natively for Linux/ARM64 with Go 1.26.3.
- [DONE] Gather ARM64 userland tools, ELF interpreter, and complete dynamic
  runtime dependencies.
- [DONE] Build deterministic kernel and initramfs outputs plus a schema-1
  manifest and `.tar.zst` archive.
- [DONE] Verify every initramfs ELF is ARM64, require all expected tools, reject
  nested-VM payloads, and verify archive membership, sizes, and hashes.
- [ ] Add a repeatable artifact publication/import step for Aperture+.
- [ ] Decide whether release artifacts are checked into this repository,
  attached to a Thundersnap release, or imported by a release-only build step.
  Regardless of storage, normal application runtime must be download-free.

### ARM64 kernel requirements

Keep required drivers/features built in where they are needed before the real
root is available:

- ARM64 generic Virtualization.framework boot support
- virtio PCI/MMIO as required by Apple's devices
- virtio block and network
- virtio console
- virtio-vsock
- entropy and memory balloon devices
- devtmpfs
- initramfs and selected decompressor support
- DHCP/IP autoconfiguration
- btrfs
- md RAID0 and RAID1
- bcache
- NBD
- cgroup v2
- namespaces and other Thundersnap container requirements

KVM host/nested virtualization support is not required in round one.

### Build and boot findings

- [DONE] Created and provisioned the local `thunderboot-arm64` Lima 2.2 VM using
  Apple Virtualization.framework: 6 vCPUs, 8 GiB RAM, and an 80 GiB disk.
- [DONE] Pinned the Debian 13 ARM64 image by immutable URL/SHA-512 and apt
  packages to a dated Debian snapshot. The repository is mounted at
  `/work/thundersnap`; generated output remains ignored in `thunderboot-out/`.
- [DONE] Verified the final ARM64 artifact at clean Thundersnap commit
  `ed8ed004c935f56a44097481adc6c59c2a8c8666`.
- [DONE] Built the kernel twice from clean build directories and confirmed
  byte-identical `Image` output. A non-obvious requirement was converting
  `SOURCE_DATE_EPOCH` to a date string for `KBUILD_BUILD_TIMESTAMP`; otherwise
  the kernel's tiny built-in fallback cpio received current mtimes and changed
  every build.
- [DONE] Normalized initramfs entry ownership, ordering, and mtimes. The
  resulting cpio is deterministic for unchanged inputs.
- [DONE] Proved the generated `Image` and `initramfs.cpio` boot directly on this
  M4 Pro through `VZLinuxBootLoader`. The working serial console is `hvc0`, not
  Cloud Hypervisor's x86 `ttyS0`.
- [DONE] Confirmed `VZVirtioBlockDeviceConfiguration` exposes the first raw disk
  as `/dev/vda`. A 512 MiB disposable disk was formatted as btrfs, emitted
  `THUNDERBOOT STORAGE OK: /dev/vda`, and powered off cleanly in about a second.
- [DONE] Re-ran Thundersnap's unit, e2e, not-e2e, and `e2e-tb` suites on the x86
  Linux host after removing the checked-in x86 binaries. Raw, RAID0, RAID1,
  bcache, combined RAID/bcache, and NBD layouts still pass.
- The current ARM64 `arm64_defconfig`-based kernel is approximately 68 MiB and
  contains many irrelevant platform drivers. This is acceptable for the first
  integration; a later size/boot-log optimization can replace it with a smaller
  known-good config after Aperture+ integration is stable.
- The current initramfs is approximately 61 MiB and the complete compressed
  import archive approximately 38 MiB. The archive verifier confirms that the
  nested Cloud Hypervisor binary and nested kernel are absent.
- The committed proof covers direct boot and storage initialization only. The
  full long-running appliance, networking, vsock status channel, login, update,
  and restart paths remain to be proven in Aperture+.

## Aperture+ VM ownership and lifecycle

Move VM lifetime ownership out of `ExperimentalVMView`. An app-level,
MainActor-isolated VM supervisor should own controllers keyed by workspace ID.
A console window observes and interacts with a controller but does not retain or
terminate the VM merely by existing or closing.

Suggested product states:

```text
absent
creating
starting
waitingForLogin(authURL)
running(hostname, addresses)
stopping
stopped
failed(stage, message)
deleting
```

Persist desired state separately from transient runtime state:

- desired `running`: automatically start on the next Aperture+ launch
- desired `stopped`: retain disk and identity but do not automatically start
- absent/deleted: no metadata or disk remains

Lifecycle checklist:

- [ ] Define versioned per-workspace VM metadata.
- [ ] Add an app-level supervisor independent of workspace/console windows.
- [ ] Discover existing VM records when workspaces load.
- [ ] Start desired-running VMs once their owning workspace tsnet node is ready.
- [ ] Keep the owning workspace and its TSNet manager alive while its VM runs.
- [ ] Make start/stop/restart idempotent and safe against rapid repeated UI
  actions.
- [ ] Stop all VM and bridge resources cleanly during app termination when time
  permits; recover safely from abrupt termination on the next launch.
- [ ] Confirm deletion before removing persistent data.
- [ ] Integrate workspace deletion with VM shutdown and deletion.
- [ ] Add appliance/data schema migration and downgrade checks.
- [ ] Preserve `/var/lib/thundersnap` and its tsnet state across appliance
  upgrades.
- [ ] Never clone a guest Tailscale identity accidentally if VM duplication is
  added in the future.

## Virtualization.framework configuration

Replace the Alpine EFI/ISO path with direct Linux boot:

- `VZGenericPlatformConfiguration`
- `VZLinuxBootLoader` using bundled ARM64 `Image`
- `initialRamdiskURL` using the bundled initramfs
- ARM64-appropriate console and kernel command line
- approximately 2 GB memory initially
- approximately 2 vCPUs initially
- entropy device
- memory balloon device
- one `VZVirtioBlockDeviceConfiguration` for `disk.raw`
- one `VZVirtioNetworkDeviceConfiguration` using the existing
  `VZFileHandleNetworkDeviceAttachment`
- one `VZVirtioSocketDeviceConfiguration` for host/guest control
- bidirectional serial attachment for logs and the development console
- no graphics device in the eventual headless configuration

The storage proof established `console=hvc0` and `/dev/vda` for the first
virtio block disk. Network-device naming and DHCP still need validation with the
real Aperture bridge.

- [ ] Add bundle resource lookup and manifest validation.
- [ ] Create sparse persistent disks atomically and clean up partial creation.
- [ ] Implement direct Linux boot configuration.
- [ ] Validate the VM configuration before start and surface actionable errors.
- [ ] Ensure all file handles, sockets, bridges, serial handlers, and VM objects
  are torn down in deterministic order.
- [ ] Keep serial output in a bounded in-memory buffer and optionally in a
  bounded diagnostic log.

## Networking

Continue using the bridge already integrated into TailscaleKit:

```text
VZ virtio-net
  -> VZFileHandleNetworkDeviceAttachment
  -> Unix datagram Ethernet frames
  -> TailscaleKit vmnet DHCP/DNS/gVisor bridge
  -> owning workspace network policy/dialers
```

The guest gets its own private address and runs its own `thundersnapd` tsnet
node. The parent workspace node supplies transport only.

### Bootstrap/public-routing requirement

The current bridge sends TCP, UDP, and DNS through the workspace's
`tsnet.Server.Dial`, which is tailnet-oriented and may require a usable exit
node for public destinations. Guest enrollment needs public access before the
guest has a Tailscale identity, including access to Tailscale control/DERP and
the user's identity provider.

The VM bridge therefore needs split routing analogous to the browser:

- tailnet destinations -> owning workspace tsnet
- public destinations -> direct host networking
- when the workspace intentionally uses an exit node, public traffic may follow
  that exit-node policy
- DNS must resolve both public names and workspace-tailnet names without making
  public bootstrap depend on an exit node

- [ ] Specify bridge routing behavior for tailnet, public, and exit-node modes.
- [ ] Add a direct host dial seam to the TailscaleKit VM bridge.
- [ ] Preserve MagicDNS peer/FQDN resolution through the owning workspace.
- [ ] Make DHCP-derived addressing the guest default; remove hard-coded passt
  addresses from the appliance path.
- [ ] Verify TCP, UDP, DNS, large packets/MTU, and reconnect behavior.
- [ ] Verify workspace logout or tsnet failure produces a clear VM state and can
  recover after workspace login.
- [ ] Confirm initial guest Tailscale enrollment works with no workspace exit
  node selected.

## Guest/host control over virtio-vsock

Use a versioned control protocol over virtio-vsock rather than parsing serial
logs or reading the guest's btrfs disk from macOS. The host installs its listener
before starting the VM; the guest initiates the connection and reconnects after
transient failure.

A newline-delimited JSON protocol is sufficient initially. Example events:

```json
{"version":1,"event":"booting"}
{"version":1,"event":"storage-ready","device":"/dev/vda"}
{"version":1,"event":"installing-appliance"}
{"version":1,"event":"needs-login","authURL":"https://login.tailscale.com/a/..."}
{"version":1,"event":"running","hostname":"host.tailnet.ts.net","ips":["100.x.y.z"]}
{"version":1,"event":"failed","stage":"daemon","message":"..."}
```

Initial host commands should include at least status request and graceful
shutdown. Restart can initially be implemented as stop followed by a new VM
start. Add protocol capabilities/version negotiation before extending it
substantially.

`thunderboot-init` is the preferred guest supervisor because it already owns
early storage and installation. It should remain PID 1, reap child processes,
start/supervise `thundersnapd`, and forward structured status to the host.

- [ ] Define protocol framing, versioning, event schema, and error semantics.
- [ ] Implement guest reconnect behavior and host reconnection tolerance.
- [ ] Report storage setup/install progress before switch-root.
- [ ] Report the same waiting-for-auth state and URL that Thundersnap currently
  writes to its status file.
- [ ] Report authenticated hostname, addresses, daemon health, and fatal errors.
- [ ] Implement graceful shutdown and acknowledge completion where possible.
- [ ] Avoid including auth URLs or future secrets in ordinary persistent logs.
- [ ] Treat malformed/unknown messages as protocol errors without crashing the
  app or guest supervisor.

## Tailscale enrollment UX

`thundersnapd` already captures tsnet's interactive URL and writes an `auth-url`
and status file under its state directory. Preserve that behavior for its CLI,
but additionally publish the structured state through the vsock supervisor.

Expected flow:

1. User creates/starts the workspace VM.
2. Aperture+ displays boot and storage progress.
3. Guest `thundersnapd` reaches `NeedsLogin` and produces an auth URL.
4. Aperture+ changes to `waitingForLogin` and offers **Sign in to Tailscale**.
5. Open the URL in the system browser.
6. Keep the VM running while polling/receiving status.
7. On successful enrollment, show the guest's Tailscale hostname and IPs.
8. Future boots reuse the guest's state from `disk.raw` and skip login.

The user logs the guest in as their own identity so the Thundersnap sandbox acts
on their behalf. Do not reuse or copy the parent workspace's node state.

- [ ] Add waiting-for-login UI with safe URL handling.
- [ ] Open enrollment in the system browser.
- [ ] Handle URL expiration, cancellation, reauthentication, and node approval
  requirements.
- [ ] Show enough identity/hostname information to distinguish parent workspace
  and guest nodes.
- [ ] Add a deliberate reset/reauth operation later without deleting user data.

## UI plan

Remove **File -> New VM (experimental)** as the primary creation model. Put VM
management in workspace-specific UI, likely workspace Settings.

Suggested controls:

- Absent: **Create & Start Thundersnap VM**
- Starting: progress, **Open Console**, **Stop**
- Waiting for login: **Sign in to Tailscale**, **Open Console**, **Stop**
- Running: hostname/IP/status, **Open Console**, **Restart**, **Stop**
- Stopped: **Start**, **Delete**
- Failed: failure stage/message, **Open Console**, **Restart**, **Stop/Delete**

Creation/start may automatically open the console during the development phase.
Closing that window never stops the VM.

- [ ] Add workspace-specific VM settings/status section.
- [ ] Route actions to the app-level VM supervisor.
- [ ] Remove the disposable per-window request/lifetime model.
- [ ] Keep accessibility identifiers and deterministic status text for UI tests.
- [ ] Ensure controls clearly distinguish stop (retain disk) from delete
  (irreversible data loss).
- [ ] Decide whether to expose disk size/usage in the first UI.

## Development serial console

Use a serial console window rather than `VZVirtualMachineView`; the appliance has
no graphical desktop. Retain both serial directions so output is visible and
keyboard input reaches the guest.

During development, `thunderboot-init` should run/supervise `thundersnapd` while
also providing a root shell or getty on the serial console. Gate this behavior
with a development-only build setting or kernel parameter such as:

```text
thunderboot.debug-console=1
```

- [ ] Build a native text console/log view with input support.
- [ ] Make console window lifetime independent from VM lifetime.
- [ ] Make console reconnect to an already-running VM controller.
- [ ] Add an explicit **Open Console** diagnostic action.
- [ ] Disable the root debug shell in distribution builds once normal
  diagnostics are sufficient.
- [ ] Retain structured vsock diagnostics when the debug shell is disabled.

## Appliance updates

The current thunderboot design copies the appliance payload from initramfs onto
the persistent root at boot. Preserve this so an Aperture+ update can update the
appliance without recreating the user's data disk.

- [ ] Add an installed-appliance version marker.
- [ ] Define atomic or recoverable install/update behavior.
- [ ] Refuse unsafe downgrade when disk state requires a newer appliance.
- [ ] Add explicit data migrations as needed.
- [ ] Preserve Thundersnap and Tailscale state through normal updates.
- [ ] Surface migration/install failures over vsock and serial.

## Testing and milestones

### Milestone 1: ARM64 artifact and storage proof

- [DONE] Produce ARM64 kernel and initramfs in the pinned builder.
- [DONE] Boot them with `VZLinuxBootLoader` and a disposable test disk.
- [DONE] Use the existing `thundersnap.testonly=storage` path with Apple's
  virtio block device.
- [DONE] Observe `THUNDERBOOT STORAGE OK` over `hvc0` and clean poweroff.
- [ ] Verify the same created filesystem is reusable on a second boot. The
  storage setup is designed to be idempotent, but this exact two-boot assertion
  has not yet been recorded as an automated test.

### Milestone 2: persistent workspace appliance

- [ ] Create versioned per-workspace VM metadata and sparse `disk.raw`.
- [ ] Boot the full appliance and persist it across stop/start.
- [ ] Keep it running after console/workspace windows close.
- [ ] Stop, restart, and delete it from workspace UI.
- [ ] Relaunch Aperture+ and honor persisted desired state.

### Milestone 3: network and interactive enrollment

- [ ] Make bootstrap public networking work without a workspace exit node.
- [ ] Establish host/guest vsock control.
- [ ] Surface `auth_url`, open it, and observe successful login.
- [ ] Show guest hostname and Tailscale IPs.
- [ ] Restart and confirm no reauthentication is required.
- [ ] Confirm the VM appears as a distinct node from Aperture's workspace node.

### Milestone 4: usable Thundersnap appliance

- [ ] Reach the guest over its tailnet identity.
- [ ] Download and initialize a user-selected frame.
- [ ] Exercise basic `ts` frame/snapshot operations.
- [ ] Verify data and refs survive app and VM restarts.
- [ ] Verify the bundled appliance itself requires no runtime download.

### Automated coverage

- [ ] Unit-test metadata/state transitions and desired-state recovery.
- [ ] Unit-test manifest and protocol parsing, including unknown versions and
  malformed messages.
- [DONE] Add artifact membership, architecture, required-tool, size, and hash
  verification to the ARM64 build pipeline (`make verify-thunderboot-appliance-arm64`).
- [ ] Add a storage-only VM integration test with a bounded timeout.
- [ ] Add a persistent-disk two-boot integration test.
- [ ] Add bridge tests for public direct routing, tailnet routing, MagicDNS,
  exit-node mode, TCP, UDP, and DNS.
- [ ] Add Mac UI tests for absent, starting, stopped, failed, and delete-confirm
  states without requiring real enrollment where possible.
- [ ] Add a connected enrollment/startup test using the repository's existing
  staged-credential conventions or a purpose-built test tailnet flow.
- [ ] Continue verifying the signed Mac app carries the virtualization
  entitlement in development and distribution archives.

## Deferred work

- More than one VM per workspace
- Moving a VM between workspaces
- VM cloning (especially safe identity handling)
- User-configurable cache, RAID, or NBD storage
- NBD-backed remote storage and Infiniblock integration
- Nested virtualization and VMX isolation inside the appliance
- Bundling initial Debian/other frames
- Suspend/save/restore support
- Running VMs while Aperture+ is not running
- Fully graphical guest display

## Implementation hygiene

- Keep iOS code/builds unaffected; all VM APIs remain native-macOS-only.
- Preserve Swift 6 strict concurrency and MainActor defaults.
- Do not hand-edit `project.pbxproj` to add Swift files under synchronized
  source folders; bundle resources may still require explicit project/resource
  build configuration.
- Do not commit generated build directories or ordinary DerivedData.
- Follow the nested submodule commit order for any TailscaleKit bridge changes.
- After every top-level commit, run `make subtrac` as required by `CLAUDE.md`.
