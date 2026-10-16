"""Actual CLI → optional Linear process → service → SQLite; Linear HTTP/Keychain are fake."""
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
ISSUE_ID = "5f0f2a6c-1b1e-4c55-9f00-000000000123"
TEAM_ID = "7a1d0c55-3f6e-4f0a-8d4b-0000000000aa"
TODO = "11111111-2222-4333-8444-000000000001"
DONE = "11111111-2222-4333-8444-000000000003"
URL = "https://linear.app/acme/issue/ENG-123/fix-login-timeout"
WRAPPER = r'''#!/usr/bin/env python3
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
spec=importlib.util.spec_from_file_location("provider",Path(__file__).with_name("provider.py"))
linear=importlib.util.module_from_spec(spec)
spec.loader.exec_module(linear)
KEY="lin_api_TESTONLY0123456789abcdef"
URL="https://linear.app/acme/issue/ENG-123/fix-login-timeout"
state_path=Path(os.environ["WORKBOARD_PLUGIN_DATA_DIR"])/"fixture.json"
class Response(io.BytesIO):
    headers={}
def state(): return json.loads(state_path.read_text())
def save(value): state_path.write_text(json.dumps(value,ensure_ascii=False))
def fake_keychain(*args,**kwargs): return {"api_key":KEY,"workspace":"acme","organization_id":"org-1"}
def fake_http(request):
    value=state()
    assert request.get_header("Authorization")==KEY
    body=json.loads(request.data)
    name=next(k for k,q in linear.QUERIES.items() if q==body["query"])
    variables=body["variables"]
    value["calls"].append(name)
    save(value)
    if name=="viewer": data={"viewer":{"id":"user-1","name":"Test","organization":{"id":"org-1","name":"Acme","urlKey":"acme"}}}
    elif name=="issue": data={"issue":value["issue"]}
    elif name=="comment_create":
        comment=variables["input"]
        if any(c["id"]==comment["id"] for c in value["comments"]):
            return Response(json.dumps({"errors":[{"message":"Duplicate","extensions":{"code":"INVALID_INPUT"}}]}).encode())
        value["comments"].append(comment)
        save(value)
        if value.get("comment_uncertain"): raise TimeoutError("TEST response lost after write")
        data={"commentCreate":{"success":True,"comment":{"id":comment["id"],"url":URL+"#comment-1","issue":{"id":comment["issueId"]}}}}
    elif name=="comment":
        if value.get("lookup_unavailable"): raise TimeoutError("TEST network unavailable")
        found=next((c for c in value["comments"] if c["id"]==variables["id"]),None)
        if found is None: return Response(json.dumps({"errors":[{"message":"Entity not found: Comment","extensions":{"code":"INVALID_INPUT"}}]}).encode())
        data={"comment":{"id":found["id"],"url":URL+"#comment-1","issue":{"id":found["issueId"]}}}
    elif name=="issue_update":
        value["updates"].append(variables)
        target=next(s for s in value["issue"]["team"]["states"]["nodes"] if s["id"]==variables["input"]["stateId"])
        value["issue"]["state"]={"id":target["id"],"name":target["name"],"type":target["type"]}
        save(value)
        data={"issueUpdate":{"success":True,"issue":value["issue"]}}
    else: raise AssertionError("Unexpected external API")
    return Response(json.dumps({"data":data}).encode())
linear.keychain=fake_keychain
linear.http_open=fake_http
request=json.load(sys.stdin)
value=state();value["invocations"]+=1;value["last_request"]=request;save(value)
try: response=linear.run(request)
except linear.IntegrationError as error: response={"ok":False,"error":{"code":error.code,"message":str(error)}}
print(json.dumps(response,ensure_ascii=False))
'''


def issue():
    return {"id": ISSUE_ID, "identifier": "ENG-123", "title": "Fix login timeout",
            "description": "Users are signed out after 5 minutes.", "url": URL, "priority": 2,
            "priorityLabel": "High", "dueDate": "2026-10-20", "updatedAt": "2026-10-16T01:00:00.000Z",
            "archivedAt": None, "state": {"id": TODO, "name": "Todo", "type": "unstarted"},
            "assignee": None, "parent": None,
            "team": {"id": TEAM_ID, "key": "ENG", "name": "Engineering", "states": {"nodes": [
                {"id": TODO, "name": "Todo", "type": "unstarted", "position": 1},
                {"id": DONE, "name": "Done", "type": "completed", "position": 3}]}}}


class LinearHost(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="awb-linear-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.data = self.directory / "data"
        self.socket = self.directory / "s.sock"
        self.server = subprocess.Popen([str(SERVICE), "--data-dir", str(self.data), "--socket", str(self.socket)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop_service)
        deadline = time.monotonic() + 6
        while True:
            self.assertIsNone(self.server.poll())
            try:
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.connect(str(self.socket))
                break
            except OSError:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.02)
        package = self.directory / "plugin"
        package.mkdir()
        shutil.copyfile(ROOT / "plugins/linear/plugin.json", package / "plugin.json")
        shutil.copyfile(ROOT / "plugins/linear/plugin.py", package / "provider.py")
        (package / "plugin.py").write_text(WRAPPER)
        (package / "plugin.py").chmod(0o700)
        self.cli("plugin", "install", str(package))
        fixture_dir = self.data / "plugin-data/linear"
        fixture_dir.mkdir(parents=True)
        self.fixture = fixture_dir / "fixture.json"
        self.save({"issue": issue(), "invocations": 0, "calls": [], "comments": [], "updates": []})
        self.config = {"account": "test", "workspace": "acme", "issues_enabled": True,
                       "comments_enabled": True, "state_changes_enabled": True}
        self.cli("plugin", "enable", "linear", "--config", json.dumps(self.config))
        self.project = self.rpc("project.create", {"name": "Linear test"})["result"]["project"]["id"]

    def stop_service(self):
        if self.server.poll() is None:
            self.server.terminate()
            self.server.wait(timeout=5)

    def save(self, value):
        self.fixture.write_text(json.dumps(value, ensure_ascii=False))

    def state(self):
        return json.loads(self.fixture.read_text())

    def change(self, **values):
        self.save({**self.state(), **values})

    def cli(self, *args, ok=True):
        result = subprocess.run([str(CLI), "--json", "--data-dir", str(self.data), "--socket", str(self.socket), *args],
                                text=True, capture_output=True, timeout=12)
        payload = json.loads(result.stdout)
        self.assertEqual(result.returncode == 0, ok, payload)
        return payload

    def rpc(self, method, params=None, **options):
        return self.cli("rpc", method, "--params", json.dumps(params or {}, ensure_ascii=False), **options)

    def plugin(self, method, params=None, request_id="linear-operation", **options):
        return self.cli("plugin", "run", "linear", method, "--params", json.dumps(params or {}, ensure_ascii=False),
                        "--request-id", request_id, **options)

    def task(self):
        return self.rpc("task.create", {"project_id": self.project, "title": "Original board task", "goal": "PRIVATE GOAL"})["result"]["task"]

    def detail(self, task_id):
        return self.rpc("task.get", {"task_id": task_id})["result"]

    def read(self):
        return self.plugin("issues.read", {"issue_id": "ENG-123"})["result"]["result"]

    def test_import_subtask_retry_and_removal_preserve_evidence(self):
        parent = self.task()
        params = {"project_id": self.project, "parent_id": parent["id"], "issue_id": "ENG-123", "workspace": "acme"}
        response = self.plugin("issues.import", params)
        task_id = response["result"]["applied"][0]["task_id"]
        detail = self.detail(task_id)
        self.assertEqual(detail["task"]["parent_id"], parent["id"])
        self.assertEqual(detail["task"]["title"], "Fix login timeout")
        self.assertEqual(detail["task"]["due_at"], "2026-10-20")
        self.assertEqual(detail["task"]["priority"], 3)
        self.assertIn(URL, detail["task"]["goal"])
        artifact = detail["artifacts"][0]
        self.assertEqual(artifact["path"], URL)
        self.assertEqual(artifact["provider"], "linear")
        self.assertEqual(artifact["metadata"]["identifier"], "ENG-123")
        self.assertEqual(artifact["metadata"]["source_version"], response["result"]["result"]["version"])
        self.assertEqual(self.plugin("issues.import", params), response)
        self.assertEqual(self.state()["invocations"], 1)
        self.assertEqual(len(self.rpc("task.list")["result"]["tasks"]), 2)
        self.cli("plugin", "disable", "linear")
        self.assertEqual(self.plugin("issues.read", {"issue_id": "ENG-123"}, ok=False)["error"]["code"], "PLUGIN_DISABLED")
        self.cli("plugin", "remove", "linear")
        self.assertEqual(self.detail(task_id)["artifacts"], detail["artifacts"])
        self.assertEqual(self.detail(parent["id"])["task"]["status"], "todo")
        self.assertEqual(self.state()["invocations"], 1)
        self.assertTrue(self.rpc("doctor")["ok"])

    def test_read_version_then_source_edit_blocks_import(self):
        item = self.read()
        changed = self.state()
        changed["issue"]["title"] = "Edited in Linear"
        self.save(changed)
        response = self.plugin("issues.import", {"issue_id": "ENG-123", "project_id": self.project,
            "expected_version": item["version"]}, request_id="changed-source", ok=False)
        self.assertEqual(response["error"]["code"], "CONFLICT")
        self.assertEqual(self.rpc("task.list")["result"]["tasks"], [])

    def test_comment_uses_current_host_task_ignores_forgery_and_replays_once(self):
        task = self.task()
        params = {"task_id": task["id"], "issue_id": "ENG-123", "expected_revision": task["revision"],
                  "confirmed_by_user": True, "task": {"id": task["id"], "revision": task["revision"], "title": "FORGED"}}
        response = self.plugin("issues.comment", params)
        self.assertTrue(response["result"]["result"]["posted"])
        self.assertFalse(response["result"]["result"]["reused"])
        body = self.state()["comments"][0]["body"]
        self.assertIn("Original board task", body)
        self.assertNotIn("FORGED", body)
        self.assertNotIn("PRIVATE", body)
        self.assertEqual(self.state()["last_request"]["params"]["task"], self.detail(task["id"])["task"])
        self.assertEqual(self.plugin("issues.comment", params), response)
        conflict = self.plugin("issues.comment", {**params, "issue_id": "ENG-124"}, ok=False)
        self.assertEqual(conflict["error"]["code"], "REQUEST_ID_CONFLICT")
        # A new request for the same task revision finds the existing comment instead of posting again.
        again = self.plugin("issues.comment", params, request_id="linear-operation-2")
        self.assertTrue(again["result"]["result"]["reused"])
        self.assertEqual(len(self.state()["comments"]), 1)
        self.assertEqual(self.detail(task["id"])["artifacts"], [])
        self.assertNotIn("viewer", self.state()["calls"])

    def test_stale_revision_stops_before_plugin_or_http(self):
        task = self.task()
        self.rpc("task.update", {"task_id": task["id"], "expected_revision": task["revision"], "title": "Changed elsewhere"})
        for method, extra in (("issues.comment", {}), ("issues.update_state", {"state_id": DONE, "expected_version": "v"})):
            response = self.plugin(method, {"task_id": task["id"], "issue_id": "ENG-123", "expected_revision": task["revision"],
                                            "confirmed_by_user": True, **extra}, request_id=method, ok=False)
            self.assertEqual(response["error"]["code"], "PLUGIN_REVISION_CONFLICT")
        self.assertEqual(self.state()["invocations"], 0)

    def test_lost_comment_response_is_never_posted_twice(self):
        task = self.task()
        params = {"task_id": task["id"], "issue_id": "ENG-123", "confirmed_by_user": True}
        self.change(comment_uncertain=True, lookup_unavailable=True)
        first = self.plugin("issues.comment", params, ok=False)
        self.assertEqual(first["error"]["code"], "INTEGRATION_UNAVAILABLE")
        second = self.plugin("issues.comment", params, ok=False)
        self.assertEqual(second["error"]["code"], "PLUGIN_RESULT_UNCERTAIN")
        self.assertEqual(self.state()["invocations"], 1)
        self.change(comment_uncertain=False, lookup_unavailable=False)
        checked = self.plugin("issues.comment", params, request_id="checked-after-uncertain")
        self.assertTrue(checked["result"]["result"]["reused"])
        self.assertEqual(len(self.state()["comments"]), 1)
        self.assertTrue(self.rpc("doctor")["ok"])

    def test_state_change_updates_issue_and_records_new_version(self):
        task = self.task()
        item = self.read()
        params = {"task_id": task["id"], "issue_id": "ENG-123", "state_id": DONE, "expected_version": item["version"],
                  "expected_revision": task["revision"], "confirmed_by_user": True}
        response = self.plugin("issues.update_state", params)
        result = response["result"]["result"]
        self.assertTrue(result["changed"])
        self.assertEqual(result["state_name"], "Done")
        self.assertEqual(self.state()["updates"], [{"id": ISSUE_ID, "input": {"stateId": DONE}}])
        detail = self.detail(task["id"])
        self.assertEqual(detail["task"]["status"], "todo")
        artifact = detail["artifacts"][0]
        self.assertEqual(artifact["description"], "Linear ENG-123 state: Done")
        self.assertEqual(artifact["metadata"]["source_version"], result["version"])
        self.assertEqual(self.plugin("issues.update_state", params), response)
        self.assertEqual(len(self.state()["updates"]), 1)
        stale = self.plugin("issues.update_state", {**params, "expected_revision": detail["task"]["revision"]},
                            request_id="stale-version", ok=False)
        self.assertEqual(stale["error"]["code"], "CONFLICT")
        same = self.plugin("issues.update_state", {**params, "expected_version": result["version"],
                           "expected_revision": detail["task"]["revision"]}, request_id="same-state")
        self.assertFalse(same["result"]["result"]["changed"])
        self.assertEqual(same["result"]["applied"], [])
        self.assertEqual(len(self.state()["updates"]), 1)


if __name__ == "__main__":
    unittest.main()
