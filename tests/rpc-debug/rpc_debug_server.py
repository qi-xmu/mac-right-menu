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


# ---------------------------------------------------------------------------
# Server — asyncio TCP listener with connection multiplexing
# ---------------------------------------------------------------------------

import asyncio
import sys
from pathlib import Path

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
    # Log the inbound message
    _log_inbound(msg, verbose)

    # Dispatch
    reply = dispatch_message(msg, config)

    if reply is not None:
        data = encode_message(reply)
        writer.write(data)
        await writer.drain()
        _log_outbound(reply, verbose)


def _log_inbound(msg: dict[str, Any], verbose: bool) -> None:
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


def _log_outbound(reply: dict[str, Any], verbose: bool) -> None:
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
