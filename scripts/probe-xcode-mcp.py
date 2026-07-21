#!/usr/bin/env python3
"""Minimal Xcode MCP server probe.

Spawns `xcrun mcpbridge`, does the JSON-RPC 2.0 handshake, and reports — with
timings — exactly which step stalls. This is the smallest useful "is the Xcode
MCP server alive and reachable?" check.

Usage:
    python3 scripts/probe-xcode-mcp.py              # 60s timeout, auto-detect Xcode
    python3 scripts/probe-xcode-mcp.py --timeout 30
    python3 scripts/probe-xcode-mcp.py --pid 499    # attach to a specific Xcode PID

What each step tells you:
  - initialize fails            -> xcrun mcpbridge can't run / no Xcode reachable
  - initialize OK, tools/list   -> if this hangs, Xcode is showing an approval
    hangs                          banner you must click "Allow" on. If NO banner
                                   appears, Xcode isn't receiving the connection
                                   (wrong PID? no project open? toggle off?).
  - tools/list returns          -> fully working; prints the tool count + names.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time


def log(msg: str) -> None:
    print(msg, flush=True)


def main() -> int:
    ap = argparse.ArgumentParser(description="Probe the Xcode MCP server (xcrun mcpbridge).")
    ap.add_argument("--timeout", type=float, default=60.0,
                    help="seconds to wait for tools/list (default 60; leaves time to click Allow)")
    ap.add_argument("--pid", type=int, default=None,
                    help="Xcode PID to attach to (else auto-detect)")
    args = ap.parse_args()

    # --- Context: which Xcode(s) are running? --------------------------------
    try:
        ps = subprocess.run(
            ["pgrep", "-lf", "Xcode.app/Contents/MacOS/Xcode"],
            capture_output=True, text=True,
        )
        xcodes = [l for l in ps.stdout.splitlines() if l.strip()]
    except FileNotFoundError:
        xcodes = []
    if xcodes:
        log("Xcode processes:")
        for line in xcodes:
            log(f"  {line}")
    else:
        log("⚠️  No Xcode.app process found. The bridge needs Xcode running with a project open.")

    env = dict(os.environ)
    if args.pid:
        env["MCP_XCODE_PID"] = str(args.pid)
        log(f"\nUsing MCP_XCODE_PID={args.pid}")

    # --- Spawn the bridge ----------------------------------------------------
    log("\nSpawning `xcrun mcpbridge`…")
    t0 = time.time()
    try:
        proc = subprocess.Popen(
            ["xcrun", "mcpbridge"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=env,
        )
    except FileNotFoundError:
        log("❌ `xcrun mcpbridge` not found. Is Xcode 26.x installed?")
        return 1

    def elapsed() -> str:
        return f"{(time.time() - t0) * 1000:.0f}ms"

    # --- Read one JSON-RPC response line, with a timeout ---------------------
    def read_response(timeout: float) -> dict | None:
        result: dict | None = None

        def reader():
            nonlocal result
            assert proc.stdout is not None
            line = proc.stdout.readline()
            if line:
                try:
                    result = json.loads(line)
                except json.JSONDecodeError:
                    result = {"_raw": line.strip()}

        th = threading.Thread(target=reader, daemon=True)
        th.start()
        th.join(timeout)
        return result

    def send(obj: dict) -> None:
        assert proc.stdin is not None
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    # --- 1. initialize -------------------------------------------------------
    send({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "probe", "version": "0.1"},
        },
    })
    init = read_response(10.0)
    if init is None:
        log(f"❌ [{elapsed()}] initialize: NO RESPONSE in 10s — bridge can't reach Xcode")
        proc.kill()
        return 2
    if "_raw" in init:
        log(f"❌ [{elapsed()}] initialize: non-JSON response: {init['_raw'][:200]}")
        proc.kill()
        return 2
    log(f"✅ [{elapsed()}] initialize OK: server={init.get('result', {}).get('serverInfo')!r}")

    # --- 2. notifications/initialized ----------------------------------------
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    # --- 3. tools/list (this is the step that blocks on the Xcode banner) ----
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    log(f"\n[{elapsed()}] tools/list sent — waiting up to {args.timeout}s…")
    log("    👉 If Xcode shows an approval banner, click Allow now.")
    tools = read_response(args.timeout)

    if tools is None:
        log(f"⏳ [{elapsed()}] tools/list: TIMED OUT after {args.timeout}s.")
        log("   This means Xcode is gating tool access. If no banner appeared in")
        log("   Xcode, check: a project is open, Intelligence→MCP toggle is ON,")
        log("   and you're attaching to the right Xcode PID (--pid).")
        proc.kill()
        return 3

    if "_raw" in tools:
        log(f"❌ [{elapsed()}] tools/list: non-JSON response: {tools['_raw'][:200]}")
        proc.kill()
        return 2

    err = tools.get("error")
    if err:
        log(f"❌ [{elapsed()}] tools/list returned an error: {err}")
        proc.kill()
        return 4

    names = [t.get("name") for t in tools.get("result", {}).get("tools", [])]
    log(f"✅ [{elapsed()}] tools/list OK: {len(names)} tools")
    log("   " + ", ".join(str(n) for n in names))
    log("\n🎉 Xcode MCP server is fully reachable.")
    proc.kill()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
