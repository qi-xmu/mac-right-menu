# RPC Debug Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Python script that replaces the macOS Container app for debugging Finder Extension RPC communication.

**Architecture:** Single-file asyncio TCP server (`tests/rpc-debug/rpc-debug-server.py`) listening on `127.0.0.1:57421`, dispatching JSON-RPC 2.0 line-delimited messages (ping/getConfig/executeCommand) and replying with default-success responses. Uses typer for CLI, rich for terminal output, and pixi for environment management.

**Tech Stack:** Python 3.12+, typer, rich, pytest (dev), asyncio (stdlib), json (stdlib), pathlib (stdlib)

---

### Task 1: Update pixi.toml with dependencies and task

**Files:**
- Modify: `pixi.toml`

- [ ] **Step 1: Add dependencies and task to pixi.toml**

Read the current `pixi.toml` and replace the empty `[dependencies]` and `[tasks]` sections:

```toml
[workspace]
authors = ["qi-xmu <360141773@qq.com>"]
channels = ["conda-forge"]
name = "mac-right-menu"
platforms = ["osx-arm64"]
version = "0.1.0"

[tasks]
rpc-debug = "python tests/rpc-debug/rpc-debug-server.py"

[dependencies]
python = ">=3.12"
rich = ">=13.0"
typer = ">=0.12"
pytest = ">=8.0"
```

- [ ] **Step 2: Install dependencies**

Run: `pixi install`
Expected: pixi resolves and installs python, rich, typer, pytest from conda-forge.

- [ ] **Step 3: Verify Python is available**

Run: `pixi run python --version`
Expected: Python 3.12.x

- [ ] **Step 4: Commit**

```bash
git add pixi.toml
git commit -m "chore: add Python deps and rpc-debug task to pixi"
```

---

### Task 2: Create example debug-config.json

**Files:**
- Create: `tests/rpc-debug/debug-config.json`

- [ ] **Step 1: Write the config file**

Create `tests/rpc-debug/debug-config.json` with a valid `MenuConfiguration` matching the Swift model shapes in `Shared/Preferences/MenuConfiguration.swift` and `Shared/Models/AppMenuItem.swift`:

```json
{
  "isEnabled": true,
  "appsSectionEnabled": true,
  "appItems": [
    {
      "id": "/Applications/Visual Studio Code.app",
      "title": "Open with VS Code",
      "isEnabled": true,
      "appURL": "file:///Applications/Visual%20Studio%20Code.app",
      "displayName": "Visual Studio Code",
      "arguments": [],
      "environment": {}
    },
    {
      "id": "/Applications/Terminal.app",
      "title": "Open with Terminal",
      "isEnabled": true,
      "appURL": "file:///Applications/Terminal.app",
      "displayName": "Terminal",
      "arguments": [],
      "environment": {}
    }
  ],
  "actionItems": [
    {"actionType": "newFile", "isEnabled": true},
    {"actionType": "copyPath", "isEnabled": true},
    {"actionType": "copyFileName", "isEnabled": true},
    {"actionType": "toggleHidden", "isEnabled": true}
  ],
  "newFileTemplates": [
    {"fileName": "", "fileExtension": "txt", "defaultContent": "", "isEnabled": true},
    {"fileName": "", "fileExtension": "md", "defaultContent": "", "isEnabled": true},
    {"fileName": "", "fileExtension": "swift", "defaultContent": "import Foundation\n\n", "isEnabled": true}
  ]
}
```

Note: `appURL` uses `file://` URL scheme (percent-encoded spaces) because Swift's `URL` Codable serializes as `absoluteString`.

- [ ] **Step 2: Commit**

```bash
git add tests/rpc-debug/debug-config.json
git commit -m "feat: add example debug config for RPC server"
```

---

### Task 3: Write protocol layer (message dispatch + response builders)

**Files:**
- Create: `tests/rpc-debug/test_protocol.py`
- Modify: `tests/rpc-debug/rpc-debug-server.py` (create initial file)

- [ ] **Step 1: Write the failing tests**

Create `tests/rpc-debug/test_protocol.py`:

```python
"""Tests for RPC protocol message dispatch and response building."""
import json
import sys
from pathlib import Path

# Add parent to path so we can import the server module
sys.path.insert(0, str(Path(__file__).parent))

# We'll import from the server module once we create it
import rpc_debug_server as srv


class TestBuildResponse:
    def test_build_success_response(self):
        reply = srv.build_response(rid=1, success=True)
        assert reply == {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {"success": True, "errorDescription": None},
            "error": None,
        }

    def test_build_failure_response(self):
        reply = srv.build_response(rid=2, success=False, error_desc="something broke")
        assert reply == {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {"success": False, "errorDescription": "something broke"},
            "error": None,
        }


class TestBuildConfigResponse:
    def test_build_config_response_wraps_config(self):
        config = {"isEnabled": True, "appItems": [], "actionItems": [], "newFileTemplates": [], "appsSectionEnabled": True}
        reply = srv.build_config_response(rid=3, config=config)
        assert reply["jsonrpc"] == "2.0"
        assert reply["id"] == 3
        assert reply["result"]["success"] is True
        assert reply["result"]["config"] == config


class TestBuildError:
    def test_build_method_not_found(self):
        reply = srv.build_error(rid=4, code=-32601, message="Method not found")
        assert reply == {
            "jsonrpc": "2.0",
            "id": 4,
            "result": None,
            "error": {"code": -32601, "message": "Method not found"},
        }


class TestDispatchMessage:
    def test_ping_returns_success_response(self):
        msg = {"jsonrpc": "2.0", "id": 1, "method": "ping", "meta": {"pid": "123", "version": "1.0"}}
        config = {"isEnabled": True}
        reply = srv.dispatch_message(msg, config)
        assert reply is not None
        assert reply["id"] == 1
        assert reply["result"]["success"] is True

    def test_getConfig_returns_config_response(self):
        msg = {"jsonrpc": "2.0", "id": 2, "method": "getConfig"}
        config = {"isEnabled": True, "appItems": [{"id": "test"}], "actionItems": [], "newFileTemplates": [], "appsSectionEnabled": True}
        reply = srv.dispatch_message(msg, config)
        assert reply is not None
        assert reply["id"] == 2
        assert reply["result"]["config"] == config

    def test_executeCommand_returns_success_and_no_config(self):
        msg = {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "executeCommand",
            "params": {"action": 0, "files": ["/tmp/test.txt"], "command": None, "extra": None},
        }
        config = {"isEnabled": True}
        reply = srv.dispatch_message(msg, config)
        assert reply is not None
        assert reply["id"] == 3
        assert reply["result"]["success"] is True
        # executeCommand must NOT carry config
        assert "config" not in reply["result"]

    def test_unknown_method_with_id_returns_error(self):
        msg = {"jsonrpc": "2.0", "id": 5, "method": "unknownMethod"}
        config = {"isEnabled": True}
        reply = srv.dispatch_message(msg, config)
        assert reply is not None
        assert reply["error"]["code"] == -32601

    def test_pong_notification_returns_none(self):
        """pong has method but no id — it's a notification, no reply expected."""
        msg = {"jsonrpc": "2.0", "method": "pong"}
        config = {"isEnabled": True}
        reply = srv.dispatch_message(msg, config)
        assert reply is None

    def test_unknown_notification_returns_none(self):
        """Any message with method but no id is a notification — no reply."""
        msg = {"jsonrpc": "2.0", "method": "shutdown"}
        config = {"isEnabled": True}
        reply = srv.dispatch_message(msg, config)
        assert reply is None

    def test_message_without_method_or_id_returns_none(self):
        msg = {"jsonrpc": "2.0", "garbage": True}
        config = {"isEnabled": True}
        reply = srv.dispatch_message(msg, config)
        assert reply is None


class TestActionName:
    def test_known_actions(self):
        assert srv.action_name(0) == "newFile"
        assert srv.action_name(1) == "openWithApp"
        assert srv.action_name(2) == "copyPath"
        assert srv.action_name(3) == "copyFileName"
        assert srv.action_name(4) == "toggleHidden"
        assert srv.action_name(6) == "shell"

    def test_unknown_action(self):
        assert srv.action_name(99) == "unknown(99)"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pixi run python -m pytest tests/rpc-debug/test_protocol.py -v`
Expected: FAIL — `rpc_debug_server` module not found (no `ImportError` if file exists but empty, or `AttributeError` for missing functions).

- [ ] **Step 3: Write the protocol layer in rpc-debug-server.py**

Create `tests/rpc-debug/rpc-debug-server.py` with the protocol functions:

```python
#!/usr/bin/env python3
"""RPC Debug Server — standalone JSON-RPC 2.0 host for Finder Extension debugging.

Replaces the macOS Container app. Listens on 127.0.0.1:{port}, accepts
line-delimited JSON-RPC requests from the Finder Extension, and replies
with default-success responses.
"""

from __future__ import annotations

import json
from typing import Any


# ---------------------------------------------------------------------------
# Protocol — message dispatch & response builders
# ---------------------------------------------------------------------------

def build_response(rid: int, success: bool, error_desc: str | None = None) -> dict[str, Any]:
    """Build an RPCResponse for a command result (ping, executeCommand)."""
    return {
        "jsonrpc": "2.0",
        "id": rid,
        "result": {
            "success": success,
            "errorDescription": error_desc,
        },
        "error": None,
    }


def build_config_response(rid: int, config: dict[str, Any]) -> dict[str, Any]:
    """Build an RPCResponse that carries the full MenuConfiguration (for getConfig)."""
    return {
        "jsonrpc": "2.0",
        "id": rid,
        "result": {
            "success": True,
            "errorDescription": None,
            "config": config,
        },
        "error": None,
    }


def build_error(rid: int, code: int, message: str) -> dict[str, Any]:
    """Build an RPCResponse with an error payload."""
    return {
        "jsonrpc": "2.0",
        "id": rid,
        "result": None,
        "error": {
            "code": code,
            "message": message,
        },
    }


def dispatch_message(
    msg: dict[str, Any], config: dict[str, Any]
) -> dict[str, Any] | None:
    """Dispatch an inbound JSON-RPC message; return the reply dict or None.

    Detection rules (matching RPCSession.swift):
    - Has `id` + `method` → RPCRequest; dispatch by method name.
    - Has `method` but no `id` → RPCShutdownNotification (pong); no reply.
    - Neither → unknown; no reply.
    """
    method = msg.get("method")
    rid = msg.get("id")

    # Notification (method, no id) — e.g. pong, shutdown
    if method and rid is None:
        return None

    # Request (method + id)
    if method and rid is not None:
        if method == "ping":
            return build_response(rid, success=True)
        elif method == "getConfig":
            return build_config_response(rid, config)
        elif method == "executeCommand":
            # Details are logged by the caller; here we just return success
            return build_response(rid, success=True)
        else:
            return build_error(rid, -32601, f"Method not found: {method}")

    # Unknown — no method, or no id for a request
    return None


def action_name(action: int) -> str:
    """Map CommandRequest.Action rawValue → human-readable name.

    Values match CommandRequest.Action enum in Shared/Models/CommandRequest.swift:
    0=newFile, 1=openWithApp, 2=copyPath, 3=copyFileName, 4=toggleHidden, 6=shell.
    """
    names = {
        0: "newFile",
        1: "openWithApp",
        2: "copyPath",
        3: "copyFileName",
        4: "toggleHidden",
        6: "shell",
    }
    return names.get(action, f"unknown({action})")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pixi run python -m pytest tests/rpc-debug/test_protocol.py -v`
Expected: All 10 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/rpc-debug/rpc-debug-server.py tests/rpc-debug/test_protocol.py
git commit -m "feat: add RPC protocol dispatch and response builders"
```

---

### Task 4: Write framing layer (line-delimited JSON encode/decode)

**Files:**
- Create: `tests/rpc-debug/test_framing.py`
- Modify: `tests/rpc-debug/rpc-debug-server.py` (append framing functions)

- [ ] **Step 1: Write the failing tests**

Create `tests/rpc-debug/test_framing.py`:

```python
"""Tests for line-delimited JSON framing (matching RPCSession.swift framing)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import rpc_debug_server as srv


class TestEncodeMessage:
    def test_simple_message_ends_with_newline(self):
        msg = {"jsonrpc": "2.0", "id": 1, "result": {"success": True}}
        data = srv.encode_message(msg)
        assert data.endswith(b"\n")
        assert data.count(b"\n") == 1  # exactly one newline, at the end

    def test_compact_json_no_spaces(self):
        """Messages should be compact (no spaces after separators) to match Swift JSONEncoder output."""
        msg = {"a": 1, "b": "hello"}
        data = srv.encode_message(msg)
        line = data[:-1]  # strip trailing \n
        # no spaces after : or ,
        assert b": " not in line
        assert b", " not in line


class TestDecodeMessages:
    def test_single_complete_message(self):
        buf = b'{"jsonrpc":"2.0","id":1}\n'
        messages, remaining = srv.decode_messages(buf)
        assert len(messages) == 1
        assert messages[0] == {"jsonrpc": "2.0", "id": 1}
        assert remaining == b""

    def test_multiple_complete_messages(self):
        buf = b'{"a":1}\n{"b":2}\n'
        messages, remaining = srv.decode_messages(buf)
        assert len(messages) == 2
        assert messages[0] == {"a": 1}
        assert messages[1] == {"b": 2}
        assert remaining == b""

    def test_partial_message_returns_remaining(self):
        buf = b'{"a":1}\n{"b":'
        messages, remaining = srv.decode_messages(buf)
        assert len(messages) == 1
        assert messages[0] == {"a": 1}
        assert remaining == b'{"b":'

    def test_empty_buffer(self):
        messages, remaining = srv.decode_messages(b"")
        assert messages == []
        assert remaining == b""

    def test_only_newline(self):
        messages, remaining = srv.decode_messages(b"\n")
        assert messages == []
        assert remaining == b""

    def test_invalid_json_logs_and_skips(self):
        """Invalid JSON line should be skipped, not crash."""
        buf = b'not-json\n{"valid":1}\n'
        messages, remaining = srv.decode_messages(buf)
        # The invalid line is skipped; valid message is parsed
        assert len(messages) == 1
        assert messages[0] == {"valid": 1}
        assert remaining == b""
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pixi run python -m pytest tests/rpc-debug/test_framing.py -v`
Expected: FAIL — `encode_message` / `decode_messages` not defined.

- [ ] **Step 3: Write the framing functions**

Append to `tests/rpc-debug/rpc-debug-server.py`:

```python
# ---------------------------------------------------------------------------
# Framing — line-delimited JSON (matching RPCSession.swift sendJSON / readLines)
# ---------------------------------------------------------------------------

def encode_message(msg: dict[str, Any]) -> bytes:
    """Encode a JSON-RPC message to wire format: compact JSON + \\n."""
    # separators=(',',':') produces compact output — no spaces after , or :
    # This matches Swift's JSONEncoder.outputFormatting = [] (default, compact).
    body = json.dumps(msg, ensure_ascii=False, separators=(",", ":"))
    return body.encode("utf-8") + b"\n"


def decode_messages(buf: bytes) -> tuple[list[dict[str, Any]], bytes]:
    """Split buffer on \\n, parse each complete line as JSON.

    Returns (parsed_messages, leftover_bytes).
    Invalid JSON lines are silently skipped (the connection stays alive).
    Empty lines (just \\n) are also skipped.
    """
    messages: list[dict[str, Any]] = []
    remaining = buf

    while b"\n" in remaining:
        line, remaining = remaining.split(b"\n", 1)
        if not line:
            # Skip empty lines (just \n with nothing before)
            continue
        try:
            msg = json.loads(line.decode("utf-8"))
            messages.append(msg)
        except (json.JSONDecodeError, UnicodeDecodeError):
            # Malformed line — skip and continue
            pass

    return messages, remaining
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pixi run python -m pytest tests/rpc-debug/test_framing.py -v`
Expected: All 6 tests PASS.

- [ ] **Step 5: Run all tests together**

Run: `pixi run python -m pytest tests/rpc-debug/ -v`
Expected: All 16 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add tests/rpc-debug/rpc-debug-server.py tests/rpc-debug/test_framing.py
git commit -m "feat: add line-delimited JSON framing layer"
```

---

### Task 5: Write server, CLI, and rich logging

**Files:**
- Modify: `tests/rpc-debug/rpc-debug-server.py` (append server + CLI + logging)

- [ ] **Step 1: Write the remaining implementation**

Append to `tests/rpc-debug/rpc-debug-server.py`:

```python
# ---------------------------------------------------------------------------
# Server — asyncio TCP listener with connection multiplexing
# ---------------------------------------------------------------------------

import asyncio
import sys
from pathlib import Path
from typing import Any

import typer
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

app = typer.Typer(
    name="rpc-debug",
    help="Standalone JSON-RPC 2.0 debug server for Finder Extension RPC testing.",
    add_completion=False,
)

console = Console()
_conn_counter = 0


def load_config(path: Path) -> dict[str, Any]:
    """Load MenuConfiguration from a JSON file.

    Returns a minimal fallback config if the file is missing or invalid.
    """
    fallback: dict[str, Any] = {
        "isEnabled": True,
        "appItems": [],
        "actionItems": [],
        "newFileTemplates": [],
        "appsSectionEnabled": True,
    }
    if not path.exists():
        console.print(f"[yellow]⚠ Config file not found: {path}, using fallback[/]")
        return fallback
    try:
        data = json.loads(path.read_text("utf-8"))
        console.print(f"[dim]Loaded config from {path}[/]")
        return data
    except (json.JSONDecodeError, OSError) as exc:
        console.print(f"[yellow]⚠ Failed to parse config: {exc}, using fallback[/]")
        return fallback


async def handle_connection(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    conn_id: int,
    config: dict[str, Any],
    verbose: bool,
) -> None:
    """Handle one TCP connection from the Finder Extension."""
    addr = writer.get_extra_info("peername")
    addr_str = f"{addr[0]}:{addr[1]}" if addr else "unknown"
    console.print(f"[cyan]⬆ CONNECT[/]  id={conn_id}  from [dim]{addr_str}[/]")

    buf = b""
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                console.print(f"[cyan]↓ DISCONNECT[/]  id={conn_id}  reason=EOF")
                break

            buf += data
            messages, buf = decode_messages(buf)

            for msg in messages:
                await process_message(msg, writer, conn_id, config, verbose)
    except asyncio.CancelledError:
        pass
    except OSError as exc:
        console.print(f"[cyan]↓ DISCONNECT[/]  id={conn_id}  reason={exc}")
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except OSError:
            pass


async def process_message(
    msg: dict[str, Any],
    writer: asyncio.StreamWriter,
    conn_id: int,
    config: dict[str, Any],
    verbose: bool,
) -> None:
    """Process one parsed JSON-RPC message and send the reply if applicable."""
    method = msg.get("method", "?")
    rid = msg.get("id")

    # Log the inbound message
    _log_inbound(msg, conn_id, verbose)

    # Dispatch
    reply = dispatch_message(msg, config)

    if reply is not None:
        data = encode_message(reply)
        writer.write(data)
        await writer.drain()
        _log_outbound(reply, conn_id, verbose)


def _log_inbound(msg: dict[str, Any], conn_id: int, verbose: bool) -> None:
    """Log an inbound message with rich formatting."""
    method = msg.get("method", "?")
    rid = msg.get("id", "?")
    meta = msg.get("meta")

    parts: list[str] = [f"[yellow]→ RECV[/] [bold]{method}[/]  id={rid}"]

    if method == "ping" and meta:
        parts.append(f"pid={meta.get('pid','?')} v={meta.get('version','?')}")
    elif method == "executeCommand":
        params = msg.get("params", {})
        action = params.get("action", "?")
        files = params.get("files", [])
        cmd = params.get("command")
        parts.append(f"action=[bold]{action_name(action)}[/]")
        if files:
            parts.append(f"files={files}")
        if cmd:
            parts.append(f'cmd="{cmd}"')
    elif method == "getConfig":
        pass  # nothing extra to show

    console.print("  ".join(parts))

    if verbose:
        console.print(f"  [dim]{json.dumps(msg, ensure_ascii=False)}[/]")


def _log_outbound(reply: dict[str, Any], conn_id: int, verbose: bool) -> None:
    """Log an outbound message with rich formatting."""
    rid = reply.get("id", "?")
    error = reply.get("error")
    result = reply.get("result", {})

    if error:
        status = f"[red]✗[/] {error.get('message','')}"
    elif result.get("config"):
        item_count = _count_config_items(result["config"])
        status = f"[green]✓[/] config({item_count})"
    else:
        status = "[green]✓[/]"

    console.print(f"[green]← SEND[/]  id={rid}  {status}")

    if verbose:
        console.print(f"  [dim]{json.dumps(reply, ensure_ascii=False)}[/]")


def _count_config_items(config: dict[str, Any]) -> str:
    """Human-readable count of config items for log output."""
    apps = len(config.get("appItems", []))
    actions = len(config.get("actionItems", []))
    templates = len(config.get("newFileTemplates", []))
    return f"{apps}a/{actions}c/{templates}t"


async def run_server(port: int, config_path: Path, verbose: bool) -> None:
    """Start the TCP server and run until interrupted."""
    global _conn_counter

    config = load_config(config_path)

    # Print banner
    banner = Table.grid(padding=(0, 2))
    banner.add_column(justify="center")
    banner.add_row(Text("RPC Debug Server v0.1.0", style="bold white"))
    banner.add_row(Text(f"Listening on 127.0.0.1:{port}", style="dim"))
    banner.add_row(Text(f"Config: {config_path}", style="dim"))
    console.print(Panel(banner, border_style="blue"))

	    async def on_connect(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        global _conn_counter
        conn_id = _conn_counter
        _conn_counter += 1
        await handle_connection(reader, writer, conn_id, config, verbose)

    try:
        server = await asyncio.start_server(on_connect, "127.0.0.1", port)
    except OSError as exc:
        console.print(f"[red]✗ Cannot start server: {exc}[/]")
        console.print(
            f"[yellow]  Is the main app running? Port {port} may be in use.[/]"
        )
        raise typer.Exit(code=1)

    async with server:
        try:
            await server.serve_forever()
        except asyncio.CancelledError:
            pass
        finally:
            console.print("[dim]Server stopped.[/]")


@app.command()
def main(
    port: int = typer.Option(57421, help="TCP port to listen on"),
    config: Path = typer.Option(
        Path("tests/rpc-debug/debug-config.json"),
        exists=False,
        help="Path to MenuConfiguration JSON file",
    ),
    verbose: bool = typer.Option(False, "--verbose", "-v", help="Show full JSON payloads"),
) -> None:
    """Start the RPC debug server for Finder Extension testing.

    Listens on 127.0.0.1:{port} and replies to JSON-RPC requests
    (ping, getConfig, executeCommand) with default-success responses.
    """
    try:
        asyncio.run(run_server(port, config, verbose))
    except KeyboardInterrupt:
        console.print("\n[dim]Received SIGINT, shutting down...[/]")


if __name__ == "__main__":
    app()
```

- [ ] **Step 2: Verify syntax and imports**

Run: `pixi run python -c "import ast; ast.parse(open('tests/rpc-debug/rpc-debug-server.py').read()); print('Syntax OK')"`
Expected: `Syntax OK`

- [ ] **Step 3: Run all tests to verify nothing is broken**

Run: `pixi run python -m pytest tests/rpc-debug/ -v`
Expected: All 16 tests still PASS.

- [ ] **Step 4: Verify CLI help works**

Run: `pixi run python tests/rpc-debug/rpc-debug-server.py --help`
Expected: typer help output showing --port, --config, --verbose options.

- [ ] **Step 5: Commit**

```bash
git add tests/rpc-debug/rpc-debug-server.py
git commit -m "feat: add asyncio server, typer CLI, and rich logging"
```

---

### Task 6: End-to-end verification

**Files:**
- Create: `tests/rpc-debug/verify_e2e.py` (standalone smoke test)

- [ ] **Step 1: Write the verification script**

Create `tests/rpc-debug/verify_e2e.py`:

```python
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
import subprocess
import sys
import time
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

        # Test 3: executeCommand
        req = {
            "jsonrpc": "2.0", "id": 3, "method": "executeCommand",
            "params": {"action": 2, "files": ["/tmp/test.txt"], "command": None, "extra": None},
        }
        writer.write(srv.encode_message(req))
        await writer.drain()
        resp = json.loads((await reader.read(65536)).rstrip(b"\n"))
        check("executeCommand → success", resp["result"]["success"] is True, str(resp))

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
```

- [ ] **Step 2: Run the verification script**

Run: `pixi run python tests/rpc-debug/verify_e2e.py`
Expected: All 5 tests PASS.

- [ ] **Step 3: Run all tests one final time**

Run: `pixi run python -m pytest tests/rpc-debug/ -v`
Expected: 16 unit tests PASS (verify_e2e.py is not a pytest test, so not included).

- [ ] **Step 4: Commit**

```bash
git add tests/rpc-debug/verify_e2e.py
git commit -m "test: add E2E verification script for RPC debug server"
```

---

### Task 7: Final cleanup and .gitignore

**Files:**
- Modify: `.gitignore` (verify test artifacts are covered)

- [ ] **Step 1: Verify __pycache__ is in .gitignore**

Run: `grep -n "__pycache__" .gitignore`
Expected: Should find a line like `__pycache__/` or `*.pyc`. If not, add:

```gitignore
# Python
__pycache__/
*.pyc
.pytest_cache/
```

- [ ] **Step 2: Verify pixi.lock is tracked (or not)**

Check if `pixi.lock` should be committed:
Run: `git status pixi.lock` — if it exists and is untracked, add it (pixi.lock is the lockfile, should be committed).

- [ ] **Step 3: Final commit**

```bash
git add .gitignore pixi.lock  # if modified/created
git commit -m "chore: update .gitignore for Python artifacts"
```
