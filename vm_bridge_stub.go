// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

//go:build ios

package main

// #include "errno.h"
import "C"

// The VM bridge is a macOS-only feature. Keep the symbols in iOS archives so
// the shared TailscaleKit Swift source still links, but reject every call.

//export TsnetVMBridgeStart
func TsnetVMBridgeStart(sd C.int, socketPath, magicDNSSuffix *C.char, bridgeOut *C.int) C.int {
	return C.ENOTSUP
}

//export TsnetVMBridgeReady
func TsnetVMBridgeReady(sd, bridgeHandle C.int) C.int {
	return C.ENOTSUP
}

//export TsnetVMBridgeStop
func TsnetVMBridgeStop(sd, bridgeHandle C.int) C.int {
	return C.ENOTSUP
}
