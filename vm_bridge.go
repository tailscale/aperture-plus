// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

//go:build !ios

package main

// #include "errno.h"
import "C"

import (
	"fmt"

	"github.com/tailscale/libtailscale/vmnet"
)

//export TsnetVMBridgeStart
func TsnetVMBridgeStart(sd C.int, socketPath, magicDNSSuffix *C.char, bridgeOut *C.int) C.int {
	s := getServer(sd)
	if s == nil {
		return C.EBADF
	}
	if socketPath == nil || bridgeOut == nil {
		return C.EINVAL
	}
	bridge, err := vmnet.Start(C.GoString(socketPath), C.GoString(magicDNSSuffix), s.s.Dial)
	if err != nil {
		return s.recErr(fmt.Errorf("start VM bridge: %w", err))
	}
	s.vmMu.Lock()
	if s.vmBridges == nil {
		s.vmBridges = map[C.int]vmBridge{}
	}
	s.vmNext++
	if s.vmNext == 0 {
		s.vmNext++
	}
	handle := s.vmNext
	s.vmBridges[handle] = bridge
	s.vmMu.Unlock()
	*bridgeOut = handle
	return 0
}

//export TsnetVMBridgeReady
func TsnetVMBridgeReady(sd, bridgeHandle C.int) C.int {
	s := getServer(sd)
	if s == nil {
		return C.EBADF
	}
	s.vmMu.Lock()
	bridge := s.vmBridges[bridgeHandle]
	s.vmMu.Unlock()
	if bridge == nil {
		return C.EBADF
	}
	if bridge.Ready() {
		return 1
	}
	if err := bridge.Err(); err != nil {
		s.recErr(err)
		return -1
	}
	return 0
}

//export TsnetVMBridgeStop
func TsnetVMBridgeStop(sd, bridgeHandle C.int) C.int {
	s := getServer(sd)
	if s == nil {
		return C.EBADF
	}
	s.vmMu.Lock()
	bridge := s.vmBridges[bridgeHandle]
	delete(s.vmBridges, bridgeHandle)
	s.vmMu.Unlock()
	if bridge == nil {
		return C.EBADF
	}
	return s.recErr(bridge.Close())
}
