# RPC Debug Server — Design Spec

**Date**: 2026-06-17  
**Status**: Approved  
**Context**: Need a lightweight Python host-side RPC server to debug Finder Extension communication without running the full Container app.

## 1. Purpose

Replace the macOS Container app (`mac-right-menu`) with a Python script that:

- Listens on the same TCP loopback address (`127.0.0.1:57421`)
- Accepts JSON-RPC 2.0 requests from the Finder Extension
- Replies with valid protocol responses (default: success)
- Logs all traffic to the terminal with rich formatting

This enables faster debug cycles — no Xcode build, no SwiftUI window, just start the script and interact with the Extension.

## 2. File Layout

```
tests/rpc-debug/
├── rpc-debug-server.py       # single-file Python script (~300 lines)
└── debug-config.json          # example MenuConfiguration for getConfig responses

pixi.toml                      # updated: add [dependencies] + [tasks]
```

## 3. Architecture (Single-File Layers)

```
┌───────────────────────────────────────────┐
│  CLI (typer)                              │
│  --port 57421 --config debug-config.json  │
│  --verbose                                │
├───────────────────────────────────────────┤
│  Server (asyncio.start_server)            │
│  - Listen 127.0.0.1:{port}               │
│  - Concurrent connections                 │
│  - Connection lifecycle logging           │
├───────────────────────────────────────────┤
│  Protocol (line-delimited JSON-RPC)       │
│  - Read until \n → json.loads            │
│  - Dispatch: ping / getConfig / executeCmd│
│  - json.dumps + \n → send                │
│  - Error handling + format validation     │
├───────────────────────────────────────────┤
│  ConfigLoader                             │
│  - Load MenuConfiguration from JSON file  │
│  - Fallback to built-in minimal config    │
├───────────────────────────────────────────┤
│  Logger (rich)                            │
│  - Color-coded structured terminal output │
│  - Timestamp, direction arrows, payload   │
└───────────────────────────────────────────┘
```

## 4. Protocol Behavior

Complete match with existing `RPCSession.swift` wire format.

### 4.1 Inbound Message Dispatch

Messages arrive as `\n`-terminated JSON lines. The script decodes and dispatches by checking the presence/absence of `id` and `method` fields:

| Received | Detection Rule | Response |
|----------|---------------|----------|
| `{"jsonrpc":"2.0","id":N,"method":"ping","meta":{...}}` | Has `id` + `method`="ping" | `{"jsonrpc":"2.0","id":N,"result":{"success":true}}` |
| `{"jsonrpc":"2.0","id":N,"method":"getConfig"}` | Has `id` + `method`="getConfig" | `{"jsonrpc":"2.0","id":N,"result":{"success":true,"config":{...}}}` |
| `{"jsonrpc":"2.0","id":N,"method":"executeCommand","params":{...}}` | Has `id` + `method`="executeCommand" | Rich-print action/files; `{"jsonrpc":"2.0","id":N,"result":{"success":true}}` |
| `{"jsonrpc":"2.0","method":"pong"}` | Has `method`, no `id` | Log only (Extension heartbeat ack, no reply) |
| Unknown method (has `id`) | — | `{"jsonrpc":"2.0","id":N,"error":{"code":-32601,"message":"Method not found"}}` |

### 4.2 Wire Format Details

- Framing: each message is a compact JSON object followed by `\n` (0x0A byte). No whitespace between objects.
- Encoding: UTF-8.
- The `id` field is an integer, echoed back in all responses.
- `RPCResult` shape: `{"success": bool, "errorDescription": string|null}`, plus optional `config` key for `getConfig`.
- `RPCError` shape: `{"code": int, "message": string}`.

### 4.3 `getConfig` Response Payload

Read from the `--config` JSON file. The file must contain a valid `MenuConfiguration`:

```json
{
  "isEnabled": true,
  "appItems": [
    {
      "id": "vscode",
      "title": "Open with VS Code",
      "iconName": "",
      "isEnabled": true,
      "appURL": "/Applications/Visual Studio Code.app",
      "displayName": "VS Code",
      "arguments": "",
      "environment": {}
    }
  ],
  "actionItems": [
    {"actionType": "copyPath", "isEnabled": true},
    {"actionType": "copyFileName", "isEnabled": true},
    {"actionType": "toggleHidden", "isEnabled": true}
  ],
  "newFileTemplates": [
    {"fileName": "", "fileExtension": "txt", "defaultContent": "", "isEnabled": true},
    {"fileName": "", "fileExtension": "md", "defaultContent": "", "isEnabled": true}
  ],
  "appsSectionEnabled": true
}
```

If the file is missing or invalid, the script starts with a minimal fallback config (`isEnabled: true`, empty items).

## 5. CLI Interface

```bash
# Default: port 57421, config = tests/rpc-debug/debug-config.json
pixi run rpc-debug

# Custom port and config
pixi run rpc-debug --port 57422 --config my-config.json

# Verbose mode (show full JSON payloads)
pixi run rpc-debug --verbose

# Help
pixi run rpc-debug --help
```

`typer` provides the CLI with auto-generated help. Arguments:
- `--port`: int, default 57421
- `--config`: Path, default `tests/rpc-debug/debug-config.json`
- `--verbose` / `--no-verbose`: bool flag, default False

## 6. Terminal Output (rich)

Non-verbose mode shows summarized one-liners with color:

```
╔══════════════════════════════════════════╗
║   RPC Debug Server v0.1.0               ║
║   Listening on 127.0.0.1:57421          ║
║   Config: tests/rpc-debug/debug-config.json ║
╚══════════════════════════════════════════╝
[12:34:56] ⬆ CONNECT  id=0  from 127.0.0.1:55432
[12:34:56] → RECV ping  id=1  meta pid=1234 v=1.0
[12:34:56] ← SEND pong  id=1  ✓
[12:34:58] → RECV getConfig  id=2
[12:34:58] ← SEND config  id=2  ✓
[12:35:02] → RECV executeCommand  id=3  action=newFile  files=/tmp/test.txt
[12:35:02] ← SEND result  id=3  ✓
[12:35:30] ↓ DISCONNECT  id=0  reason=EOF
```

Verbose mode additionally prints full JSON payloads for each message.

### Color Scheme

| Element | Color |
|---------|-------|
| CONNECT/DISCONNECT | cyan |
| RECV prefix | yellow |
| SEND prefix | green |
| Success checkmark ✓ | green |
| Error ✗ | red |
| Method names | bold white |
| Connection IDs | dim |

## 7. pixi.toml Changes

Add to existing `pixi.toml`:

```toml
[dependencies]
python = ">=3.12"
rich = ">=13.0"
typer = ">=0.12"

[tasks]
rpc-debug = "python tests/rpc-debug/rpc-debug-server.py"
```

The existing `[workspace]` section (channel `conda-forge`, platform `osx-arm64`) stays unchanged.

## 8. Error Handling

| Scenario | Behavior |
|----------|----------|
| Port already in use | Exit with clear error message — "Port 57421 is busy. Is the main app running? Stop it first." |
| Invalid JSON in received line | Log warning with raw bytes, continue (don't crash connection) |
| Config file missing | Warn, use built-in minimal config, continue |
| Config file invalid JSON | Warn, use built-in minimal config, continue |
| Client disconnects mid-message | Log, clean up connection state |
| Unknown method (no `id`) | Log, no reply (notification-style messages don't get responses) |
| Unknown method (has `id`) | Reply with JSON-RPC error code -32601 |

## 9. Limitations (Non-Goals)

- Does NOT send `configDidChange` notifications (no config hot-reload during debug session)
- Does NOT initiate Con→Ext pings (no heartbeat to Extension; Extension heartbeat still works)
- Does NOT send `shutdown` notifications
- Does NOT actually execute file operations (shell, file creation, etc.) — only logs and returns success
- Single process, no graceful reload of config file at runtime

## 10. Compatibility

- Matches wire format exactly: `RPCRequest` / `RPCResponse` / `RPCShutdownNotification` shapes from `Shared/RPC/RPCSession.swift`
- `RPCParams` shape: `{"action": int, "files": [string], "command": string|null, "extra": {string:string}|null}`
- `RPCResult` shape: `{"success": bool, "errorDescription": string|null}` plus optional `config`
- `MenuConfiguration` shape as defined in `Shared/Preferences/MenuConfiguration.swift`
