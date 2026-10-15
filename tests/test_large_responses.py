"""Large results built from valid requests must not be truncated by the CLI or fail on retry."""
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "target/debug/workboard"
SERVICE = ROOT / "target/debug/workboard-service"


class LargeResponses(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="awb-response-", dir="/tmp")
        self.directory = Path(self.temp.name)
        self.data = self.directory / "data"
        self.socket = self.directory / "s.sock"
        self.log = self.directory / "service.log"
        self.log_handle = self.log.open("wb")
        self.server = subprocess.Popen([str(SERVICE), "--data-dir", str(self.data), "--socket", str(self.socket)],
                                       stdout=subprocess.DEVNULL, stderr=self.log_handle)
        deadline = time.monotonic() + 5
        while not self.socket.exists():
            self.assertIsNone(self.server.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.02)

    def tearDown(self):
        if self.server.poll() is None:
            self.server.terminate()
        self.server.wait(timeout=5)
        self.log_handle.close()
        self.temp.cleanup()

    def direct(self, method, params):
        frame = json.dumps({"schema_version": 1, "request_id": str(uuid.uuid4()),
                            "method": method, "params": params}).encode() + b"\n"
        self.assertLess(len(frame), 1024 * 1024, "Each request stays within the actual service’s 1 MiB limit")
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(15)
            connection.connect(str(self.socket))
            try:
                connection.sendall(frame)
            except OSError as error:
                self.fail(f"{error}; server={self.server.poll()}; log={self.log.read_text()[-4000:]}")
            response = json.loads(connection.makefile("rb").readline())
        self.assertTrue(response["ok"], response.get("error"))
        return response["result"]

    def cli(self, method, params=None, *, request_id=None):
        arguments = [str(CLI), "--json", "--data-dir", str(self.data), "--socket", str(self.socket),
                     "rpc", method, "--params", json.dumps(params or {})]
        if request_id:
            arguments.extend(["--request-id", request_id])
        result = subprocess.run(arguments, text=True, capture_output=True, timeout=30)
        response = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0, response.get("error"))
        self.assertTrue(response["ok"], response.get("error"))
        return response, len(result.stdout.encode())

    def test_fragmented_request_waits_for_the_remaining_frame(self):
        frame = json.dumps({"schema_version": 1, "request_id": "split-frame", "method": "project.create",
                            "params": {"name": "fragmented request"}}).encode() + b"\n"
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(5)
            connection.connect(str(self.socket))
            connection.sendall(frame[:30])
            time.sleep(0.1)
            connection.sendall(frame[30:])
            reply = json.loads(connection.makefile("rb").readline())
        self.assertTrue(reply["ok"], reply.get("error"))
        self.assertEqual(reply["request_id"], "split-frame")

    def test_service_request_limit_includes_the_newline(self):
        request = {"schema_version": 1, "request_id": "maximum-frame", "method": "project.create", "params": {"name": ""}}
        overhead = len(json.dumps(request).encode()) + 1
        request["params"]["name"] = "x" * (1024 * 1024 - overhead)
        for excess in [0, 1]:
            if excess:
                request["params"]["name"] += "x"
            frame = json.dumps(request).encode() + b"\n"
            self.assertEqual(len(frame), 1024 * 1024 + excess)
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(10)
                connection.connect(str(self.socket))
                connection.sendall(frame)
                reply = json.loads(connection.makefile("rb").readline())
            if excess:
                self.assertEqual(reply["error"]["code"], "REQUEST_TOO_LARGE")
            else:
                self.assertTrue(reply["ok"], reply.get("error"))

    def test_aggregate_metadata_over_eight_mib_roundtrips_and_committed_retry_replays(self):
        project = self.direct("project.create", {"name": "large history"})["project_id"]
        task = self.direct("task.create", {"project_id": project, "title": "large history"})["task_id"]
        for index in range(10):
            self.direct("task.attach", {"task_id": task, "path": "/test/evidence-" + str(index),
                                        "metadata": {"body": "m" * 900_000, "index": index}})
        before, size = self.cli("task.get", {"task_id": task})
        self.assertGreater(size, 8 * 1024 * 1024)
        self.assertEqual(len(before["result"]["artifacts"]), 10)
        update = {"task_id": task, "expected_revision": before["result"]["task"]["revision"],
                  "title": "committed once"}
        changed, size = self.cli("task.update", update, request_id="large-idempotent-change")
        self.assertGreater(size, 8 * 1024 * 1024)
        replay, _ = self.cli("task.update", update, request_id="large-idempotent-change")
        self.assertEqual(replay, changed)
        self.assertEqual(changed["result"]["task"]["revision"], before["result"]["task"]["revision"] + 1)
        context, size = self.cli("task.resume_context", {"task_id": task})
        self.assertGreater(size, 8 * 1024 * 1024)
        self.assertEqual(len(context["result"]["artifacts"]), 10)

    def test_large_board_and_children_are_not_truncated(self):
        project = self.direct("project.create", {"name": "large board"})["project_id"]
        parent = self.direct("task.create", {"project_id": project, "title": "parent"})["task_id"]
        for index in range(10):
            self.direct("task.create", {"project_id": project, "parent_id": parent,
                                        "title": "child " + str(index), "goal": "g" * 900_000})
        board, size = self.cli("board.snapshot")
        self.assertGreater(size, 8 * 1024 * 1024)
        self.assertEqual(len(board["result"]["tasks"]), 11)
        detail, size = self.cli("task.get", {"task_id": parent})
        self.assertGreater(size, 8 * 1024 * 1024)
        self.assertEqual(detail["result"]["child_count"], 10)
        self.assertEqual(len(detail["result"]["children"]), 10)


if __name__ == "__main__":
    unittest.main(verbosity=2)
