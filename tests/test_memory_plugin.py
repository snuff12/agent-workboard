#!/usr/bin/env python3
"""Independent process tests for the optional amem bridge; never use a real amem."""
import concurrent.futures
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugins" / "agent-memory" / "plugin.py"

FAKE_AMEM = r'''#!__PYTHON__
import hashlib
import json
import os
from pathlib import Path
import sys
import time

args = sys.argv[1:]
with Path(os.environ["FAKE_AMEM_CALLS"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(args, ensure_ascii=False) + "\n")
if args == ["--help"]:
    print("fake amem: search/read/capture")
elif args[0] == "search":
    print(json.dumps({"results": [{"ref": "doc:good", "snippet": "Search hint", "path": os.environ["FAKE_AMEM_SOURCE"]}]}, ensure_ascii=False))
elif args[0] == "read":
    reference = args[1]
    if reference == "doc:bad":
        print("Missing or out-of-scope ref", file=sys.stderr)
        sys.exit(3)
    source = Path(os.environ["FAKE_AMEM_SOURCE"])
    if reference != "doc:missing-path":
        print("path: " + str(source))
    if reference != "doc:missing-collection":
        print("collection: " + ("another-collection" if reference == "doc:wrong-collection" else "reviewed-docs"))
    if reference != "doc:missing-hash":
        print("sha256: " + hashlib.sha256(source.read_bytes()).hexdigest())
    if reference == "doc:duplicate-header":
        print("path: /ambiguous/other-source.md")
    if reference != "doc:no-boundary":
        print("--- L12-L19 | ref " + reference + " ---")
    print(source.read_text())
    if reference == "doc:body-header":
        print("path: /untrusted/body/path.md")
        print("collection: reviewed-docs")
        print("sha256: untrusted-body-hash")
elif args[0] == "capture":
    if os.environ.get("FAKE_CAPTURE_DELAY"):
        time.sleep(float(os.environ["FAKE_CAPTURE_DELAY"]))
    if os.environ.get("FAKE_CAPTURE_FAIL") == "1":
        print("External save attempted but response not confirmed", file=sys.stderr)
        sys.exit(4)
    print("inbox candidate saved")
else:
    print("unsupported fake amem command", file=sys.stderr)
    sys.exit(2)
'''


class MemoryPluginTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="workboard-memory-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "Source document.md"
        self.source.write_text("Source to verify\nEvidence from an unchanged external file\n", encoding="utf-8")
        self.calls_file = self.directory / "calls.jsonl"
        self.executable = self.directory / "fake amem executable"
        self.executable.write_text(FAKE_AMEM.replace("__PYTHON__", sys.executable), encoding="utf-8")
        self.executable.chmod(0o700)
        self.state = self.directory / "plugin-state"
        self.environment = dict(os.environ, FAKE_AMEM_CALLS=str(self.calls_file), FAKE_AMEM_SOURCE=str(self.source), WORKBOARD_PLUGIN_DATA_DIR=str(self.state))
        self.scope = {"collection": "reviewed-docs", "project": "agent-workboard", "domain": "architecture"}

    def invoke(self, method, params=None, request_id="test-request", environment=None, executable=None):
        request = {"protocol_version": 1, "request_id": request_id, "method": method,
                   "config": {"executable": str(executable or self.executable)}, "params": params or {}}
        completed = subprocess.run([sys.executable, str(PLUGIN)], input=json.dumps(request, ensure_ascii=False), text=True,
                                   capture_output=True, env=environment or self.environment, timeout=10)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        response = json.loads(completed.stdout)
        self.assertIn("ok", response)
        return response

    def calls(self):
        return [json.loads(line) for line in self.calls_file.read_text(encoding="utf-8").splitlines()] if self.calls_file.exists() else []

    def assert_flag(self, args, flag, expected):
        self.assertIn(flag, args)
        self.assertEqual(args[args.index(flag) + 1], expected)

    def capture_params(self, **changes):
        return dict({"kind": "decision", "title": "Store task state", "body": "Use a persistent database", "confirmed_by_user": True}, **changes)

    def assert_rejected(self, response, part=None):
        self.assertFalse(response["ok"], response)
        self.assertNotIn("requests", response)
        self.assertEqual(response["error"]["code"], "INTEGRATION_UNAVAILABLE")
        if part:
            self.assertIn(part, response["error"]["message"])

    def test_search_uses_reviewed_explain_and_literal_scoped_arguments(self):
        query = "Decision $(never-execute) `literal`"
        response = self.invoke("search", dict(self.scope, query=query, limit=99))
        self.assertTrue(response["ok"], response)
        args = self.calls()[0]
        self.assertEqual(args[:2], ["search", query])
        self.assertIn("--json", args)
        self.assertIn("--explain", args)
        self.assert_flag(args, "--memory-status", "reviewed")
        self.assert_flag(args, "--limit", "10")
        self.assert_flag(args, "--collection", "reviewed-docs")
        self.assert_flag(args, "--project", "agent-workboard")
        self.assert_flag(args, "--domain", "architecture")
        self.assertNotIn("requests", response)
        self.assertEqual(response["result"]["results"][0]["snippet"], "Search hint")

    def test_search_requires_collection_and_query_and_clamps_limit(self):
        self.assert_rejected(self.invoke("search", {"query": "q"}))
        self.assert_rejected(self.invoke("search", {"collection": "reviewed-docs"}))
        self.assertEqual(self.calls(), [])
        self.assertTrue(self.invoke("search", dict(self.scope, query="q", limit=0))["ok"])
        self.assert_flag(self.calls()[0], "--limit", "1")

    def test_read_then_attach_reads_original_again_with_same_scope_and_metadata(self):
        self.assertTrue(self.invoke("search", dict(self.scope, query="Task status"))["ok"])
        params = dict(self.scope, ref="doc:good")
        read = self.invoke("read", params)
        self.assertTrue(read["ok"], read)
        self.assertIn("Source to verify", read["result"]["text"])
        self.assertNotIn("requests", read)
        attached = self.invoke("attach", dict(params, task_id="task-1", description="Verified source"))
        self.assertTrue(attached["ok"], attached)
        calls = self.calls()
        self.assertEqual([args[0] for args in calls], ["search", "read", "read"])
        for args in calls:
            self.assert_flag(args, "--project", self.scope["project"])
            self.assert_flag(args, "--domain", self.scope["domain"])
            self.assert_flag(args, "--memory-status", "reviewed")
        for args in calls[1:]:
            self.assert_flag(args, "--max-tokens", "1600")
        request = attached["requests"][0]
        self.assertEqual(request["method"], "task.attach")
        self.assertEqual(request["params"]["task_id"], "task-1")
        self.assertEqual(request["params"]["path"], str(self.source))
        self.assertEqual(request["params"]["kind"], "evidence")
        metadata = request["params"]["metadata"]
        self.assertEqual(metadata, attached["result"])
        self.assertEqual(metadata["provider"], "agent-memory")
        self.assertEqual(metadata["collection"], self.scope["collection"])
        self.assertEqual(metadata["locator"], "L12-L19")
        self.assertEqual(metadata["source_sha256"], hashlib.sha256(self.source.read_bytes()).hexdigest())
        self.assertEqual(metadata["scope"], {"project": self.scope["project"], "domain": self.scope["domain"]})
        self.assertIsNotNone(datetime.datetime.fromisoformat(metadata["verified_at"]).tzinfo)
        self.assertEqual(self.source.read_text(encoding="utf-8"), "Source to verify\nEvidence from an unchanged external file\n")

    def test_invalid_ref_and_missing_ref_are_rejected(self):
        self.assert_rejected(self.invoke("read", dict(self.scope, ref="doc:bad")), "ref")
        self.assert_rejected(self.invoke("attach", dict(self.scope, ref="doc:bad", task_id="task")), "ref")
        before = len(self.calls())
        self.assert_rejected(self.invoke("attach", dict(self.scope, task_id="task")), "ref")
        self.assertEqual(len(self.calls()), before)

    def test_attach_rejects_missing_source_metadata_collection_mismatch_and_task(self):
        for reference in ("doc:missing-hash", "doc:missing-path", "doc:missing-collection"):
            with self.subTest(reference=reference):
                self.assert_rejected(self.invoke("attach", dict(self.scope, ref=reference, task_id="task")), "source path")
        self.assert_rejected(self.invoke("attach", dict(self.scope, ref="doc:wrong-collection", task_id="task")), "collection")
        self.assert_rejected(self.invoke("attach", dict(self.scope, ref="doc:good")), "task_id")

    def test_source_body_cannot_override_verified_header_metadata(self):
        response = self.invoke("attach", dict(self.scope, ref="doc:body-header", task_id="task"))
        self.assertTrue(response["ok"], response)
        artifact = response["requests"][0]["params"]
        self.assertEqual(artifact["path"], str(self.source))
        self.assertEqual(artifact["metadata"]["source_sha256"], hashlib.sha256(self.source.read_bytes()).hexdigest())

    def test_attach_rejects_ambiguous_header_and_missing_source_boundary(self):
        self.assert_rejected(self.invoke("attach", dict(self.scope, ref="doc:duplicate-header", task_id="task")), "ambiguous")
        self.assert_rejected(self.invoke("attach", dict(self.scope, ref="doc:no-boundary", task_id="task")), "location")

    def test_capture_requires_explicit_true_decision_or_procedure_and_content(self):
        for value in (None, False, 1, "true"):
            with self.subTest(confirmation=value):
                self.assert_rejected(self.invoke("capture", self.capture_params(confirmed_by_user=value)), "explicitly requested")
        for changes in ({"kind": "conversation"}, {"kind": "search"}, {"title": ""}, {"body": ""}):
            with self.subTest(changes=changes):
                self.assert_rejected(self.invoke("capture", self.capture_params(**changes)))
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.state.exists())

    def test_capture_allowed_kinds_are_private_inbox_candidates_without_sync(self):
        for index, kind in enumerate(("decision", "procedure")):
            response = self.invoke("capture", self.capture_params(kind=kind), request_id=f"allowed-{index}")
            self.assertTrue(response["ok"], response)
        for args, kind in zip(self.calls(), ("decision", "procedure")):
            self.assertEqual(args[0], "capture")
            self.assert_flag(args, "--kind", kind)
            self.assertIn("--no-sync", args)
            self.assert_flag(args, "--sensitivity", "private")
            self.assert_flag(args, "--source", "Agent Workboard")
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        for record in self.state.glob("*.json"):
            self.assertEqual(record.stat().st_mode & 0o777, 0o600)

    def test_capture_same_request_id_reuses_response_without_second_external_write(self):
        first = self.invoke("capture", self.capture_params(), request_id="capture-once")
        second = self.invoke("capture", self.capture_params(), request_id="capture-once")
        self.assertTrue(first["ok"], first)
        self.assertEqual(second, first)
        self.assertEqual(len(self.calls()), 1)

    def test_capture_same_request_id_with_changed_body_is_rejected(self):
        first = self.invoke("capture", self.capture_params(), request_id="same-id")
        self.assertTrue(first["ok"], first)
        second = self.invoke("capture", self.capture_params(body="Content different from the original request"), request_id="same-id")
        self.assert_rejected(second, "request ID")
        self.assertEqual(len(self.calls()), 1)

    def test_capture_uncertain_pending_result_blocks_retry_without_reinvoking_amem(self):
        failing_environment = dict(self.environment, FAKE_CAPTURE_FAIL="1")
        first = self.invoke("capture", self.capture_params(), request_id="pending-write", environment=failing_environment)
        self.assert_rejected(first, "External save")
        self.assertEqual(len(self.calls()), 1)
        retried = self.invoke("capture", self.capture_params(), request_id="pending-write")
        self.assert_rejected(retried, "uncertain")
        self.assertEqual(len(self.calls()), 1)

    def test_concurrent_capture_retry_cannot_write_twice(self):
        environment = dict(self.environment, FAKE_CAPTURE_DELAY="0.15")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.invoke("capture", self.capture_params(), request_id="concurrent-write", environment=environment), range(2)))
        self.assertTrue(any(response["ok"] for response in results), results)
        self.assertEqual(len(self.calls()), 1)

    def test_distinct_request_ids_do_not_share_sanitized_capture_record(self):
        first = self.invoke("capture", self.capture_params(title="First decision"), request_id="capture/one")
        second = self.invoke("capture", self.capture_params(title="Another decision"), request_id="capture_one")
        self.assertTrue(first["ok"] and second["ok"], (first, second))
        self.assertEqual(len(self.calls()), 2, "Different requests must not silently reuse an unrelated capture")

    def test_missing_executable_fails_without_any_real_amem_fallback(self):
        response = self.invoke("check", executable=self.directory / "does-not-exist")
        self.assert_rejected(response)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
