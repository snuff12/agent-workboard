"""Agent session support and the optional Claude Code and Codex integration kit."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "target/debug/workboard"
SERVICE = ROOT / "target/debug/workboard-service"
KIT = ROOT / "integrations/agents"
PROTOCOL = (KIT / "protocol.md").read_text()


class Kit(unittest.TestCase):
    def test_skills_and_brief_carry_the_single_protocol(self):
        for tool in ("claude", "codex"):
            skill = (KIT / tool / "skills/workboard/SKILL.md").read_text()
            front, body = skill.split("\n---\n\n", 1)
            self.assertIn("name: workboard", front)
            self.assertIn("description:", front)
            self.assertEqual(body, PROTOCOL, tool)
        brief = subprocess.run([str(CLI), "agent", "brief"], text=True, capture_output=True, timeout=10)
        self.assertEqual(brief.stdout, PROTOCOL)

    def test_marketplaces_hooks_and_scripts_are_consistent(self):
        claude = json.loads((KIT / ".claude-plugin/marketplace.json").read_text())
        codex = json.loads((KIT / ".agents/plugins/marketplace.json").read_text())
        self.assertEqual(claude["name"], codex["name"])
        self.assertTrue((KIT / claude["plugins"][0]["source"] / ".claude-plugin/plugin.json").is_file())
        self.assertTrue((KIT / codex["plugins"][0]["source"]["path"] / ".codex-plugin/plugin.json").is_file())
        for tool, root_variable in (("claude", "CLAUDE_PLUGIN_ROOT"), ("codex", "PLUGIN_ROOT")):
            hooks = json.loads((KIT / tool / "hooks/hooks.json").read_text())["hooks"]
            self.assertEqual(list(hooks), ["SessionStart"], "the kit adds context only; it never changes task state")
            command = hooks["SessionStart"][0]["hooks"][0]["command"]
            self.assertIn("${" + root_variable + "}/scripts/workboard-hook", command)
            self.assertTrue(command.endswith(" " + tool))
            self.assertTrue(os.access(KIT / tool / "scripts/workboard-hook", os.X_OK))

    @unittest.skipUnless(shutil.which("codex"), "Codex CLI is not installed")
    def test_codex_rules_allow_board_work_and_prompt_for_user_decisions(self):
        expected = {
            "workboard task show TASK --json": "allow",
            "workboard agent context": "allow",
            "workboard task review TASK --run RUN --summary done": "allow",
            "workboard inbox capture --title follow-up": "allow",
            "workboard task complete TASK --summary done": "prompt",
            "workboard task delete TASK": "prompt",
            "workboard backup restore FILE": "prompt",
            "workboard plugin run orca agents.start": "prompt",
            "workboard rpc task.update --params {}": "prompt",
        }
        for command, decision in expected.items():
            result = subprocess.run(["codex", "execpolicy", "check", "--rules", str(KIT / "codex/workboard.rules"),
                                     "--", *command.split()], text=True, capture_output=True, timeout=30)
            self.assertEqual(json.loads(result.stdout)["decision"], decision, command)


class AgentSessions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="awk-", dir="/tmp")
        root = Path(self.temp.name)
        self.data, self.socket = root / "data", root / "s.sock"
        self.environment = {key: value for key, value in os.environ.items()
                            if key not in ("WORKBOARD_AGENT", "CODEX_THREAD_ID", "CLAUDE_ENV_FILE")}
        self.environment.update({"WORKBOARD_DATA_DIR": str(self.data), "WORKBOARD_SOCKET": str(self.socket)})
        self.server = subprocess.Popen([str(SERVICE), "--data-dir", str(self.data), "--socket", str(self.socket)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(150):
            if self.socket.exists():
                break
            time.sleep(0.02)
        # A repository with a linked worktree elsewhere, laid out as git does.
        self.main = root / "projects/app"
        (self.main / ".git/worktrees/feature").mkdir(parents=True)
        (self.main / ".git/worktrees/feature/commondir").write_text("../..\n")
        self.worktree = root / "workspaces/app-feature"
        (self.worktree / "src").mkdir(parents=True)
        (self.worktree / ".git").write_text(f"gitdir: {self.main}/.git/worktrees/feature\n")

    def tearDown(self):
        if self.server.poll() is None:
            self.server.terminate()
            self.server.wait(timeout=5)
        self.temp.cleanup()

    def cli(self, *args, agent=None, codex_thread=None, cwd=None, ok=True):
        environment = dict(self.environment)
        if agent:
            environment["WORKBOARD_AGENT"] = agent
        if codex_thread:
            environment["CODEX_THREAD_ID"] = codex_thread
        result = subprocess.run([str(CLI), *map(str, args), "--json"], text=True, capture_output=True,
                                timeout=15, env=environment, cwd=cwd)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["ok"], ok, payload)
        return payload.get("result", payload.get("error"))

    def hook(self, tool, event, **environment):
        result = subprocess.run([str(KIT / tool / "scripts/workboard-hook"), tool], input=json.dumps(event),
                                text=True, capture_output=True, timeout=15,
                                env={**self.environment, "WORKBOARD_BIN": str(CLI), **environment})
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_session_identity_reaches_claims_and_board_context(self):
        project = self.cli("project", "add", "--name", "App", "--directory", self.main)["project_id"]
        task = self.cli("task", "add", "--project", project, "--title", "Write tests",
                        "--next-action", "Cover the worktree case")["task"]
        claimed = self.cli("task", "claim", task["id"], agent="claude:aaaa1111")["task"]
        self.assertEqual(claimed["assignee"], "claude:aaaa1111")
        conflict = self.cli("task", "claim", task["id"], codex_thread="0199BBBB-2222", ok=False)
        self.assertEqual(conflict["code"], "CLAIM_CONFLICT", "a Codex thread gets its own identity")
        run = self.cli("task", "start", task["id"], agent="claude:aaaa1111")["run_id"]
        self.cli("task", "heartbeat", task["id"], agent="claude:aaaa1111")
        paused = self.cli("task", "pause", task["id"], "--run", run, "--summary", "Half done",
                          "--next-action", "Finish the edge cases", agent="claude:aaaa1111")["task"]
        self.assertEqual((paused["status"], paused["next_action"]), ("todo", "Finish the edge cases"))
        released = self.cli("task", "release", task["id"], agent="claude:aaaa1111")["task"]
        self.assertIsNone(released["assignee"])
        item = self.cli("inbox", "capture", "--title", "Follow-up", agent="claude:aaaa1111")
        self.assertIn("claude:aaaa1111", json.dumps(item), "inbox items record which agent captured them")
        context = self.cli("agent", "context", agent="codex:cccc3333", cwd=self.worktree / "src")
        self.assertEqual(context["agent"], "codex:cccc3333")
        self.assertIn("Project: App.", context["context"], "a worktree maps to its repository's project")
        self.assertIn(task["id"], context["context"], "context carries full task IDs that commands accept")

    def test_hooks_add_context_set_identity_and_fail_open(self):
        project = self.cli("project", "add", "--name", "App", "--directory", self.main)["project_id"]
        self.cli("task", "add", "--project", project, "--title", "Ready work")
        env_file = Path(self.temp.name) / "claude.env"
        output = json.loads(self.hook("claude", {"session_id": "9f8e7d6c-0000", "cwd": str(self.worktree)},
                                      CLAUDE_ENV_FILE=str(env_file)))
        context = output["hookSpecificOutput"]
        self.assertEqual(context["hookEventName"], "SessionStart")
        self.assertIn("`claude:9f8e7d6c`", context["additionalContext"])
        self.assertIn("Ready work", context["additionalContext"])
        self.assertEqual(env_file.read_text(), "export WORKBOARD_AGENT='claude:9f8e7d6c'\n")
        launched = json.loads(self.hook("codex", {"session_id": "x", "cwd": str(self.worktree)},
                                        WORKBOARD_AGENT="orca:codex"))
        self.assertIn("`orca:codex`", launched["hookSpecificOutput"]["additionalContext"],
                      "a launcher's agent ID wins over the session")
        self.server.terminate()
        self.server.wait(timeout=5)
        started = time.monotonic()
        self.assertEqual(self.hook("claude", {"session_id": "abc", "cwd": "/tmp"}), "")
        self.assertLess(time.monotonic() - started, 5)
        self.assertFalse(self.socket.exists(), "a hook never starts the service")
        self.assertEqual(self.hook("codex", {"session_id": "abc"}, WORKBOARD_BIN="/nonexistent", PATH="/usr/bin:/bin",
                                   HOME=self.temp.name), "")


if __name__ == "__main__":
    unittest.main()
