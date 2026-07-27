#!/usr/bin/env python3
"""SOCKS5 proxy that always answers CONNECT with a chosen failure reply code.
Used to learn which NSURLError WebKit surfaces for each SOCKS failure mode."""
import socket, threading, struct, sys

REPLY = int(sys.argv[2])   # SOCKS5 reply code: 1=general,2=notallowed,3=netunreach,4=hostunreach,5=refused
PORT = int(sys.argv[1])

def handle(c):
    try:
        d = c.recv(2)
        if len(d) < 2: return
        nm = d[1]; methods = c.recv(nm)
        if 2 in methods:
            c.sendall(b'\x05\x02')
            c.recv(1); ul = c.recv(1)[0]; c.recv(ul); pl = c.recv(1)[0]; c.recv(pl)
            c.sendall(b'\x01\x00')
        else:
            c.sendall(b'\x05\x00')
        hdr = c.recv(4)
        if len(hdr) < 4: return
        atyp = hdr[3]
        if atyp == 1: c.recv(4)
        elif atyp == 3: c.recv(c.recv(1)[0])
        elif atyp == 4: c.recv(16)
        c.recv(2)
        c.sendall(bytes([5, REPLY, 0, 1]) + b'\x00'*6)
    except Exception:
        pass
    finally:
        try: c.close()
        except Exception: pass

s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', PORT)); s.listen(64)
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
