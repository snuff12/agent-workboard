"""Slack HTTP and Keychain are mocked. No real account access or message sending."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import urllib.error
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("slack_plugin", ROOT / "plugins/slack/plugin.py")
slack = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(slack)
TS = "1792034000.000123"
PARENT_TS = "1792033000.000001"
URL = "https://example.slack.com/archives/C123/p1792034000000123"
TOKEN = "xoxp-TEST-ONLY"


def message(**changes):
    return {"ts": TS, "text": "Request review\nCheck by Friday", "user": "U123", **changes}


class SlackPlugin(unittest.TestCase):
    def setUp(self):
        self.config = {"account": "test", "team_id": "T123", "messages_enabled": True}
        self.keychain = mock.patch.object(slack, "keychain", return_value={"access_token": TOKEN, "team_id": "T123"}).start()
        self.http = mock.patch.object(slack, "http_open").start()
        self.addCleanup(mock.patch.stopall)

    def responses(self, *items):
        def response(*args, **kwargs):
            value = next(sequence)
            if isinstance(value, Exception):
                raise value
            return io.BytesIO(json.dumps(value).encode())
        sequence = iter(items)
        self.http.side_effect = response

    def run_method(self, method, params=None, config=None):
        return slack.run({"protocol_version": 1, "method": method, "params": params or {},
                          "config": self.config if config is None else config, "request_id": "slack-test"})

    def request(self, index=-1):
        return self.http.call_args_list[index].args[0]

    def error(self, code, method, params=None, config=None):
        with self.assertRaises(slack.IntegrationError) as raised:
            self.run_method(method, params, config)
        self.assertEqual(raised.exception.code, code)
        return str(raised.exception)

    def target(self, **changes):
        return {"channel_id": "C123", "ts": TS, **changes}

    def read_responses(self, **changes):
        self.responses({"ok": True, "messages": [message(**changes)]}, {"ok": True, "permalink": URL})

    def task(self, **changes):
        return {"id": "task-123", "title": "Review screen <@U123>", "status": "review", "revision": 7,
                "assignee": "codex", "next_action": "User review", "due_at": "2026-10-16",
                "goal": "PRIVATE GOAL MUST NOT LEAVE", "artifacts": ["PRIVATE FILE"], **changes}

    def test_disabled_and_nonboolean_flags_never_read_keychain_or_http(self):
        for value in (False, None, "true", "false", 1):
            self.error("INTEGRATION_DISABLED", "messages.search", {"query": "Due"},
                       {**self.config, "messages_enabled": value})
        self.keychain.assert_not_called()
        self.http.assert_not_called()

    def test_invalid_request_is_rejected_before_credentials_or_http(self):
        for method, params in [("messages.import", self.target()), ("messages.attach", self.target()),
                               ("messages.read", self.target(ts=1792034000.000123)),
                               ("messages.read", self.target(channel_id="U123")),
                               ("messages.search", {"query": "test", "limit": True}),
                               ("messages.search", {"query": "test", "limit": 21}),
                               ("messages.search", {"query": "test", "page": 0}),
                               ("messages.thread", self.target(limit=16))]:
            self.error("INVALID_REQUEST", method, params)
        self.keychain.assert_not_called()
        self.http.assert_not_called()

    def test_secrets_are_not_accepted_in_registry_config(self):
        self.error("INVALID_REQUEST", "check", config={**self.config, "access_token": TOKEN})
        self.keychain.assert_not_called()

    def test_wrong_workspace_or_bot_token_never_reaches_http(self):
        self.keychain.return_value = {"access_token": TOKEN, "team_id": "TOTHER"}
        self.error("AUTHORIZATION_REQUIRED", "check")
        self.keychain.return_value = {"access_token": "xoxb-TEST-ONLY", "team_id": "T123"}
        self.error("AUTHORIZATION_REQUIRED", "check")
        self.http.assert_not_called()

    def test_authorize_validates_identity_then_stores_no_secret_in_response(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token.credentials.json"
            path.write_text(json.dumps({"access_token": TOKEN}))
            self.responses({"ok": True, "team_id": "T123", "team": "Test", "user_id": "U123"})
            response = self.run_method("authorize", config={**self.config, "credentials_file": str(path)})
        self.assertTrue(response["result"]["connected"])
        self.assertNotIn(TOKEN, json.dumps(response))
        self.assertEqual(self.keychain.call_args.args[1]["access_token"], TOKEN)
        self.assertEqual(self.request().get_header("Authorization"), "Bearer " + TOKEN)
        self.assertNotIn(TOKEN, self.request().full_url)

    def test_authorize_wrong_workspace_does_not_overwrite_keychain(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token.credentials.json"
            path.write_text(json.dumps({"access_token": TOKEN}))
            self.responses({"ok": True, "team_id": "TOTHER"})
            self.error("AUTHORIZATION_REQUIRED", "authorize", config={**self.config, "credentials_file": str(path)})
        self.keychain.assert_not_called()

    def test_authorize_bad_credentials_has_redacted_diagnostic(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token.credentials.json"
            for content in ("not JSON " + TOKEN, json.dumps({"access_token": "xoxb-TEST-ONLY"})):
                path.write_text(content)
                diagnostic = self.error("AUTHORIZATION_REQUIRED", "authorize", config={**self.config, "credentials_file": str(path)})
                self.assertNotIn(TOKEN, diagnostic)
        self.keychain.assert_not_called()
        self.http.assert_not_called()

    def test_keychain_save_uses_stdin_and_disconnect_is_local_only(self):
        # Call the actual helper saved from a fresh module to inspect subprocess arguments.
        spec = importlib.util.spec_from_file_location("slack_keychain", ROOT / "plugins/slack/plugin.py")
        provider = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(provider)
        with mock.patch.object(provider.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            provider.keychain("test", {"access_token": TOKEN})
            self.assertNotIn(TOKEN, repr(run.call_args.args))
            self.assertIn(TOKEN, run.call_args.kwargs["input"])
        result = self.run_method("disconnect", config={"account": "test"})
        self.assertFalse(result["result"]["connected"])
        self.assertFalse(result["result"]["token_revoked"])
        self.http.assert_not_called()

    def test_search_preserves_query_pagination_and_limits_preview(self):
        self.responses({"ok": True, "messages": {"matches": [message(text="\u20ac" * 2000,
            channel={"id": "C123", "name": "general"})], "total": 30, "paging": {"page": 2, "pages": 3}}})
        result = self.run_method("messages.search", {"query": "in:general deadline", "page": 2})["result"]
        params = urllib.parse.parse_qs(urllib.parse.urlsplit(self.request().full_url).query)
        self.assertEqual(params["query"], ["in:general deadline"])
        self.assertEqual(params["page"], ["2"])
        self.assertEqual(result["next_page"], 3)
        self.assertEqual(len(result["messages"][0]["text"]), 1000)
        self.assertTrue(result["messages"][0]["text_truncated"])
        self.assertNotIn("requests", result)

    def test_read_exact_reply_preserves_string_timestamp_and_permalink_arguments(self):
        self.read_responses(thread_ts=PARENT_TS)
        result = self.run_method("messages.read", self.target(thread_ts=PARENT_TS))["result"]
        params = urllib.parse.parse_qs(urllib.parse.urlsplit(self.request(0).full_url).query)
        self.assertEqual(params, {"channel": ["C123"], "ts": [PARENT_TS], "oldest": [TS], "latest": [TS], "inclusive": ["true"], "limit": ["1"]})
        link_params = urllib.parse.parse_qs(urllib.parse.urlsplit(self.request().full_url).query)
        self.assertEqual(link_params, {"channel": ["C123"], "message_ts": [TS]})
        self.assertEqual(result["ts"], TS)
        self.assertEqual(result["url"], URL)

    def test_read_never_substitutes_nearby_or_deleted_message(self):
        for row in (message(ts=PARENT_TS), message(subtype="tombstone")):
            self.responses({"ok": True, "messages": [row]})
            self.error("INTEGRATION_NOT_FOUND", "messages.attach", self.target(task_id="task"))
        self.assertEqual(self.http.call_count, 2)

    def test_source_change_blocks_mutations_before_any_requests_are_returned(self):
        self.responses({"ok": True, "messages": [message(edited={"ts": "1792035000.000001"})]})
        self.error("CONFLICT", "messages.import", self.target(project_id="project", expected_version="old"))
        self.assertEqual(self.http.call_count, 1)

    def test_import_retrieves_fresh_source_and_returns_service_requests_for_subtask(self):
        self.read_responses(thread_ts=PARENT_TS)
        result = self.run_method("messages.import", self.target(project_id="project", parent_id="parent"))
        creation, attachment = result["requests"]
        self.assertEqual(creation["method"], "task.create")
        self.assertEqual(creation["params"]["parent_id"], "parent")
        self.assertIn(message()["text"], creation["params"]["goal"])
        self.assertEqual(attachment["params"]["task_id"], {"$result": "/0/task_id"})
        self.assertEqual(attachment["params"]["metadata"]["source_version"], result["result"]["version"])
        self.assertEqual(attachment["params"]["path"], URL)

    def test_attach_forwards_revision_to_service(self):
        self.read_responses()
        response = self.run_method("messages.attach", self.target(task_id="task", expected_revision=3))
        self.assertEqual(response["requests"][0]["params"]["expected_revision"], 3)
        self.assertEqual(response["requests"][0]["params"]["provider"], "slack")

    def test_thread_returns_cursor_without_auto_fetching_all_pages(self):
        self.responses({"ok": True, "messages": [message(thread_ts=PARENT_TS)], "has_more": True,
                        "response_metadata": {"next_cursor": "NEXT"}})
        response = self.run_method("messages.thread", self.target(ts=PARENT_TS, cursor="PREVIOUS"))
        self.assertEqual(response["result"]["next_cursor"], "NEXT")
        self.assertTrue(response["result"]["has_more"])
        self.assertEqual(self.http.call_count, 1)

    def test_http_and_slack_failures_are_redacted_and_preserve_codes(self):
        for payload, code in [({"ok": False, "error": "missing_scope"}, "AUTHORIZATION_REQUIRED"),
                              ({"ok": False, "error": "token_revoked"}, "AUTHORIZATION_REQUIRED"),
                              ({"ok": False, "error": "thread_not_found"}, "INTEGRATION_NOT_FOUND"),
                              ({"ok": False, "error": TOKEN}, "INTEGRATION_UNAVAILABLE")]:
            self.responses(payload)
            self.assertNotIn(TOKEN, self.error(code, "check"))
        error = urllib.error.HTTPError("https://slack.com/api/auth.test", 429, "secret", {"Retry-After": "60"}, None)
        self.responses(error)
        self.assertIn("60 seconds", self.error("INTEGRATION_RATE_LIMITED", "check"))

    def test_non_slack_permalink_is_rejected(self):
        self.responses({"ok": True, "messages": [message()]}, {"ok": True, "permalink": "https://slack.com.evil.test/"})
        self.error("INTEGRATION_UNAVAILABLE", "messages.read", self.target())

    def test_redirect_cannot_forward_bearer_token(self):
        with self.assertRaises(slack.IntegrationError):
            slack.NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.test/")

    def test_actionable_integration_diagnostics_survive_json_error_handling(self):
        self.http.side_effect = slack.IntegrationError("The Slack API redirected to another address.")
        self.assertIn("another address", self.error("INTEGRATION_UNAVAILABLE", "check"))
        self.http.side_effect = None
        self.http.return_value = io.BytesIO(b"x" * (1024 * 1024 + 1))
        self.assertIn("too large", self.error("INTEGRATION_UNAVAILABLE", "check"))

    def test_send_is_separately_gated_and_requires_explicit_action(self):
        params = {"channel_id": "C123", "task": self.task(), "confirmed_by_user": True}
        for flag in (None, False, "true", 1):
            self.error("INTEGRATION_DISABLED", "tasks.send", params, {**self.config, "send_enabled": flag})
        self.error("INVALID_REQUEST", "tasks.send", {**params, "confirmed_by_user": False}, {**self.config, "send_enabled": True})
        self.keychain.assert_not_called()
        self.http.assert_not_called()

    def test_send_posts_only_status_fields_as_plain_text_with_no_unfurls(self):
        self.responses({"ok": True, "team_id": "T123"}, {"ok": True, "channel": "C123", "ts": TS})
        response = self.run_method("tasks.send", {"channel_id": "C123", "task": self.task(), "confirmed_by_user": True},
                                   {**self.config, "send_enabled": True})
        request = self.request()
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.full_url, "https://slack.com/api/chat.postMessage")
        body = json.loads(request.data)
        self.assertEqual(body["blocks"][0]["text"]["type"], "plain_text")
        self.assertIn("Status: In Review", body["blocks"][0]["text"]["text"])
        self.assertNotIn("<@U123>", body["text"])
        self.assertFalse(body["unfurl_links"])
        self.assertFalse(body["unfurl_media"])
        self.assertFalse(body["mrkdwn"])
        self.assertNotIn("PRIVATE", request.data.decode())
        self.assertTrue(response["result"]["sent"])
        self.assertEqual(response["result"]["task_revision"], 7)

    def test_send_wrong_identity_never_posts(self):
        self.responses({"ok": True, "team_id": "TOTHER"})
        self.error("AUTHORIZATION_REQUIRED", "tasks.send", {"channel_id": "C123", "task": self.task(), "confirmed_by_user": True},
                   {**self.config, "send_enabled": True})
        self.assertEqual(self.http.call_count, 1)
        self.assertEqual(self.request().get_method(), "GET")

    def test_send_stale_revision_never_reads_keychain(self):
        self.error("CONFLICT", "tasks.send", {"channel_id": "C123", "task": self.task(), "expected_revision": 6,
            "confirmed_by_user": True}, {**self.config, "send_enabled": True})
        self.keychain.assert_not_called()


if __name__ == "__main__":
    unittest.main()
