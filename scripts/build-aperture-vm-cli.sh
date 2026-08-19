#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
package="$root/Packages/ApertureVM"
out="$root/build/aperture-vm-cli.app"
build="$package/.build/arm64-apple-macosx/debug"
mkdir -p "$root/build"

swift build --package-path "$package"
# Emit a standalone module/library so the CLI is linked against the exact
# package implementation rather than relying on SwiftPM's internal paths.
swiftc -swift-version 6 -emit-module -emit-library -parse-as-library \
  -target arm64-apple-macosx26.0 \
  -module-name ApertureVM \
  -emit-module-path "$build/ApertureVM.swiftmodule" \
  -o "$build/libApertureVM.dylib" \
  -framework Virtualization \
  Packages/ApertureVM/Sources/ApertureVM/*.swift

app="$out"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
cp -R "$root/ThirdParty/libtailscale/swift/build/Build/Products/Release/TailscaleKit.framework" "$app/Contents/Frameworks/"
cp Tools/aperture-vm-cli/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp "$root/MacApp/Thunderboot/Image" "$app/Contents/Resources/Image"
cp "$root/MacApp/Thunderboot/initramfs.cpio" "$app/Contents/Resources/initramfs.cpio"
cp "$root/MacApp/Thunderboot/manifest.json" "$app/Contents/Resources/manifest.json"
cp Tools/aperture-vm-cli/main.swift /tmp/aperture-vm-cli-main.swift
swiftc -swift-version 6 -parse-as-library \
  -target arm64-apple-macosx26.0 \
  -I "$build" -L "$build" -lApertureVM \
  -I "$root/ThirdParty/libtailscale/swift/build/Build/Intermediates.noindex/TailscaleKit.build/Release/TailscaleKit macOS.build/Objects-normal/arm64" \
  -F "$root/ThirdParty/libtailscale/swift/build/Build/Products/Release" \
  -framework TailscaleKit -framework Virtualization \
  /tmp/aperture-vm-cli-main.swift \
  -o "$app/Contents/MacOS/aperture-vm"

cp "$build/libApertureVM.dylib" "$app/Contents/Frameworks/libApertureVM.dylib"
install_name_tool -change "$build/libApertureVM.dylib" \
  '@rpath/libApertureVM.dylib' "$app/Contents/MacOS/aperture-vm"
install_name_tool -id '@rpath/libApertureVM.dylib' "$app/Contents/Frameworks/libApertureVM.dylib"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/aperture-vm"

tmp=$(mktemp)
trap 'rm -f "$tmp" /tmp/aperture-vm-cli-main.swift' EXIT
codesign --force --sign - --entitlements "$package/aperture-vm.entitlements" "$app/Contents/Frameworks/TailscaleKit.framework"
codesign --force --sign - --entitlements "$package/aperture-vm.entitlements" "$app/Contents/Frameworks/libApertureVM.dylib"
codesign --force --sign - --entitlements "$package/aperture-vm.entitlements" "$app/Contents/MacOS/aperture-vm"
codesign --force --sign - --entitlements "$package/aperture-vm.entitlements" "$app"
codesign --verify --deep --strict "$app"
codesign -d --entitlements :- "$app" >"$tmp" 2>/dev/null
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.virtualization' "$tmp" | grep -qx true
printf 'built signed sandboxed CLI app: %s\n' "$app"
