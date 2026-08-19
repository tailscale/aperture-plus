#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
package="$root/Packages/ApertureVM"
out="$root/build/aperture-vm-cli"

swift build --package-path "$package" --product aperture-vm
cp "$package/.build/debug/aperture-vm" "$out"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
# The CLI is an unsandboxed developer diagnostic tool. It needs the
# virtualization entitlement but not app-sandbox/container entitlements.
codesign --force --sign - --entitlements "$package/aperture-vm.entitlements" "$out"
codesign --verify --deep --strict "$out"
codesign -d --entitlements :- "$out" >"$tmp" 2>/dev/null
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.virtualization' "$tmp" | grep -qx true
printf 'built signed CLI: %s\n' "$out"
