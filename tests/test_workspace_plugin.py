"""Google HTTP is mocked; no account, Keychain token or external write is used."""
import base64
import importlib.util
import io
import hashlib
import http.client
import json
from pathlib import Path
import re
import time
import threading
import unittest
from unittest import mock
import urllib.error
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("workspace_plugin", ROOT / "plugins/google-workspace/plugin.py")
workspace = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(workspace)


def event(**changes):
    value = {"id": "event1", "summary": "Product review", "description": "Check task outcomes", "etag": '"v1"',
        "htmlLink": "https://calendar.google.com/calendar/event?eid=event1", "status": "confirmed",
        "start": {"dateTime": "2026-10-16T10:00:00+09:00", "timeZone": "Asia/Seoul"},
        "end": {"dateTime": "2026-10-16T11:00:00+09:00", "timeZone": "Asia/Seoul"}}
    value.update(changes)
    return value


class WorkspacePlugin(unittest.TestCase):
    def setUp(self):
        self.config = {"calendar_enabled": True, "gmail_enabled": False, "account": "test"}
        self.token = {"access_token": "MOCK_TOKEN", "expires_at": time.time() + 3600,
            "workspace_scopes": [workspace.CALENDAR_SCOPE, workspace.CALENDAR_LIST_SCOPE, workspace.GMAIL_SCOPE]}
        self.keychain = mock.patch.object(workspace, "keychain", return_value=self.token).start()
        self.urlopen = mock.patch.object(workspace.urllib.request, "urlopen").start()
        self.addCleanup(mock.patch.stopall)

    def responses(self, *responses):
        def execute(*args, **kwargs):
            item = next(sequence)
            if isinstance(item, Exception):
                raise item
            return io.BytesIO(json.dumps(item).encode())
        sequence = iter(responses)
        self.urlopen.side_effect = execute

    def run_method(self, method, params=None, config=None):
        return workspace.run({"method": method, "params": params or {}, "config": config or self.config, "request_id": "test-request"})

    def request(self, index=-1):
        return self.urlopen.call_args_list[index].args[0]

    def task(self, **changes):
        value = {"id": "task-123", "title": "Design review", "goal": "Check the kanban screen", "revision": 7,
                 "due_at": "2026-10-16", "time_zone": "Asia/Seoul"}
        value.update(changes)
        return value

    def test_scopes_are_selected_per_service(self):
        self.assertEqual(workspace.scopes(self.config), [workspace.CALENDAR_SCOPE, workspace.CALENDAR_LIST_SCOPE])
        self.assertEqual(workspace.scopes({"gmail_enabled": True}), [workspace.GMAIL_SCOPE])
        with self.assertRaises(workspace.IntegrationError):
            workspace.scopes({"calendar_enabled": "false"})

    def test_discovery_uses_packaged_desktop_client_without_keychain_or_network(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            location = Path(directory)
            (location / "oauth-client.json").write_text(json.dumps({"installed": {"client_id": "publisher.apps.googleusercontent.com"}}))
            with mock.patch.object(workspace, "__file__", str(location / "plugin.py")):
                response = workspace.run({"method": "discover", "config": {}, "params": {}})["result"]
                self.assertTrue(response["available"])
                self.assertEqual(response["config"], {"account": "default", "calendar_enabled": True, "gmail_enabled": False})
        self.keychain.assert_not_called()
        self.urlopen.assert_not_called()

    def test_missing_publisher_client_reports_setup_status_without_account_reads(self):
        with mock.patch.object(workspace, "credentials", side_effect=workspace.IntegrationError("Publisher sign-in is unavailable")):
            result = workspace.run({"method": "discover", "config": {}, "params": {}})["result"]
        self.assertFalse(result["available"])
        self.keychain.assert_not_called()
        self.urlopen.assert_not_called()

    def test_authorization_uses_selected_services_before_enabling_plugin(self):
        choices = {"account": "personal", "calendar_enabled": True, "gmail_enabled": False}
        with mock.patch.object(workspace, "authorize", return_value={"connected": True}) as authorize:
            response = workspace.run({"method": "authorize", "config": {}, "params": {"connection_config": choices}})
        authorize.assert_called_once_with(choices, "personal")
        self.assertEqual(response["result"]["config"], choices)

    def test_connection_choices_cannot_inject_developer_credentials(self):
        with self.assertRaises(workspace.IntegrationError):
            workspace.run({"method": "authorize", "config": {}, "params": {"connection_config": {"credentials_file": "/untrusted/client.json"}}})
        self.keychain.assert_not_called()
        self.urlopen.assert_not_called()

    def test_disabled_service_has_no_keychain_or_http_access(self):
        with self.assertRaises(workspace.IntegrationError) as error:
            self.run_method("gmail.search")
        self.assertEqual(error.exception.code, "INTEGRATION_DISABLED")
        self.keychain.assert_not_called()
        self.urlopen.assert_not_called()
        with self.assertRaises(workspace.IntegrationError):
            self.run_method("check", config={"calendar_enabled": False, "gmail_enabled": False})
        self.keychain.assert_not_called()

    def test_enabling_new_service_requires_reauthorization(self):
        self.token["workspace_scopes"] = [workspace.CALENDAR_SCOPE, workspace.CALENDAR_LIST_SCOPE]
        with self.assertRaises(workspace.IntegrationError) as error:
            self.run_method("gmail.search", config={**self.config, "gmail_enabled": True})
        self.assertEqual(error.exception.code, "AUTHORIZATION_REQUIRED")
        self.urlopen.assert_not_called()

    def test_desktop_oauth_uses_pkce_state_and_only_selected_scopes(self):
        captured, statuses, threads = {}, [], []

        def open_browser(arguments, **kwargs):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(arguments[1]).query)
            captured.update({key: values[0] for key, values in query.items()})
            callback = urllib.parse.urlparse(captured["redirect_uri"])

            def send_callbacks():
                for state in ("wrong-state", captured["state"]):
                    connection = http.client.HTTPConnection(callback.hostname, callback.port, timeout=3)
                    connection.request("GET", callback.path + "?" + urllib.parse.urlencode({"state": state, "code": "mock-code"}))
                    response = connection.getresponse()
                    statuses.append(response.status)
                    response.read()
                    connection.close()
            thread = threading.Thread(target=send_callbacks, daemon=True)
            thread.start()
            threads.append(thread)
            return mock.Mock(returncode=0)

        token = {"access_token": "mock", "refresh_token": "mock-refresh", "scope": " ".join(workspace.scopes(self.config))}
        with mock.patch.object(workspace, "credentials", return_value={"client_id": "client"}), \
             mock.patch.object(workspace.subprocess, "run", side_effect=open_browser), \
             mock.patch.object(workspace, "token_request", return_value=token) as exchange:
            result = self.run_method("authorize")
            for thread in threads:
                thread.join(timeout=4)
            self.assertTrue(result["result"]["connected"])
            self.assertEqual(statuses, [400, 200])
            self.assertEqual(captured["code_challenge_method"], "S256")
            self.assertEqual(captured["prompt"], "consent select_account")
            self.assertNotIn("gmail", captured["scope"])
            self.assertTrue(captured["redirect_uri"].startswith("http://127.0.0.1:"))
            verifier = exchange.call_args.args[0]["code_verifier"]
            challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
            self.assertEqual(captured["code_challenge"], challenge)
            self.assertEqual(self.keychain.call_args.args[1]["refresh_token"], "mock-refresh")
        self.urlopen.assert_not_called()

    def test_refresh_preserves_refresh_token_and_scope_record(self):
        self.token.update({"expires_at": 0, "refresh_token": "old-refresh"})
        self.responses({"items": []})
        with mock.patch.object(workspace, "credentials", return_value={"client_id": "client"}), \
             mock.patch.object(workspace, "token_request", return_value={"access_token": "new-token", "expires_in": 3600}):
            self.run_method("calendar.list")
        saved = self.keychain.call_args.args[1]
        self.assertEqual(saved["refresh_token"], "old-refresh")
        self.assertEqual(saved["workspace_scopes"], self.token["workspace_scopes"])
        self.assertEqual(self.request().get_header("Authorization"), "Bearer new-token")

    def test_calendar_list_and_check_do_not_read_gmail(self):
        self.responses({"items": [{"id": "primary", "summary": "My calendar", "timeZone": "Asia/Seoul", "primary": True, "accessRole": "owner"}]})
        result = self.run_method("calendar.list")["result"]
        self.assertEqual(result["calendars"][0]["title"], "My calendar")
        self.assertIn("calendar/v3/users/me/calendarList", self.request().full_url)
        self.responses({"items": []})
        self.assertEqual(self.run_method("check")["result"]["calendar_count"], 0)
        self.assertNotIn("gmail.googleapis.com", self.request().full_url)

    def test_list_normalizes_range_pagination_and_calendar_id(self):
        self.responses({"items": [event()], "nextPageToken": "page2", "timeZone": "Asia/Seoul"})
        result = self.run_method("events.list", {"calendar_id": "a+b@example.com", "time_min": "2026-10-15T00:00:00Z", "time_max": "2026-10-17T00:00:00Z"})["result"]
        self.assertEqual(result["events"][0]["start"], "2026-10-16T10:00:00+09:00")
        self.assertEqual(result["next_page_token"], "page2")
        parsed = urllib.parse.urlparse(self.request().full_url)
        self.assertIn("a%2Bb%40example.com", parsed.path)
        self.assertEqual(urllib.parse.parse_qs(parsed.query)["singleEvents"], ["true"])

    def test_invalid_range_has_no_http_write(self):
        with self.assertRaises(workspace.IntegrationError):
            self.run_method("events.list", {"time_min": "2026-10-17T00:00:00Z", "time_max": "2026-10-15T00:00:00Z"})
        self.urlopen.assert_not_called()

    def test_import_meeting_uses_service_requests_and_parent(self):
        self.responses(event())
        result = self.run_method("events.import", {"event_id": "event1", "project_id": "p", "parent_id": "parent"})
        self.assertEqual(result["requests"][0]["method"], "task.create")
        creation = result["requests"][0]["params"]
        self.assertEqual(creation["parent_id"], "parent")
        self.assertEqual(creation["due_at"], "2026-10-16T11:00:00+09:00")
        self.assertEqual(creation["time_zone"], "Asia/Seoul")
        self.assertEqual(result["requests"][1]["params"]["task_id"], {"$result": "/0/task_id"})
        self.assertEqual(result["requests"][1]["params"]["metadata"]["etag"], '"v1"')
        self.assertEqual(self.request().method, "GET")

    def test_import_all_day_preserves_exclusive_end_and_inclusive_due_date(self):
        self.responses(event(start={"date": "2026-10-16"}, end={"date": "2026-10-18"}),
                       {"timeZone": "America/Los_Angeles"})
        creation = self.run_method("events.import", {"event_id": "e", "project_id": "p"})["requests"][0]["params"]
        self.assertEqual(creation["scheduled_end"], "2026-10-18")
        self.assertEqual(creation["due_at"], "2026-10-17")
        self.assertEqual(creation["time_zone"], "America/Los_Angeles")
        self.assertTrue(self.request().full_url.endswith("users/me/calendarList/primary"))

    def test_all_day_list_and_detail_use_authoritative_calendar_zone(self):
        item = event(start={"date": "2026-10-16"}, end={"date": "2026-10-18"})
        self.responses({"items": [item], "timeZone": "America/Los_Angeles"})
        result = self.run_method("events.list")["result"]
        self.assertEqual(result["events"][0]["time_zone"], "America/Los_Angeles")
        self.responses(item, {"timeZone": "America/Los_Angeles"})
        result = self.run_method("events.get", {"event_id": "event1", "calendar_id": "a+b@example.com"})["result"]
        self.assertEqual(result["time_zone"], "America/Los_Angeles")
        self.assertTrue(self.request().full_url.endswith("calendarList/a%2Bb%40example.com"))

    def test_missing_calendar_zone_does_not_guess_utc_or_prepare_board_writes(self):
        for calendar in ({}, {"timeZone": "Invalid/Zone"}):
            self.responses(event(start={"date": "2026-10-16"}, end={"date": "2026-10-18"}), calendar)
            with self.subTest(calendar=calendar), self.assertRaises(workspace.IntegrationError):
                self.run_method("events.import", {"event_id": "e", "project_id": "p"})

    def test_timed_event_without_explicit_zone_uses_calendar_zone(self):
        self.responses(event(start={"dateTime": "2026-10-16T10:00:00-07:00"},
                             end={"dateTime": "2026-10-16T11:00:00-07:00"}),
                       {"timeZone": "America/Los_Angeles"})
        creation = self.run_method("events.import", {"event_id": "e", "project_id": "p"})["requests"][0]["params"]
        self.assertEqual(creation["scheduled_start"], "2026-10-16T10:00:00-07:00")
        self.assertEqual(creation["time_zone"], "America/Los_Angeles")

    def test_pull_updates_only_schedule_with_revision_and_source_link(self):
        self.responses(event())
        result = self.run_method("events.pull", {"event_id": "event1", "etag": '"v1"', "task": self.task()})
        update = result["requests"][0]
        self.assertEqual(update["method"], "task.update")
        self.assertEqual(set(update["params"]), {"task_id", "expected_revision", "due_at", "scheduled_start", "scheduled_end", "time_zone"})
        self.assertEqual(update["params"]["expected_revision"], 7)
        self.assertEqual(update["params"]["scheduled_start"], "2026-10-16T10:00:00+09:00")
        self.assertEqual(result["requests"][1]["params"]["expected_revision"], {"$result": "/0/task/revision"})
        self.assertEqual(self.request().method, "GET")

    def test_pull_rejects_changed_remote_etag(self):
        self.responses(event(etag='"changed"'))
        with self.assertRaises(workspace.IntegrationError) as error:
            self.run_method("events.pull", {"event_id": "event1", "etag": '"v1"', "task": self.task()})
        self.assertEqual(error.exception.code, "CONFLICT")
        self.assertEqual(self.urlopen.call_count, 1)

    def test_pull_all_day_uses_last_inclusive_day_and_calendar_zone(self):
        self.responses(event(start={"date": "2026-10-16"}, end={"date": "2026-10-18"}),
                       {"timeZone": "America/Los_Angeles"})
        update = self.run_method("events.pull", {"event_id": "event1", "etag": '"v1"', "task": self.task()})["requests"][0]["params"]
        self.assertEqual(update["due_at"], "2026-10-17")
        self.assertEqual(update["scheduled_end"], "2026-10-18")
        self.assertEqual(update["time_zone"], "America/Los_Angeles")

    def test_pull_rejects_cancelled_or_invalid_event_without_board_requests(self):
        for changes in [{"status": "cancelled"}, {"start": {}, "end": {}}]:
            self.responses(event(**changes))
            with self.subTest(changes=changes), self.assertRaises(workspace.IntegrationError):
                self.run_method("events.pull", {"event_id": "event1", "etag": '"v1"', "task": self.task()})

    def test_create_all_day_has_stable_id_and_never_invites(self):
        self.responses(event(start={"date": "2026-10-16"}, end={"date": "2026-10-17"}))
        result = self.run_method("events.create", {"task": self.task()})
        request = self.request()
        body = json.loads(request.data)
        self.assertEqual(request.method, "POST")
        self.assertEqual(body["start"], {"date": "2026-10-16"})
        self.assertEqual(body["end"], {"date": "2026-10-17"})
        self.assertRegex(body["id"], r"^[0-9a-v]{52}$")
        self.assertEqual(body["id"], workspace.stable_event_id("test", "primary", "task-123"))
        self.assertNotIn("attendees", body)
        self.assertEqual(urllib.parse.parse_qs(urllib.parse.urlparse(request.full_url).query)["sendUpdates"], ["none"])
        self.assertEqual(result["requests"][0]["params"]["expected_revision"], 7)

    def test_timed_meeting_and_due_time_are_explicit(self):
        self.responses(event())
        self.run_method("events.create", {"task": self.task(scheduled_start="2026-10-16T10:00:00+09:00", scheduled_end="2026-10-16T11:00:00+09:00")})
        self.assertEqual(json.loads(self.request().data)["start"]["timeZone"], "Asia/Seoul")
        due = workspace.task_event(self.task(due_at="2026-10-16T10:00:00Z"))
        self.assertEqual(due["end"]["dateTime"], "2026-10-16T10:30:00+00:00")

    def test_invalid_schedule_and_zone_are_rejected_before_http(self):
        for changes in [{"scheduled_start": "2026-10-16"}, {"due_at": "2026-02-30"},
                        {"due_at": "2026-10-16T10:00:00"}, {"time_zone": "Unknown/Zone"},
                        {"scheduled_start": "2026-10-17", "scheduled_end": "2026-10-16"}]:
            with self.subTest(changes=changes), self.assertRaises(workspace.IntegrationError):
                self.run_method("events.create", {"task": self.task(**changes)})
        self.urlopen.assert_not_called()

    def test_duplicate_insert_reuses_only_own_linked_event(self):
        conflict = urllib.error.HTTPError("https://mock", 409, "conflict", {}, None)
        self.responses(conflict, event(extendedProperties={"private": {"workboard_task_id": "task-123"}}))
        result = self.run_method("events.create", {"task": self.task()})
        self.assertTrue(result["result"]["reused"])
        self.assertEqual([call.args[0].method for call in self.urlopen.call_args_list], ["POST", "GET"])
        self.responses(conflict, event(extendedProperties={"private": {"workboard_task_id": "someone-else"}}))
        with self.assertRaises(workspace.IntegrationError) as error:
            self.run_method("events.create", {"task": self.task()})
        self.assertEqual(error.exception.code, "CONFLICT")

    def test_update_preserves_metadata_and_sends_if_match(self):
        previous = event(extendedProperties={"private": {"other_app": "preserve"}}, attendees=[{"email": "person@example.test"}])
        self.responses(previous, event(etag='"v2"'))
        result = self.run_method("events.update", {"event_id": "event1", "etag": '"v1"', "task": self.task()})
        request = self.request()
        self.assertEqual(request.method, "PATCH")
        self.assertEqual(request.get_header("If-match"), '"v1"')
        body = json.loads(request.data)
        self.assertEqual(body["extendedProperties"]["private"]["other_app"], "preserve")
        self.assertNotIn("attendees", body)
        self.assertNotIn("recurrence", body)
        self.assertEqual(result["result"]["etag"], '"v2"')

    def test_stale_etag_or_race_never_overwrites_calendar(self):
        self.responses(event(etag='"new"'))
        with self.assertRaises(workspace.IntegrationError) as error:
            self.run_method("events.update", {"event_id": "event1", "etag": '"old"', "task": self.task()})
        self.assertEqual(error.exception.code, "CONFLICT")
        self.assertEqual(self.urlopen.call_count, 1)
        self.responses(event(), urllib.error.HTTPError("https://mock", 412, "stale", {}, None))
        with self.assertRaises(workspace.GoogleHTTPError) as error:
            self.run_method("events.update", {"event_id": "event1", "etag": '"v1"', "task": self.task()})
        self.assertEqual(error.exception.code, "CONFLICT")

    def test_recurring_series_cannot_be_changed_accidentally(self):
        self.responses(event(recurrence=["RRULE:FREQ=DAILY"]))
        with self.assertRaises(workspace.IntegrationError):
            self.run_method("events.update", {"event_id": "event1", "etag": '"v1"', "task": self.task()})
        self.assertEqual(self.urlopen.call_count, 1)

    def test_gmail_read_is_plain_text_without_scripts_or_remote_requests(self):
        html = '<p>Please review</p><script>secret()</script><img src="https://external.test/a"><p>Thank you</p>'
        payload = {"mimeType": "text/html", "headers": [{"name": "Subject", "value": "Request review"}],
                   "body": {"data": base64.urlsafe_b64encode(html.encode()).decode().rstrip("=")}}
        self.responses({"id": "mail1", "snippet": "Review", "payload": payload})
        result = self.run_method("gmail.read", {"message_id": "mail1"}, {**self.config, "gmail_enabled": True})["result"]
        self.assertIn("Please review", result["body"])
        self.assertNotIn("secret", result["body"])
        self.assertNotIn("external.test", result["body"])
        self.assertEqual(self.urlopen.call_count, 1)
        self.assertIn("format=full", self.request().full_url)

    def test_gmail_import_creates_task_then_preserves_source_link(self):
        self.responses({"id": "mail1", "snippet": "To do", "threadId": "thread", "payload": {}})
        result = self.run_method("gmail.import", {"message_id": "mail1", "project_id": "p", "parent_id": "parent"},
                                 {"gmail_enabled": True})
        self.assertEqual(result["requests"][0]["params"]["parent_id"], "parent")
        self.assertEqual(result["requests"][1]["params"]["task_id"], {"$result": "/0/task_id"})
        self.assertEqual(result["requests"][1]["params"]["metadata"]["service"], "gmail")

    def test_unknown_method_does_not_access_keychain(self):
        with self.assertRaises(workspace.IntegrationError):
            self.run_method("gmail.send")
        self.keychain.assert_not_called()
        self.urlopen.assert_not_called()


class WorkspaceKeychainLabels(unittest.TestCase):
    def test_unsafe_labels_fail_before_keychain_storage_or_authorization(self):
        labels = ["O'Brien", "work\nlist-keychains", "two words", "", "caf\u00e9", "a" * 81, 'quote"d', "back\\slash"]
        with mock.patch.object(workspace.subprocess, "run") as process, \
                mock.patch.object(workspace, "authorize") as authorize:
            for label in labels:
                with self.subTest(label=label):
                    with self.assertRaises(workspace.IntegrationError) as caught:
                        workspace.keychain(label, {"access_token": "MOCK_TOKEN"})
                    self.assertEqual(caught.exception.code, "INVALID_REQUEST")
                    with self.assertRaises(workspace.IntegrationError):
                        workspace.run({"method": "authorize", "config": {"account": label, "calendar_enabled": True}})
            process.assert_not_called()
            authorize.assert_not_called()

    def test_saved_legacy_labels_can_still_be_read_and_disconnected(self):
        for label in ["two words", "caf\u00e9", "a" * 90, "O'Brien", "work\nlist-keychains"]:
            with self.subTest(label=label), mock.patch.object(workspace.subprocess, "run",
                    return_value=mock.Mock(returncode=0, stdout='{"k":"v"}')) as process:
                self.assertEqual(workspace.keychain(label), {"k": "v"})
                workspace.run({"method": "disconnect", "config": {"account": label}})
                for call in process.call_args_list:
                    args = call.args[0]
                    self.assertNotIn("-i", args)
                    self.assertEqual(args[args.index("-a") + 1], label)
                self.assertIn("delete-generic-password", process.call_args.args[0])

    def test_safe_labels_can_still_store_tokens_over_stdin(self):
        for label in ["default", "work-mail@example.com", "team_1.backup"]:
            with self.subTest(label=label), mock.patch.object(workspace.subprocess, "run",
                    return_value=mock.Mock(returncode=0, stdout="")) as process:
                workspace.keychain(label, {"access_token": "MOCK_TOKEN"})
                self.assertEqual(process.call_args.args[0], ["/usr/bin/security", "-i"])
                self.assertIn(" -a %s " % label, process.call_args.kwargs["input"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
