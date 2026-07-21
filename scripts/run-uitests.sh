#!/bin/bash
#
# run-uitests.sh — build & run the Aperture UI tests on the iOS simulator,
# while capturing libtailscale/tsnet logs two ways:
#
#   1. The app's stdout (print("tsnet: ...")) — captured by the OS unified
#      log, surfaced via `simctl log stream` into unified.log. (It does NOT
#      appear in the UI-test runner's own stdout, so combined.log usually has
#      no `tsnet:` lines; unified.log is the authoritative source.)
#   2. Apple's unified logging system (OSLog, subsystem io.tailscale.Aperture)
#      — streamed live via `simctl log stream`.
#
# Usage:
#   scripts/run-uitests.sh                # use iPhone 17 simulator
#   scripts/run-uitests.sh "iPhone 17 Pro" # pick a different sim
#   scripts/run-uitests.sh --no-build      # skip build-for-testing (reuse prior)
#
# Output lands in build/uitest-logs/<timestamp>/:
#   combined.log     full xcodebuild output
#   unified.log      streamed OSLog for our subsystem (libtailscale/tsnet)
#   tsnet-stdout.log tsnet: lines extracted from combined.log (usually empty)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

SIM_NAME="${SIM_NAME:-iPhone 17}"
BUILD=1
if [[ "${1:-}" == "--no-build" ]]; then BUILD=0; shift; fi
[[ -n "${1:-}" ]] && SIM_NAME="$1"

DERIVED="$PROJECT_ROOT/build/DerivedData"
LOG_DIR="$PROJECT_ROOT/build/uitest-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

# --- Resolve / boot the simulator -------------------------------------------
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
data=json.load(sys.stdin)
want='$SIM_NAME'.strip()
for runtime,devices in data['devices'].items():
    for d in devices:
        if d['name']==want:
            print(d['udid']); sys.exit(0)
print('NOTFOUND')
")
if [[ "$UDID" == "NOTFOUND" || -z "$UDID" ]]; then
    echo "❌ Simulator \"$SIM_NAME\" not found." >&2
    echo "Available:" >&2
    xcrun simctl list devices available | grep -E 'iPhone|iPad' >&2
    exit 1
fi
echo "▶ Simulator: $SIM_NAME ($UDID)"
xcrun simctl bootstatus "$UDID" -b 2>/dev/null || true   # boot if needed, wait if booting

DEST="platform=iOS Simulator,id=$UDID"
echo "▶ Destination: $DEST"

# --- Start the unified-log stream in the background -------------------------
UNIFIED_LOG="$LOG_DIR/unified.log"
echo "▶ Streaming unified logs (subsystem == io.tailscale.Aperture) → $UNIFIED_LOG"
xcrun simctl spawn "$UDID" log stream \
    --predicate 'subsystem == "io.tailscale.Aperture"' \
    --level debug --style compact >"$UNIFIED_LOG" 2>&1 &
LOG_PID=$!
sleep 1   # let the stream attach

cleanup() {
    if kill -0 "$LOG_PID" 2>/dev/null; then
        kill "$LOG_PID" 2>/dev/null || true
        wait "$LOG_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- Build (optional) then run the tests ------------------------------------
COMBINED="$LOG_DIR/combined.log"
if [[ "$BUILD" -eq 1 ]]; then
    echo "▶ Building for testing…"
    xcodebuild build-for-testing \
        -project Aperture.xcodeproj -scheme Aperture \
        -configuration Debug -destination "$DEST" \
        -derivedDataPath "$DERIVED" 2>&1 | tee "$COMBINED"
fi

echo "▶ Running tests…"
set +e
xcodebuild test-without-building \
    -project Aperture.xcodeproj -scheme Aperture \
    -configuration Debug -destination "$DEST" \
    -derivedDataPath "$DERIVED" 2>&1 | tee -a "$COMBINED"
TEST_RC=${PIPESTATUS[0]}
set -e

cleanup
trap - EXIT

# --- Extract any tsnet stdout lines (usually empty for UI tests) ------------
TSNET_LOG="$LOG_DIR/tsnet-stdout.log"
grep -E 'tsnet: ' "$COMBINED" 2>/dev/null >"$TSNET_LOG" || true
UNIFIED_LINES=$(wc -l <"$UNIFIED_LOG" | tr -d ' ')
TSNET_LINES=$(wc -l <"$TSNET_LOG" | tr -d ' ')

# --- Summary ----------------------------------------------------------------
echo
echo "════════════════════════════════════════════════════════════════"
if [[ "$TEST_RC" -eq 0 ]]; then
    echo "✅ UI tests PASSED (xcodebuild exit $TEST_RC)"
else
    echo "❌ UI tests FAILED (xcodebuild exit $TEST_RC)"
fi
echo "──────────────────────────────────────────────────────────────────"
echo "Combined test log : $COMBINED"
echo "Unified OSLog     : $UNIFIED_LOG  ($UNIFIED_LINES lines)  <- libtailscale/tsnet"
echo "tsnet stdout grep : $TSNET_LOG  ($TSNET_LINES lines; usually 0 for UI tests)"
echo "──────────────────────────────────────────────────────────────────"
echo "View the captured libtailscale logs:"
echo "  cat \"$UNIFIED_LOG\""
echo "  grep -E 'State|Authenticate' \"$UNIFIED_LOG\""
echo "════════════════════════════════════════════════════════════════"

exit "$TEST_RC"
