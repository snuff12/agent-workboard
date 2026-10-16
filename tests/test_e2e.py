"""Development checks connecting the actual Rust CLI, service, and external plugin processes."""
import concurrent.futures
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "target/debug/workboard"
SERVICE = ROOT / "target/debug/workboard-service"


class EndToEnd(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="awb-", dir="/tmp")
        self.data = Path(self.temp.name) / "data"
        self.socket = Path(self.temp.name) / "s.sock"
        self.environment = dict(os.environ)
        self.environment.pop("WORKBOARD_WIDGET_SNAPSHOT", None)
        empty_path = Path(self.temp.name) / "no-external-cli"
        empty_path.mkdir()
        self.core_environment = {**self.environment, "PATH": str(empty_path)}
        self.server = None
        self.start_server()

    def start_server(self):
        self.server = subprocess.Popen([str(SERVICE), "--data-dir", str(self.data), "--socket", str(self.socket)],
                                       env=self.core_environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(150):
            if self.socket.exists():
                return
            if self.server.poll() is not None:
                self.fail("The service exited during startup")
            time.sleep(0.02)
        self.fail("The service socket was not created")

    def stop_server(self):
        if self.server and self.server.poll() is None:
            self.server.terminate()
            self.server.wait(timeout=5)
        if self.socket.exists():
            self.socket.unlink()

    def tearDown(self):
        self.stop_server()
        self.temp.cleanup()

    def cli(self, *args, ok=True):
        result = subprocess.run([str(CLI), "--data-dir", str(self.data), "--socket", str(self.socket),
                                 "--json", *map(str, args)], text=True, capture_output=True, timeout=15,
                                env=self.environment if args[0] == "plugin" else self.core_environment)
        payload = json.loads(result.stdout)
        if ok:
            self.assertEqual(result.returncode, 0, payload)
            self.assertTrue(payload["ok"], payload)
        else:
            self.assertFalse(payload["ok"], payload)
        return payload

    def rpc(self, method, params=None, ok=True, request_id=None):
        args = ["rpc", method, "--params", json.dumps(params or {}, ensure_ascii=False)]
        if request_id:
            args += ["--request-id", request_id]
        return self.cli(*args, ok=ok)

    def project(self):
        return self.rpc("project.create", {"name": "Verify actual integration", "directory": str(ROOT)})["result"]["project_id"]

    def test_cli_next_action_and_delete_commands(self):
        project = self.project()
        parent = self.cli("task", "add", "--project", project, "--title", "Parent task to delete",
                          "--next-action", "Clean up subtasks")["result"]["task"]
        self.assertEqual(parent["next_action"], "Clean up subtasks")
        child = self.cli("task", "add", "--project", project, "--title", "Child", "--parent", parent["id"])["result"]["task_id"]
        refused = self.cli("task", "delete", parent["id"], ok=False)
        self.assertEqual(refused["error"]["code"], "HAS_SUBTASKS")
        deleted = self.cli("task", "delete", parent["id"], "--with-subtasks",
                           "--expected-revision", parent["revision"])["result"]
        self.assertEqual(deleted["deleted_task_ids"], [parent["id"], child])
        self.cli("task", "show", child, ok=False)
        trash = self.cli("trash", "list")["result"]["items"]
        self.assertEqual([item["task"]["id"] for item in trash], [parent["id"]])
        self.assertEqual(trash[0]["subtask_count"], 1)
        self.assertEqual(self.cli("trash", "restore", child, ok=False)["error"]["code"], "INVALID_STATE")
        restored = self.cli("trash", "restore", parent["id"])["result"]
        self.assertEqual(restored["restored_task_ids"], [parent["id"], child])
        self.assertEqual(self.cli("task", "show", child)["result"]["task"]["parent_id"], parent["id"])
        self.cli("task", "delete", parent["id"], "--with-subtasks")
        purged = self.cli("trash", "delete", parent["id"])["result"]
        self.assertEqual(purged["deleted_task_ids"], [parent["id"], child])
        self.assertEqual(self.cli("trash", "delete", parent["id"], ok=False)["error"]["code"], "NOT_FOUND")
        self.assertEqual(self.cli("trash", "empty")["result"]["deleted_task_ids"], [])
        kept = self.cli("task", "add", "--project", project, "--title", "With the project")["result"]["task_id"]
        trashed = self.cli("task", "add", "--project", project, "--title", "Trashed with the project")["result"]["task_id"]
        self.cli("task", "delete", trashed)
        refused = self.cli("project", "delete", project, ok=False)["error"]
        self.assertEqual(refused["code"], "HAS_TASKS")
        self.assertIn("1 in the trash", refused["message"])
        self.assertEqual(set(self.cli("project", "delete", project, "--with-tasks")["result"]["deleted_task_ids"]), {kept, trashed})
        self.assertEqual(self.cli("trash", "list")["result"]["items"], [])
        self.assertEqual(self.cli("project", "list")["result"]["projects"], [])

    def test_task_hierarchy_retry_restore_and_resume(self):
        project = self.project()
        parent = self.rpc("task.create", {"project_id": project, "title": "Implement the kanban board"})["result"]["task_id"]
        params = {"project_id": project, "parent_id": parent, "title": "Connect the widget", "completion_criteria": "Show the native widget"}
        created = self.rpc("task.create", params, request_id="same-create")
        child = created["result"]["task_id"]
        self.assertEqual(created, self.rpc("task.create", params, request_id="same-create"))
        changed = self.rpc("task.create", {**params, "title": "Another request"}, request_id="same-create", ok=False)
        self.assertIn("CONFLICT", changed["error"]["code"])
        self.cli("task", "claim", child, "--agent", "codex")
        started = self.cli("task", "start", child, "--agent", "codex")["result"]
        self.rpc("run.finish", {"task_id": child, "run_id": started["run_id"], "agent_id": "codex", "summary": "Response turn ended"})
        self.assertEqual(self.cli("task", "show", child)["result"]["task"]["status"], "in_progress")
        self.rpc("task.attach", {"task_id": child, "path": str(ROOT / "README.md"), "metadata": {"provider": "local", "locator": "L1"}})
        self.rpc("task.pause", {"task_id": child, "agent_id": "codex", "next_action": "Verify widget display", "summary": "Interrupted"})
        backup = Path(self.temp.name) / "backup.sqlite3"
        self.cli("backup", "create", backup)
        self.stop_server()
        self.start_server()
        context = self.cli("task", "resume-context", child)["result"]
        self.assertEqual(context["task"]["next_action"], "Verify widget display")
        self.assertEqual(context["artifacts"][0]["metadata"]["locator"], "L1")
        self.cli("task", "complete", child, "--agent", "codex", "--summary", "Verification complete")
        self.assertEqual(self.cli("task", "show", parent)["result"]["task"]["status"], "todo")
        self.cli("backup", "restore", backup)
        self.assertEqual(self.cli("task", "show", child)["result"]["task"]["status"], "todo")
        self.assertEqual(len(self.rpc("task.list", {"query": "Widget"})["result"]["tasks"]), 1)
        snapshot = json.loads((self.data / "widget-snapshot.json").read_text())
        self.assertTrue(snapshot["tasks"])
        exported = Path(self.temp.name) / "board.md"
        self.cli("export", "--path", exported, "--format", "markdown")
        self.assertIn("Connect the widget", exported.read_text())

    def test_concurrent_claim_and_revision_conflict(self):
        task = self.rpc("task.create", {"project_id": self.project(), "title": "Concurrent request"})["result"]["task_id"]
        def claim(agent):
            return self.rpc("task.claim", {"task_id": task, "agent_id": agent}, ok=None)
        def raw_claim(agent):
            result = subprocess.run([str(CLI), "--data-dir", str(self.data), "--socket", str(self.socket), "--json", "task", "claim", task, "--agent", agent], capture_output=True, text=True, env=self.core_environment)
            return json.loads(result.stdout)
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            responses = list(pool.map(raw_claim, ["codex", "claude"]))
        self.assertEqual(sum(r["ok"] for r in responses), 1)
        task_info = self.rpc("task.get", {"task_id": task})["result"]["task"]
        rejected = self.rpc("task.update", {"task_id": task, "expected_revision": task_info["revision"] - 1, "title": "Stale edit"}, ok=False)
        self.assertIn("CONFLICT", rejected["error"]["code"])

    def test_cli_run_identity_rejects_late_completion_and_allows_current_review(self):
        task = self.rpc("task.create", {"project_id": self.project(), "title": "Distinguish runs"})["result"]["task_id"]
        self.cli("task", "start", task, "--agent", "codex", "--run", "old-run")
        self.cli("task", "start", task, "--agent", "codex", "--run", "current-run")
        revision = self.cli("task", "show", task)["result"]["task"]["revision"]
        rejected = self.cli("task", "complete", task, "--agent", "codex", "--run", "old-run",
                            "--summary", "Late completion", "--expected-revision", revision, ok=False)
        self.assertEqual(rejected["error"]["code"], "RUN_CONFLICT")
        self.cli("task", "review", task, "--agent", "codex", "--run", "current-run",
                 "--summary", "Review current run", "--expected-revision", revision)
        current = self.cli("task", "show", task)["result"]["task"]
        self.assertEqual(current["status"], "review")
        self.cli("task", "complete", task, "--agent", "codex", "--run", "current-run",
                 "--summary", "Complete current run", "--expected-revision", current["revision"])
        self.assertEqual(self.cli("task", "show", task)["result"]["task"]["status"], "done")

    def plugin_package(self, name="probe", body=None):
        package = Path(self.temp.name) / name
        package.mkdir()
        (package / "plugin.json").write_text(json.dumps({"id": name, "name": "Test plugin", "version": "1.0", "protocol_version": 1,
            "executable": "run.sh", "methods": ["check"], "allowed_requests": []}))
        executable = package / "run.sh"
        executable.write_text(body or '#!/bin/sh\ncat >/dev/null\nprintf \'{"ok":true,"result":{"live":true}}\'\n')
        executable.chmod(0o700)
        return package

    def test_plugin_separate_install_disabled_and_remove_preserves_tasks(self):
        project = self.project()
        self.rpc("task.create", {"project_id": project, "title": "Task to preserve"})
        self.assertEqual(self.cli("plugin", "list")["result"]["plugins"], [])
        self.assertFalse((self.data / "plugins").exists())
        self.cli("plugin", "install", self.plugin_package())
        blocked = self.cli("plugin", "check", "probe", ok=False)
        self.assertEqual(blocked["error"]["code"], "PLUGIN_DISABLED")
        self.cli("plugin", "enable", "probe")
        self.assertTrue(self.cli("plugin", "check", "probe")["result"]["result"]["live"])
        self.cli("plugin", "remove", "probe")
        self.assertEqual(len(self.cli("board")["result"]["tasks"]), 1)
        self.cli("doctor")

    def test_plugin_disable_cancels_running_process(self):
        package = self.plugin_package(body='#!/bin/sh\ncat >/dev/null\nsleep 8\nprintf \'{"ok":true,"result":{}}\'\n')
        self.cli("plugin", "install", package)
        self.cli("plugin", "enable", "probe")
        process = subprocess.Popen([str(CLI), "--data-dir", str(self.data), "--socket", str(self.socket), "--json", "plugin", "check", "probe"], text=True, stdout=subprocess.PIPE)
        time.sleep(0.15)
        self.cli("plugin", "disable", "probe")
        stdout, _ = process.communicate(timeout=3)
        self.assertEqual(json.loads(stdout)["error"]["code"], "PLUGIN_DISABLED")


if __name__ == "__main__":
    unittest.main(verbosity=2)
