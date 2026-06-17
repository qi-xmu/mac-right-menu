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
