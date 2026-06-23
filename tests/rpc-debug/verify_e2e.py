#!/usr/bin/env python3
"""Manual end-to-end smoke test for the RPC debug server.

Usage:
  1. Start the server in one terminal:
     pixi run rpc-debug

  2. Run this script in another:
     pixi run python tests/rpc-debug/verify_e2e.py

Or let this script start+stop the server automatically.
"""
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import rpc_debug_server as srv

PASS = 0
FAIL = 0


def check(name: str, condition: bool, detail: str = ""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print(f"  ✅ {name}")
    else:
        FAIL += 1
        print(f"  ❌ {name}  {detail}")


async def main():
    port = 57422  # Use a non-default port so we don't conflict with the real app
    config_path = Path(__file__).parent / "debug-config.json"

    print(f"Starting server on 127.0.0.1:{port}...")
    server_task = asyncio.create_task(
        srv.run_server(port, config_path, verbose=False)
    )
    await asyncio.sleep(0.2)

    try:
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        print("Connected.\n")

        # Test 1: ping
        ping = {"jsonrpc": "2.0", "id": 1, "method": "ping", "meta": {"pid": "999", "version": "1.0"}}
        writer.write(srv.encode_message(ping))
        await writer.drain()
        resp = json.loads((await reader.read(65536)).rstrip(b"\n"))
        check("ping → success", resp["result"]["success"] is True, str(resp))

        # Test 2: getConfig
        req = {"jsonrpc": "2.0", "id": 2, "method": "getConfig"}
        writer.write(srv.encode_message(req))
        await writer.drain()
        resp = json.loads((await reader.read(65536)).rstrip(b"\n"))
        check("getConfig → has config", "config" in resp["result"], str(resp)[:80])

        # Test 3: executeAction
        req = {
            "jsonrpc": "2.0", "id": 3, "method": "executeAction",
            "params": {"actionID": 2000, "targetURL": "/tmp", "selectedURLs": ["/tmp/test.txt"]},
        }
        writer.write(srv.encode_message(req))
        await writer.drain()
        resp = json.loads((await reader.read(65536)).rstrip(b"\n"))
        check("executeAction → success", resp["result"]["success"] is True, str(resp))

        # Test 4: unknown method
        req = {"jsonrpc": "2.0", "id": 4, "method": "unknownMethod"}
        writer.write(srv.encode_message(req))
        await writer.drain()
        resp = json.loads((await reader.read(65536)).rstrip(b"\n"))
        check("unknown method → error", resp["error"] is not None and resp["error"]["code"] == -32601, str(resp))

        # Test 5: pong notification (no reply expected)
        pong = {"jsonrpc": "2.0", "method": "pong"}
        writer.write(srv.encode_message(pong))
        await writer.drain()
        # Give the server a moment to process, then check no data was sent back
        await asyncio.sleep(0.1)
        try:
            extra = await asyncio.wait_for(reader.read(65536), timeout=0.5)
            check("pong → no reply", len(extra) == 0, f"Got unexpected data: {extra}")
        except asyncio.TimeoutError:
            check("pong → no reply", True)

        print(f"\n{'─'*40}")
        print(f"Results: {PASS} passed, {FAIL} failed")

        writer.close()
        await writer.wait_closed()
    finally:
        server_task.cancel()
        try:
            await server_task
        except asyncio.CancelledError:
            pass

    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
