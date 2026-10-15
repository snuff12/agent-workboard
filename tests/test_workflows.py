"""Verify planning features through the actual CLI → service → isolated SQLite database."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "target/debug/workboard"
SERVICE = ROOT / "target/debug/workboard-service"


class Workflows(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="awb-flow-", dir="/tmp")
        self.directory = Path(self.temp.name)
        self.data = self.directory / "data"
        self.socket_path = self.directory / "s.sock"
        self.environment = dict(os.environ)
        for key in ("WORKBOARD_WIDGET_SNAPSHOT", "WORKBOARD_DATA_DIR", "WORKBOARD_SOCKET"):
            self.environment.pop(key, None)
        self.empty_path = self.directory / "empty-path"
        self.empty_path.mkdir()
        self.environment["PATH"] = str(self.empty_path)
        self.server = None
        self.start_server()
        self.project = self.cli("project", "add", "--name", "Planning verification")["result"]["project_id"]

    def start_server(self):
        self.server = subprocess.Popen(
            [str(SERVICE), "--data-dir", str(self.data), "--socket", str(self.socket_path)],
            cwd=self.directory, env=self.environment,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 5
        while True:
            self.assertIsNone(self.server.poll(), "The isolated service exited during startup")
            try:
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.connect(str(self.socket_path))
                return
            except OSError:
                self.assertLess(time.monotonic(), deadline, "Isolated service startup timed out")
                time.sleep(0.02)

    def stop_server(self):
        if self.server and self.server.poll() is None:
            self.server.terminate()
            self.server.wait(timeout=5)
        if self.socket_path.exists():
            self.socket_path.unlink()

    def tearDown(self):
        self.stop_server()
        self.temp.cleanup()

    def cli(self, *args, ok=True, request_id=None, revision=None):
        command = [str(CLI), "--json", "--data-dir", str(self.data), "--socket", str(self.socket_path)]
        if request_id is not None:
            command += ["--request-id", str(request_id)]
        if revision is not None:
            command += ["--expected-revision", str(revision)]
        result = subprocess.run(command + list(map(str, args)), cwd=self.directory,
                                env=self.environment, capture_output=True, text=True, timeout=15)
        self.assertTrue(result.stdout.strip(), (args, result.stderr))
        payload = json.loads(result.stdout)
        if ok is not None:
            self.assertEqual(payload["ok"], ok, (args, payload))
            self.assertEqual(result.returncode, 0 if ok else 1, (args, payload))
        return payload

    def rpc(self, method, params, **options):
        return self.cli("rpc", method, "--params", json.dumps(params, ensure_ascii=False), **options)

    def task(self, title, **options):
        arguments = ["task", "add", "--project", options.pop("project", self.project), "--title", title]
        for key, value in options.items():
            arguments += ["--" + key.replace("_", "-"), value]
        return self.cli(*arguments)["result"]["task"]

    def show(self, task):
        return self.cli("task", "show", task if isinstance(task, str) else task["id"])["result"]

    def revision(self, task):
        return self.show(task)["task"]["revision"]

    def task_ids(self, *arguments):
        return {t["id"] for t in self.cli("task", "list", *arguments)["result"]["tasks"]}

    def test_dependency_ready_cycle_completion_and_retry_guards(self):
        prerequisite = self.task("Verify prerequisite")
        dependent = self.task("Next task")
        args = ("task", "dependency", "add", dependent["id"], "--on", prerequisite["id"])
        linked = self.cli(*args, revision=1, request_id="link-once")
        self.assertEqual(linked, self.cli(*args, revision=1, request_id="link-once"))
        task = self.show(dependent)["task"]
        self.assertEqual(task["dependency_ids"], [prerequisite["id"]])
        self.assertEqual(task["blocked_by"], [prerequisite["id"]])
        self.assertFalse(task["ready"])
        self.assertNotIn(dependent["id"], self.task_ids("--ready"))
        self.assertIn(prerequisite["id"], {t["id"] for t in self.cli("task", "ready")["result"]["tasks"]})
        self.cli("task", "start", dependent["id"], ok=False)
        self.cli("task", "complete", dependent["id"], "--summary", "Prerequisite incomplete", ok=False)
        cycle = self.cli("task", "dependency", "add", prerequisite["id"], "--on", dependent["id"], revision=1, ok=False)
        self.assertIn("CYCLE", cycle["error"]["code"])
        stale = self.cli("task", "dependency", "remove", dependent["id"], "--on", prerequisite["id"], revision=1, ok=False)
        self.assertEqual(stale["error"]["code"], "REVISION_CONFLICT")
        self.cli("task", "complete", prerequisite["id"], "--summary", "Check prerequisite")
        self.assertTrue(self.show(dependent)["task"]["ready"])
        self.cli("task", "start", dependent["id"], "--run", "dependent-run")

    def test_template_atomic_tree_and_independent_checklists(self):
        builtins = self.cli("template", "list")["result"]["templates"]
        self.assertEqual({t["id"] for t in builtins}, {"builtin-bugfix", "builtin-feature", "builtin-research"})
        definition = {"title": "Release feature", "goal": "Verify behavior", "checklist": [{"text": "Final check", "required": True}],
                      "children": [{"title": "Core", "checklist": [{"text": "Check", "required": True}],
                                    "children": [{"title": "Conflict handling"}]}, {"title": "App"}]}
        path = self.directory / "definition.json"
        path.write_text(json.dumps(definition, ensure_ascii=False))
        saved = self.cli("template", "save", "--name", "My release procedure", "--file", path)["result"]["template"]
        args = ("template", "apply", saved["id"], "--project", self.project, "--title", "First release")
        first = self.cli(*args, request_id="apply-once")
        self.assertEqual(first, self.cli(*args, request_id="apply-once"))
        tasks = first["result"]["tasks"]
        self.assertEqual(len(tasks), 4)
        self.assertEqual(len(self.task_ids()), 4)
        root = first["result"]["task"]
        self.assertEqual(root["title"], "First release")
        child = next(t for t in tasks if t["title"] == "Core")
        self.assertEqual(child["parent_id"], root["id"])
        self.assertNotEqual(root["checklist"][0]["id"], child["checklist"][0]["id"])
        self.cli("task", "checklist", "check", child["id"], child["checklist"][0]["id"], revision=child["revision"])
        self.assertFalse(self.show(root)["task"]["checklist"][0]["checked"])
        copied = self.cli("template", "save", "--name", "Copy existing task", "--from-task", root["id"])["result"]["template"]
        self.assertEqual(len(copied["definition"]["children"]), 2)
        before = self.task_ids()
        invalid = {**definition, "children": [{"title": "Valid"}, {"title": ""}]}
        path.write_text(json.dumps(invalid))
        rejected = self.cli("template", "save", "--name", "Invalid definition", "--file", path, ok=False)
        self.assertEqual(rejected["error"]["code"], "INVALID_PARAMS")
        self.assertEqual(self.task_ids(), before)
        self.cli("template", "apply", saved["id"], "--project", "missing-project", ok=False)
        self.assertEqual(self.task_ids(), before)
        self.cli("template", "delete", saved["id"], revision=saved["revision"])

    def test_required_checklist_and_review_decisions_have_history(self):
        task = self.task("Task under review")
        added = self.cli("task", "checklist", "add", task["id"], "--text", "Check outcome", revision=1)["result"]["task"]
        item = added["checklist"][0]
        self.cli("task", "complete", task["id"], "--summary", "Skip verification", ok=False)
        self.rpc("task.update", {"task_id": task["id"], "status": "done", "completion_summary": "Bypass"},
                 revision=added["revision"], ok=False)
        self.cli("task", "checklist", "check", task["id"], item["id"], "--evidence", "Checks passed", revision=added["revision"])
        for decision in ("request-changes", "reject", "approve"):
            self.cli("task", "review", task["id"], "--summary", "Request confirmation", revision=self.revision(task))
            response = self.cli("task", "decide", task["id"], "--decision", decision, "--summary", f"Decision {decision}",
                                revision=self.revision(task), request_id=f"decision-{decision}")
            if decision == "approve":
                self.assertEqual(response["result"]["task"]["status"], "done")
            else:
                self.assertNotEqual(response["result"]["task"]["status"], "done")
            if decision == "reject":
                self.cli("task", "update", task["id"], "--blocked-reason", "", revision=self.revision(task))
        detail = self.show(task)
        self.assertEqual([d["decision"] for d in detail["review_decisions"]], ["request_changes", "reject", "approve"])
        self.assertTrue(all(d["summary"] for d in detail["review_decisions"]))
        self.cli("task", "checklist", "update", task["id"], item["id"], "--text", "Corrected check", "--required", "false",
                 "--clear-evidence", revision=self.revision(task))
        self.assertIsNone(self.show(task)["task"]["checklist"][0]["evidence"])

    def test_inbox_preserves_capture_and_promotes_once_across_restart(self):
        missing_source = self.directory / "Unread source.txt"
        capture = ("inbox", "capture", "--title", "Quick idea", "--source", str(missing_source), "--note", "Source note")
        response = self.cli(*capture, request_id="capture-once")
        self.assertEqual(response, self.cli(*capture, request_id="capture-once"))
        item = response["result"]["item"]
        self.assertEqual(self.task_ids(), set())
        self.stop_server()
        self.start_server()
        loaded = self.cli("inbox", "list", "--status", "pending")["result"]["items"]
        self.assertEqual(loaded[0]["note"], "Source note")
        promoted = self.cli("inbox", "promote", item["id"], "--project", self.project,
                            revision=item["revision"], request_id="promote-once")
        self.assertEqual(promoted, self.cli("inbox", "promote", item["id"], "--project", self.project,
                                          revision=item["revision"], request_id="promote-once"))
        self.cli("inbox", "promote", item["id"], "--project", self.project, ok=None)
        self.assertEqual(len(self.task_ids()), 1)
        self.assertEqual(promoted["result"]["item"]["source"], str(missing_source))
        self.assertEqual(promoted["result"]["item"]["note"], "Source note")
        self.assertEqual(promoted["result"]["item"]["status"], "processed")
        ignored = self.cli("inbox", "capture", "--title", "Idea to dismiss")["result"]["item"]
        self.cli("inbox", "dismiss", ignored["id"], revision=ignored["revision"])
        self.assertEqual(len(self.cli("inbox", "list", "--status", "dismissed")["result"]["items"]), 1)
        self.assertFalse(missing_source.exists())

    def test_saved_view_filters_and_layout_survive_restart(self):
        a = self.task("Verify important task")
        self.cli("task", "claim", a["id"], "--agent", "codex")
        self.task("Another task")
        view = self.cli("view", "save", "--name", "My ready tasks", "--project", self.project,
                        "--status", "todo", "--assignee", "codex", "--ready", "--query", "important",
                        "--layout", "week")["result"]["view"]
        self.assertEqual(self.task_ids("--view", view["id"]), {a["id"]})
        prerequisite = self.task("Prerequisite")
        self.cli("task", "dependency", "add", a["id"], "--on", prerequisite["id"], revision=self.revision(a))
        self.assertEqual(self.task_ids("--view", view["id"]), set())
        self.assertEqual(self.task_ids("--view", view["id"], "--ready", "false"), {a["id"]})
        self.cli("task", "dependency", "remove", a["id"], "--on", prerequisite["id"], revision=self.revision(a))
        self.stop_server()
        self.start_server()
        loaded = self.cli("view", "list")["result"]["views"]
        self.assertEqual(loaded[0]["layout"], "week")
        self.assertEqual(self.task_ids("--view", view["id"]), {a["id"]})
        self.assertEqual(self.task_ids("--view", view["id"], "--status", "done"), set())
        self.assertEqual(len(self.task_ids("--stale-days", "0")), 3)
        self.assertEqual(self.task_ids("--stale-days", "1"), set())
        self.cli("view", "delete", view["id"], revision=view["revision"])
        self.assertEqual(self.cli("view", "list")["result"]["views"], [])

    def test_schedule_preview_overlap_dst_exclusive_end_and_self_done_exclusion(self):
        meeting = self.task("DST overlap", scheduled_start="2026-11-01T01:30:00-04:00",
                            scheduled_end="2026-11-01T01:30:00-05:00", time_zone="America/New_York")
        preview = ("task", "schedule-preview", "--starts", "2026-11-01T01:15:00-05:00",
                   "--ends", "2026-11-01T01:45:00-05:00", "--time-zone", "America/New_York")
        self.assertTrue(self.cli(*preview)["result"]["has_conflicts"])
        self.assertFalse(self.cli(*preview, meeting["id"])["result"]["has_conflicts"])
        self.cli("task", "complete", meeting["id"], "--summary", "Meeting complete")
        self.assertFalse(self.cli(*preview)["result"]["has_conflicts"])
        all_day = self.task("All-day event", scheduled_start="2026-11-01", scheduled_end="2026-11-02", time_zone="America/New_York")
        adjacent = self.cli("task", "schedule-preview", "--starts", "2026-11-02", "--ends", "2026-11-03",
                            "--time-zone", "America/New_York")["result"]
        self.assertFalse(adjacent["has_conflicts"], "All-day event end date must be exclusive")
        self.assertTrue(self.cli("task", "schedule-preview", "--starts", "2026-11-01", "--ends", "2026-11-02",
                                "--time-zone", "America/New_York")["result"]["has_conflicts"])
        self.assertEqual(self.show(all_day)["task"]["scheduled_end"], "2026-11-02", "Preview must not save")
        self.cli("task", "schedule-preview", "--starts", "2026-11-03", "--ends", "2026-11-02",
                 "--time-zone", "America/New_York", ok=False)

    def test_backup_restore_preserves_new_workflow_data(self):
        a, b = self.task("A"), self.task("B")
        self.cli("task", "dependency", "add", b["id"], "--on", a["id"], revision=1)
        self.cli("task", "checklist", "add", a["id"], "--text", "Required", revision=1)
        self.cli("task", "review", a["id"], "--summary", "Request confirmation", revision=self.revision(a))
        self.cli("task", "decide", a["id"], "--decision", "request-changes", "--summary", "Additional review needed",
                 revision=self.revision(a))
        review_history = self.show(a)["review_decisions"]
        self.cli("inbox", "capture", "--title", "Backup capture", "--note", "Note")
        self.cli("view", "save", "--name", "Blocked", "--blocked", "--layout", "list")
        self.cli("template", "save", "--name", "Copy A", "--from-task", a["id"])
        before = self.cli("board")["result"]
        backup = self.directory / "new-features.sqlite3"
        self.cli("backup", "create", backup)
        self.task("After backup")
        self.cli("backup", "restore", backup)
        self.stop_server()
        self.start_server()
        restored = self.cli("board")["result"]
        for key in ("inbox", "views", "templates"):
            original = {item["id"]: item for item in before[key]}
            self.assertEqual({item["id"] for item in restored[key]}, set(original), key)
            for item in restored[key]:
                self.assertGreater(item["revision"], original[item["id"]]["revision"])
                self.assertEqual({k: v for k, v in item.items() if k != "revision"},
                                 {k: v for k, v in original[item["id"]].items() if k != "revision"}, key)
        self.assertEqual(self.show(b)["task"]["dependency_ids"], [a["id"]])
        self.assertEqual(self.show(a)["task"]["checklist"][0]["text"], "Required")
        self.assertEqual(self.show(a)["review_decisions"], review_history)
        self.assertEqual(self.task_ids("--blocked"), {b["id"]})

    def test_template_and_view_updates_preserve_request_and_revision_guards(self):
        path = self.directory / "saved.json"
        path.write_text('{"title":"Original template"}')
        template = self.cli("template", "save", "--name", "Original", "--file", path)["result"]["template"]
        args = ("template", "save", "--id", template["id"], "--name", "Correction", "--file", path)
        updated = self.cli(*args, revision=template["revision"], request_id="template-update")
        self.assertEqual(updated, self.cli(*args, revision=template["revision"], request_id="template-update"))
        stale = self.cli("template", "delete", template["id"], revision=template["revision"], ok=False)
        self.assertEqual(stale["error"]["code"], "REVISION_CONFLICT")
        stale = self.cli("template", "apply", template["id"], "--project", self.project,
                         revision=template["revision"], ok=False)
        self.assertEqual(stale["error"]["code"], "REVISION_CONFLICT")
        self.assertEqual(self.task_ids(), set())
        self.cli("template", "apply", template["id"], "--project", self.project,
                 revision=updated["result"]["template"]["revision"])
        view = self.cli("view", "save", "--name", "Original view")["result"]["view"]
        saved = self.cli("view", "save", "--id", view["id"], "--name", "Edited view", "--blocked",
                         revision=view["revision"], request_id="view-update")
        self.assertEqual(saved, self.cli("view", "save", "--id", view["id"], "--name", "Edited view", "--blocked",
                                        revision=view["revision"], request_id="view-update"))
        stale = self.cli("view", "delete", view["id"], revision=view["revision"], ok=False)
        self.assertEqual(stale["error"]["code"], "REVISION_CONFLICT")
        self.assertEqual(self.cli("view", "list")["result"]["views"][0]["name"], "Edited view")

    def test_deletion_with_workflow_links_survives_cli_retries_and_restart(self):
        item = self.cli("inbox", "capture", "--title", "Task to delete", "--note", "Note to preserve")["result"]["item"]
        promoted = self.cli("inbox", "promote", item["id"], "--project", self.project)["result"]
        root = promoted["task"]
        child = self.task("Subtask", parent=root["id"])
        self.cli("task", "checklist", "add", child["id"], "--text", "Completion check", revision=child["revision"])
        survivor = self.task("Task to continue")
        self.cli("task", "dependency", "add", survivor["id"], "--on", child["id"], revision=survivor["revision"])
        before = self.show(survivor)["task"]
        arguments = ("task", "delete", root["id"], "--with-subtasks")
        deleted = self.cli(*arguments, request_id="delete-tree", revision=self.revision(root))
        self.assertEqual(self.task_ids(), {survivor["id"]})
        after = self.show(survivor)["task"]
        self.assertTrue(after["ready"])
        self.assertEqual(after["dependency_ids"], [])
        self.assertGreater(after["revision"], before["revision"])
        self.assertEqual(self.cli("task", "update", survivor["id"], "--title", "Stale edit",
                                  revision=before["revision"], ok=False)["error"]["code"], "REVISION_CONFLICT")
        self.stop_server()
        self.start_server()
        self.assertEqual(deleted, self.cli(*arguments, request_id="delete-tree", revision=root["revision"]))
        archived = self.cli("inbox", "list")["result"]["items"][0]
        self.assertEqual(archived["note"], "Note to preserve")
        self.assertEqual(archived["status"], "processed")
        self.assertIsNone(archived["task_id"])
        self.assertEqual(self.cli("inbox", "promote", item["id"], "--project", self.project,
                                  revision=archived["revision"], ok=False)["error"]["code"], "INVALID_STATE")
        self.cli("task", "checklist", "add", survivor["id"], "--text", "Cleanup", revision=after["revision"])
        self.cli("project", "delete", self.project, "--with-tasks")
        self.assertEqual(self.cli("project", "list")["result"]["projects"], [])

    def test_invalid_template_file_fails_before_starting_a_service(self):
        unused_data = self.directory / "never-started"
        path = self.directory / "invalid.json"
        for content in ("{broken", "[]"):
            path.write_text(content)
            result = subprocess.run([str(CLI), "--json", "--data-dir", str(unused_data),
                                     "--socket", str(self.directory / "unused.sock"), "--request-id", "bad-file",
                                     "template", "save", "--name", "Invalid file", "--file", str(path)],
                                    cwd=self.directory, env=self.environment, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["error"]["code"], "INVALID_PARAMS")
            self.assertEqual(payload["request_id"], "bad-file")
            self.assertFalse(unused_data.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
