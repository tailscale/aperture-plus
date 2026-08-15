#!/bin/bash
# Build and smoke-test the native macOS foundation without requiring a signing
# identity. The copied framework and app are ad-hoc signed so the test exercises
# the entitlement and a real process launch, not only compilation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="${MAC_DERIVED:-build/DerivedDataMac}"
APP="$DERIVED/Build/Products/Debug/AperturePlus.app"
FRAMEWORK="$APP/Contents/Frameworks/TailscaleKit.framework"
ENTITLEMENTS="MacApp/ApertureMac.entitlements"
LOG="build/mac-smoke.log"

xcodebuild build \
  -project Aperture.xcodeproj -scheme ApertureMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=io.tailscale.Aperture.SmokeTest

test -x "$APP/Contents/MacOS/AperturePlus"
test -d "$FRAMEWORK"

# Sign inside-out, matching Xcode's normal embed-and-sign behavior.
codesign --force --sign - "$FRAMEWORK"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"

extracted_entitlements="$(mktemp)"
codesign -d --entitlements :- "$APP" >"$extracted_entitlements" 2>/dev/null
actual="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.virtualization' "$extracted_entitlements")"
test "$actual" = true || {
  echo "error: built app is missing com.apple.security.virtualization=true" >&2
  exit 1
}

# Ensure dyld can load the native TailscaleKit framework and shared browser app
# stays alive. Use a disposable HOME and reset launch flags so this never reads
# or mutates the developer's normal workspaces. This does not log in or exercise
# any VM functionality.
: > "$LOG"
smoke_home="$(mktemp -d)"
HOME="$smoke_home" "$APP/Contents/MacOS/AperturePlus" \
  -UITestResetWorkspaces -UITestResetLogin >"$LOG" 2>&1 &
pid=$!
cleanup() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$extracted_entitlements"
  rm -rf "$smoke_home"
}
trap cleanup EXIT
sleep 3
if ! kill -0 "$pid" 2>/dev/null; then
  echo "error: native app exited during launch smoke test" >&2
  cat "$LOG" >&2
  exit 1
fi

echo "::: native macOS foundation launched with virtualization entitlement :::"
