"""Actual service/host/Orca-plugin workflow checks using harmless local agent processes."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "target/debug/workboard"
SERVICE = ROOT / "target/debug/workboard-service"
# One worker may take 40 seconds; a complete flow can execute six stages.
STEP_WAIT = 60
WORKFLOW_WAIT = 300

ORCA = r'''#!__PYTHON__
import json
import os
from pathlib import Path
import subprocess
import sys
import time
state=Path(__STATE__)
repo=Path(__REPO__)
args=sys.argv[1:]
with (state/"calls").open("a") as file: file.write(json.dumps(args)+"\n")
worktree={"id":"repo::"+str(repo),"repoId":"repo","projectId":"project","hostId":"local","path":str(repo),"instanceId":"instance","displayName":"Automation fixture","branch":"main","head":"fixture"}
if args[:2]==["repo","list"]:
    result={"repos":[{"id":"repo","path":str(repo),"displayName":"Automation fixture"}]}
elif args[:2]==["worktree","show"]:
    result={"worktree":worktree}
elif args[:2]==["terminal","create"]:
    output=(state/"agent-output").open("ab")
    child=subprocess.Popen(["/bin/sh","-c",args[args.index("--command")+1]],cwd=repo,stdout=output,stderr=output,start_new_session=True)
    with (state/"pids").open("a") as file: file.write(str(child.pid)+"\n")
    time.sleep(0.2)
    result={"terminal":{"handle":"fixture-"+str(child.pid),"worktreeId":worktree["id"],"title":args[args.index("--title")+1]}}
else:
    print(json.dumps({"ok":False,"error":{"message":"Unsupported fixture command"}}));sys.exit(1)
print(json.dumps({"ok":True,"result":result}))
'''

AGENT = r'''import json
import os
from pathlib import Path
import subprocess
import sys
import time
state=Path(__STATE__)
repo=Path(__REPO__)
cli=__CLI__
(state/("prompt-"+os.environ["WORKBOARD_AUTOMATION_ATTEMPT"]+".txt")).write_text(sys.argv[1])
mode=(state/"mode").read_text() if (state/"mode").exists() else "normal"
if mode=="exit": sys.exit(0)
if mode=="hold":
    (state/"waiting").touch()
    deadline=time.monotonic()+300
    while not (state/"continue").exists():
        if time.monotonic()>=deadline: raise RuntimeError("Fixture continuation signal was not received")
        time.sleep(.02)
task=os.environ["WORKBOARD_AUTOMATION_TASK"]
response=subprocess.check_output([cli,"automation","show",task,"--json"])
workflow=json.loads(response)["result"]["automation"]
stage=workflow["stage"]
if "WORKBOARD_AUTOMATION_TOKEN" in os.environ: sys.exit(79)
if stage in ("work","rework"): (repo/"feature.txt").write_text("implemented\n" if stage=="work" else "reviewed implementation\n")
reviews=sum(1 for entry in workflow["attempts"] if entry["stage"]=="review")
outcome="changes_requested" if stage=="review" and reviews==1 else "pass"
report=state/("report-"+os.environ["WORKBOARD_AUTOMATION_ATTEMPT"]+".txt")
report.write_text("Verified "+stage+" with fixture checks.\n")
selection=["--preset-id","small","--selection-reason","A narrow fixture change with independent review"] if stage=="select" else []
code=subprocess.call([cli,"automation","report","--source-dir",str(repo),"--outcome",outcome,"--summary","Verified "+stage,"--evidence",str(report),"--request-id","stage-report:"+os.environ["WORKBOARD_AUTOMATION_ATTEMPT"],"--json"]+selection)
sys.exit(code)
'''


class AutomationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wb-auto-", dir="/tmp")
        self.directory = Path(self.temp.name)
        self.repo = self.directory / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        (self.repo / "feature.txt").write_text("initial\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Workflow fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "Initial fixture"], check=True)
        self.env = {key: value for key, value in os.environ.items() if key not in (
            "WORKBOARD_AGENT", "CODEX_THREAD_ID", "WORKBOARD_SOCKET", "WORKBOARD_DATA_DIR", "WORKBOARD_WIDGET_SNAPSHOT",
            "WORKBOARD_AUTOMATION_TASK", "WORKBOARD_AUTOMATION_ATTEMPT", "WORKBOARD_AUTOMATION_TOKEN")}
        self.env["WORKBOARD_DATA_DIR"] = str(self.directory / "board")
        self.env["WORKBOARD_SOCKET"] = str(self.directory / "board.sock")
        self.env["WORKBOARD_CLI_BIN"] = str(CLI)
        self.log = (self.directory / "service.log").open("ab")
        self.service = subprocess.Popen([str(SERVICE)], env=self.env, stdout=self.log, stderr=self.log)
        self.wait(lambda: Path(self.env["WORKBOARD_SOCKET"]).exists())
        self.orca = self.directory / "orca"
        self.orca.write_text(ORCA.replace("__PYTHON__", sys.executable).replace("__STATE__", repr(str(self.directory))).replace("__REPO__", repr(str(self.repo))))
        self.orca.chmod(0o700)
        self.agent = self.directory / "agent.py"
        self.agent.write_text(AGENT.replace("__STATE__", repr(str(self.directory))).replace("__REPO__", repr(str(self.repo))).replace("__CLI__", repr(str(CLI))))
        self.cli("plugin", "install", str(ROOT / "plugins/orca"))
        self.enable()
        project = self.cli("project", "add", "--name", "Automation fixture", "--directory", str(self.repo))["project_id"]
        self.task = self.cli("task", "add", "--project", project, "--title", "Verify development workflow", "--goal", "Implement the fixture", "--completion-criteria", "Verify implementation, review, and release preparation")["task_id"]
        self.configure()

    def tearDown(self):
        if self.service.poll() is None:
            self.service.terminate()
            self.service.wait(timeout=10)
        if (self.directory / "pids").exists():
            for pid in (self.directory / "pids").read_text().splitlines():
                try:
                    os.killpg(int(pid), signal.SIGTERM)
                except ProcessLookupError:
                    pass
        self.log.close()
        self.temp.cleanup()

    def cli(self, *args, ok=True):
        result = subprocess.run([str(CLI), *args, "--json"], env=self.env, capture_output=True, text=True, timeout=40)
        response = json.loads(result.stdout)
        if ok:
            self.assertTrue(response["ok"], response)
            return response["result"]
        return response

    def enable(self):
        self.cli("plugin", "enable", "orca", "--executable", str(self.orca), "--config", json.dumps({"repos": ["id:repo"], "automation_agent_commands": {"codex": [sys.executable, str(self.agent)]}}))

    def configure(self):
        self.cli("automation", "configure", self.task, "--executor", "orca", "--resource-key", "repo::" + str(self.repo), "--params", json.dumps({"worktree_id": "repo::" + str(self.repo), "agent": "codex", "reviewer": "codex"}))

    def workflow(self):
        return self.cli("automation", "show", self.task)["automation"]

    def wait(self, predicate, timeout=STEP_WAIT):
        started = time.monotonic()
        while time.monotonic() - started < timeout:
            if predicate():
                return
            time.sleep(.05)
        logs = (self.directory / "agent-output").read_text() if (self.directory / "agent-output").exists() else ""
        self.fail("Condition timed out. Agent output: " + logs[-3000:])

    def launches(self):
        return sum(json.loads(line)[:2] == ["terminal", "create"] for line in (self.directory / "calls").read_text().splitlines()) if (self.directory / "calls").exists() else 0

    def test_agent_selection_runs_the_chosen_small_process_with_real_wrapper(self):
        self.cli("automation", "configure", self.task, "--executor", "orca", "--resource-key", "repo::" + str(self.repo),
                 "--params", json.dumps({"worktree_id": "repo::" + str(self.repo), "agent": "codex"}),
                 "--process-preset", "auto", "--allowed-presets", "small,standard")
        self.cli("automation", "start", self.task)
        self.wait(lambda: self.workflow()["state"] in ("awaiting_approval", "blocked"), timeout=WORKFLOW_WAIT)
        workflow = self.workflow()
        self.assertEqual(workflow["state"], "awaiting_approval", workflow["message"])
        self.assertEqual(workflow["process"]["preset"]["id"], "small")
        self.assertEqual(workflow["process"]["selected_by"], "agent")
        self.assertIn("narrow fixture", workflow["process"]["selection_reason"])
        self.assertEqual([a["stage"] for a in workflow["attempts"]], ["select", "work", "review", "rework", "review"])
        selection_prompt = (self.directory / ("prompt-" + workflow["attempts"][0]["id"] + ".txt")).read_text()
        self.assertIn("Authorized process candidates", selection_prompt)
        self.assertNotIn('"id": "large"', selection_prompt)
        self.assertTrue(all(a["worker_exited"] for a in workflow["attempts"]))

    def test_preset_cli_library_and_creation_override_with_manual_opt_out(self):
        preset = self.cli("automation", "preset", "show", "small")["preset"]
        preset.update(id="docs-check", name="Documentation check", when_to_use="Documentation edits")
        path = self.directory / "preset.json"; path.write_text(json.dumps(preset))
        saved = self.cli("automation", "preset", "save", "--file", str(path))["preset"]
        self.assertFalse(saved["builtin"])
        project = self.cli("task", "show", self.task)["task"]["project_id"]
        config = self.workflow()["configuration"]
        config["process_preset"] = "standard"
        configuration = self.directory / "defaults.json"; configuration.write_text(json.dumps(config))
        self.cli("automation", "set-defaults", project, "--configuration", str(configuration), "--enabled", "false")
        self.task = self.cli("task", "add", "--project", project, "--title", "Custom process task", "--process-preset", "docs-check", "--preset-reason", "Only documentation changes")["task_id"]
        self.assertEqual(self.workflow()["process"]["preset"]["id"], "docs-check")
        self.cli("automation", "preset", "apply", self.task, "--preset", "large", "--reason", "Expanded scope")
        self.assertEqual(self.workflow()["process"]["preset"]["id"], "large")
        self.cli("automation", "preset", "delete", "docs-check")
        manual = self.cli("template", "apply", "builtin-feature", "--project", project, "--automation", "manual")
        snapshot = self.cli("board")
        family = {manual["task"]["id"], *(t["id"] for t in snapshot["tasks"] if t.get("parent_id") == manual["task"]["id"])}
        self.assertFalse(any(a["task_id"] in family for a in snapshot["automations"]))
        self.assertEqual(len(snapshot["process_presets"]), 3)

    def test_control_and_library_retries_preserve_the_original_revisions(self):
        arguments = ("automation", "disable", self.task, "--request-id", "retry-disable")
        first = self.cli(*arguments)
        self.assertEqual(self.cli(*arguments), first)
        preset = self.cli("automation", "preset", "show", "small")["preset"]
        preset.update(id="retry-preset", name="Retry preset")
        path = self.directory / "retry-preset.json"; path.write_text(json.dumps(preset))
        save = ("automation", "preset", "save", "--file", str(path), "--request-id", "retry-save")
        saved = self.cli(*save)
        self.assertEqual(self.cli(*save), saved)
        delete = ("automation", "preset", "delete", "retry-preset", "--request-id", "retry-delete")
        deleted = self.cli(*delete)
        self.assertEqual(self.cli(*delete), deleted)
        conflict = self.cli("automation", "preset", "apply", self.task, "--preset", "small", "--reason", "Changed request", "--request-id", "retry-disable", ok=False)
        self.assertFalse(conflict["ok"])
        project = self.cli("task", "show", self.task)["task"]["project_id"]
        config = self.workflow()["configuration"]
        path = self.directory / "retry-defaults.json"; path.write_text(json.dumps(config))
        defaults = ("automation", "set-defaults", project, "--configuration", str(path), "--request-id", "retry-defaults")
        first = self.cli(*defaults)
        self.assertEqual(self.cli(*defaults), first)

    def test_preset_apply_identifies_the_cli_agent_and_checks_assignment(self):
        self.cli("task", "claim", self.task, "--agent", "owner")
        self.env["WORKBOARD_AGENT"] = "other"
        refused = self.cli("automation", "preset", "apply", self.task, "--preset", "small", "--reason", "A narrow fix", ok=False)
        self.assertFalse(refused["ok"], "The CLI omitted the agent identity")
        self.assertEqual(refused["error"]["code"], "CLAIM_CONFLICT")
        self.env["WORKBOARD_AGENT"] = "owner"
        self.cli("automation", "preset", "apply", self.task, "--preset", "small", "--reason", "A narrow fix")
        self.assertEqual(self.workflow()["process"]["selected_by"], "owner")
        project = self.cli("task", "show", self.task)["task"]["project_id"]
        config = self.workflow()["configuration"]
        self.cli("rpc", "automation.defaults.set", "--params", json.dumps({"project_id": project, "configuration": config, "enabled": True, "expected_defaults_revision": 0}))
        created = self.cli("task", "add", "--project", project, "--title", "Agent selected at creation", "--process-preset", "small", "--preset-reason", "A scoped edit")["task_id"]
        self.assertEqual(self.cli("automation", "show", created)["automation"]["process"]["selected_by"], "owner")
        family = self.cli("template", "apply", "builtin-feature", "--project", project, "--process-preset", "small", "--preset-reason", "Scoped child tasks")["tasks"]
        for task in family:
            self.assertEqual(self.cli("automation", "show", task["id"])["automation"]["process"]["selected_by"], "owner")

    def test_status_trigger_runs_rework_loop_and_waits_for_user_approval(self):
        self.assertFalse((self.directory / "calls").exists(), "An armed workflow must not invoke the executor")
        revision = self.cli("task", "show", self.task)["task"]["revision"]
        self.cli("task", "start", self.task, "--agent", "user", "--expected-revision", str(revision))
        self.wait(lambda: self.workflow()["state"] in ("awaiting_approval", "blocked"), timeout=WORKFLOW_WAIT)
        workflow = self.workflow()
        self.assertEqual(workflow["state"], "awaiting_approval", workflow["message"])
        self.assertEqual([entry["stage"] for entry in workflow["attempts"]], ["preflight", "work", "review", "rework", "review", "release"])
        self.assertEqual(workflow["reworks"], 1)
        self.wait(lambda: all(entry["receipt"].get("terminal") for entry in self.workflow()["attempts"]))
        self.assertEqual(self.launches(), 6)
        self.assertTrue(all(entry["worker_exited"] for entry in workflow["attempts"]))
        self.assertEqual(self.cli("task", "show", self.task)["task"]["status"], "review")
        self.assertEqual(len(self.cli("task", "show", self.task)["artifacts"]), 6)
        self.cli("task", "decide", self.task, "--decision", "approve", "--summary", "Checked the release preparation report")
        self.assertEqual(self.workflow()["state"], "completed")

    def test_project_defaults_and_custom_rule_reach_the_agent_prompt(self):
        project = self.cli("task", "show", self.task)["task"]["project_id"]
        config = {"plugin_id": "orca", "method": "automation.start", "resource_key": "repo::" + str(self.repo),
                  "params": {"worktree_id": "repo::" + str(self.repo), "agent": "codex"}, "max_reworks": 1, "timeout_seconds": 60,
                  "rules": [{"id": "review-card", "status": "review", "action": "stage", "stage": "review",
                             "skills": ["fixture-review"], "prompt": "Inspect the custom acceptance marker", "instructions": "Record the custom instruction marker"}]}
        path = self.directory / "configuration.json"
        path.write_text(json.dumps(config))
        self.cli("automation", "set-defaults", project, "--configuration", str(path))
        defaults = self.cli("automation", "defaults", project)["defaults"]
        self.assertTrue(defaults["enabled"])
        self.task = self.cli("task", "add", "--project", project, "--title", "Inherited rules", "--goal", "Inspect the fixture", "--completion-criteria", "Review records findings")["task_id"]
        self.assertEqual(self.workflow()["state"], "armed")
        self.assertEqual(self.launches(), 0)
        self.cli("task", "review", self.task, "--summary", "Manual review move")
        self.wait(lambda: self.workflow()["state"] in ("waiting", "blocked"))
        workflow = self.workflow()
        self.assertEqual(workflow["state"], "waiting", workflow["message"])
        self.assertEqual(self.cli("task", "show", self.task)["task"]["status"], "review")
        prompt = (self.directory / ("prompt-" + workflow["attempts"][0]["id"] + ".txt")).read_text()
        for text in ("fixture-review", "Inspect the custom acceptance marker", "Record the custom instruction marker", "report blocked"):
            self.assertIn(text, prompt)
        self.assertEqual(self.launches(), 1)
        self.assertEqual(workflow["attempts"][0]["settings"]["skills"], ["fixture-review"])

    def test_manual_creation_cli_overrides_enabled_project_defaults(self):
        project = self.cli("task", "show", self.task)["task"]["project_id"]
        config = self.workflow()["configuration"]
        path = self.directory / "defaults.json"
        path.write_text(json.dumps(config))
        self.cli("automation", "set-defaults", project, "--configuration", str(path))
        manual = self.cli("task", "add", "--project", project, "--title", "Manual by choice", "--goal", "Work by hand", "--completion-criteria", "User verifies", "--automation", "manual")["task_id"]
        self.assertIsNone(self.cli("automation", "show", manual)["automation"])
        revision = self.cli("task", "show", manual)["task"]["revision"]
        self.cli("task", "start", manual, "--agent", "user", "--expected-revision", str(revision))
        self.assertIsNone(self.cli("automation", "show", manual)["automation"])
        self.assertEqual(self.launches(), 0)
        automatic = self.cli("task", "add", "--project", project, "--title", "Explicit automatic", "--automation", "automatic")["task_id"]
        self.assertEqual(self.cli("automation", "show", automatic)["automation"]["state"], "armed")
        self.assertEqual(self.launches(), 0)

    def test_report_handoff_is_private_token_free_and_does_not_connect(self):
        path = self.directory / "handoff.json"
        env = self.env | {"WORKBOARD_SOCKET": str(self.directory / "absent.sock"), "WORKBOARD_AUTOMATION_REPORT_FILE": str(path), "WORKBOARD_AUTOMATION_TASK": "task-fixture", "WORKBOARD_AUTOMATION_ATTEMPT": "attempt-fixture"}
        result = subprocess.run([str(CLI), "automation", "report", "--source-dir", str(self.repo), "--outcome", "pass", "--summary", "Sandbox report", "--evidence", "Inspected fixture", "--json"], env=env, text=True, capture_output=True, timeout=10)
        self.assertTrue(json.loads(result.stdout)["ok"], result.stdout)
        report = json.loads(path.read_text())
        self.assertEqual(report["attempt_id"], "attempt-fixture")
        self.assertNotIn("token", report)
        self.assertTrue(report["source_version"].startswith("sha256:"))
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertFalse(Path(env["WORKBOARD_SOCKET"]).exists())

    def test_exit_without_report_blocks_and_core_remains_usable(self):
        (self.directory / "mode").write_text("exit")
        self.cli("automation", "start", self.task)
        self.wait(lambda: self.workflow()["state"] == "blocked")
        self.assertEqual(len(self.workflow()["attempts"]), 1)
        self.assertTrue(self.workflow()["attempts"][0]["worker_exited"])
        self.assertTrue(self.cli("doctor")["healthy"])
        self.assertEqual(self.cli("task", "show", self.task)["task"]["status"], "in_progress")

    def test_disabling_plugin_fences_late_reports_and_preserves_history(self):
        (self.directory / "mode").write_text("hold")
        self.cli("automation", "start", self.task)
        self.wait(lambda: (self.directory / "waiting").exists())
        self.cli("plugin", "disable", "orca")
        self.assertEqual(self.workflow()["state"], "blocked")
        (self.directory / "continue").touch()
        self.wait(lambda: self.workflow()["attempts"][0]["worker_exited"])
        self.assertIsNone(self.workflow()["attempts"][0]["result"])
        self.assertEqual(self.launches(), 1)
        self.assertTrue(self.cli("doctor")["healthy"])
        self.cli("plugin", "remove", "orca")
        self.assertEqual(len(self.workflow()["attempts"]), 1)

    def test_pause_waits_for_process_exit_and_resume_uses_next_stage(self):
        (self.directory / "mode").write_text("hold")
        self.cli("automation", "start", self.task)
        self.wait(lambda: (self.directory / "waiting").exists())
        self.cli("automation", "pause", self.task)
        (self.directory / "continue").touch()
        self.wait(lambda: self.workflow()["attempts"][0]["worker_exited"])
        self.assertEqual(self.workflow()["state"], "paused")
        self.assertEqual(self.launches(), 1)
        (self.directory / "mode").write_text("normal")
        self.cli("automation", "resume", self.task)
        self.wait(lambda: self.workflow()["state"] in ("awaiting_approval", "blocked"), timeout=WORKFLOW_WAIT)
        self.assertEqual(self.workflow()["state"], "awaiting_approval")
        self.assertEqual(self.launches(), 6)

    def test_fingerprint_includes_untracked_content_and_symlink_targets(self):
        def fingerprint():
            return self.cli("automation", "fingerprint", str(self.repo))["source_version"]
        original = fingerprint()
        (self.repo / "new.txt").write_text("one")
        first = fingerprint()
        (self.repo / "new.txt").write_text("two")
        second = fingerprint()
        (self.repo / "link").symlink_to("new.txt")
        third = fingerprint()
        self.assertEqual(len({original, first, second, third}), 4)
        (self.repo / "link").unlink()
        (self.repo / "link").symlink_to("feature.txt")
        self.assertNotEqual(third, fingerprint())

    def test_unreadable_plugin_registry_does_not_block_core_after_restart(self):
        self.service.terminate()
        self.service.wait(timeout=10)
        (self.directory / "board/plugins/registry.json").write_text("invalid registry JSON")
        self.service = subprocess.Popen([str(SERVICE)], env=self.env, stdout=self.log, stderr=self.log)
        self.wait(lambda: Path(self.env["WORKBOARD_SOCKET"]).exists())
        self.assertTrue(self.cli("doctor")["healthy"])
        self.cli("automation", "start", self.task)
        self.wait(lambda: self.workflow()["state"] == "blocked")
        self.assertEqual(self.launches(), 0)
        self.assertTrue(self.cli("doctor")["healthy"])

    def test_fingerprint_tracks_changes_inside_a_dirty_submodule(self):
        origin = self.directory / "module-origin"
        subprocess.run(["git", "init", "-q", str(origin)], check=True)
        (origin / "nested.txt").write_text("initial")
        subprocess.run(["git", "-C", str(origin), "add", "."], check=True)
        subprocess.run(["git", "-C", str(origin), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "Initial module"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "protocol.file.allow=always", "submodule", "add", "-q", str(origin), "module"], check=True)
        def fingerprint():
            return self.cli("automation", "fingerprint", str(self.repo))["source_version"]
        first = fingerprint()
        (self.repo / "module/nested.txt").write_text("first edit")
        second = fingerprint()
        (self.repo / "module/nested.txt").write_text("another edit")
        third = fingerprint()
        (self.repo / "module/new.txt").write_text("untracked source")
        self.assertEqual(len({first, second, third, fingerprint()}), 4)


if __name__ == "__main__":
    unittest.main()
