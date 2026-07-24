# TestFlight / App Store distribution for Aperture

How to build, sign, validate, and upload `io.tailscale.Aperture` to App Store
Connect for TestFlight, plus how version and build numbers are managed.

The whole flow is driven by `make` targets added to the `Makefile`; this doc is
the companion explainer. The dev-signed real-device install flow (`make ipa`)
is separate and documented in `README.md`.

## TL;DR

```bash
# One-time: drop your App Store Connect API key at the standard path:
#   ~/private_keys/AuthKey_<KEYID>.p8
# (App Store Connect → Users and Access → Integrations → App Store Connect API)

# Build, sign, and upload to TestFlight in one shot:
make tf ASC_KEY_ID=<KEYID> ASC_ISSUER_ID=<ISSUER_ID>

# The build number (CFBundleVersion) defaults to the git commit count, so each
# commit uploads as a fresh build with no bookkeeping. To force a number:
make tf ASC_KEY_ID=<KEYID> ASC_ISSUER_ID=<ISSUER_ID> BUILD_NUMBER=30
```

## Prerequisites (one-time, mostly in App Store Connect)

1. **Paid Apple Developer membership** for team `W5364U7YZB` (Tailscale Inc.).
2. **Sign the Paid Applications Agreement** — App Store Connect → Business →
   Agreements. **Uploads are rejected until this is signed**; it's the most
   common blocker.
3. **App record** — App Store Connect → My Apps → "+" → New App: Name
   `Aperture`, Bundle ID `io.tailscale.Aperture`. (A first successful upload can
   auto-create it, but creating it explicitly avoids surprises.)
4. **Signing identity** — an *Apple Distribution* certificate for the team, plus
   an App Store provisioning profile. In this environment, automatic signing
   (`-allowProvisioningUpdates`) fetches/creates both during export — verified:
   the exported IPA is signed `Apple Distribution: Tailscale Inc. (W5364U7YZB)`
   with an `iOS Team Store Provisioning Profile` and the correct TestFlight
   entitlements (`get-task-allow=false`, `beta-reports-active=true`). No manual
   profile juggling needed on the build host.
5. **Upload credentials** — pick one:
   - **Preferred: App Store Connect API key.** App Store Connect → Users and
     Access → Integrations → App Store Connect API → "+" → name it, Access =
     App Manager (enough for uploads + TestFlight) or Admin. Download the `.p8`
     (one-time). Note the **Issuer ID** shown on that page and the **Key ID**.
     Place the key where `altool` looks by default:
     `~/private_keys/AuthKey_<KEY_ID>.p8`
   - **Or: Apple ID + app-specific password.** Generate an app-specific password
     at appleid.apple.com → Sign-In & Security → App-Specific Passwords (this is
     *not* the account login password).

   **Providing the credentials:** `make tf` checks for creds *up front* and
   fails fast (before the slow archive) with instructions if none are found.
   Put them in an env file at `~/.aperture-testflight.env` (recommended for
   repeated use; `chmod 600` it) so `make tf` works with no arguments:
   ```sh
   ASC_KEY_ID=<key-id>
   ASC_ISSUER_ID=<issuer-id>
   ```
   (or `ASC_USERNAME`/`ASC_PASSWORD` for Apple-ID auth). Override the file path
   with `APERTURE_TF_ENV=/path/to/file`. You can also pass the vars on the
   `make` command line or `export` them in your shell. The `.p8` key lives at
   `~/private_keys/AuthKey_<KEY_ID>.p8` (outside the repo, never committed).

## The make targets

| Target | What it does |
|---|---|
| `make tf-archive` | Archive a Release build for App Store distribution (`build/Aperture.xcarchive`) |
| `make tf-export` | Export an App Store `.ipa` → `build/ipa-appstore/Aperture.ipa` |
| `make tf-validate` | Validate the `.ipa` with `altool` (catches signing/entitlement issues pre-upload) |
| `make tf-upload` | Upload the `.ipa` to App Store Connect (TestFlight) |
| `make tf-check-creds` | Verify ASC upload creds are set; fail fast with instructions if not |
| `make tf` | `tf-archive` → `tf-export` → `tf-upload` (checks creds first, fails fast) |

All signing/export targets run `scripts/unlock-keychain.sh` first (the embedded
`TailscaleKit.framework` is re-signed on copy, which needs an unlocked keychain —
see `README.md`'s "Installing on a real device" for the SSH/unlock notes).

`ExportOptions.AppStore.plist` (method `app-store`) is used for the TestFlight
flow; the existing `ExportOptions.plist` (method `debugging`) stays for
`make ipa` dev-signed device installs.

### Credential variables

Provide these any of three ways (checked in this order by
`scripts/tf-check-creds.sh`): an env file at `~/.aperture-testflight.env`
(recommended; override with `APERTURE_TF_ENV=`), real environment variables
(`export` them), or on the `make` command line. `make tf` verifies creds up
front and aborts before archiving if none are found.

| Var | When |
|---|---|
| `ASC_KEY_ID` + `ASC_ISSUER_ID` | API-key auth (preferred) |
| `ASC_KEY_PATH` | Override the key file path (default `~/private_keys/AuthKey_<KEY_ID>.p8`) |
| `ASC_USERNAME` + `ASC_PASSWORD` | Apple ID + app-specific password |
| `APERTURE_TF_ENV` | Override the creds env file path (default `~/.aperture-testflight.env`) |
| `BUILD_NUMBER` | Override the build number (see below) |

### Examples

```bash
# If ~/.aperture-testflight.env exists with ASC_KEY_ID + ASC_ISSUER_ID,
# no args are needed — just:
make tf

# Validate before uploading (no upload; fast feedback on signing):
make tf-validate ASC_KEY_ID=FG54QN43A3 ASC_ISSUER_ID=9ff1ebe7-73a7-4102-9451-3472e4e629a7

# Full build + upload, build number = git commit count:
make tf ASC_KEY_ID=FG54QN43A3 ASC_ISSUER_ID=9ff1ebe7-73a7-4102-9451-3472e4e629a7

# Force a specific build number (e.g. re-upload after a failed processing step):
make tf ASC_KEY_ID=FG54QN43A3 ASC_ISSUER_ID=9ff1ebe7-73a7-4102-9451-3472e4e629a7 BUILD_NUMBER=30

# Reuse an already-exported IPA (skip re-archive) — just upload:
make tf-upload ASC_KEY_ID=FG54QN43A3 ASC_ISSUER_ID=9ff1ebe7-73a7-4102-9451-3472e4e629a7
```

`altool` is invoked via `xcrun`, so it uses the Xcode-bundled
`ContentDelivery.framework`. Upload output is JSON (`--output-format json`).

## Version vs. build number

Apple has two independent version fields per build:

- **`CFBundleShortVersionString`** (marketing version) — the visible `0.1`,
  `1.0`, etc. Set in the Xcode project as `MARKETING_VERSION` (currently `0.1`
  in `project.pbxproj`, one value per build configuration). Bump it manually in
  Xcode's target → General → Version when you want a new visible version.
- **`CFBundleVersion`** (build number) — must be unique per uploaded build for a
  given marketing version. Set as `CURRENT_PROJECT_VERSION` in the project, but
  `make tf-archive` **overrides it at build time** (see below), so you don't
  manage it by hand.

### Build number strategy: derived from git, not stored

`make tf-archive` defaults `CFBundleVersion` to the **total git commit count**
(`git rev-list --count HEAD`):

- Monotonically increasing, identical across fresh clones, and unique per
  commit, so every commit produces a fresh upload-able build number with **zero
  state to maintain** in the repo.
- Override with `BUILD_NUMBER=N` if you ever need to (e.g. re-upload the same
  commit, or adopt a different scheme).

This mirrors how the **main Tailscale app** handles it: its build number is
computed from git by `tailscale.com/cmd/mkversion` (the `changeCount` = commits
since `VERSION.txt` last changed) and injected into the IPA via a generated
`version.h` + Info.plist preprocessing (`INFOPLIST_PREFIX_HEADER` /
`INFOPLIST_PREPROCESS=YES` in `corp/xcode/Config/Project-Shared.xcconfig`). The
principle is the same — **the build number is derived from git, never stored** —
just scaled down to this repo's size (no Go version tool or plist preprocessing
needed; the Makefile passes `CURRENT_PROJECT_VERSION=<count>` straight to
`xcodebuild`, which overrides the project setting).

> Note: `CFBundleVersion` for App Store builds must be a positive integer (or
> `x.y.z` of integers) — Apple rejects non-numeric values, so we can't embed a
> git hash in it. The commit count is the simplest numeric, monotonic,
> git-derived value.

### Am I locked into version ≥ 1.0?

**No.** `CFBundleShortVersionString` and `CFBundleVersion` are independent and
can both go *down* at any time. Apple only requires that each uploaded build's
`(version, build)` pair is unique, and that a *live App Store* version can't be
replaced by a lower-numbered one. TestFlight has no such "can't go lower" rule,
and nothing has been published to the App Store, so the next upload can be
`0.1 (25)` with no problem. The `1.0` already uploaded to TestFlight (build 1)
is independent of future uploads — `MARKETING_VERSION` is now `0.1` in the
project, so the next `make tf` ships `0.1 (N)`.

### Should I use git tags?

Git tags are optional here and mark *releases* (the marketing version), e.g.
`git tag v0.9.0`. They're good practice for recording "this commit is what we
shipped as 0.9.0", but they're **not** how the build number is tracked — that's
the commit count. Tag if you want a release history; the build flow doesn't
depend on it.

## After the upload lands (App Store Connect → TestFlight)

1. **Wait ~10–30 min for processing.** The build appears under TestFlight → iOS
   builds. While processing, it may show "Missing Compliance Information" —
   answer the export-compliance prompt (typically "no encryption" / exempt).
2. **Internal testers** (team members, up to 100): once the build is
   "Available", add them under a TestFlight internal group — installable
   immediately, no review.
3. **External testers**: requires **beta app review** first. Fill in TestFlight
   → Test Information (beta app description, feedback email, review notes),
   create an external testing group, add testers, then submit the build for beta
   review.

## Notes

- `xcodebuild` may print `Command line name "app-store" is deprecated. Use
  "app-store-connect" instead.` during export — this is a harmless warning; the
  export succeeds with `method=app-store` (the documented value in
  `ExportOptions.AppStore.plist`).
- Build artifacts (`build/`, including `build/ipa-appstore/` and
  `build/Aperture.xcarchive`) are gitignored, as is the submodule's
  `swift/build/`. Upload logs (e.g. `build/tf-upload.log`) are not committed.
- The App Store Connect API key (`.p8`) lives at `~/private_keys/` (outside the
  repo) and is never committed.
