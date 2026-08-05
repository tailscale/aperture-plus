#!/bin/bash
# End-to-end real Go panic recovery through the process-wide filch/logtail,
# plus TailscaleKit dSYM symbolication.
set -euo pipefail

SIM_NAME="${1:-${SIM_NAME:-iPhone 17}}"
BUNDLE="io.tailscale.Aperture"
APP="build/DerivedData/Build/Products/Debug-iphonesimulator/Aperture.app"
DSYM="ThirdParty/libtailscale/swift/build/Build/Products/Release-iphonesimulator/TailscaleKit.framework.dSYM/Contents/Resources/DWARF/TailscaleKit"
OUT=$(mktemp); SERVER=$(mktemp); LOG_PID=""
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() { [ -z "$LOG_PID" ] || kill "$LOG_PID" 2>/dev/null || true; rm -f "$OUT" "$SERVER"; }
trap cleanup EXIT

xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_NAME" -b >/dev/null
xcrun simctl install booted "$APP"

# Start the repository-local service. It flushes stdout before HTTP 200.
(cd scripts/logcatcher && go run .) >"$OUT" 2>"$SERVER" & LOG_PID=$!
for _ in $(seq 1 100); do grep -q '^LOGCATCHER_URL=' "$OUT" && break; sleep .1; done
URL=$(awk -F= '/^LOGCATCHER_URL=/{print $2; exit}' "$OUT")
[ -n "$URL" ] || fail "logcatcher did not start: $(cat "$SERVER")"

# Phase 1: point at an unavailable endpoint so the panic remains in filch.
# Wait for any prior run to disappear before launching so this PID is the one
# whose death we observe.
xcrun simctl terminate booted "$BUNDLE" 2>/dev/null || true
sleep .5
LAUNCH=$(SIMCTL_CHILD_TS_LOG_TARGET=http://127.0.0.1:1 xcrun simctl launch \
  booted "$BUNDLE" -UITestResetLogin -CrashTest)
PID=${LAUNCH##*: }
for _ in $(seq 1 100); do
  xcrun simctl spawn booted kill -0 "$PID" 2>/dev/null || break
  sleep .1
done
xcrun simctl spawn booted kill -0 "$PID" 2>/dev/null && fail "app did not crash"
# SpringBoard can still be reconciling the crashed scene after PID exit.
sleep 1

# Phase 2: relaunch against the fake service. Startup drains leftovers promptly.
RELAUNCH=""
for _ in $(seq 1 30); do
  if RELAUNCH=$(SIMCTL_CHILD_TS_LOG_TARGET="$URL" xcrun simctl launch \
      booted "$BUNDLE" -UITestFlushLogs 2>/dev/null); then
    break
  fi
  sleep .2
done
[ -n "$RELAUNCH" ] || fail "could not relaunch app after crash"
for _ in $(seq 1 200); do
  grep -q 'panic: TsnetCrashTest' "$OUT" && grep -q 'goroutine ' "$OUT" && break
  sleep .1
done
grep -q 'panic: TsnetCrashTest' "$OUT" || fail "panic not uploaded after relaunch; catcher output: $(tail -20 "$OUT")"
grep -q 'goroutine ' "$OUT" || fail "goroutine dump not uploaded; catcher output: $(tail -20 "$OUT")"

# Verify matching dSYM still resolves a Go source location.
FWK="ThirdParty/libtailscale/swift/build/Build/Products/Release-iphonesimulator/TailscaleKit.framework/TailscaleKit"
OFF=$(nm -arch arm64 "$FWK" | awk '/ _main\.TsnetCrashTest$/ && !found {print "0x"$1; found=1}')
[ -n "$OFF" ] || fail "TsnetCrashTest symbol not found"
SYM=$(atos -arch arm64 -o "$DSYM" "$OFF")
echo "$SYM" | grep -qE '\.(go|s):[0-9]+' || fail "dSYM lacks Go file:line: $SYM"

echo "PASS: panic and goroutine dump recovered through global logtail"
echo "PASS: $SYM"
