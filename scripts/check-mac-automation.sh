#!/bin/bash
#
# check-mac-automation.sh — verify the macOS permissions + prerequisites for
# autonomous Aperture UI automation (screenshots, AX-driven clicks, XCUITest,
# native Mac builds) and report exactly what to fix. Non-destructive; pass
# --fix to also clear any stale talagent window-restoration state that would
# otherwise block the native app's window on launch.
#
# What it checks (each prints ✅ PASS / ❌ FAIL with a remediation hint):
#   1. libtailscale frameworks present (iOS xcframework + macOS framework)
#   2. a UI-test auth key is staged
#   3. an iPhone 17 simulator exists
#   4. screencapture works  →  Screen Recording granted to this shell's
#      responsible process (the thing you must add to System Settings →
#      Privacy & Security → Screen Recording)
#   5. Accessibility tree is readable  →  Accessibility granted to the same
#      responsible process (needed for System Events `click`/AXPress and for
#      XCUITest to see the app)
#   6. console screen is unlocked (XCUITest cannot activate apps below the
#      lock-screen shield, even when Accessibility permission is granted)
#   7. no stale talagent "Reopen windows?" restoration marker for Aperture
#      (a non-zero restorecount.plist in the daemon container makes the next
#      native launch block on a Reopen/Don't-Reopen modal — under XCUITest the
#      dialog is suppressed so the app comes up with NO window and every test
#      times out at its first app.windows wait)
#
# Usage:
#   scripts/check-mac-automation.sh          # check only
#   scripts/check-mac-automation.sh --fix    # also clear stale talagent state
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FIX=0
if [[ "${1:-}" == "--fix" ]]; then FIX=1; fi

# The TCC "responsible process" for the current shell — this is the binary you
# must grant Screen Recording + Accessibility to. On SSH it's sshd-keygen-
# wrapper; in Terminal it's Terminal itself. Walk up the process tree.
responsible=""
pid=$$
while [[ -n "$pid" && "$pid" != "1" && "$pid" != "0" ]]; do
  comm=$(ps -p "$pid" -o comm= 2>/dev/null | sed 's/^-*//')
  case "$comm" in
    *sshd*|sshd-keygen-wrapper) responsible="/usr/libexec/sshd-keygen-wrapper"; break;;
    *Terminal|com.apple.Terminal) responsible="com.apple.Terminal"; break;;
    *iTerm*) responsible="com.googlecode.iterm2"; break;;
  esac
  pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
  [[ -z "$pid" ]] && break
done
[[ -z "$responsible" ]] && responsible="(unknown — add the app that launched this shell)"

pass=0; fail=0
ok()   { printf '✅ PASS: %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '❌ FAIL: %s\n' "$1"; fail=$((fail+1)); }
info() { printf '   %s\n' "$1"; }

echo "════════════════════════════════════════════════════════════════"
echo "Aperture macOS automation preflight"
echo "Responsible process for this shell: $responsible"
echo "════════════════════════════════════════════════════════════════"

# 1. Frameworks -------------------------------------------------------------
XCFW="ThirdParty/libtailscale/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework"
MACFW="ThirdParty/libtailscale/swift/build/Build/Products/Release/TailscaleKit.framework"
if [[ -d "$XCFW" ]]; then ok "iOS TailscaleKit.xcframework present"
else bad "iOS TailscaleKit.xcframework missing at $XCFW"
     info "fix: cd ThirdParty/libtailscale/swift && make ios-fat   (needs Go 1.26.5)"; fi
if [[ -d "$MACFW" ]]; then ok "macOS TailscaleKit.framework present"
else bad "macOS TailscaleKit.framework missing at $MACFW"
     info "fix: cd ThirdParty/libtailscale/swift && make macos"; fi

# 2. Auth key ---------------------------------------------------------------
KEY=""
for f in "$HOME/.aperture-ios-authkey" /tmp/aperture-test-authkey; do
  if [[ -s "$f" ]]; then KEY="$f"; break; fi
done
if [[ -n "$KEY" ]]; then ok "UI-test auth key staged ($KEY)"
else bad "No UI-test auth key found"
     info "fix: stage ~/.aperture-ios-authkey (or pass AUTHKEY=... to make)"; fi

# 3. Simulator --------------------------------------------------------------
if xcrun simctl list devices available 2>/dev/null | grep -q "iPhone 17"; then
  ok "iPhone 17 simulator available"
else bad "No 'iPhone 17' simulator available"
     info "fix: install the iOS 26 simulator runtime in Xcode → Settings → Components"; fi

# 4. screencapture (Screen Recording) --------------------------------------
SC=/tmp/aperture-preflight-sc.png
if screencapture -x "$SC" >/dev/null 2>&1 && [[ -s "$SC" ]] \
   && file "$SC" | grep -q "PNG image"; then
  ok "screencapture works (Screen Recording granted to $responsible)"
else
  bad "screencapture failed (Screen Recording NOT granted to $responsible)"
  info "fix: System Settings → Privacy & Security → Screen Recording → + →"
  info "     press ⌘⇧G and enter the responsible process path above, add, toggle ON"
  info "     (SSH: $responsible ; Terminal: add com.apple.Terminal)"
fi
rm -f "$SC" 2>/dev/null || true

# 5. Accessibility (AX tree read) ------------------------------------------
# Reading another process's accessibility tree requires Accessibility. This is
# the same permission XCUITest/System Events `click` (AXPress) needs.
AXOUT=$(osascript -e 'tell application "System Events" to get name of every application process whose visible is true' 2>&1)
if [[ $? -eq 0 && -n "$AXOUT" && "$AXOUT" != *error* && "$AXOUT" != *assistive* ]]; then
  ok "Accessibility tree is readable (Accessibility granted to $responsible)"
else
  bad "Accessibility tree read failed (Accessibility NOT granted to $responsible)"
  info "fix: System Settings → Privacy & Security → Accessibility → add the"
  info "     responsible process path above and toggle ON"
  info "     (SSH: /usr/libexec/sshd-keygen-wrapper ; Terminal: com.apple.Terminal)"
fi

# 6. Console lock state ------------------------------------------------------
# Accessibility permission can be granted while the login session is locked,
# but XCUITest still cannot bring an app above the lock-screen shield. Without
# this explicit check every Mac test waits ~60s and reports Running Background.
LOCK_STATE=$(ioreg -n Root -d1 2>/dev/null | grep -o '"CGSessionScreenIsLocked"=Yes' || true)
if [[ -z "$LOCK_STATE" ]]; then
  ok "Console screen is unlocked"
else
  bad "Console screen is locked; native Mac XCUITest cannot activate apps"
  info "fix: unlock the logged-in console session before running make test-mac-ui"
fi

# 7. Stale talagent window-restoration state --------------------------------
# talagent (com.apple.talagent) stores per-app window-restoration state in a
# daemon container. A non-zero restorecount.plist makes the next launch show
# the "Aperture unexpectedly quit while reopening windows" Reopen/Don't-Reopen
# modal. Under XCUITest that modal is suppressed → no window → every test
# times out. ApertureMac now sets .restorationBehavior(.disabled), but a
# marker left by an OLD build (or a real crash) still blocks until cleared.
TALAGENT_DIR="$HOME/Library/Daemon Containers"
stale_found=0
if [[ -d "$TALAGENT_DIR" ]]; then
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    wp="$d/windows.plist"; rc="$d/restorecount.plist"
    [[ -f "$wp" ]] || continue
    # Aperture's bundle version is "1"; only flag those.
    if ! plutil -p "$wp" 2>/dev/null | grep -q '"CFBundleVersion" => "1"'; then continue; fi
    if [[ -f "$rc" ]]; then
      cnt=$(plutil -p "$rc" 2>/dev/null | grep -oE 'count => [0-9]+' | grep -oE '[0-9]+' || echo 0)
      if [[ "$cnt" != "0" && -n "$cnt" ]]; then
        stale_found=1
        if [[ "$FIX" -eq 1 ]]; then
          rm -rf "$d" && info "cleared stale talagent state: $(basename "$d")"
        else
          bad "Stale talagent restoration marker for Aperture: $(basename "$d") (restorecount=$cnt)"
        fi
      fi
    fi
  done < <(find "$TALAGENT_DIR" -type d -name "*.savedState" 2>/dev/null)
fi
if [[ "$stale_found" -eq 0 ]]; then
  ok "No stale talagent 'Reopen windows?' marker for Aperture"
elif [[ "$FIX" -eq 1 ]]; then
  ok "Stale talagent state cleared (re-run without --fix to confirm)"
fi
# Also clear the app container's own saved state (harmless; the native app
# opts out of restoration).
if [[ "$FIX" -eq 1 ]]; then
  for c in "$HOME/Library/Containers"/*/Data/Library/Saved\ Application\ State; do
    [[ -d "$c" ]] || continue
    if ls "$c"/*Aperture* >/dev/null 2>&1 || ls "$c"/* >/dev/null 2>&1; then
      rm -rf "$c"/io.tailscale.Aperture* "$c"/io.tailscale.Aperture~iosmac* 2>/dev/null || true
    fi
  done
fi

echo "──────────────────────────────────────────────────────────────────"
printf 'Summary: %d passed, %d failed\n' "$pass" "$fail"
if [[ "$fail" -gt 0 ]]; then
  echo "❌ Preflight NOT ready — fix the items above."
  [[ "$stale_found" -eq 1 && "$FIX" -eq 0 ]] && info "rerun with --fix to clear stale talagent state"
  exit 1
fi
echo "✅ Preflight ready for autonomous macOS automation."
exit 0
