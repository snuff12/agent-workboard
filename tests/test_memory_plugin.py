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
import argparse
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
    if os.environ.get("FAKE_SEARCH_MALFORMED") == "1":
        print("not a JSON response")
        sys.exit(0)
    print(json.dumps({"results": [{"ref": "doc:good", "snippet": "Search hint", "path": os.environ["FAKE_AMEM_SOURCE"]}]}, ensure_ascii=False))
elif args[0] == "read":
    reference = args[1]
    if reference == "doc:bad":
        print("Missing or out-of-scope ref", file=sys.stderr)
        sys.exit(3)
    if reference == "doc:expired":
        print("amem: Document unavailable or changed; search again with the same policy", file=sys.stderr)
        sys.exit(2)
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
    # Parse with the installed amem's capture options so leading dashes are checked as amem would see them.
    parser = argparse.ArgumentParser(prog="amem capture")
    parser.add_argument("--kind", required=True, choices=("decision", "fact", "preference", "episode", "procedure"))
    parser.add_argument("--title", required=True)
    parser.add_argument("--body")
    parser.add_argument("--source", default="manual")
    parser.add_argument("--no-sync", action="store_true")
    parser.add_argument("--scope", default="global")
    parser.add_argument("--sensitivity", choices=("private", "shareable"), default="private")
    parsed = parser.parse_args(args[1:])
    body = parsed.body if parsed.body is not None else sys.stdin.read()
    with Path(os.environ["FAKE_AMEM_CAPTURED"]).open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(dict(vars(parsed), body=body), ensure_ascii=False) + "\n")
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
        self.captured_file = self.directory / "captured.jsonl"
        self.executable = self.directory / "fake amem executable"
        self.executable.write_text(FAKE_AMEM.replace("__PYTHON__", sys.executable), encoding="utf-8")
        self.executable.chmod(0o700)
        self.state = self.directory / "plugin-state"
        self.environment = dict(os.environ, FAKE_AMEM_CALLS=str(self.calls_file), FAKE_AMEM_SOURCE=str(self.source),
                                FAKE_AMEM_CAPTURED=str(self.captured_file), WORKBOARD_PLUGIN_DATA_DIR=str(self.state))
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

    def captured(self):
        return [json.loads(line) for line in self.captured_file.read_text(encoding="utf-8").splitlines()] if self.captured_file.exists() else []

    def assert_flag(self, args, flag, expected):
        self.assertIn(flag, args)
        self.assertEqual(args[args.index(flag) + 1], expected)

    def attached_artifact(self, **params):
        """Attach the fake source and return the artifact as the board would store it."""
        response = self.invoke("attach", dict(self.scope, ref="doc:good", task_id="task-1", **params))
        self.assertTrue(response["ok"], response)
        return dict(response["requests"][0]["params"], id="artifact-1")

    def capture_params(self, **changes):
        return dict({"kind": "decision", "title": "Store task state", "body": "Use a persistent database", "confirmed_by_user": True}, **changes)

    def assert_rejected(self, response, part=None, code="INTEGRATION_UNAVAILABLE"):
        self.assertFalse(response["ok"], response)
        self.assertNotIn("requests", response)
        self.assertEqual(response["error"]["code"], code)
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
        self.assert_rejected(self.invoke("search", {"query": "q"}), code="INVALID_REQUEST")
        self.assert_rejected(self.invoke("search", {"collection": "reviewed-docs"}), code="INVALID_REQUEST")
        self.assert_rejected(self.invoke("search", dict(self.scope, query="q", limit="many")), "limit", "INVALID_REQUEST")
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
        for key in ("provider", "locator", "verified_at"):
            self.assertEqual(request["params"][key], request["params"]["metadata"][key], key)
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
        self.assert_rejected(self.invoke("attach", dict(self.scope, task_id="task")), "ref", "INVALID_REQUEST")
        self.assertEqual(len(self.calls()), before)

    def test_attach_rejects_missing_source_metadata_collection_mismatch_and_task(self):
        for reference in ("doc:missing-hash", "doc:missing-path", "doc:missing-collection"):
            with self.subTest(reference=reference):
                self.assert_rejected(self.invoke("attach", dict(self.scope, ref=reference, task_id="task")), "source path")
        self.assert_rejected(self.invoke("attach", dict(self.scope, ref="doc:wrong-collection", task_id="task")), "collection")
        before = len(self.calls())
        self.assert_rejected(self.invoke("attach", dict(self.scope, ref="doc:good")), "task_id", "INVALID_REQUEST")
        self.assertEqual(len(self.calls()), before, "A request missing task_id must not read the source first")

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
                self.assert_rejected(self.invoke("capture", self.capture_params(confirmed_by_user=value)), "explicitly requested", "INVALID_REQUEST")
        for changes in ({"kind": "conversation"}, {"kind": "search"}, {"title": ""}, {"body": ""},
                        {"project": "agent-workboard", "domain": "architecture"}, {"project": "two words"}, {"domain": "a:b"}):
            with self.subTest(changes=changes):
                self.assert_rejected(self.invoke("capture", self.capture_params(**changes)), code="INVALID_REQUEST")
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.state.exists())

    def test_capture_allowed_kinds_are_private_inbox_candidates_without_sync(self):
        for index, kind in enumerate(("decision", "procedure")):
            response = self.invoke("capture", self.capture_params(kind=kind), request_id=f"allowed-{index}")
            self.assertTrue(response["ok"], response)
        for args, saved, kind in zip(self.calls(), self.captured(), ("decision", "procedure")):
            self.assertEqual(args[0], "capture")
            self.assert_flag(args, "--kind", kind)
            self.assertIn("--no-sync", args)
            self.assert_flag(args, "--sensitivity", "private")
            self.assertFalse(any(arg.startswith("--body") for arg in args), "The body is sent on standard input")
            self.assertEqual((saved["kind"], saved["source"], saved["scope"], saved["body"]),
                             (kind, "Agent Workboard", "global", "Use a persistent database"))
            self.assertTrue(saved["no_sync"])
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
        self.assert_rejected(second, "request ID", "REQUEST_ID_CONFLICT")
        self.assertEqual(len(self.calls()), 1)

    def test_capture_uncertain_pending_result_blocks_retry_without_reinvoking_amem(self):
        failing_environment = dict(self.environment, FAKE_CAPTURE_FAIL="1")
        first = self.invoke("capture", self.capture_params(), request_id="pending-write", environment=failing_environment)
        self.assert_rejected(first, "External save")
        self.assertEqual(len(self.calls()), 1)
        retried = self.invoke("capture", self.capture_params(), request_id="pending-write")
        self.assert_rejected(retried, "uncertain", "PLUGIN_RESULT_UNCERTAIN")
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

    def test_capture_links_scope_task_and_artifact_and_keeps_leading_dashes_literal(self):
        params = self.capture_params(title="-verbose", body="--help",
                                     project="agent-workboard", task_id="task-7", artifact_path="/notes/result.md")
        response = self.invoke("capture", params, request_id="scoped-capture")
        self.assertTrue(response["ok"], response)
        self.assertEqual(response["result"]["scope"], "project:agent-workboard")
        [saved] = self.captured()
        self.assertEqual(saved["title"], "-verbose")
        self.assertEqual(saved["body"], "--help")
        self.assertEqual(saved["scope"], "project:agent-workboard")
        self.assertEqual(saved["source"], "Agent Workboard; task task-7; artifact /notes/result.md")
        domain = self.invoke("capture", self.capture_params(domain="architecture"), request_id="domain-capture")
        self.assertTrue(domain["ok"], domain)
        self.assertEqual(self.captured()[1]["scope"], "domain:architecture")

    def test_attach_keeps_search_query_for_rediscovery(self):
        artifact = self.attached_artifact(query="task state storage")
        self.assertEqual(artifact["metadata"]["query"], "task state storage")
        self.assertNotIn("query", self.attached_artifact()["metadata"])

    def test_verify_reports_current_source_without_mutation_or_search(self):
        artifact = self.attached_artifact(query="task state storage")
        before = len(self.calls())
        response = self.invoke("verify", {"artifact": artifact})
        self.assertTrue(response["ok"], response)
        self.assertNotIn("requests", response)
        result = response["result"]
        self.assertEqual(result["status"], "current")
        self.assertEqual((result["artifact_id"], result["path"]), ("artifact-1", str(self.source)))
        self.assertEqual(result["current_sha256"], result["recorded_sha256"])
        self.assertNotIn("candidates", result)
        [args] = self.calls()[before:]
        self.assertEqual(args[:2], ["read", "doc:good"])
        self.assert_flag(args, "--project", self.scope["project"])
        self.assert_flag(args, "--domain", self.scope["domain"])
        self.assert_flag(args, "--memory-status", "reviewed")

    def test_verify_detects_changed_source_and_rediscovers_with_same_scope(self):
        artifact = self.attached_artifact(query="task state storage")
        self.source.write_text("Source to verify\nThe evidence changed after attachment\n", encoding="utf-8")
        before = len(self.calls())
        response = self.invoke("verify", {"artifact": artifact})
        self.assertTrue(response["ok"], response)
        result = response["result"]
        self.assertEqual(result["status"], "changed")
        self.assertEqual(result["current_sha256"], hashlib.sha256(self.source.read_bytes()).hexdigest())
        self.assertNotEqual(result["current_sha256"], result["recorded_sha256"])
        self.assertEqual([(hit["ref"], hit["same_path"]) for hit in result["candidates"]], [("doc:good", True)])
        self.assertIn("next_step", result)
        read, search = self.calls()[before:]
        self.assertEqual(read[0], "read")
        self.assertEqual(search[:2], ["search", "task state storage"])
        self.assert_flag(search, "--collection", self.scope["collection"])
        self.assert_flag(search, "--project", self.scope["project"])
        self.assert_flag(search, "--domain", self.scope["domain"])
        self.assertIn("--explain", search)

    def test_verify_reports_expired_ref_and_uses_supplied_query_for_older_evidence(self):
        artifact = self.attached_artifact()
        artifact["metadata"] = dict(artifact["metadata"], ref="doc:expired")
        result = self.invoke("verify", {"artifact": artifact})["result"]
        self.assertEqual(result["status"], "unreadable")
        self.assertIn("search again", result["detail"])
        self.assertNotIn("candidates", result, "Without a stored or supplied query, verify must not guess one")
        rediscovered = self.invoke("verify", {"artifact": artifact, "query": "task state storage"})["result"]
        self.assertEqual(rediscovered["status"], "unreadable")
        self.assertEqual(rediscovered["candidates"][0]["ref"], "doc:good")

    def test_verify_reports_rediscovery_failure_without_hiding_the_status(self):
        artifact = self.attached_artifact(query="task state storage")
        artifact["metadata"] = dict(artifact["metadata"], ref="doc:expired")
        environment = dict(self.environment, FAKE_SEARCH_MALFORMED="1")
        result = self.invoke("verify", {"artifact": artifact}, environment=environment)["result"]
        self.assertEqual(result["status"], "unreadable")
        self.assertIn("malformed", result["rediscovery_error"])
        self.assertNotIn("candidates", result)

    def test_verify_rejects_other_artifacts_before_running_amem(self):
        artifact = self.attached_artifact()
        before = len(self.calls())
        for candidate in (None, {"path": "/file.md"}, dict(artifact, metadata=dict(artifact["metadata"], provider="orca")),
                          dict(artifact, metadata=dict(artifact["metadata"], source_sha256=""))):
            with self.subTest(artifact=candidate):
                self.assert_rejected(self.invoke("verify", {"artifact": candidate}), code="INVALID_REQUEST")
        self.assertEqual(len(self.calls()), before)

    def test_verify_fails_instead_of_reporting_unreadable_when_amem_cannot_run(self):
        artifact = self.attached_artifact()
        response = self.invoke("verify", {"artifact": artifact}, executable=self.directory / "does-not-exist")
        self.assert_rejected(response, "Could not run")

    def test_malformed_search_response_is_an_integration_error(self):
        environment = dict(self.environment, FAKE_SEARCH_MALFORMED="1")
        self.assert_rejected(self.invoke("search", dict(self.scope, query="q"), environment=environment), "malformed")

    def test_missing_executable_fails_without_any_real_amem_fallback(self):
        response = self.invoke("check", executable=self.directory / "does-not-exist")
        self.assert_rejected(response, "Could not run")
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
