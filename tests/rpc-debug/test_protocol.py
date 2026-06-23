"""Tests for RPC protocol message dispatch and response building."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

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
        # MenuConfig shape: {isEnabled, showAppIcons, menus: [MenuItem]}
        config = {"isEnabled": True, "showAppIcons": True, "menus": []}
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
        config = {"isEnabled": True, "showAppIcons": True, "menus": [{"id": "op.copyPath"}]}
        reply = srv.dispatch_message(msg, config)
        assert reply is not None
        assert reply["id"] == 2
        assert reply["result"]["config"] == config

    def test_executeAction_returns_success_and_no_config(self):
        msg = {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "executeAction",
            "params": {"actionID": 2000, "targetURL": "/tmp", "selectedURLs": ["/tmp/test.txt"]},
        }
        config = {"isEnabled": True, "showAppIcons": True, "menus": []}
        reply = srv.dispatch_message(msg, config)
        assert reply is not None
        assert reply["id"] == 3
        assert reply["result"]["success"] is True
        # executeAction must NOT carry config
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
    """actionID → name mapping, by range (see Constants.TagBase)."""

    def test_new_file_range(self):
        # 0–999: newFile (0 + templateIndex)
        assert srv.action_name(0) == "newFile"
        assert srv.action_name(1) == "newFile"
        assert srv.action_name(999) == "newFile"

    def test_open_with_range(self):
        # 1000–1999: openWith (1000 + appIndex)
        assert srv.action_name(1000) == "openWith"
        assert srv.action_name(1500) == "openWith"

    def test_general_operations_fixed_ids(self):
        assert srv.action_name(2000) == "copyPath"
        assert srv.action_name(2001) == "copyFileName"
        assert srv.action_name(2002) == "toggleHidden"

    def test_shell_range(self):
        # 4000–4999: shell (reserved)
        assert srv.action_name(4000) == "shell"
        assert srv.action_name(4999) == "shell"

    def test_unknown_action(self):
        # 3000 falls in the gap between general ops (2002) and shell (4000).
        assert srv.action_name(3000) == "unknown(3000)"
