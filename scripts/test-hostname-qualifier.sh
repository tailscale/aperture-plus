#!/bin/bash
# Compile and run the pure shipping hostname qualifier on the host.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cp scripts/test-hostname-qualifier.swift "$OUT/main.swift"
xcrun swiftc -O \
    App/Browser/TailnetHostnameQualifier.swift \
    "$OUT/main.swift" \
    -o "$OUT/hostname-qualifier-tests"
"$OUT/hostname-qualifier-tests"
