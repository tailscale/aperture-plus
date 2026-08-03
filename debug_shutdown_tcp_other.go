// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

//go:build !darwin

package main

import "errors"

func debugShutdownTCPConnections() (matched, succeeded int, err error) {
	return 0, 0, errors.New("TCP shutdown chaos is only implemented on Darwin")
}
