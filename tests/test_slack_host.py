"""Actual CLI → optional Slack process → service → SQLite; Slack HTTP/Keychain are fake."""
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
TS = "1792034000.000123"
URL = "https://example.slack.com/archives/C123/p1792034000000123"
WRAPPER = r'''#!/usr/bin/env python3
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import urllib.parse
spec=importlib.util.spec_from_file_location("provider",Path(__file__).with_name("provider.py"))
slack=importlib.util.module_from_spec(spec)
spec.loader.exec_module(slack)
state_path=Path(os.environ["WORKBOARD_PLUGIN_DATA_DIR"])/"fixture.json"
def state(): return json.loads(state_path.read_text())
def save(value): state_path.write_text(json.dumps(value,ensure_ascii=False))
def fake_keychain(*args,**kwargs): return {"access_token":"xoxp-TEST-ONLY","team_id":"T123"}
def fake_http(request):
    value=state()
    path=urllib.parse.urlsplit(request.full_url).path.rsplit("/",1)[-1]
    value["calls"].append(path)
    params=urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)
    if path=="auth.test": response={"ok":True,"team_id":"T123","user_id":"U123"}
    elif path=="conversations.replies": response={"ok":True,"messages":[value["message"]]}
    elif path=="chat.getPermalink":
        assert params=={"channel":["C123"],"message_ts":[value["message"]["ts"]]}
        response={"ok":True,"permalink":"https://example.slack.com/archives/C123/p1792034000000123"}
    elif path=="search.messages": response={"ok":True,"messages":{"matches":[{**value["message"],"channel":{"id":"C123","name":"general"}}]}}
    elif path=="chat.postMessage":
        assert request.get_method()=="POST"
        value["posts"].append(json.loads(request.data))
        save(value)
        if value.get("post_uncertain"): raise TimeoutError("TEST response lost after write")
        response={"ok":True,"channel":"C123","ts":"1792034001.000456"}
    else: raise AssertionError("Unexpected external API")
    save(value)
    return io.BytesIO(json.dumps(response).encode())
slack.keychain=fake_keychain
slack.http_open=fake_http
request=json.load(sys.stdin)
value=state();value["invocations"]+=1;value["last_request"]=request;save(value)
try: response=slack.run(request)
except slack.IntegrationError as error: response={"ok":False,"error":{"code":error.code,"message":str(error)}}
print(json.dumps(response,ensure_ascii=False))
'''


class SlackHost(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="awb-slack-", dir="/tmp")
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
        shutil.copyfile(ROOT / "plugins/slack/plugin.json", package / "plugin.json")
        shutil.copyfile(ROOT / "plugins/slack/plugin.py", package / "provider.py")
        (package / "plugin.py").write_text(WRAPPER)
        (package / "plugin.py").chmod(0o700)
        self.cli("plugin", "install", str(package))
        fixture_dir = self.data / "plugin-data/slack"
        fixture_dir.mkdir(parents=True)
        self.fixture = fixture_dir / "fixture.json"
        self.save({"message": {"ts": TS, "text": "Slack review request\nCheck completion criteria", "user": "U123"},
                   "invocations": 0, "calls": [], "posts": []})
        self.config = {"account": "test", "team_id": "T123", "messages_enabled": True, "send_enabled": True}
        self.cli("plugin", "enable", "slack", "--config", json.dumps(self.config))
        self.project = self.rpc("project.create", {"name": "Slack test"})["result"]["project"]["id"]

    def stop_service(self):
        if self.server.poll() is None:
            self.server.terminate()
            self.server.wait(timeout=5)

    def save(self, value):
        self.fixture.write_text(json.dumps(value, ensure_ascii=False))

    def state(self):
        return json.loads(self.fixture.read_text())

    def cli(self, *args, ok=True):
        result = subprocess.run([str(CLI), "--json", "--data-dir", str(self.data), "--socket", str(self.socket), *args],
                                text=True, capture_output=True, timeout=12)
        payload = json.loads(result.stdout)
        self.assertEqual(result.returncode == 0, ok, payload)
        return payload

    def rpc(self, method, params=None, **options):
        return self.cli("rpc", method, "--params", json.dumps(params or {}, ensure_ascii=False), **options)

    def plugin(self, method, params=None, request_id="slack-operation", **options):
        return self.cli("plugin", "run", "slack", method, "--params", json.dumps(params or {}, ensure_ascii=False),
                        "--request-id", request_id, **options)

    def task(self):
        return self.rpc("task.create", {"project_id": self.project, "title": "Original board task", "goal": "PRIVATE GOAL"})["result"]["task"]

    def detail(self, task_id):
        return self.rpc("task.get", {"task_id": task_id})["result"]

    def test_import_subtask_retry_and_removal_preserve_evidence(self):
        parent = self.task()
        params = {"project_id": self.project, "parent_id": parent["id"], "channel_id": "C123", "ts": TS}
        response = self.plugin("messages.import", params)
        task_id = response["result"]["applied"][0]["task_id"]
        detail = self.detail(task_id)
        self.assertEqual(detail["task"]["parent_id"], parent["id"])
        self.assertEqual(detail["task"]["status"], "todo")
        self.assertIn(self.state()["message"]["text"], detail["task"]["goal"])
        artifact = detail["artifacts"][0]
        self.assertEqual(artifact["path"], URL)
        self.assertEqual(artifact["provider"], "slack")
        self.assertEqual(artifact["metadata"]["ts"], TS)
        self.assertEqual(artifact["metadata"]["source_version"], response["result"]["result"]["version"])
        self.assertEqual(self.plugin("messages.import", params), response)
        self.assertEqual(self.state()["invocations"], 1)
        self.assertEqual(len(self.rpc("task.list")["result"]["tasks"]), 2)
        self.cli("plugin", "disable", "slack")
        self.assertEqual(self.plugin("messages.read", {"channel_id": "C123", "ts": TS}, ok=False)["error"]["code"], "PLUGIN_DISABLED")
        self.cli("plugin", "remove", "slack")
        self.assertEqual(self.detail(task_id)["artifacts"], detail["artifacts"])
        self.assertEqual(self.detail(parent["id"])["task"]["status"], "todo")
        self.assertEqual(self.state()["invocations"], 1)
        self.assertTrue(self.rpc("doctor")["ok"])

    def test_send_uses_current_host_task_ignores_forgery_and_replays_once(self):
        task = self.task()
        params = {"task_id": task["id"], "channel_id": "C123", "expected_revision": task["revision"],
                  "confirmed_by_user": True, "task": {"id": task["id"], "revision": task["revision"], "title": "FORGED"}}
        response = self.plugin("tasks.send", params)
        self.assertTrue(response["result"]["result"]["sent"])
        text = self.state()["posts"][0]["blocks"][0]["text"]["text"]
        self.assertIn(task["title"], text)
        self.assertNotIn("FORGED", text)
        self.assertNotIn("PRIVATE", text)
        self.assertEqual(self.state()["last_request"]["params"]["task"], self.detail(task["id"])["task"])
        self.assertEqual(self.plugin("tasks.send", params), response)
        self.assertEqual(len(self.state()["posts"]), 1)
        conflict = self.plugin("tasks.send", {**params, "channel_id": "COTHER"}, ok=False)
        self.assertEqual(conflict["error"]["code"], "REQUEST_ID_CONFLICT")
        self.assertEqual(len(self.state()["posts"]), 1)

    def test_send_stale_revision_stops_before_plugin_or_http(self):
        task = self.task()
        self.rpc("task.update", {"task_id": task["id"], "expected_revision": task["revision"], "title": "Changed elsewhere"})
        response = self.plugin("tasks.send", {"task_id": task["id"], "channel_id": "C123",
            "expected_revision": task["revision"], "confirmed_by_user": True}, ok=False)
        self.assertEqual(response["error"]["code"], "PLUGIN_REVISION_CONFLICT")
        self.assertEqual(self.state()["invocations"], 0)

    def test_lost_send_response_never_sends_again_automatically(self):
        task = self.task()
        self.save({**self.state(), "post_uncertain": True})
        params = {"task_id": task["id"], "channel_id": "C123", "confirmed_by_user": True}
        first = self.plugin("tasks.send", params, ok=False)
        self.assertEqual(first["error"]["code"], "INTEGRATION_UNAVAILABLE")
        second = self.plugin("tasks.send", params, ok=False)
        self.assertEqual(second["error"]["code"], "PLUGIN_RESULT_UNCERTAIN")
        self.assertEqual(len(self.state()["posts"]), 1)
        self.assertEqual(self.state()["invocations"], 1)
        self.assertTrue(self.rpc("doctor")["ok"])

    def test_read_version_then_source_edit_blocks_import(self):
        item = self.plugin("messages.read", {"channel_id": "C123", "ts": TS})["result"]["result"]
        state = self.state()
        state["message"]["text"] = "Source edited elsewhere"
        self.save(state)
        response = self.plugin("messages.import", {"channel_id": "C123", "ts": TS, "project_id": self.project,
            "expected_version": item["version"]}, request_id="changed-source", ok=False)
        self.assertEqual(response["error"]["code"], "CONFLICT")
        self.assertEqual(self.rpc("task.list")["result"]["tasks"], [])


if __name__ == "__main__":
    unittest.main()
