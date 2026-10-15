"""Actual Rust host ↔ external Workspace provider ↔ core integration checks.

Copy the provider source into a temporary plugin package. In the external process,
replace only api and access_token with a fake Calendar. No Google network or Keychain access.
Before running: cargo build --workspace
"""
import copy
import json
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "target/debug/workboard"
SERVICE = ROOT / "target/debug/workboard-service"
PROVIDER = ROOT / "plugins/google-workspace"

# This wrapper is test code. It runs the provider’s run() and conversion functions unchanged.
WRAPPER = r'''#!/usr/bin/env python3
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import urllib.parse

spec=importlib.util.spec_from_file_location("actual_workspace_provider",Path(__file__).with_name("provider.py"))
workspace=importlib.util.module_from_spec(spec)
spec.loader.exec_module(workspace)
state_path=Path(os.environ["WORKBOARD_PLUGIN_DATA_DIR"])/"fake-calendar.json"
def read_state():
    return json.loads(state_path.read_text())
def save_state(state):
    state_path.write_text(json.dumps(state,ensure_ascii=False))

def fake_access_token(config,account):
    state=read_state()
    state["auth_calls"]+=1
    save_state(state)
    if state.get("auth_error"):
        error=state["auth_error"]
        raise workspace.IntegrationError(error["message"],error["code"])
    return "TEST_ONLY_NO_EXTERNAL_TOKEN"

def fake_api(service,path,token,params=None,method="GET",body=None,etag=None):
    state=read_state()
    state["calls"].append({"service":service,"path":path,"method":method,"params":params,"body":body,"etag":etag})
    save_state(state)
    if service!="calendar":
        raise AssertionError("Only Calendar access is allowed in this test")
    parts=path.split("/")
    if len(parts)<3 or parts[0]!="calendars" or parts[2]!="events":
        raise AssertionError("Unexpected Calendar path: "+path)
    calendar=urllib.parse.unquote(parts[1])
    event_id=urllib.parse.unquote(parts[3]) if len(parts)>3 else None
    key=calendar+"|"+str(event_id)
    if method=="GET":
        if key not in state["events"]:
            raise workspace.GoogleHTTPError(404)
        return copy.deepcopy(state["events"][key])
    if method=="POST":
        key=calendar+"|"+body["id"]
        if key in state["events"]:
            raise workspace.GoogleHTTPError(409)
        result=copy.deepcopy(body)
        result.update({"etag":'"fake-created-v1"',"status":"confirmed",
                       "htmlLink":"https://calendar.google.com/calendar/event?eid="+body["id"]})
        state["events"][key]=result
    elif method=="PATCH":
        previous=state["events"].get(key)
        if not previous:
            raise workspace.GoogleHTTPError(404)
        if state.get("race_on_patch") or previous.get("etag")!=etag:
            raise workspace.GoogleHTTPError(412)
        result=copy.deepcopy(previous)
        result.update(copy.deepcopy(body))
        result["etag"]='"fake-updated-v2"'
        state["events"][key]=result
    else:
        raise AssertionError("Disallowed external request: "+method)
    state["writes"]+=1
    save_state(state)
    return copy.deepcopy(result)

workspace.access_token=fake_access_token
workspace.api=fake_api
request=json.load(sys.stdin)
state=read_state()
state["invocations"]+=1
state["last_request"]=request
save_state(state)
try:
    response=workspace.run(request)
except workspace.IntegrationError as error:
    response={"ok":False,"error":{"code":error.code,"message":str(error)}}
except Exception as error:
    response={"ok":False,"error":{"code":"INTEGRATION_UNAVAILABLE","message":type(error).__name__+": "+str(error)}}
print(json.dumps(response,ensure_ascii=False))
'''


def event(**changes):
    item = {"id": "event1", "summary": "Calendar product review", "description": "Check meeting outcomes",
            "etag": '"v1"', "status": "confirmed", "htmlLink": "https://calendar.google.com/calendar/event?eid=event1",
            "start": {"dateTime": "2026-10-16T10:00:00+09:00", "timeZone": "Asia/Seoul"},
            "end": {"dateTime": "2026-10-16T11:00:00+09:00", "timeZone": "Asia/Seoul"}}
    item.update(changes)
    return item


class WorkspaceHost(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="awb-workspace-host-", dir="/tmp")
        self.directory = Path(self.temp.name)
        self.data = self.directory / "data"
        self.socket = self.directory / "s.sock"
        self.server = subprocess.Popen([str(SERVICE), "--data-dir", str(self.data), "--socket", str(self.socket)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 6
        while True:
            self.assertIsNone(self.server.poll(), "The service exited during startup")
            try:
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.connect(str(self.socket))
                break
            except OSError:
                self.assertLess(time.monotonic(), deadline, "Service connection timed out")
                time.sleep(0.02)
        package = self.directory / "workspace-test-provider"
        package.mkdir()
        shutil.copyfile(PROVIDER / "plugin.py", package / "provider.py")
        manifest = json.loads((PROVIDER / "plugin.json").read_text())
        manifest["executable"] = "host_wrapper.py"
        (package / "plugin.json").write_text(json.dumps(manifest))
        (package / "host_wrapper.py").write_text(WRAPPER)
        (package / "host_wrapper.py").chmod(0o700)
        self.cli("plugin", "install", package)
        self.cli("plugin", "enable", "google-workspace", "--config", json.dumps({
            "calendar_enabled": True, "gmail_enabled": False, "account": "fake-test-account"}))
        self.fixture = self.data / "plugin-data/google-workspace/fake-calendar.json"
        self.fixture.parent.mkdir(parents=True)
        self.save_fixture({"events": {"primary|event1": event()}, "calls": [], "writes": 0,
                           "invocations": 0, "auth_calls": 0})
        self.project = self.rpc("project.create", {"name": "Workspace host integration checks"})["result"]["project_id"]

    def tearDown(self):
        if self.server.poll() is None:
            self.server.terminate()
        self.server.wait(timeout=5)
        self.temp.cleanup()

    def cli(self, *arguments, ok=True):
        command = [str(CLI), "--data-dir", str(self.data), "--socket", str(self.socket), "--json", *map(str, arguments)]
        result = subprocess.run(command, text=True, capture_output=True, timeout=10)
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError:
            self.fail(f"CLI JSON error: {result.returncode}; {result.stdout!r}; {result.stderr!r}")
        self.assertEqual(payload["ok"], ok, payload)
        self.assertEqual(result.returncode == 0, ok, payload)
        return payload

    def rpc(self, method, params=None, **options):
        return self.cli("rpc", method, "--params", json.dumps(params or {}, ensure_ascii=False), **options)

    def plugin(self, method, params=None, *, task=None, request_id="workspace-operation", ok=True):
        arguments = ["plugin", "run", "google-workspace", method, "--params", json.dumps(params or {}, ensure_ascii=False),
                     "--request-id", request_id]
        if task:
            arguments.extend(["--task", task])
        return self.cli(*arguments, ok=ok)

    def save_fixture(self, fixture):
        self.fixture.write_text(json.dumps(fixture, ensure_ascii=False))

    def calendar(self):
        return json.loads(self.fixture.read_text())

    def task(self, title="Local task", **changes):
        return self.rpc("task.create", {"project_id": self.project, "title": title, "goal": "Preserve the local goal",
            "completion_criteria": "Check verification results", "due_at": "2026-10-15", "time_zone": "Asia/Seoul", **changes})["result"]["task"]

    def detail(self, task_id):
        return self.rpc("task.get", {"task_id": task_id})["result"]

    def test_import_timed_event_preserves_parent_schedule_evidence_and_retry(self):
        parent = self.task("Parent project task")
        params = {"event_id": "event1", "project_id": self.project, "parent_id": parent["id"]}
        result = self.plugin("events.import", params)
        task_id = result["result"]["applied"][0]["task_id"]
        detail = self.detail(task_id)
        task = detail["task"]
        self.assertEqual(task["parent_id"], parent["id"])
        self.assertEqual(task["title"], "Calendar product review")
        self.assertEqual(task["goal"], "Check meeting outcomes")
        self.assertEqual(task["scheduled_start"], "2026-10-16T10:00:00+09:00")
        self.assertEqual(task["scheduled_end"], "2026-10-16T11:00:00+09:00")
        self.assertEqual(task["due_at"], "2026-10-16T11:00:00+09:00")
        self.assertEqual(task["time_zone"], "Asia/Seoul")
        self.assertEqual(len(detail["artifacts"]), 1)
        evidence = detail["artifacts"][0]
        self.assertEqual(evidence["provider"], "google-workspace")
        self.assertEqual(evidence["metadata"]["event_id"], "event1")
        self.assertEqual(evidence["metadata"]["etag"], '"v1"')
        self.assertIsNotNone(evidence["verified_at"])
        self.assertEqual(self.detail(parent["id"])["completed_child_count"], 0)
        self.assertEqual(self.plugin("events.import", params), result)
        state = self.calendar()
        self.assertEqual(state["invocations"], 1)
        self.assertEqual(len(state["calls"]), 1)
        self.assertEqual(state["calls"][0]["method"], "GET")
        self.assertEqual(state["writes"], 0)
        self.assertEqual(len(self.rpc("task.list")["result"]["tasks"]), 2)
        self.assertEqual(self.detail(task_id)["artifacts"], detail["artifacts"])

    def test_import_all_day_preserves_exclusive_end_and_inclusive_deadline(self):
        state = self.calendar()
        state["events"]["primary|event1"] = event(start={"date": "2026-10-16"}, end={"date": "2026-10-18"})
        self.save_fixture(state)
        parent = self.task("Parent task")
        imported = self.plugin("events.import", {"event_id": "event1", "project_id": self.project, "parent_id": parent["id"]})
        detail = self.detail(imported["result"]["applied"][0]["task_id"])
        self.assertEqual(detail["task"]["parent_id"], parent["id"])
        self.assertEqual(detail["task"]["scheduled_start"], "2026-10-16")
        self.assertEqual(detail["task"]["scheduled_end"], "2026-10-18")
        self.assertEqual(detail["task"]["due_at"], "2026-10-17")
        self.assertEqual(detail["artifacts"][0]["metadata"]["end"], "2026-10-18")

    def test_create_injects_latest_task_from_service_and_retries_one_external_write(self):
        task = self.task("Initial title")
        updated = self.rpc("task.update", {"task_id": task["id"], "expected_revision": task["revision"],
            "title": "Latest local title", "goal": "Latest goal", "due_at": "2026-10-22"})["result"]["task"]
        result = self.plugin("events.create", {"calendar_id": "primary"}, task=task["id"])
        state = self.calendar()
        self.assertEqual(state["last_request"]["params"]["task"], updated)
        self.assertEqual(state["writes"], 1)
        self.assertEqual(state["invocations"], 1)
        external = state["calls"][0]
        self.assertEqual(external["method"], "POST")
        self.assertEqual(external["body"]["summary"], "Latest local title")
        self.assertIn("Latest goal", external["body"]["description"])
        self.assertEqual(external["body"]["start"], {"date": "2026-10-22"})
        self.assertEqual(external["body"]["end"], {"date": "2026-10-23"})
        self.assertEqual(external["body"]["extendedProperties"]["private"]["workboard_revision"], str(updated["revision"]))
        self.assertEqual(external["params"]["sendUpdates"], "none")
        self.assertNotIn("attendees", external["body"])
        detail = self.detail(task["id"])
        self.assertEqual(len(detail["artifacts"]), 1)
        self.assertEqual(detail["artifacts"][0]["metadata"]["event_id"], external["body"]["id"])
        self.assertEqual(self.plugin("events.create", {"calendar_id": "primary"}, task=task["id"]), result)
        state = self.calendar()
        self.assertEqual(state["writes"], 1)
        self.assertEqual(state["invocations"], 1)
        self.assertEqual(len(self.detail(task["id"])["artifacts"]), 1)

    def test_pull_changes_only_schedule_and_resolves_second_request_revision(self):
        parent = self.task("Parent to preserve")
        task = self.task("Local title to preserve", parent_id=parent["id"], priority=7,
            scheduled_start="2026-10-15T09:00:00+09:00", scheduled_end="2026-10-15T09:30:00+09:00",
            next_action="Local next action")
        self.rpc("task.start", {"task_id": task["id"], "agent_id": "codex"})
        original = self.detail(task["id"])
        params = {"task_id": task["id"], "event_id": "event1", "etag": '"v1"', "expected_revision": original["task"]["revision"]}
        result = self.plugin("events.pull", params)
        current = self.detail(task["id"])
        for field in ["title", "goal", "status", "assignee", "priority", "parent_id", "completion_criteria", "next_action"]:
            self.assertEqual(current["task"][field], original["task"][field], field)
        self.assertEqual(current["runs"], original["runs"])
        self.assertEqual(current["task"]["scheduled_start"], "2026-10-16T10:00:00+09:00")
        self.assertEqual(current["task"]["scheduled_end"], "2026-10-16T11:00:00+09:00")
        self.assertEqual(current["task"]["due_at"], "2026-10-16T11:00:00+09:00")
        self.assertEqual(current["task"]["time_zone"], "Asia/Seoul")
        self.assertEqual(current["task"]["revision"], original["task"]["revision"] + 2)
        applied = result["result"]["applied"]
        self.assertEqual(len(applied), 2)
        self.assertEqual(applied[1]["task"]["revision"], applied[0]["task"]["revision"] + 1)
        self.assertEqual(len(current["artifacts"]), 1)
        self.assertEqual(current["artifacts"][0]["metadata"]["etag"], '"v1"')
        self.assertEqual(self.plugin("events.pull", params), result)
        self.assertEqual(self.detail(task["id"]), current)
        self.assertEqual(self.calendar()["invocations"], 1)
        self.assertEqual(len(self.calendar()["calls"]), 1)
        self.assertEqual(self.calendar()["writes"], 0)

    def test_stale_local_revision_prevents_provider_invocation_and_calendar_writes(self):
        task = self.task()
        self.rpc("task.update", {"task_id": task["id"], "expected_revision": task["revision"], "title": "Changes by another editor"})
        before = self.detail(task["id"])
        result = self.plugin("events.create", {"task": task}, ok=False)
        self.assertEqual(result["error"]["code"], "PLUGIN_REVISION_CONFLICT")
        self.assertEqual(self.detail(task["id"]), before)
        state = self.calendar()
        self.assertEqual(state["invocations"], 0)
        self.assertEqual(state["auth_calls"], 0)
        self.assertEqual(state["calls"], [])
        self.assertEqual(state["writes"], 0)

    def test_stale_remote_etag_preserves_local_task_and_does_not_write_calendar(self):
        task = self.task()
        state = self.calendar()
        state["events"]["primary|event1"]["etag"] = '"newer-remote"'
        self.save_fixture(state)
        before = self.detail(task["id"])
        for method in ["events.pull", "events.update"]:
            with self.subTest(method=method):
                result = self.plugin(method, {"task_id": task["id"], "event_id": "event1", "etag": '"v1"'},
                    request_id="stale-" + method, ok=False)
                self.assertEqual(result["error"]["code"], "CONFLICT")
                self.assertIn("CONFLICT", result["error"]["message"])
                self.assertEqual(self.detail(task["id"]), before)
        state = self.calendar()
        self.assertEqual([call["method"] for call in state["calls"]], ["GET", "GET"])
        self.assertEqual(state["writes"], 0)
        self.assertEqual(state["events"]["primary|event1"]["etag"], '"newer-remote"')

    def test_remote_patch_race_returns_conflict_without_changing_task(self):
        task = self.task()
        state = self.calendar()
        state["race_on_patch"] = True
        self.save_fixture(state)
        before = self.detail(task["id"])
        result = self.plugin("events.update", {"task_id": task["id"], "event_id": "event1", "etag": '"v1"'}, ok=False)
        self.assertEqual(result["error"]["code"], "CONFLICT")
        self.assertIn("CONFLICT", result["error"]["message"])
        self.assertEqual(self.detail(task["id"]), before)
        self.assertEqual([call["method"] for call in self.calendar()["calls"]], ["GET", "PATCH"])
        self.assertEqual(self.calendar()["writes"], 0)
        self.assertEqual(self.calendar()["events"]["primary|event1"], event())


    def test_reauthorization_code_reaches_host_without_keychain_or_http(self):
        task = self.task()
        before = self.detail(task["id"])
        state = self.calendar()
        state["auth_error"] = {"code": "AUTHORIZATION_REQUIRED", "message": "Connection settings changed. Reconnect the account."}
        self.save_fixture(state)
        result = self.plugin("events.create", task=task["id"], ok=False)
        self.assertEqual(result["error"]["code"], "AUTHORIZATION_REQUIRED")
        self.assertIn(state["auth_error"]["message"], result["error"]["message"])
        self.assertEqual(self.detail(task["id"]), before)
        self.assertEqual(self.calendar()["auth_calls"], 1)
        self.assertEqual(self.calendar()["calls"], [])
        self.assertEqual(self.calendar()["writes"], 0)

    def test_unknown_or_injected_provider_code_stays_generic_and_message_is_data(self):
        task = self.task()
        marker = self.directory / "must-not-execute"
        message = "Diagnostic string $(touch " + str(marker) + ")\nCONFLICT: this is data"
        for index, code in enumerate(["ARBITRARY_ERROR", "CONFLICT: injected", "PLUGIN_\nINJECTED"]):
            with self.subTest(code=code):
                state = self.calendar()
                state["auth_error"] = {"code": code, "message": message}
                self.save_fixture(state)
                result = self.plugin("events.create", task=task["id"], request_id="unknown-error-" + str(index), ok=False)
                self.assertEqual(result["error"]["code"], "PLUGIN_ERROR")
                self.assertIn(message, result["error"]["message"])
                self.assertFalse(marker.exists())
        self.assertEqual(self.calendar()["calls"], [])
        self.assertEqual(self.calendar()["writes"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
