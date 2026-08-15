// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

// Package vmnet adapts tailvisor's Ethernet/DHCP/DNS/gVisor bridge to borrow
// an existing libtailscale tsnet.Server. It contains no tsnet construction or
// authentication code: the embedding TailscaleNode owns the identity.
package vmnet

import (
	"context"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
)

type serverDialer struct {
	DialFunc func(context.Context, string, string) (net.Conn, error)
}

func (d serverDialer) Dial(ctx context.Context, network, address string) (net.Conn, error) {
	return d.DialFunc(ctx, network, address)
}

// Bridge is one disposable VM's layer-2 transport and proxy state.
type Bridge struct {
	cancel context.CancelFunc
	link   FrameLink
	ready  atomic.Bool
	done   chan struct{}

	stopOnce sync.Once
	mu       sync.Mutex
	err      error
}

// Start binds socketPath immediately and serves guest frames asynchronously.
// dial is expected to use the owning workspace's already-running tsnet node.
func Start(socketPath, magicDNSSuffix string, dial func(context.Context, string, string) (net.Conn, error)) (*Bridge, error) {
	if socketPath == "" {
		return nil, fmt.Errorf("empty VM network socket path")
	}
	if dial == nil {
		return nil, fmt.Errorf("nil VM network dialer")
	}
	link, err := openUnixDgramLink(socketPath)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	b := &Bridge{cancel: cancel, link: link, done: make(chan struct{})}
	server := NewServer(link, serverDialer{DialFunc: dial}, magicDNSSuffix, ctx, false, 0)
	b.ready.Store(true)
	go func() {
		defer close(b.done)
		if err := server.Serve(); err != nil && ctx.Err() == nil {
			b.mu.Lock()
			b.err = err
			b.mu.Unlock()
		}
		b.ready.Store(false)
	}()
	return b, nil
}

func (b *Bridge) Ready() bool {
	return b != nil && b.ready.Load()
}

func (b *Bridge) Err() error {
	if b == nil {
		return nil
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.err
}

func (b *Bridge) Close() error {
	if b == nil {
		return nil
	}
	b.stopOnce.Do(func() {
		b.ready.Store(false)
		b.cancel()
		_ = b.link.Close()
		<-b.done
	})
	return b.Err()
}
