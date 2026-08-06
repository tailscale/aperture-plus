#!/bin/bash
# Build and smoke-test the native macOS foundation without requiring a signing
# identity. The copied framework and app are ad-hoc signed so the test exercises
# the entitlement and a real process launch, not only compilation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="${MAC_DERIVED:-build/DerivedDataMac}"
APP="$DERIVED/Build/Products/Debug/Aperture.app"
FRAMEWORK="$APP/Contents/Frameworks/TailscaleKit.framework"
ENTITLEMENTS="MacApp/ApertureMac.entitlements"
LOG="build/mac-smoke.log"

xcodebuild build \
  -project Aperture.xcodeproj -scheme ApertureMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO

test -x "$APP/Contents/MacOS/Aperture"
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

# Ensure dyld can load the native TailscaleKit framework and the SwiftUI app
# stays alive. This does not log in or exercise any VM functionality.
: > "$LOG"
"$APP/Contents/MacOS/Aperture" >"$LOG" 2>&1 &
pid=$!
cleanup() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$extracted_entitlements"
}
trap cleanup EXIT
sleep 3
if ! kill -0 "$pid" 2>/dev/null; then
  echo "error: native app exited during launch smoke test" >&2
  cat "$LOG" >&2
  exit 1
fi

echo "::: native macOS foundation launched with virtualization entitlement :::"
