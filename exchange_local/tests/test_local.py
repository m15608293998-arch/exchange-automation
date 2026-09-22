import io
import json
import logging
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.request import Request, urlopen
from urllib.error import HTTPError

from exchange_local.api import create_server
from exchange_local.core import ExchangeService, OperationError, PowerShellRunner


MAILBOX = "11111111-1111-1111-1111-111111111111"
GROUP = "22222222-2222-2222-2222-222222222222"


class FakeRunner:
    def __init__(self):
        self.calls = []
        self.missing_group = False
        self.timeout_add = False
        self.member = False
        self.created = False

    def execute(self, operation, parameters, seconds):
        self.calls.append((operation, parameters))
        if operation == "resolve_groups":
            if self.missing_group:
                raise OperationError("GROUP_NOT_FOUND", "No group", step=operation)
            return {"groups": [{"identity": GROUP, "label": "app"}]}
        if operation == "ensure_mailbox":
            was_created = not self.created
            self.created = True
            return {"created": was_created, "mailbox_id": MAILBOX, "login_name": "alice",
                    "display_name": "Alice", "user_principal_name": "alice@example.com",
                    "primary_smtp_address": "alice@example.com"}
        if operation == "ensure_group_member":
            if self.timeout_add:
                raise OperationError("AUTOMATION_UNAVAILABLE", "timed out", step=operation,
                                     state_unknown=True, timeout=True)
            was_added = not self.member
            self.member = True
            return {"added": was_added, "group": "app", "group_id": GROUP, "member_id": MAILBOX}
        if operation == "discover_user_groups":
            return {"mailbox_id": MAILBOX, "groups": [{"identity": GROUP, "label": "app"}] if self.member else []}
        if operation == "remove_group_member":
            self.member = False
            return {"removed": True, "group": "app", "group_id": GROUP, "member_id": MAILBOX}
        raise AssertionError(operation)


class LocalServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = {
            "project_directory": self.temp.name,
            "http_address": "127.0.0.1:18082", "mail_domain": "example.com", "upn_suffix": "example.com",
            "mailbox_database": "DB 1", "domain_controller": "dc.example.com",
            "state_directory": self.temp.name, "operation_timeout_seconds": 30,
        }
        self.runner = FakeRunner()
        self.service = ExchangeService(self.config, self.runner)

    def test_preflight_precedes_account_creation_and_retry_is_idempotent(self):
        request = {"login_name": "ALICE", "display_name": "Alice", "initial_password": "private-123",
                   "groups": ["app", "APP"]}
        self.runner.missing_group = True
        with self.assertRaises(OperationError) as failure:
            self.service.onboard(request)
        self.assertEqual(failure.exception.code, "GROUP_NOT_FOUND")
        self.assertEqual([call[0] for call in self.runner.calls], ["resolve_groups"])
        self.assertFalse(list(Path(self.temp.name).glob("*.pending")))
        self.runner.missing_group = False
        first = self.service.onboard(request)
        second = self.service.onboard(request)
        self.assertTrue(first["created"])
        self.assertEqual(first["added_groups"], ["app"])
        self.assertFalse(second["created"])
        self.assertFalse(second["password_applied"])
        self.assertEqual(second["existing_groups"], ["app"])
        self.assertEqual(self.service.offboard("ALICE")["removed_groups"], ["app"])
        self.assertEqual(self.service.offboard("alice")["removed_groups"], [])

    def test_unknown_mutation_keeps_pending_across_restart(self):
        self.runner.timeout_add = True
        with self.assertRaises(OperationError) as failure:
            self.service.onboard({"login_name": "alice", "display_name": "Alice", "groups": ["app"]})
        self.assertTrue(failure.exception.state_unknown)
        self.assertEqual(failure.exception.partial["mailbox_id"], MAILBOX)
        self.assertTrue(Path(self.temp.name, "alice.pending").exists())
        restarted = ExchangeService(self.config, self.runner)
        with self.assertRaises(OperationError) as blocked:
            restarted.offboard("alice")
        self.assertEqual(blocked.exception.code, "OPERATION_STATE_UNKNOWN")

    def test_concurrent_same_login_is_busy_not_unknown(self):
        entered, release = threading.Event(), threading.Event()
        original = self.runner.execute

        def slow_execute(operation, parameters, seconds):
            if operation == "ensure_mailbox":
                entered.set()
                if not release.wait(5):
                    raise AssertionError("timed out waiting for test release")
            return original(operation, parameters, seconds)

        self.runner.execute = slow_execute
        results = []
        thread = threading.Thread(target=lambda: results.append(self.service.onboard({
            "login_name": "alice", "display_name": "Alice"})))
        thread.start()
        self.assertTrue(entered.wait(2))
        try:
            with self.assertRaises(OperationError) as busy:
                self.service.offboard("alice")
            self.assertEqual(busy.exception.code, "OPERATION_BUSY")
        finally:
            release.set()
            thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(results[0]["mailbox_id"], MAILBOX)

    def test_http_contract_and_no_secret_in_log(self):
        logs = io.StringIO()
        logger = logging.getLogger("exchange_local_test")
        logger.handlers = [logging.StreamHandler(logs)]
        logger.propagate = False
        server = create_server(("127.0.0.1", 0), self.config, self.service, logger)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        base = "http://127.0.0.1:" + str(server.server_port)

        def post(path, body, content_type="application/json"):
            request = Request(base + path, data=body, headers={"Content-Type": content_type}, method="POST")
            try:
                response = urlopen(request)
            except HTTPError as exc:
                response = exc
            with response:
                return response.status, json.load(response), response.headers["X-Request-ID"]

        secret = "not-in-audit-987"
        status, data, request_id = post("/api/exchange/users", json.dumps({
            "login_name": "alice", "display_name": "Alice", "initial_password": secret, "groups": ["app"]}).encode())
        self.assertEqual(status, 201)
        self.assertEqual(data["mailbox_id"], MAILBOX)
        self.assertEqual(len(request_id), 32)
        status, data, _ = post("/api/exchange/users/alice/offboard", b"")
        self.assertEqual(status, 200)
        self.assertEqual(data["removed_groups"], ["app"])
        status, data, _ = post("/api/exchange/users/alice/offboard", b"{}")
        self.assertEqual(status, 400)
        self.assertEqual(data["error"]["code"], "INVALID_REQUEST")
        status, data, _ = post("/api/exchange/users", b"{}", "text/plain")
        self.assertEqual(status, 415)
        self.assertNotIn(secret, logs.getvalue())

    def test_subprocess_stdin_not_command_line(self):
        script = Path(self.temp.name) / "Invoke-ExchangeOperation.ps1"
        script.write_text("", encoding="utf-8")
        runner = PowerShellRunner(script, "powershell.exe")
        output = {"ok": True, "data": {"groups": []}}
        with patch("exchange_local.core.subprocess.run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = json.dumps(output).encode()
            run.return_value.stderr = b""
            result = runner.execute("resolve_groups", {"InitialPassword": "private-123"}, 3)
        self.assertEqual(result, {"groups": []})
        self.assertNotIn("private-123", " ".join(run.call_args.args[0]))
        self.assertIn(b"private-123", run.call_args.kwargs["input"])


if __name__ == "__main__":
    unittest.main()
