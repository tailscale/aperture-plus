#!/bin/bash
# Compile + run the TailnetProxyPolicy unit tests on the host.
#
# Compiles the REAL TSNet/TailnetProxyPolicy.swift against stubs of the two
# TailscaleKit types it reads, so the shipping split-tunnel logic is tested with
# no xcframework, no simulator and no signing. Fast (~2s).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# `import TailscaleKit` is stripped: the stubs provide those types instead.
sed 's/^import TailscaleKit$//' TSNet/TailnetProxyPolicy.swift > "$OUT/policy.swift"
# Swift only allows top-level statements in a file called main.swift.
cp scripts/test-proxy-policy.swift "$OUT/main.swift"

xcrun swiftc -O \
    "$OUT/policy.swift" \
    scripts/test-proxy-policy-stubs.swift \
    "$OUT/main.swift" \
    -o "$OUT/policytests"

"$OUT/policytests"
