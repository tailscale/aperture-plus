// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

//go:build darwin

package main

import (
	"fmt"

	"golang.org/x/sys/unix"
)

// debugShutdownTCPConnections deliberately damages every TCP socket currently
// owned by this process without closing any descriptor. It is test-only chaos
// injection for iOS-style socket defuncting: descriptors retain their identity,
// so there is no close/reuse race, but current listeners/connections must
// report failure or recover.
func debugShutdownTCPConnections() (matched, succeeded int, err error) {
	var firstErr error
	for fd := 0; fd < 1000; fd++ {
		if _, getErr := unix.GetsockoptTCPConnectionInfo(fd, unix.IPPROTO_TCP, unix.TCP_CONNECTION_INFO); getErr != nil {
			continue
		}
		matched++
		if shutdownErr := unix.Shutdown(fd, unix.SHUT_RDWR); shutdownErr != nil {
			// Some Darwin socket states reject shutdown even though the fd is a
			// TCP socket. Continue damaging the rest and report the first error.
			if firstErr == nil {
				firstErr = fmt.Errorf("shutdown TCP fd %d: %w", fd, shutdownErr)
			}
			continue
		}
		succeeded++
	}
	return matched, succeeded, firstErr
}
