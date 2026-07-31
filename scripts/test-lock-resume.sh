#!/bin/bash
# Reproduce physical lock/unlock more faithfully than an ordinary simulator
# XCUITest: Home supplies real scene background/active transitions, while a
# host-side SIGSTOP freezes the Aperture process (Swift + URLSession + Go) for
# the same interval during which iOS suspends it after screen lock.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

SIM_NAME="${SIM_NAME:-iPhone 17}"
SUSPEND_SECONDS="${LOCK_SUSPEND_SECONDS:-7}"
# The test's UI assertion allows 7s after activation. Keep this explicit: a
# 20–45s assertion would bless the observed ~30s fallback as success.
DERIVED="$ROOT/build/DerivedData"
LOG_DIR="$ROOT/build/lock-resume-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, os, sys
want=os.environ.get("SIM_NAME", "iPhone 17")
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"] == want:
            print(d["udid"]); raise SystemExit
raise SystemExit(1)
')
xcrun simctl bootstatus "$UDID" -b 2>/dev/null || true
DEST="platform=iOS Simulator,id=$UDID"

AUTHKEY_FILE="${APERTURE_TEST_AUTHKEY_FILE:-/tmp/aperture-test-authkey}"
if [[ -n "${APERTURE_TEST_AUTHKEY:-}" ]]; then
    printf '%s' "$APERTURE_TEST_AUTHKEY" > "$AUTHKEY_FILE"
elif [[ -f "$HOME/.aperture-ios-authkey" ]]; then
    cp "$HOME/.aperture-ios-authkey" "$AUTHKEY_FILE"
else
    echo "No auth key (APERTURE_TEST_AUTHKEY or ~/.aperture-ios-authkey)" >&2
    exit 1
fi

UNIFIED="$LOG_DIR/unified.log"
xcrun simctl spawn "$UDID" log stream \
    --predicate 'subsystem == "io.tailscale.Aperture"' \
    --level debug --style compact >"$UNIFIED" 2>&1 &
LOG_PID=$!
TEST_PID=""
APP_PID=""
cleanup() {
    [[ -z "$APP_PID" ]] || kill -CONT "$APP_PID" 2>/dev/null || true
    [[ -z "$TEST_PID" ]] || kill "$TEST_PID" 2>/dev/null || true
    kill "$LOG_PID" 2>/dev/null || true
    rm -f "$AUTHKEY_FILE"
}
trap cleanup EXIT

if [[ "${NO_BUILD:-0}" != 1 ]]; then
    xcodebuild build-for-testing -project Aperture.xcodeproj -scheme Aperture \
        -configuration Debug -destination "$DEST" -derivedDataPath "$DERIVED" \
        >"$LOG_DIR/build.log" 2>&1
fi

xcodebuild test-without-building -project Aperture.xcodeproj -scheme Aperture \
    -configuration Debug -destination "$DEST" -derivedDataPath "$DERIVED" \
    -only-testing:ApertureUITests/ApertureUITests/testExternalProcessSuspendRecoversWithoutReloadingPage \
    >"$LOG_DIR/test.log" 2>&1 &
TEST_PID=$!

# Wait for the actual app lifecycle callback, not an arbitrary sleep.
for _ in $(seq 1 300); do
    if grep -q 'Background: preserving tsnet/proxy sessions' "$UNIFIED"; then break; fi
    sleep 0.1
done
if ! grep -q 'Background: preserving tsnet/proxy sessions' "$UNIFIED"; then
    echo "Timed out waiting for Aperture to enter background" >&2
    tail -80 "$UNIFIED" >&2
    exit 1
fi

APP_PID=$(pgrep -f "Devices/$UDID/.*/Aperture.app/Aperture" | head -1 || true)
if [[ -z "$APP_PID" ]]; then
    echo "Could not find Aperture simulator process" >&2
    exit 1
fi

echo "Freezing Aperture pid $APP_PID for ${SUSPEND_SECONDS}s"
kill -STOP "$APP_PID"
sleep "$SUSPEND_SECONDS"
kill -CONT "$APP_PID"
APP_PID=""

set +e
wait "$TEST_PID"
RC=$?
set -e
TEST_PID=""

echo "Logs: $LOG_DIR"
tail -100 "$LOG_DIR/test.log"
exit "$RC"
