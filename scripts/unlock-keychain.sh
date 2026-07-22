#!/bin/bash
#
# unlock-keychain.sh — ensure the login keychain is unlocked for non-interactive
# codesign (needed by `make ipa`).
#
# Over SSH the login keychain starts locked, and `security unlock-keychain`
# (without -p) tries to show a GUI password prompt that can't appear, so
# codesign later fails with errSecInternalComponent. This script:
#
#   1. Checks whether the login keychain is already usable (unlocked). If so,
#      exits 0 immediately — common case in a GUI session (unlocked at login)
#      or after a prior unlock in the same SSH session.
#   2. If it's locked and stdin is a terminal, prompts for the login password
#      (no echo) and unlocks with `security unlock-keychain -p`, then
#      re-verifies. The password lives only in a shell variable, is `unset`
#      right after, and is never echoed or logged.
#   3. If it's locked and stdin is NOT a terminal (piped / cron / headless
#      with no tty), aborts with a clear error instead of hanging on a prompt
#      that can never appear.
#
# The keychain re-locks on reboot, so run this once per SSH session before
# `make ipa` (the `make ipa` target runs it automatically). Override the
# keychain path with KC=/path/to/keychain.
#
# Exit 0 = unlocked (and usable); exit 1 = still locked / couldn't unlock.
set -euo pipefail

KC="${KC:-$HOME/Library/Keychains/login.keychain-db}"

# `security show-keychain-info` exits 0 when the keychain is unlocked and
# non-zero when it's locked (over SSH it reports "User interaction is not
# allowed"). That's our cheap, prompt-free lock probe.
unlocked() {
    security show-keychain-info "$KC" >/dev/null 2>&1
}

if unlocked; then
    exit 0
fi

# Locked (or otherwise unusable non-interactively). Decide whether we can ask.
if [ ! -t 0 ]; then
    echo "❌ Login keychain is locked and stdin is not a terminal — can't prompt." >&2
    echo "   codesign needs an unlocked keychain to sign the embedded" >&2
    echo "   TailscaleKit.framework; without it the archive fails with" >&2
    echo "   errSecInternalComponent. Either run \`make ipa\` from an" >&2
    echo "   interactive SSH/GUI terminal (it will prompt for your login" >&2
    echo "   password), or unlock the keychain first, e.g.:" >&2
    echo "     read -s PW; security unlock-keychain -p \"\$PW\" \"$KC\"; unset PW" >&2
    exit 1
fi

# Interactive: prompt and unlock.
echo "Login keychain is locked. Enter your login password to unlock it for codesign." >&2
read -s PW
ok=0
if security unlock-keychain -p "$PW" "$KC" 2>/dev/null && unlocked; then
    ok=1
fi
unset PW
if [ "$ok" -eq 1 ]; then
    echo "Keychain unlocked." >&2
    exit 0
fi
echo "❌ Failed to unlock the login keychain (wrong password, or the keychain" >&2
echo "   password differs from your login password)." >&2
exit 1
