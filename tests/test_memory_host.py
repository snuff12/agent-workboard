"""Real CLI, host journal and service with synthetic memory sources only."""
import hashlib
import json
import shutil
import sys
import unittest

import test_e2e as e2e
from test_memory_plugin import FAKE_AMEM

ROOT = e2e.ROOT


class MemoryEvidenceHost(unittest.TestCase):
    start_server = e2e.EndToEnd.start_server
    stop_server = e2e.EndToEnd.stop_server
    tearDown = e2e.EndToEnd.tearDown
    cli = e2e.EndToEnd.cli
    rpc = e2e.EndToEnd.rpc
    project = e2e.EndToEnd.project

    def setUp(self):
        e2e.EndToEnd.setUp(self)
        self.addCleanup(self.stop_server)
        self.directory = self.data.parent
        self.source = self.directory / "Synthetic evidence.md"
        self.source.write_text("Original synthetic evidence")
        self.calls_file = self.directory / "calls.jsonl"
        self.executable = self.directory / "fake amem"
        fake = FAKE_AMEM.replace("__PYTHON__", sys.executable)
        # The host intentionally clears arbitrary environment variables before plugin execution.
        fake = fake.replace("args = sys.argv[1:]", "os.environ.update(" + repr({"FAKE_AMEM_CALLS": str(self.calls_file), "FAKE_AMEM_SOURCE": str(self.source)}) + ")\nargs = sys.argv[1:]")
        self.executable.write_text(fake)
        self.executable.chmod(0o700)
        self.environment.update(FAKE_AMEM_CALLS=str(self.calls_file), FAKE_AMEM_SOURCE=str(self.source))
        self.cli("plugin", "install", ROOT / "plugins/agent-memory")
        self.cli("plugin", "enable", "agent-memory", "--config", json.dumps({"executable": str(self.executable)}))
        self.task = self.rpc("task.create", {"project_id": self.project(), "title": "Evidence continuity"})["result"]["task_id"]
        self.artifact = self.run_plugin("attach", {"task_id": self.task, "ref": "doc:good", "collection": "reviewed-docs",
                                                  "project": "synthetic", "query": "evidence"})["result"]["applied"][0]["artifact"]

    def run_plugin(self, method, params, request_id=None, ok=True):
        args = ["plugin", "run", "agent-memory", method, "--params", json.dumps(params)]
        if request_id:
            args += ["--request-id", request_id]
        return self.cli(*args, ok=ok)

    def verify(self, request_id=None, **extra):
        return self.run_plugin("verify", {"task_id": self.task, "artifact_id": self.artifact["id"], **extra}, request_id)

    def checks(self):
        return self.rpc("task.get", {"task_id": self.task})["result"]["evidence_verifications"]

    def test_rechecks_replay_once_survive_restart_and_preserve_original_and_replacement(self):
        current = self.verify("same-check")
        before = self.calls_file.read_bytes()
        self.assertEqual(self.verify("same-check"), current)
        self.assertEqual(self.calls_file.read_bytes(), before)
        self.assertEqual(len(self.checks()), 1)
        conflict = self.run_plugin("verify", {"task_id": self.task, "artifact_id": self.artifact["id"], "query": "different"},
                                   "same-check", ok=False)
        self.assertEqual(conflict["error"]["code"], "REQUEST_ID_CONFLICT")
        self.source.write_text("Changed synthetic evidence")
        self.assertEqual(self.verify()["result"]["result"]["status"], "changed")
        replacement = self.run_plugin("attach", {"task_id": self.task, "ref": "doc:good", "collection": "reviewed-docs",
                                                  "project": "synthetic", "supersedes_artifact_id": self.artifact["id"]})
        new = replacement["result"]["applied"][0]["artifact"]
        self.assertNotEqual(new["metadata"]["source_sha256"], self.artifact["metadata"]["source_sha256"])
        self.stop_server(); self.start_server()
        detail = self.rpc("task.get", {"task_id": self.task})["result"]
        self.assertEqual(detail["artifacts"][0], self.artifact)
        self.assertEqual(len(detail["evidence_verifications"]), 2)
        self.assertTrue(all(c["artifact_id"] == self.artifact["id"] for c in detail["evidence_verifications"]))
        self.assertEqual(detail["evidence_verifications"][0]["observed"]["source_sha256"], hashlib.sha256(self.source.read_bytes()).hexdigest())

    def test_host_uses_saved_scope_and_rejects_a_foreign_artifact_before_external_read(self):
        forged = dict(self.artifact, path="/untrusted/path", metadata={**self.artifact["metadata"], "scope": {"project": "wrong"}})
        self.verify(artifact=forged)
        args = json.loads(self.calls_file.read_text().splitlines()[-1])
        self.assertEqual(args[args.index("--project") + 1], "synthetic")
        other = self.rpc("task.create", {"project_id": self.project(), "title": "Other"})["result"]["task_id"]
        before = self.calls_file.read_bytes()
        rejected = self.run_plugin("verify", {"task_id": other, "artifact_id": self.artifact["id"]}, ok=False)
        self.assertEqual(rejected["error"]["code"], "EVIDENCE_SOURCE_CONFLICT")
        self.assertEqual(self.calls_file.read_bytes(), before)
        self.assertEqual(len(self.checks()), 1)

    def test_unavailable_amem_is_a_saved_attempt_without_a_source_verdict(self):
        self.executable.unlink()
        result = self.verify()["result"]
        self.assertEqual(result["result"]["status"], "integration_failure")
        self.assertEqual(self.checks()[0]["status"], "integration_failure")
        self.assertIsNone(self.checks()[0]["observed"])

    def test_invalid_evidence_is_rejected_without_recording_an_execution_failure(self):
        plain = self.rpc("task.attach", {"task_id": self.task, "path": "/synthetic/plain-file.md"})["result"]["artifact"]
        before = self.calls_file.read_bytes()
        rejected = self.run_plugin("verify", {"task_id": self.task, "artifact_id": plain["id"]}, ok=False)
        self.assertEqual(rejected["error"]["code"], "INVALID_REQUEST")
        self.assertEqual(self.checks(), [])
        self.assertEqual(self.calls_file.read_bytes(), before)

    def test_broken_plugin_and_timeout_are_saved_as_failed_attempts(self):
        self.cli("plugin", "disable", "agent-memory")
        self.cli("plugin", "remove", "agent-memory")
        package = self.directory / "broken-package"
        shutil.copytree(ROOT / "plugins/agent-memory", package)
        manifest = json.loads((package / "plugin.json").read_text())
        manifest["timeout_seconds"] = 1
        (package / "plugin.json").write_text(json.dumps(manifest))
        (package / "plugin.py").write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(10)\n")
        self.cli("plugin", "install", package)
        self.cli("plugin", "enable", "agent-memory")
        result = self.verify()["result"]["result"]
        self.assertEqual(result["status"], "integration_failure")
        self.assertIn("PLUGIN_TIMEOUT", self.checks()[0]["detail"])
        self.assertTrue(self.rpc("doctor")["result"]["core_healthy"])

    def test_disabled_plugin_preserves_history_and_never_runs_external_reads(self):
        self.verify()
        checks = self.checks()
        before = self.calls_file.read_bytes()
        self.cli("plugin", "disable", "agent-memory")
        refused = self.run_plugin("verify", {"task_id": self.task, "artifact_id": self.artifact["id"]}, ok=False)
        self.assertEqual(refused["error"]["code"], "PLUGIN_DISABLED")
        self.assertEqual(self.checks(), checks)
        self.assertEqual(self.calls_file.read_bytes(), before)
        backup = self.directory / "saved.sqlite3"
        self.rpc("backup.create", {"path": str(backup)})
        self.rpc("backup.restore", {"path": str(backup)})
        self.assertEqual(self.checks(), checks)
        for format in ("json", "markdown"):
            self.assertIn("current", self.rpc("export", {"format": format})["result"]["content"])


if __name__ == "__main__":
    unittest.main()
