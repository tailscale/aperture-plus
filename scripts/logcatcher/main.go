// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

// Command logcatcher is Aperture's minimal test log service. It accepts the
// logtail upload protocol and writes every entry to stdout before acknowledging
// the request, giving integration tests a deterministic durability boundary.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"

	"tailscale.com/types/logid"
	"tailscale.com/util/zstdframe"
)

var (
	out = bufio.NewWriter(os.Stdout)
	mu  sync.Mutex
)

func main() {
	ln, err := net.Listen("tcp", "0.0.0.0:0")
	if err != nil {
		log.Fatal(err)
	}
	host, err := reachableIPv4()
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("LOGCATCHER_URL=http://%s:%d\n", host, ln.Addr().(*net.TCPAddr).Port)
	if err := out.Flush(); err != nil {
		log.Fatal(err)
	}
	log.Fatal(http.Serve(ln, http.HandlerFunc(serve)))
}

func reachableIPv4() (string, error) {
	ifs, err := net.Interfaces()
	if err != nil {
		return "", err
	}
	for _, iface := range ifs {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := iface.Addrs()
		for _, addr := range addrs {
			ip, _, _ := net.ParseCIDR(addr.String())
			if ip != nil && ip.To4() != nil {
				return ip.String(), nil
			}
		}
	}
	return "", fmt.Errorf("no non-loopback IPv4 address")
}

func serve(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/c/"), "/")
	if r.Method != http.MethodPost || len(parts) != 2 {
		http.Error(w, "want POST /c/<collection>/<private-id>", http.StatusBadRequest)
		return
	}
	privateID, err := logid.ParsePrivateID(parts[1])
	if err != nil {
		http.Error(w, "bad private id", http.StatusBadRequest)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err == nil && r.Header.Get("Content-Encoding") == "zstd" {
		body, err = zstdframe.AppendDecode(nil, body)
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	var entries []json.RawMessage
	if len(body) > 0 && body[0] == '[' {
		err = json.Unmarshal(body, &entries)
	} else if len(body) > 0 {
		entries = []json.RawMessage{append([]byte(nil), body...)}
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	mu.Lock()
	for _, entry := range entries {
		fmt.Fprintf(out, "LOGTAIL %s %s %s\n", parts[0], privateID.Public(), entry)
	}
	err = out.Flush()
	mu.Unlock()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}
