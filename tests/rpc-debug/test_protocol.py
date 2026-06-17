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
