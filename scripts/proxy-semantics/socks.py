#!/usr/bin/env python3
"""Minimal SOCKS5 proxy that LOGS every CONNECT request, so we can see exactly
which hostnames the OS decides to send through the proxy vs. resolve directly."""
import socket, threading, struct, sys, select

import os
os.makedirs('/tmp/pxprobe', exist_ok=True)
LOG = open('/tmp/pxprobe/socks.log', 'a', buffering=1)

def log(m):
    LOG.write(m + "\n")
    print(m, flush=True)

def handle(c):
    try:
        d = c.recv(2)
        if len(d) < 2 or d[0] != 5:
            c.close(); return
        nm = d[1]
        methods = c.recv(nm)
        # accept user/pass (2) if offered, else no-auth (0)
        if 2 in methods:
            c.sendall(b'\x05\x02')
            v = c.recv(1)
            ul = c.recv(1)[0]; user = c.recv(ul)
            pl = c.recv(1)[0]; pw = c.recv(pl)
            c.sendall(b'\x01\x00')
        else:
            c.sendall(b'\x05\x00')
        hdr = c.recv(4)
        if len(hdr) < 4:
            c.close(); return
        ver, cmd, rsv, atyp = hdr
        if atyp == 1:
            host = socket.inet_ntoa(c.recv(4)); kind = 'IPv4'
        elif atyp == 3:
            l = c.recv(1)[0]; host = c.recv(l).decode(); kind = 'NAME'
        elif atyp == 4:
            host = socket.inet_ntop(socket.AF_INET6, c.recv(16)); kind = 'IPv6'
        else:
            c.close(); return
        port = struct.unpack('!H', c.recv(2))[0]
        log(f"PROXY-CONNECT {kind} {host}:{port}")
        try:
            up = socket.create_connection((host, port), timeout=10)
        except Exception as e:
            log(f"  upstream fail {host}:{port}: {e}")
            c.sendall(b'\x05\x01\x00\x01' + b'\x00'*6); c.close(); return
        c.sendall(b'\x05\x00\x00\x01' + b'\x00'*6)
        # relay
        socks = [c, up]
        while True:
            r, _, x = select.select(socks, [], socks, 30)
            if x or not r: break
            done = False
            for s in r:
                o = up if s is c else c
                try: b = s.recv(65536)
                except Exception: done = True; break
                if not b: done = True; break
                o.sendall(b)
            if done: break
        up.close()
    except Exception as e:
        log(f"  handler error: {e}")
    finally:
        try: c.close()
        except Exception: pass

def main():
    port = int(sys.argv[1])
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('127.0.0.1', port)); s.listen(64)
    log(f"=== SOCKS5 listening on 127.0.0.1:{port} ===")
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()

main()
