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
