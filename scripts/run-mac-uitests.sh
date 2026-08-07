#!/bin/bash
# Build and run every native macOS UI test. Missing auth-key setup and external
# service failures are test failures; no tests skip.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="${MAC_UITEST_DERIVED:-build/DerivedDataMacUITests}"
AUTHKEY_FILE="${APERTURE_TEST_AUTHKEY_FILE:-/tmp/aperture-test-authkey}"

cleanup() {
    rm -f "$AUTHKEY_FILE" 2>/dev/null || true
}
trap cleanup EXIT

if [[ -n "${APERTURE_TEST_AUTHKEY:-}" ]]; then
    printf '%s' "$APERTURE_TEST_AUTHKEY" > "$AUTHKEY_FILE"
elif [[ -s "$HOME/.aperture-ios-authkey" ]]; then
    cp "$HOME/.aperture-ios-authkey" "$AUTHKEY_FILE"
else
    echo "error: required Mac UI-test auth key missing" >&2
    echo "stage ~/.aperture-ios-authkey or set APERTURE_TEST_AUTHKEY" >&2
    exit 1
fi
chmod 600 "$AUTHKEY_FILE"

xcodebuild test \
    -project Aperture.xcodeproj -scheme ApertureMac \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates
