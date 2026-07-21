#!/bin/bash
#
# look.sh — capture a screenshot and (optionally) have a vision-capable sub-pi
# answer a question about it. This is how a non-vision agent "sees" the app.
#
# Usage:
#   scripts/look.sh                          # sim screenshot -> print path
#   scripts/look.sh "describe the UI"        # sim screenshot -> vision answer
#   scripts/look.sh --mac "..."              # Mac display screenshot -> vision answer
#   scripts/look.sh --sim --mac "..."        # force sim vs mac
#
# Vision model: gpt-4.1-nano via the aperture provider (image-capable override
# lives in ~/.pi/agent/models.json). It is newer and cheaper than gpt-4o-mini
# ($0.10 vs $0.15 /M input) and has no GPT-5 reasoning-token overhead.
#
# Headless notes:
#   --sim  always works (simctl reads the framebuffer; no TCC needed).
#   --mac  needs Screen Recording permission granted to this shell (System
#          Settings → Privacy & Security → Screen Recording). Without it,
#          screencapture fails with "could not create image from display".
#
set -euo pipefail

SRC="sim"
Q=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mac) SRC="mac"; shift;;
        --sim) SRC="sim"; shift;;
        --) shift; Q="$Q $*"; break;;
        *) Q="$Q $1"; shift;;
    esac
done
Q="${Q# }"

OUT="/tmp/look-$(date +%s).png"
if [[ "$SRC" == "mac" ]]; then
    if ! screencapture -x "$OUT" 2>/dev/null; then
        echo "❌ screencapture failed. Grant Screen Recording permission to this shell:" >&2
        echo "   System Settings → Privacy & Security → Screen Recording." >&2
        exit 1
    fi
else
    if ! xcrun simctl io booted screenshot "$OUT" >/dev/null 2>&1; then
        echo "❌ simctl screenshot failed. Boot a simulator first:" >&2
        echo "   xcrun simctl boot 'iPhone 17'" >&2
        exit 1
    fi
fi
echo "Screenshot: $OUT"

if [[ -n "$Q" ]]; then
    exec pi --provider aperture --model gpt-4.1-nano -p @"$OUT" "$Q"
fi
