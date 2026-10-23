"""Orca subprocess fixtures and real board host; no real agent or account is used."""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugins/orca/plugin.py"
CLI = ROOT / "target/debug/workboard"
SERVICE = ROOT / "target/debug/workboard-service"
# A provider may use its complete 24-second budget across several Orca calls.
# The harness must allow it to return its own typed timeout instead of killing it first.
PROVIDER_WAIT = 35
HOST_WAIT = 45

FAKE = r'''#!__PYTHON__
import json
from pathlib import Path
import sys
import time
directory = Path(__DIRECTORY__)
args = sys.argv[1:]
with (directory / "calls").open("a") as handle:
    handle.write(json.dumps(args) + "\n")
mode = (directory / "mode").read_text() if (directory / "mode").exists() else ""
if mode == "bad-json":
    print("not json"); sys.exit(0)
if mode == "offline":
    print(json.dumps({"ok": False, "error": {"message": "Orca runtime unavailable"}})); sys.exit(1)
worktree = {"id": "repo-1::/tmp/worktree", "repoId": "repo-1", "projectId": "project-1", "hostId": "local",
            "instanceId": "instance-1", "path": "/tmp/worktree", "branch": "refs/heads/topic", "head": "head-1",
            "displayName": "Test worktree", "comment": "Original task goal", "workspaceStatus": "done", "isArchived": False}
terminal = {"handle": "term-fixture", "title": "Test run", "worktreeId": worktree["id"],
            "agentIdentity": "codex", "connected": True, "writable": True, "preview": "PRIVATE_PREVIEW"}
second = dict(worktree, id="repo-2::/tmp/second", repoId="repo-2", path="/tmp/second", displayName="Second worktree")
unconnected = dict(worktree, id="repo-3::/tmp/third", repoId="repo-3", path="/tmp/third")
repos = [{"id": "repo-1", "displayName": "fixture $(literal)", "path": "/tmp/awb repo one"},
         {"id": "repo-2", "displayName": "second", "path": "/tmp/awb-repo-two"},
         {"id": "repo-3", "displayName": "second", "path": "/tmp/awb-repo-three"},
         {"id": "repo-4", "displayName": "remote", "path": "/srv/remote", "hostId": "remote-host"}]
if mode == "foreign": worktree["repoId"] = "other-repo"
if mode == "remote": worktree["hostId"] = "remote-host"
by_repo = {"id:repo-1": [worktree], "id:repo-2": [second], "id:repo-3": [unconnected]}
by_id = {item["id"]: item for item in (worktree, second, unconnected)}
if args[:2] == ["repo", "list"]:
    result = {"repos": repos}
elif args[:2] == ["worktree", "list"]:
    rows = by_repo[args[args.index("--repo") + 1]]
    result = {"worktrees": rows, "totalCount": 2 if rows is by_repo["id:repo-1"] else 1,
              "truncated": rows is by_repo["id:repo-1"]}
elif args[:2] == ["worktree", "show"]:
    result = {"worktree": by_id[args[args.index("--worktree") + 1][3:]]}
elif args[:2] == ["terminal", "list"]:
    if mode == "terminal-mismatch": terminal["worktreeId"] = "other"
    result = {"terminals": [terminal], "truncated": False}
elif args[:2] == ["terminal", "read"]:
    result = {"terminal": {"handle": terminal["handle"], "tail": ["Run results"], "nextCursor": "81",
                           "status": "running", "source": "stream", "draft": "PRIVATE_DRAFT"}}
elif args[:2] == ["terminal", "create"]:
    if mode == "create-fail":
        print(json.dumps({"ok": False, "error": {"message": "uncertain create"}})); sys.exit(1)
    if mode == "create-delay": time.sleep(0.3)
    result = {"terminal": terminal}
else:
    print("unexpected command", file=sys.stderr); sys.exit(2)
print(json.dumps({"ok": True, "result": result}, ensure_ascii=False))
'''


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="awb-orca-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.fake = self.directory / "orca executable"
        self.fake.write_text(FAKE.replace("__PYTHON__", sys.executable).replace("__DIRECTORY__", repr(str(self.directory))))
        self.fake.chmod(0o700)
        self.config = {"executable": str(self.fake), "repo": "name:fixture $(literal)"}
        self.environment = dict(os.environ, WORKBOARD_PLUGIN_DATA_DIR=str(self.directory / "state"))
        self.worktree_id = "repo-1::/tmp/worktree"

    def mode(self, mode):
        (self.directory / "mode").write_text(mode)

    def calls(self):
        file = self.directory / "calls"
        return [json.loads(line) for line in file.read_text().splitlines()] if file.exists() else []

    def invoke(self, method, params=None, request_id="request-1", config=None):
        result = subprocess.run([sys.executable, str(PLUGIN)], input=json.dumps({"protocol_version": 1,
            "request_id": request_id, "method": method, "params": params or {}, "config": config or self.config}),
            text=True, capture_output=True, env=self.environment, timeout=PROVIDER_WAIT)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def launch_params(self, **changes):
        return dict({"worktree_id": self.worktree_id, "task_id": "task-1", "run_id": "run-1", "agent": "codex",
            "task": {"id": "task-1", "revision": 4, "title": "Title", "goal": "Goal", "status": "in_progress", "assignee": "orca:codex"},
            "task_runs": [{"id": "run-1", "agent_id": "orca:codex", "status": "running"}],
            "board_connection": {"executable": "/custom/workboard", "data_dir": "/tmp/data dir", "socket": "/tmp/s.sock"}}, **changes)


class OrcaProvider(Fixture):
    def test_scoped_list_preserves_truncation_and_does_not_collect_previews(self):
        result = self.invoke("worktrees.list")
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["result"]["truncated"])
        self.assertEqual(result["result"]["worktrees"][0]["head"], "head-1")
        self.assertEqual(self.calls()[0], ["repo", "list", "--json"])
        self.assertEqual(self.calls()[1][:4], ["worktree", "list", "--repo", "id:repo-1"])
        self.assertEqual(len(self.calls()), 2, "the earlier single-repository setting still connects one repository")
        self.assertNotIn("requests", result)

    def test_multiple_repositories_list_together_and_scope_each_worktree(self):
        config = {"executable": str(self.fake), "repos": ["id:repo-1", "path:/tmp/awb-repo-two/", "name:missing",
                                                          "name:second", "id:repo-4", "id:repo-1"]}
        check = self.invoke("check", config=config)["result"]
        self.assertEqual([repo["id"] for repo in check["repos"]], ["repo-1", "repo-2"])
        self.assertEqual({entry["selector"]: entry["reason"] for entry in check["unmatched"]}, {
            "name:missing": "not registered in Orca on this Mac", "name:second": "matches several repositories",
            "id:repo-4": "not registered in Orca on this Mac"}, "ambiguous names and remote hosts are not connected")
        listing = self.invoke("worktrees.list", config=config)["result"]
        self.assertEqual([(row["id"], row["repo_name"], row["repo_path"]) for row in listing["worktrees"]], [
            (self.worktree_id, "fixture $(literal)", "/tmp/awb repo one"),
            ("repo-2::/tmp/second", "second", "/tmp/awb-repo-two")])
        self.assertEqual((listing["truncated"], listing["total_count"]), (True, 3))
        only = self.invoke("worktrees.list", {"repo_id": "repo-2"}, config=config)["result"]
        self.assertEqual([row["id"] for row in only["worktrees"]], ["repo-2::/tmp/second"])
        self.assertEqual(self.invoke("worktrees.list", {"repo_id": "repo-3"}, config=config)["error"]["code"],
                         "PLUGIN_SCOPE_MISMATCH")
        imported = self.invoke("worktrees.import", {"worktree_id": "repo-2::/tmp/second", "project_id": "p"}, config=config)
        self.assertEqual(imported["requests"][1]["params"]["metadata"]["repo_path"], "/tmp/awb-repo-two")
        before = len(self.calls())
        foreign = self.invoke("worktrees.get", {"worktree_id": "repo-3::/tmp/third"}, config=config)
        self.assertEqual(foreign["error"]["code"], "PLUGIN_SCOPE_MISMATCH")
        self.assertEqual(self.calls()[before:], [["repo", "list", "--json"]], "an unconnected worktree is never read")
        missing = self.invoke("check", config={"executable": str(self.fake), "repos": ["name:missing"]})
        self.assertIn("name:missing", missing["error"]["message"])

    def test_foreign_selector_rejected_before_show_and_remote_response_rejected(self):
        response = self.invoke("worktrees.get", {"worktree_id": "other::/tmp/no"})
        self.assertEqual(response["error"]["code"], "PLUGIN_SCOPE_MISMATCH")
        self.assertEqual(len(self.calls()), 1)
        for mode in ("foreign", "remote"):
            self.mode(mode)
            response = self.invoke("worktrees.list")
            self.assertEqual(response["error"]["code"], "PLUGIN_SCOPE_MISMATCH")

    def test_import_keeps_source_and_parent_without_completing_source_done(self):
        response = self.invoke("worktrees.import", {"worktree_id": self.worktree_id, "project_id": "p", "parent_id": "parent"})
        self.assertTrue(response["ok"], response)
        creation, attachment = response["requests"]
        self.assertEqual(creation["params"]["parent_id"], "parent")
        self.assertNotIn("status", creation["params"])
        self.assertEqual(attachment["params"]["task_id"], {"$result": "/0/task_id"})
        self.assertEqual(attachment["params"]["provider"], "orca")
        self.assertEqual(attachment["params"]["metadata"]["workspace_status"], "done")

    def test_invalid_settings_and_missing_import_target_do_not_invoke_orca(self):
        for config in ({"executable": "orca", "repo": "name:fixture"}, {"executable": str(self.fake), "repo": "active"},
                       {"executable": str(self.fake)}, {"executable": str(self.fake), "repos": []},
                       {"executable": str(self.fake), "repos": "id:repo-1"},
                       {"executable": str(self.fake), "repos": ["id:repo-1", "path:"]},
                       {"executable": str(self.fake), "repos": ["id:" + str(n) for n in range(51)]}):
            self.assertFalse(self.invoke("check", config=config)["ok"], config)
        self.assertFalse(self.invoke("worktrees.import", {"worktree_id": self.worktree_id})["ok"])
        self.assertEqual(self.calls(), [])

    def test_runtime_and_malformed_response_fail_without_board_requests(self):
        for mode, code in (("offline", "INTEGRATION_UNAVAILABLE"), ("bad-json", "PLUGIN_INVALID_RESPONSE")):
            self.mode(mode)
            response = self.invoke("check")
            self.assertEqual(response["error"]["code"], code)
            self.assertNotIn("requests", response)

    def test_terminal_output_is_explicit_bounded_scoped_and_excludes_draft(self):
        params = {"worktree_id": self.worktree_id, "terminal": "term-fixture", "limit": 999, "cursor": 2}
        listing = self.invoke("terminals.list", params)
        self.assertNotIn("PRIVATE_PREVIEW", json.dumps(listing))
        response = self.invoke("terminals.read", params)
        self.assertEqual(response["result"]["tail"], ["Run results"])
        self.assertNotIn("PRIVATE_DRAFT", json.dumps(response))
        self.assertEqual(self.calls()[-1], ["terminal", "read", "--terminal", "term-fixture", "--limit", "200", "--cursor", "2", "--json"])
        self.assertFalse(self.invoke("terminals.read", dict(params, terminal="foreign"))["ok"])
        self.mode("terminal-mismatch")
        self.assertFalse(self.invoke("terminals.list", params)["ok"])

    def test_start_quotes_prompt_and_prevents_duplicate_even_with_new_request_id(self):
        marker = self.directory / "shell-was-run"
        prompt = "$(touch " + str(marker) + ") `literal` ' quoted\nCommand"
        params = self.launch_params(prompt=prompt)
        first = self.invoke("agents.start", params)
        self.assertTrue(first["ok"], first)
        create = self.calls()[-1]
        command = shlex.split(create[create.index("--command") + 1])
        # The launched agent acts as the run's assignee on the same board.
        self.assertEqual(command[:4], ["env", "WORKBOARD_AGENT=orca:codex", "WORKBOARD_DATA_DIR=/tmp/data dir",
                                       "WORKBOARD_SOCKET=/tmp/s.sock"])
        self.assertEqual(command[4], "codex")
        self.assertEqual(len(command), 6)
        self.assertIn(prompt, command[5])
        self.assertIn("--socket /tmp/s.sock", command[5])
        self.assertIn("task review task-1 --run run-1", command[5])
        self.assertFalse(marker.exists())
        self.assertEqual(first["requests"][0]["params"]["run_id"], "run-1")
        second = self.invoke("agents.start", params, request_id="request-2")
        self.assertTrue(second["result"]["already_started"])
        self.assertEqual(second["requests"], first["requests"])
        self.assertEqual(sum(call[:2] == ["terminal", "create"] for call in self.calls()), 1)
        changed = self.invoke("agents.start", self.launch_params(prompt="changed"), request_id="request-3")
        self.assertEqual(changed["error"]["code"], "PLUGIN_RUN_CONFLICT")

    def test_stale_run_and_wrong_owner_do_not_launch(self):
        for params in (self.launch_params(run_id="old-run"), self.launch_params(task_runs=[]),
                       self.launch_params(task={"id": "task-1", "revision": 4, "status": "done", "assignee": "someone"})):
            response = self.invoke("agents.start", params)
            self.assertEqual(response["error"]["code"], "PLUGIN_RUN_CONFLICT")
        self.assertFalse(any(call[:2] == ["terminal", "create"] for call in self.calls()))

    def test_ambiguous_create_is_not_repeated(self):
        self.mode("create-fail")
        self.assertFalse(self.invoke("agents.start", self.launch_params())["ok"])
        self.mode("")
        response = self.invoke("agents.start", self.launch_params(), request_id="another")
        self.assertEqual(response["error"]["code"], "PLUGIN_EXTERNAL_RESULT_UNKNOWN")
        self.assertEqual(sum(call[:2] == ["terminal", "create"] for call in self.calls()), 1)

    def test_concurrent_launches_create_only_one_terminal(self):
        self.mode("create-delay")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(lambda n: self.invoke("agents.start", self.launch_params(), request_id="parallel-" + str(n)), range(2)))
        self.assertGreaterEqual(sum(response["ok"] for response in results), 1)
        self.assertEqual(sum(call[:2] == ["terminal", "create"] for call in self.calls()), 1)

    def test_timeout_is_a_structured_failure(self):
        spec = importlib.util.spec_from_file_location("orca_plugin", PLUGIN)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with patch.object(module.subprocess, "run", side_effect=subprocess.TimeoutExpired("orca", 8)):
            with self.assertRaises(module.IntegrationError) as caught:
                module.run({"protocol_version": 1, "method": "check", "config": self.config})
        self.assertEqual(caught.exception.code, "PLUGIN_TIMEOUT")


class OrcaHost(Fixture):
    def setUp(self):
        super().setUp()
        self.data = self.directory / "data"
        self.socket = self.directory / "s.sock"
        self.server = subprocess.Popen([str(SERVICE), "--data-dir", str(self.data), "--socket", str(self.socket)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop)
        deadline = time.monotonic() + 20
        while not self.socket.exists():
            self.assertIsNone(self.server.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.02)
        self.cli("plugin", "install", str(PLUGIN.parent))
        self.config = {"executable": str(self.fake), "repos": ["id:repo-1", "path:/tmp/awb-repo-two"]}

    def stop(self):
        if self.server.poll() is None:
            self.server.terminate()
        self.server.wait(timeout=5)

    def cli(self, *args, ok=True):
        completed = subprocess.run([str(CLI), "--json", "--data-dir", str(self.data), "--socket", str(self.socket), *args],
                                   capture_output=True, text=True, timeout=HOST_WAIT)
        result = json.loads(completed.stdout)
        self.assertEqual(result["ok"], ok, result)
        self.assertEqual(completed.returncode == 0, ok)
        return result

    def rpc(self, method, params, **options):
        return self.cli("rpc", method, "--params", json.dumps(params), **options)["result"]

    def enable(self):
        self.cli("plugin", "enable", "orca", "--config", json.dumps(self.config))

    def plugin(self, method, params, request_id, ok=True):
        return self.cli("plugin", "run", "orca", method, "--params", json.dumps(params), "--request-id", request_id, ok=ok)

    def test_disabled_or_removed_plugin_never_invokes_orca_and_doctor_passes(self):
        self.cli("plugin", "check", "orca", ok=False)
        self.cli("doctor")
        self.assertEqual(self.calls(), [])
        self.enable()
        self.cli("plugin", "disable", "orca")
        self.cli("plugin", "check", "orca", ok=False)
        self.cli("plugin", "remove", "orca")
        self.cli("plugin", "check", "orca", ok=False)
        self.cli("doctor")
        self.assertEqual(self.calls(), [])

    def test_check_reports_connected_repositories_through_the_host(self):
        self.enable()
        check = self.cli("plugin", "check", "orca")["result"]["result"]
        self.assertEqual([repo["name"] for repo in check["repos"]], ["fixture $(literal)", "second"])

    def test_import_retry_subtask_attach_and_removal_preserve_board(self):
        self.enable()
        project = self.rpc("project.create", {"name": "Orca verification"})["project_id"]
        parent = self.rpc("task.create", {"project_id": project, "title": "Parent"})["task_id"]
        params = {"project_id": project, "parent_id": parent, "worktree_id": self.worktree_id}
        first = self.plugin("worktrees.import", params, "import-1")
        self.assertEqual(first, self.plugin("worktrees.import", params, "import-1"))
        task_id = first["result"]["applied"][0]["task_id"]
        detail = self.rpc("task.get", {"task_id": task_id})
        self.assertEqual(detail["task"]["parent_id"], parent)
        self.assertEqual(detail["task"]["status"], "todo")
        self.assertEqual(len(detail["artifacts"]), 1)
        self.assertEqual(detail["artifacts"][0]["provider"], "orca")
        before = detail
        self.cli("plugin", "disable", "orca")
        self.cli("plugin", "remove", "orca")
        self.assertEqual(self.rpc("task.get", {"task_id": task_id}), before)

    def test_host_supplies_real_task_and_runs_and_launch_retry_is_idempotent(self):
        self.enable()
        project = self.rpc("project.create", {"name": "Orca launch verification"})["project_id"]
        task = self.rpc("task.create", {"project_id": project, "title": "Actual task title"})["task"]
        started = self.rpc("task.start", {"task_id": task["id"], "agent_id": "orca:codex", "expected_revision": task["revision"]})
        params = {"task_id": task["id"], "run_id": started["run_id"], "agent": "codex", "worktree_id": self.worktree_id,
                  "task": {"id": task["id"], "title": "Forged title", "revision": started["task"]["revision"]}, "task_runs": [], "board_connection": {}}
        first = self.plugin("agents.start", params, "launch-1")
        self.assertEqual(first, self.plugin("agents.start", params, "launch-1"))
        creates = [call for call in self.calls() if call[:2] == ["terminal", "create"]]
        self.assertEqual(len(creates), 1)
        command = creates[0][creates[0].index("--command") + 1]
        self.assertIn("Actual task title", command)
        self.assertNotIn("Forged title", command)
        self.assertIn("Agent Workboard protocol", command, "the host passes the shared agent protocol")
        self.assertIn("WORKBOARD_AGENT=orca:codex", command)
        self.assertIn(str(self.socket), command)
        detail = self.rpc("task.get", {"task_id": task["id"]})
        self.assertEqual(detail["task"]["status"], "in_progress")
        self.assertEqual(detail["artifacts"][0]["run_id"], started["run_id"])
        replay = self.plugin("agents.start", {k: v for k, v in params.items() if k != "task"}, "launch-2")
        self.assertTrue(replay["result"]["result"]["already_started"])
        self.assertEqual(len(self.rpc("task.get", {"task_id": task["id"]})["artifacts"]), 1)

    def test_stale_attach_and_missing_task_do_not_call_provider(self):
        self.enable()
        project = self.rpc("project.create", {"name": "Orca conflict verification"})["project_id"]
        task = self.rpc("task.create", {"project_id": project, "title": "Task"})["task"]
        params = {"task_id": task["id"], "expected_revision": task["revision"] + 1, "worktree_id": self.worktree_id}
        self.plugin("worktrees.attach", params, "stale", ok=False)
        self.plugin("agents.start", dict(params, task_id="missing", agent="codex", run_id="old"), "missing", ok=False)
        self.assertEqual(self.calls(), [])

    def test_recovery_after_provider_success_restores_one_link_with_concurrent_new_requests(self):
        self.enable()
        project = self.rpc("project.create", {"name": "Orca interruption recovery"})["project_id"]
        task = self.rpc("task.create", {"project_id": project, "title": "Recover attachment"})["task"]
        started = self.rpc("task.start", {"task_id": task["id"], "agent_id": "orca:codex"})
        params = {"task_id": task["id"], "run_id": started["run_id"], "agent": "codex", "worktree_id": self.worktree_id}
        context = self.rpc("task.get", {"task_id": task["id"]})
        # The external terminal was created and durably recorded, but the host
        # died before preparing/applying the returned board attachment.
        self.environment["WORKBOARD_PLUGIN_DATA_DIR"] = str(self.data / "plugin-data/orca")
        provider = self.invoke("agents.start", dict(params, task=context["task"], task_runs=context["runs"],
            board_connection={"executable": str(CLI), "data_dir": str(self.data), "socket": str(self.socket)}))
        self.assertTrue(provider["ok"], provider)
        self.assertEqual(self.rpc("task.get", {"task_id": task["id"]})["artifacts"], [])
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(lambda n: self.plugin("agents.start", params, "recover-" + str(n)), range(2)))
        for response in results:
            self.assertTrue(response["result"]["result"]["already_started"])
        detail = self.rpc("task.get", {"task_id": task["id"]})
        self.assertEqual(len(detail["artifacts"]), 1)
        self.assertEqual(detail["artifacts"][0]["run_id"], started["run_id"])
        self.assertEqual(detail["artifacts"][0]["metadata"]["terminal_handle"], "term-fixture")
        self.assertEqual(sum(call[:2] == ["terminal", "create"] for call in self.calls()), 1)

    def test_completed_launch_recovers_historical_link_after_task_and_run_change(self):
        self.enable()
        project = self.rpc("project.create", {"name": "Recover previous run attachment"})["project_id"]
        task = self.rpc("task.create", {"project_id": project, "title": "Original goal"})["task"]
        started = self.rpc("task.start", {"task_id": task["id"], "agent_id": "orca:codex"})
        params = {"task_id": task["id"], "run_id": started["run_id"], "agent": "codex", "worktree_id": self.worktree_id}
        context = self.rpc("task.get", {"task_id": task["id"]})
        self.environment["WORKBOARD_PLUGIN_DATA_DIR"] = str(self.data / "plugin-data/orca")
        self.assertTrue(self.invoke("agents.start", dict(params, task=context["task"], task_runs=context["runs"],
            board_connection={"executable": str(CLI), "data_dir": str(self.data), "socket": str(self.socket)}))["ok"])
        self.rpc("task.update", {"task_id": task["id"], "title": "Next goal", "expected_revision": context["task"]["revision"]})
        latest = self.rpc("task.start", {"task_id": task["id"], "agent_id": "orca:codex"})
        response = self.plugin("agents.start", params, "historical-recovery")
        self.assertTrue(response["result"]["result"]["already_started"])
        detail = self.rpc("task.get", {"task_id": task["id"]})
        self.assertEqual(detail["task"]["title"], "Next goal")
        self.assertEqual(detail["runs"][-1]["id"], latest["run_id"])
        self.assertEqual(detail["runs"][-1]["status"], "running")
        self.assertEqual(len(detail["artifacts"]), 1)
        self.assertEqual(detail["artifacts"][0]["run_id"], started["run_id"])
        self.assertEqual(sum(call[:2] == ["terminal", "create"] for call in self.calls()), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
