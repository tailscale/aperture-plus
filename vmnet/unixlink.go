// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

package vmnet

import (
	"errors"
	"net"
	"os"
	"sync"
	"syscall"
	"time"
)

// unixDgramLink speaks the datagram framing expected by
// VZFileHandleNetworkDeviceAttachment: one raw Ethernet frame per datagram.
type unixDgramLink struct {
	conn       *net.UnixConn
	socketPath string

	mu     sync.Mutex
	vmAddr *net.UnixAddr
}

func openUnixDgramLink(path string) (*unixDgramLink, error) {
	_ = os.Remove(path)
	addr, err := net.ResolveUnixAddr("unixgram", path)
	if err != nil {
		return nil, err
	}
	conn, err := net.ListenUnixgram("unixgram", addr)
	if err != nil {
		return nil, err
	}
	if rc, err := conn.SyscallConn(); err == nil {
		_ = rc.Control(func(fd uintptr) {
			_ = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_SNDBUF, 2<<20)
			_ = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_RCVBUF, 2<<20)
		})
	}
	return &unixDgramLink{conn: conn, socketPath: path}, nil
}

func (l *unixDgramLink) ReadFrame(buf []byte) (int, error) {
	n, addr, err := l.conn.ReadFromUnix(buf)
	if err != nil {
		return 0, err
	}
	l.mu.Lock()
	if l.vmAddr == nil {
		l.vmAddr = addr
	}
	l.mu.Unlock()
	return n, nil
}

func (l *unixDgramLink) WriteFrame(frame []byte) error {
	l.mu.Lock()
	addr := l.vmAddr
	l.mu.Unlock()
	if addr == nil {
		return nil
	}
	const maxRetries = 5
	backoff := 100 * time.Microsecond
	for i := range maxRetries {
		_, err := l.conn.WriteToUnix(frame, addr)
		if err == nil {
			return nil
		}
		if !errors.Is(err, syscall.ENOBUFS) {
			return err
		}
		if i < maxRetries-1 {
			time.Sleep(backoff)
			backoff *= 2
		}
	}
	return syscall.ENOBUFS
}

func (l *unixDgramLink) Close() error {
	err := l.conn.Close()
	_ = os.Remove(l.socketPath)
	return err
}
