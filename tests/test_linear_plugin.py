"""Linear HTTP and Keychain are mocked. No real account access, comments or state changes."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest import mock
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("linear_plugin", ROOT / "plugins/linear/plugin.py")
linear = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(linear)
KEY = "lin_api_TESTONLY0123456789abcdef"
ORG_ID = "0b8a4c47-6c3a-4f39-9a51-6f1c1b7d0001"
ISSUE_ID = "5f0f2a6c-1b1e-4c55-9f00-000000000123"
TEAM_ID = "7a1d0c55-3f6e-4f0a-8d4b-0000000000aa"
OTHER_TEAM_ID = "7a1d0c55-3f6e-4f0a-8d4b-0000000000bb"
TODO = "11111111-2222-4333-8444-000000000001"
STARTED = "11111111-2222-4333-8444-000000000002"
DONE = "11111111-2222-4333-8444-000000000003"
URL = "https://linear.app/acme/issue/ENG-123/fix-login-timeout"


class Response(io.BytesIO):
    def __init__(self, value, headers=None):
        super().__init__(json.dumps(value).encode() if not isinstance(value, bytes) else value)
        self.headers = headers or {}


def viewer(url_key="acme"):
    return {"data": {"viewer": {"id": "user-1", "name": "Test", "displayName": "test",
                                "organization": {"id": ORG_ID, "name": "Acme", "urlKey": url_key}}}}


def issue(**changes):
    value = {"id": ISSUE_ID, "identifier": "ENG-123", "title": "Fix login timeout",
             "description": "Users are signed out after 5 minutes.", "url": URL, "priority": 2,
             "priorityLabel": "High", "dueDate": "2026-10-20", "updatedAt": "2026-10-16T01:00:00.000Z",
             "archivedAt": None, "state": {"id": TODO, "name": "Todo", "type": "unstarted"},
             "assignee": {"id": "user-2", "name": "Dana", "displayName": "dana"}, "parent": None,
             "team": {"id": TEAM_ID, "key": "ENG", "name": "Engineering", "states": {"nodes": [
                 {"id": DONE, "name": "Done", "type": "completed", "position": 3},
                 {"id": TODO, "name": "Todo", "type": "unstarted", "position": 1},
                 {"id": STARTED, "name": "In Progress", "type": "started", "position": 2}]}}}
    value.update(changes)
    return value


def graphql_failure(code, message="failure", status=400, headers=None):
    body = json.dumps({"errors": [{"message": message, "extensions": {"code": code}}]}).encode()
    return urllib.error.HTTPError(linear.ENDPOINT, status, "error", headers or {}, io.BytesIO(body))


class LinearPlugin(unittest.TestCase):
    def setUp(self):
        self.config = {"account": "test", "workspace": "acme", "issues_enabled": True}
        self.keychain = mock.patch.object(linear, "keychain", return_value={"api_key": KEY, "workspace": "acme", "organization_id": ORG_ID}).start()
        self.http = mock.patch.object(linear, "http_open").start()
        self.addCleanup(mock.patch.stopall)

    def responses(self, *items):
        def response(*args, **kwargs):
            value = next(sequence)
            if isinstance(value, Exception):
                raise value
            return value if isinstance(value, Response) else Response(value)
        sequence = iter(items)
        self.http.side_effect = response

    def run_method(self, method, params=None, config=None):
        return linear.run({"protocol_version": 1, "method": method, "params": params or {},
                           "config": self.config if config is None else config, "request_id": "linear-test"})

    def request(self, index=-1):
        return self.http.call_args_list[index].args[0]

    def body(self, index=-1):
        return json.loads(self.request(index).data)

    def error(self, code, method, params=None, config=None):
        with self.assertRaises(linear.IntegrationError) as raised:
            self.run_method(method, params, config)
        self.assertEqual(raised.exception.code, code)
        return str(raised.exception)

    def task(self, **changes):
        return {"id": "task-123", "title": "Review [login](https://evil.test) @team", "status": "review", "revision": 7,
                "assignee": "codex", "next_action": "User review", "due_at": "2026-10-16",
                "goal": "PRIVATE GOAL MUST NOT LEAVE", "artifacts": ["PRIVATE FILE"], **changes}

    def version(self, **changes):
        return linear.issue_info(issue(**changes), "acme")["version"]

    def test_disabled_and_nonboolean_flags_never_read_keychain_or_http(self):
        for value in (False, None, "true", "false", 1):
            self.error("INTEGRATION_DISABLED", "issues.search", {"query": "login"}, {**self.config, "issues_enabled": value})
        self.keychain.assert_not_called()
        self.http.assert_not_called()

    def test_invalid_request_is_rejected_before_credentials_or_http(self):
        for method, params in [("issues.import", {"issue_id": "ENG-123"}),
                               ("issues.attach", {"issue_id": "ENG-123"}),
                               ("issues.read", {"issue_id": "ENG 123"}),
                               ("issues.read", {"issue_id": "../graphql"}),
                               ("issues.read", {"issue_id": "ENG-123", "expected_version": ""}),
                               ("issues.attach", {"issue_id": "ENG-123", "task_id": "task", "expected_revision": "3"}),
                               ("issues.search", {"query": 3}),
                               ("issues.search", {"query": "x" * 257}),
                               ("issues.search", {"limit": True}),
                               ("issues.search", {"limit": 51}),
                               ("issues.search", {"limit": 0}),
                               ("issues.search", {"team_id": "ENG"}),
                               ("issues.search", {"assigned_to_me": "true"}),
                               ("issues.search", {"include_closed": 1}),
                               ("issues.search", {"cursor": ""}),
                               ("issues.read", {"issue_id": "ENG-123", "workspace": "../other"})]:
            self.error("INVALID_REQUEST", method, params)
        self.error("CONFLICT", "issues.read", {"issue_id": "ENG-123", "workspace": "other"})
        self.keychain.assert_not_called()
        self.http.assert_not_called()

    def test_secrets_and_missing_workspace_are_rejected_before_keychain(self):
        for name in ("api_key", "token", "access_token", "key"):
            self.error("INVALID_REQUEST", "check", config={**self.config, name: KEY})
        self.error("INVALID_REQUEST", "check", config={"account": "test", "issues_enabled": True})
        self.keychain.assert_not_called()

    def test_wrong_workspace_or_non_personal_key_never_reaches_http(self):
        for stored in ({"api_key": KEY, "workspace": "other", "organization_id": ORG_ID},
                       {"api_key": KEY, "workspace": "acme"},
                       {"api_key": "lin_oauth_TESTONLY0123456789abcdef", "workspace": "acme", "organization_id": ORG_ID},
                       {"api_key": KEY + "\nX-Injected: 1", "workspace": "acme", "organization_id": ORG_ID}):
            self.keychain.return_value = stored
            self.error("AUTHORIZATION_REQUIRED", "check")
        self.http.assert_not_called()

    def test_authorize_validates_workspace_then_keeps_key_out_of_response(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "linear.credentials.json"
            path.write_text(json.dumps({"api_key": KEY}))
            self.responses(viewer())
            response = self.run_method("authorize", config={**self.config, "credentials_file": str(path)})
        self.assertTrue(response["result"]["connected"])
        self.assertEqual(response["result"]["organization_id"], ORG_ID)
        self.assertNotIn(KEY, json.dumps(response))
        self.assertEqual(self.keychain.call_args.args[1], {"api_key": KEY, "workspace": "acme", "organization_id": ORG_ID, "user_id": "user-1"})
        request = self.request()
        self.assertEqual(request.full_url, "https://api.linear.app/graphql")
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.get_header("Authorization"), KEY)
        self.assertNotIn(KEY, request.data.decode())

    def test_authorize_keeps_names_out_of_keychain_and_rejects_unsafe_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "linear.credentials.json"
            path.write_text(json.dumps({"api_key": KEY}))
            named = viewer()
            named["data"]["viewer"]["displayName"] = "O'Brien"
            named["data"]["viewer"]["organization"]["name"] = "Acme's Lab"
            self.responses(named)
            response = self.run_method("authorize", config={**self.config, "credentials_file": str(path)})
            self.assertEqual(response["result"]["user"], "O'Brien")
            self.assertNotIn("'", json.dumps(self.keychain.call_args.args[1]))
            self.keychain.reset_mock()
            unsafe = viewer()
            unsafe["data"]["viewer"]["id"] = "user' -w x"
            self.responses(unsafe)
            self.error("INVALID_REQUEST", "authorize", config={**self.config, "credentials_file": str(path)})
        self.keychain.assert_not_called()

    def test_authorize_wrong_workspace_does_not_overwrite_keychain(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "linear.credentials.json"
            path.write_text(json.dumps({"api_key": KEY}))
            self.responses(viewer("other"))
            self.error("AUTHORIZATION_REQUIRED", "authorize", config={**self.config, "credentials_file": str(path)})
        self.keychain.assert_not_called()

    def test_authorize_bad_credentials_has_redacted_diagnostic(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "linear.credentials.json"
            for content in ("not JSON " + KEY, json.dumps({"api_key": "lin_oauth_TESTONLY0123456789abcdef"}), json.dumps([KEY])):
                path.write_text(content)
                diagnostic = self.error("AUTHORIZATION_REQUIRED", "authorize", config={**self.config, "credentials_file": str(path)})
                self.assertNotIn(KEY, diagnostic)
        self.keychain.assert_not_called()
        self.http.assert_not_called()

    def test_keychain_save_uses_stdin_and_disconnect_is_local_only(self):
        spec = importlib.util.spec_from_file_location("linear_keychain", ROOT / "plugins/linear/plugin.py")
        provider = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(provider)
        with mock.patch.object(provider.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            provider.keychain("test", {"api_key": KEY})
            self.assertNotIn(KEY, repr(run.call_args.args))
            self.assertIn(KEY, run.call_args.kwargs["input"])
        result = self.run_method("disconnect", config={"account": "test"})
        self.assertFalse(result["result"]["connected"])
        self.assertFalse(result["result"]["key_revoked"])
        self.http.assert_not_called()

    def test_search_term_sends_filters_as_variables_and_limits_preview(self):
        team = {"id": TEAM_ID, "key": "ENG", "name": "Engineering"}
        self.responses({"data": {"searchIssues": {"nodes": [issue(description="€" * 2000, team=team)],
                                                  "pageInfo": {"hasNextPage": True, "endCursor": "NEXT"}}}})
        result = self.run_method("issues.search", {"query": "login } mutation {", "team_id": TEAM_ID,
                                                   "assigned_to_me": True, "limit": 5, "cursor": "PREVIOUS"})["result"]
        body = self.body()
        self.assertEqual(body["query"], linear.QUERIES["search"])
        self.assertEqual(body["variables"], {"term": "login } mutation {", "first": 5, "after": "PREVIOUS", "filter": {
            "team": {"id": {"eq": TEAM_ID}}, "assignee": {"isMe": {"eq": True}},
            "state": {"type": {"nin": ["completed", "canceled", "duplicate"]}}}})
        row = result["issues"][0]
        self.assertEqual(len(row["description"]), 1000)
        self.assertTrue(row["description_truncated"])
        self.assertEqual(row["version"], self.version(description="€" * 2000, team=team))
        self.assertNotIn("team_states", row)
        self.assertEqual(result["next_cursor"], "NEXT")
        self.assertNotIn("requests", result)

    def test_search_without_term_lists_recent_issues_and_closed_on_request(self):
        self.responses({"data": {"issues": {"nodes": [issue()], "pageInfo": {"hasNextPage": False, "endCursor": "END"}}}})
        result = self.run_method("issues.search", {"include_closed": True})["result"]
        body = self.body()
        self.assertEqual(body["query"], linear.QUERIES["issues"])
        self.assertIn("orderBy: updatedAt", body["query"])
        self.assertEqual(body["variables"], {"filter": None, "first": 20, "after": None})
        self.assertIsNone(result["next_cursor"])

    def test_exact_identifier_search_reads_one_issue_when_it_matches_filters(self):
        self.responses({"data": {"issue": issue()}})
        result = self.run_method("issues.search", {"query": "eng-123", "team_id": TEAM_ID.upper()})["result"]
        self.assertEqual(self.body()["variables"], {"id": "ENG-123"})
        self.assertEqual([row["identifier"] for row in result["issues"]], ["ENG-123"])
        self.assertNotIn("team_states", result["issues"][0])
        self.assertEqual(self.http.call_count, 1)

    def test_identifier_shaped_words_and_filtered_issues_fall_back_to_full_text_search(self):
        found = {"data": {"searchIssues": {"nodes": [], "pageInfo": {"hasNextPage": False}}}}
        closed = issue(state={"id": DONE, "name": "Done", "type": "completed"})
        for term, params, lookup in (("utf-8", {}, graphql_failure("INVALID_INPUT", "Entity not found: Issue")),
                                     ("covid-19", {}, graphql_failure("INVALID_INPUT", "Argument Validation Error")),
                                     ("ENG-123", {"team_id": OTHER_TEAM_ID}, {"data": {"issue": issue()}}),
                                     ("ENG-123", {}, {"data": {"issue": closed}})):
            self.http.reset_mock()
            self.responses(lookup, found)
            self.assertEqual(self.run_method("issues.search", {"query": term, **params})["result"]["issues"], [])
            self.assertEqual(self.body()["query"], linear.QUERIES["search"])
            self.assertEqual(self.body()["variables"]["term"], term)
        self.http.reset_mock()
        self.responses(found)
        self.run_method("issues.search", {"query": "ENG-123", "assigned_to_me": True})
        self.assertEqual(self.http.call_count, 1)
        self.responses(graphql_failure("RATELIMITED"))
        self.error("INTEGRATION_RATE_LIMITED", "issues.search", {"query": "ENG-123"})

    def test_read_returns_sorted_team_states_and_verified_link(self):
        self.responses({"data": {"issue": issue()}})
        item = self.run_method("issues.read", {"issue_id": ISSUE_ID.upper()})["result"]
        self.assertEqual(self.body()["variables"], {"id": ISSUE_ID})
        self.assertEqual([state["id"] for state in item["team_states"]], [TODO, STARTED, DONE])
        self.assertEqual(item["url"], URL)
        self.assertEqual(item["state_type"], "unstarted")
        self.assertEqual(item["assignee"], "dana")

    def test_read_rejects_unverified_links_and_substituted_issues(self):
        for url in ("https://linear.app.evil.test/acme/issue/ENG-123/x", "http://linear.app/acme/issue/ENG-123/x",
                    "https://linear.app/other/issue/ENG-123/x", "https://linear.app/acme/issue/ENG-999/x",
                    "https://user@linear.app/acme/issue/ENG-123/x", "https://linear.app:8443/acme/issue/ENG-123/x"):
            self.responses({"data": {"issue": issue(url=url)}})
            self.error("INTEGRATION_UNAVAILABLE", "issues.read", {"issue_id": "ENG-123"})
        self.responses({"data": {"issue": issue(id="5f0f2a6c-1b1e-4c55-9f00-000000000999")}})
        self.error("CONFLICT", "issues.read", {"issue_id": ISSUE_ID})

    def test_source_change_blocks_mutations_before_any_requests_are_returned(self):
        self.responses({"data": {"issue": issue(title="Changed elsewhere")}})
        self.error("CONFLICT", "issues.import", {"issue_id": "ENG-123", "project_id": "project", "expected_version": self.version()})
        self.assertEqual(self.http.call_count, 1)

    def test_import_returns_service_requests_for_subtask_with_due_date_and_priority(self):
        self.responses({"data": {"issue": issue()}})
        result = self.run_method("issues.import", {"issue_id": "ENG-123", "project_id": "project", "parent_id": "parent",
                                                   "expected_version": self.version()})
        creation, link = result["requests"]
        self.assertEqual(creation["method"], "task.create")
        self.assertEqual(creation["params"]["title"], "Fix login timeout")
        self.assertEqual(creation["params"]["parent_id"], "parent")
        self.assertEqual(creation["params"]["due_at"], "2026-10-20")
        self.assertEqual(creation["params"]["priority"], 3)
        self.assertIn("Users are signed out", creation["params"]["goal"])
        self.assertIn("ENG-123 · " + URL, creation["params"]["goal"])
        self.assertEqual(link["method"], "task.attach")
        self.assertEqual(link["params"]["task_id"], {"$result": "/0/task_id"})
        self.assertEqual(link["params"]["path"], URL)
        self.assertEqual(link["params"]["provider"], "linear")
        self.assertEqual(link["params"]["metadata"]["source_version"], result["result"]["version"])
        self.assertEqual(link["params"]["metadata"]["issue_id"], ISSUE_ID)

    def test_import_priority_mapping_and_missing_due_date(self):
        for priority, expected in ((0, None), (1, 3), (3, 1), (4, 0)):
            self.responses({"data": {"issue": issue(priority=priority, dueDate=None)}})
            creation = self.run_method("issues.import", {"issue_id": "ENG-123", "project_id": "project"})["requests"][0]["params"]
            self.assertEqual(creation.get("priority"), expected)
            self.assertNotIn("due_at", creation)

    def test_attach_forwards_revision_and_archived_issues_are_not_linked(self):
        self.responses({"data": {"issue": issue()}})
        response = self.run_method("issues.attach", {"issue_id": "ENG-123", "task_id": "task", "expected_revision": 3})
        self.assertEqual(len(response["requests"]), 1)
        self.assertEqual(response["requests"][0]["params"]["expected_revision"], 3)
        self.assertEqual(response["requests"][0]["params"]["kind"], "url")
        self.responses({"data": {"issue": issue(archivedAt="2026-10-15T00:00:00.000Z")}})
        self.error("INVALID_REQUEST", "issues.attach", {"issue_id": "ENG-123", "task_id": "task"})

    def test_graphql_and_http_failures_are_redacted_and_preserve_codes(self):
        reset = str(int((time.time() + 120) * 1000))
        cases = [(graphql_failure("AUTHENTICATION_ERROR", KEY, status=401), "AUTHORIZATION_REQUIRED"),
                 (graphql_failure("FORBIDDEN", KEY), "AUTHORIZATION_REQUIRED"),
                 (graphql_failure("INVALID_INPUT", "Entity not found: Issue"), "INTEGRATION_NOT_FOUND"),
                 (graphql_failure("INTERNAL_SERVER_ERROR", KEY, status=500), "INTEGRATION_UNAVAILABLE"),
                 (Response({"errors": [{"message": KEY, "extensions": {"code": "INVALID_INPUT"}}]}), "INTEGRATION_UNAVAILABLE"),
                 (urllib.error.HTTPError(linear.ENDPOINT, 502, KEY, {}, None), "INTEGRATION_UNAVAILABLE"),
                 (urllib.error.HTTPError(linear.ENDPOINT, 401, KEY, {}, io.BytesIO(b"not json")), "AUTHORIZATION_REQUIRED"),
                 (urllib.error.URLError(KEY), "INTEGRATION_UNAVAILABLE")]
        for failure, code in cases:
            self.responses(failure)
            self.assertNotIn(KEY, self.error(code, "check"))
        self.responses(graphql_failure("RATELIMITED", status=400, headers={
            "X-RateLimit-Requests-Remaining": "0", "X-RateLimit-Requests-Reset": reset}))
        diagnostic = self.error("INTEGRATION_RATE_LIMITED", "check")
        self.assertRegex(diagnostic, r"Retry after 1[12][0-9] seconds")
        self.responses(urllib.error.HTTPError(linear.ENDPOINT, 429, "", {"Retry-After": "60"}, None))
        self.assertIn("60 seconds", self.error("INTEGRATION_RATE_LIMITED", "check"))

    def test_redirect_and_oversized_responses_are_refused(self):
        with self.assertRaises(linear.IntegrationError):
            linear.NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.test/")
        self.responses(Response(b"x" * (1024 * 1024 + 1)))
        self.assertIn("too large", self.error("INTEGRATION_UNAVAILABLE", "check"))

    def test_comment_is_separately_gated_and_requires_explicit_action(self):
        params = {"issue_id": "ENG-123", "task_id": "task-123", "task": self.task(), "confirmed_by_user": True}
        for flag in (None, False, "true", 1):
            self.error("INTEGRATION_DISABLED", "issues.comment", params, {**self.config, "comments_enabled": flag})
        enabled = {**self.config, "comments_enabled": True}
        self.error("INVALID_REQUEST", "issues.comment", {**params, "confirmed_by_user": "true"}, enabled)
        self.error("INVALID_REQUEST", "issues.comment", {**params, "task": {"id": "task-123"}}, enabled)
        self.error("CONFLICT", "issues.comment", {**params, "expected_revision": 6}, enabled)
        self.keychain.assert_not_called()
        self.http.assert_not_called()

    def test_comment_posts_escaped_status_fields_with_stable_id(self):
        config = {**self.config, "comments_enabled": True}
        params = {"issue_id": "ENG-123", "task_id": "task-123", "task": self.task(), "confirmed_by_user": True}
        posted = {"data": {"commentCreate": {"success": True, "comment": {
            "id": None, "url": URL + "#comment-abc", "issue": {"id": ISSUE_ID}}}}}
        bodies = []
        for _ in range(2):
            self.responses({"data": {"issue": issue()}}, posted)
            result = self.run_method("issues.comment", params, config)["result"]
            bodies.append(self.body())
        mutation = bodies[0]
        self.assertEqual(mutation["query"], linear.QUERIES["comment_create"])
        body = mutation["variables"]["input"]["body"]
        self.assertEqual(mutation["variables"]["input"]["issueId"], ISSUE_ID)
        self.assertEqual(mutation["variables"]["input"]["id"], bodies[1]["variables"]["input"]["id"])
        self.assertEqual(str(linear.uuid.UUID(mutation["variables"]["input"]["id"]).version), "4")
        self.assertIn("- Status: Review", body)
        self.assertNotIn("Blocked", body)
        self.assertIn("\\[login\\]\\(https\\:", body)
        self.assertIn("\\@team", body)
        self.assertNotIn("PRIVATE", json.dumps(mutation))
        self.assertTrue(result["posted"])
        self.assertFalse(result["reused"])
        self.assertEqual(result["task_revision"], 7)
        self.assertEqual(result["comment_url"], URL + "#comment-abc")
        newer = linear.stable_comment_id(ORG_ID, ISSUE_ID, self.task(revision=8))
        self.assertNotEqual(newer, mutation["variables"]["input"]["id"])

    def test_comment_on_issue_from_another_workspace_never_posts(self):
        self.responses({"data": {"issue": issue(url="https://linear.app/other/issue/ENG-123/fix-login-timeout")}})
        self.error("INTEGRATION_UNAVAILABLE", "issues.comment", {"issue_id": "ENG-123", "task_id": "task-123",
                   "task": self.task(), "confirmed_by_user": True}, {**self.config, "comments_enabled": True})
        self.assertEqual(self.http.call_count, 1)

    def test_comment_reports_blocking_separately_from_status(self):
        config = {**self.config, "comments_enabled": True}
        posted = {"data": {"commentCreate": {"success": True, "comment": {"id": "c", "url": URL + "#comment-1", "issue": {"id": ISSUE_ID}}}}}
        for task, line in ((self.task(status="in_progress", blocked_reason="Waiting on [API](x) access"), "- Blocked: Waiting on \\[API\\]\\(x\\) access"),
                           (self.task(blocked_by=["a", "b"]), "- Blocked: waiting on 2 unfinished prerequisite tasks")):
            self.responses({"data": {"issue": issue()}}, posted)
            self.run_method("issues.comment", {"issue_id": "ENG-123", "task_id": "task-123", "task": task, "confirmed_by_user": True}, config)
            self.assertIn(line, self.body()["variables"]["input"]["body"])

    def test_comment_retry_reuses_existing_comment_for_same_task_revision(self):
        config = {**self.config, "comments_enabled": True}
        params = {"issue_id": "ENG-123", "task_id": "task-123", "task": self.task(), "confirmed_by_user": True}
        comment_id = linear.stable_comment_id(ORG_ID, ISSUE_ID, self.task())
        existing = {"data": {"comment": {"id": comment_id, "url": URL + "#comment-1", "issue": {"id": ISSUE_ID}}}}
        self.responses({"data": {"issue": issue()}}, graphql_failure("INVALID_INPUT", "duplicate id"), existing)
        result = self.run_method("issues.comment", params, config)["result"]
        self.assertTrue(result["reused"])
        self.assertEqual(self.body()["variables"], {"id": comment_id})
        elsewhere = {"data": {"comment": {"id": comment_id, "url": URL, "issue": {"id": "5f0f2a6c-1b1e-4c55-9f00-000000000999"}}}}
        self.responses({"data": {"issue": issue()}}, graphql_failure("INVALID_INPUT", "duplicate id"), elsewhere)
        self.error("INTEGRATION_UNAVAILABLE", "issues.comment", params, config)
        self.http.reset_mock()
        self.responses({"data": {"issue": issue()}}, graphql_failure("RATELIMITED"))
        self.error("INTEGRATION_RATE_LIMITED", "issues.comment", params, config)
        self.assertEqual(self.http.call_count, 2)

    def state_params(self, **changes):
        return {"issue_id": "ENG-123", "task_id": "task-123", "task": self.task(), "confirmed_by_user": True,
                "state_id": DONE, "expected_version": self.version(), **changes}

    def test_state_change_is_gated_and_requires_a_read_version(self):
        for flag in (None, False, "true"):
            self.error("INTEGRATION_DISABLED", "issues.update_state", self.state_params(), {**self.config, "state_changes_enabled": flag})
        enabled = {**self.config, "state_changes_enabled": True}
        params = self.state_params()
        del params["expected_version"]
        self.error("INVALID_REQUEST", "issues.update_state", params, enabled)
        self.error("INVALID_REQUEST", "issues.update_state", self.state_params(state_id="Done"), enabled)
        self.error("INVALID_REQUEST", "issues.update_state", self.state_params(confirmed_by_user=False), enabled)
        self.keychain.assert_not_called()
        self.http.assert_not_called()

    def test_state_change_refuses_changed_issue_or_foreign_state_without_writing(self):
        config = {**self.config, "state_changes_enabled": True}
        self.responses({"data": {"issue": issue(state={"id": STARTED, "name": "In Progress", "type": "started"})}})
        self.error("CONFLICT", "issues.update_state", self.state_params(), config)
        self.responses({"data": {"issue": issue()}})
        self.error("INVALID_REQUEST", "issues.update_state", self.state_params(state_id="11111111-2222-4333-8444-000000000099"), config)
        self.assertNotIn("issueUpdate", json.dumps([json.loads(call.args[0].data) for call in self.http.call_args_list]))

    def test_state_change_to_current_state_is_a_no_op(self):
        self.responses({"data": {"issue": issue()}})
        response = self.run_method("issues.update_state", self.state_params(state_id=TODO), {**self.config, "state_changes_enabled": True})
        self.assertFalse(response["result"]["changed"])
        self.assertNotIn("requests", response)
        self.assertEqual(self.http.call_count, 1)

    def test_state_change_updates_issue_and_records_new_source_version(self):
        done = issue(state={"id": DONE, "name": "Done", "type": "completed"})
        self.responses({"data": {"issue": issue()}}, {"data": {"issueUpdate": {"success": True, "issue": done}}})
        response = self.run_method("issues.update_state", self.state_params(), {**self.config, "state_changes_enabled": True})
        mutation = self.body()
        self.assertEqual(mutation["query"], linear.QUERIES["issue_update"])
        self.assertEqual(mutation["variables"], {"id": ISSUE_ID, "input": {"stateId": DONE}})
        result = response["result"]
        self.assertTrue(result["changed"])
        self.assertEqual(result["state_name"], "Done")
        self.assertEqual(result["task_revision"], 7)
        (link,) = response["requests"]
        self.assertEqual(link["params"]["task_id"], "task-123")
        self.assertNotIn("expected_revision", link["params"])
        self.assertEqual(link["params"]["description"], "Linear ENG-123 state: Done")
        self.assertEqual(link["params"]["metadata"]["source_version"], linear.issue_info(done, "acme")["version"])
        self.assertNotEqual(result["version"], self.version())

    def test_state_change_reported_elsewhere_is_a_conflict(self):
        self.responses({"data": {"issue": issue()}}, {"data": {"issueUpdate": {"success": True, "issue": issue()}}})
        self.error("CONFLICT", "issues.update_state", self.state_params(), {**self.config, "state_changes_enabled": True})
        self.responses({"data": {"issue": issue()}}, {"data": {"issueUpdate": {"success": False, "issue": None}}})
        self.error("INTEGRATION_UNAVAILABLE", "issues.update_state", self.state_params(), {**self.config, "state_changes_enabled": True})

    def test_teams_list_returns_teams_and_reports_more_pages(self):
        self.responses({"data": {"teams": {"nodes": [{"id": TEAM_ID, "key": "ENG", "name": "Engineering"}],
                                           "pageInfo": {"hasNextPage": True}}}})
        result = self.run_method("teams.list")["result"]
        self.assertEqual(result["teams"], [{"id": TEAM_ID, "key": "ENG", "name": "Engineering"}])
        self.assertTrue(result["has_more"])
        self.assertNotIn("states", self.body()["query"])


if __name__ == "__main__":
    unittest.main()
