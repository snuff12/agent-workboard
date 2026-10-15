"""Verify plugin retries, execution isolation, and termination boundaries with the actual CLI and service.

Python is used only for development checks, not as a core runtime dependency.
Run: python3 tests/test_plugin_runtime.py (run cargo build --workspace first)
"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "target/debug/workboard"
SERVICE = ROOT / "target/debug/workboard-service"


class PluginRuntime(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="awb-runtime-", dir="/tmp")
        self.directory = Path(self.temp.name)
        self.data = self.directory / "data"
        self.socket = self.directory / "s.sock"
        self.clients = []
        self.plugin_groups = []
        self.server = subprocess.Popen([str(SERVICE), "--data-dir", str(self.data), "--socket", str(self.socket)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 6
        while True:
            self.assertIsNone(self.server.poll(), "The service exited during startup")
            try:
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.connect(str(self.socket))
                break
            except OSError:
                self.assertLess(time.monotonic(), deadline, "Service socket connection timed out")
                time.sleep(0.02)

    def tearDown(self):
        for group in self.plugin_groups:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for process in self.clients:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=3)
        if self.server.poll() is None:
            self.server.terminate()
        self.server.wait(timeout=5)
        self.temp.cleanup()

    def command(self, *arguments):
        return [str(CLI), "--data-dir", str(self.data), "--socket", str(self.socket), "--json", *map(str, arguments)]

    def cli(self, *arguments, ok=True, timeout=8):
        result = subprocess.run(self.command(*arguments), text=True, capture_output=True, timeout=timeout)
        try:
            response = json.loads(result.stdout)
        except json.JSONDecodeError:
            self.fail(f"CLI JSON response error: exit={result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r}")
        self.assertEqual(response["ok"], ok, response)
        self.assertEqual(result.returncode == 0, ok, response)
        return response

    def rpc(self, method, params=None, **options):
        request_id = options.pop("request_id", None)
        arguments = ["rpc", method, "--params", json.dumps(params or {}, ensure_ascii=False)]
        if request_id:
            arguments.extend(["--request-id", request_id])
        return self.cli(*arguments, **options)

    def package(self, body, *, name="probe", methods=None, timeout=5, allowed=None, directory=None, read_only=None):
        package = directory or self.directory / name
        package.mkdir(parents=True, exist_ok=True)
        manifest = {"id": name, "name": "Execution boundary checks", "version": "1.0", "protocol_version": 1,
                    "executable": "plugin.py", "methods": methods or ["mutate", "check"],
                    "allowed_requests": allowed if allowed is not None else ["task.create", "task.attach"],
                    "timeout_seconds": timeout, "read_only_methods": read_only or ["check"]}
        (package / "plugin.json").write_text(json.dumps(manifest))
        executable = package / "plugin.py"
        executable.write_text("#!/usr/bin/env python3\n" + body)
        executable.chmod(0o700)
        return package

    def install(self, package, name="probe"):
        self.cli("plugin", "install", package)
        self.cli("plugin", "enable", name)

    def run_plugin(self, params=None, *, method="mutate", request_id="plugin-request", ok=True, timeout=8):
        return self.cli("plugin", "run", "probe", method, "--params", json.dumps(params or {}),
                        "--request-id", request_id, ok=ok, timeout=timeout)

    def project(self):
        return self.rpc("project.create", {"name": "Plugin execution checks"})["result"]["project_id"]

    def prepare_mutating_package(self):
        return self.package('''import datetime,json,os
from pathlib import Path
import sys
request=json.load(sys.stdin)
params=request["params"]
state=Path(os.environ["WORKBOARD_PLUGIN_DATA_DIR"])
state.mkdir(parents=True,exist_ok=True)
count=state/"invocations"
count.write_text(str(int(count.read_text())+1 if count.exists() else 1))
verified=datetime.datetime.now(datetime.timezone.utc).isoformat()
attachment={"task_id":{"$result":"/0/task_id"},"path":"https://example.com/source","kind":"evidence","metadata":{"provider":"probe","verified_at":verified,"locator":"L10"}}
if params.get("run_id"):
    attachment["run_id"]=params["run_id"]
print(json.dumps({"ok":True,"result":{"verified_at":verified},"requests":[
    {"method":"task.create","params":{"project_id":params["project_id"],"title":"Create only once"}},
    {"method":"task.attach","params":attachment}]}))
''')

    def invocation_count(self):
        return int((self.data / "plugin-data/probe/invocations").read_text())

    def test_completed_retry_has_one_external_invocation_and_no_duplicate_tasks_or_evidence(self):
        self.install(self.prepare_mutating_package())
        params = {"project_id": self.project()}
        first = self.run_plugin(params)
        second = self.run_plugin(params)
        self.assertEqual(first, second)
        self.assertEqual(self.invocation_count(), 1)
        tasks = self.rpc("task.list")["result"]["tasks"]
        self.assertEqual(len(tasks), 1)
        artifacts = self.rpc("task.get", {"task_id": tasks[0]["id"]})["result"]["artifacts"]
        self.assertEqual(len(artifacts), 1)
        self.assertEqual(artifacts[0]["metadata"]["verified_at"], first["result"]["result"]["verified_at"])
        conflict = self.run_plugin({**params, "different": True}, ok=False)
        self.assertEqual(conflict["error"]["code"], "REQUEST_ID_CONFLICT")
        self.assertEqual(self.invocation_count(), 1)

    def test_maximum_length_request_id_remains_valid_for_plugin_core_subrequests(self):
        self.install(self.prepare_mutating_package())
        params = {"project_id": self.project()}
        request_id = "r" * 200
        first = self.run_plugin(params, request_id=request_id)
        self.assertEqual(self.run_plugin(params, request_id=request_id), first)
        self.assertEqual(self.invocation_count(), 1)
        self.assertEqual(len(self.rpc("task.list")["result"]["tasks"]), 1)

    def test_prepared_retry_recovers_partial_core_failure_without_repeating_external_work(self):
        self.install(self.prepare_mutating_package())
        params = {"project_id": self.project(), "run_id": "available-after-first-try"}
        self.run_plugin(params, ok=False)
        self.assertEqual(self.invocation_count(), 1)
        tasks = self.rpc("task.list")["result"]["tasks"]
        self.assertEqual(len(tasks), 1)
        self.rpc("task.start", {"task_id": tasks[0]["id"], "run_id": params["run_id"], "agent_id": "test"})
        recovered = self.run_plugin(params)
        self.assertEqual(self.invocation_count(), 1)
        detail = self.rpc("task.get", {"task_id": tasks[0]["id"]})["result"]
        self.assertEqual(len(self.rpc("task.list")["result"]["tasks"]), 1)
        self.assertEqual(len(detail["artifacts"]), 1)
        self.assertEqual(detail["artifacts"][0]["metadata"]["verified_at"], recovered["result"]["result"]["verified_at"])
        self.assertEqual(self.run_plugin(params), recovered)

    def stable_operation_package(self, name="probe"):
        return self.package('''import json,sys
request=json.load(sys.stdin)
params=request["params"]
print(json.dumps({"ok":True,"result":{},"requests":[{"method":"task.create",
    "idempotency_key":params["key"],"params":{"project_id":params["project_id"],"title":params.get("title","Recovered task")}}]}))
''', name=name)

    def test_stable_operation_recovers_across_requests_and_is_scoped_to_plugin(self):
        self.install(self.stable_operation_package())
        params = {"project_id": self.project(), "key": "one-operation"}
        first = self.run_plugin(params, request_id="first")
        second = self.run_plugin(params, request_id="recovery")
        self.assertEqual(first["result"]["applied"], second["result"]["applied"])
        self.assertEqual(len(self.rpc("task.list")["result"]["tasks"]), 1)
        conflict = self.run_plugin(dict(params, title="Different content"), request_id="conflict", ok=False)
        self.assertEqual(conflict["error"]["code"], "REQUEST_ID_CONFLICT")
        self.install(self.stable_operation_package("other"), name="other")
        self.cli("plugin", "run", "other", "mutate", "--params", json.dumps(params), "--request-id", "other-plugin")
        self.assertEqual(len(self.rpc("task.list")["result"]["tasks"]), 2)

    def test_invalid_stable_operation_keys_do_not_mutate_board(self):
        self.install(self.stable_operation_package())
        project = self.project()
        for index, key in enumerate((None, [], 123, "", "   ", "x" * 201, "null\x00key")):
            response = self.run_plugin({"project_id": project, "key": key}, request_id="invalid-" + str(index), ok=False)
            self.assertEqual(response["error"]["code"], "PLUGIN_INVALID_RESPONSE")
        self.assertEqual(self.rpc("task.list")["result"]["tasks"], [])

    def test_invalid_key_later_in_batch_rejects_all_mutations(self):
        package = self.package('''import json,sys
request=json.load(sys.stdin)
params={"project_id":request["params"]["project_id"],"title":"Prevent partial application"}
print(json.dumps({"ok":True,"result":{},"requests":[
    {"method":"task.create","idempotency_key":"valid-first","params":params},
    {"method":"task.create","idempotency_key":None,"params":params}]}))
''')
        self.install(package)
        response = self.run_plugin({"project_id": self.project()}, ok=False)
        self.assertEqual(response["error"]["code"], "PLUGIN_INVALID_RESPONSE")
        self.assertEqual(self.rpc("task.list")["result"]["tasks"], [])

    def test_readonly_method_cannot_return_core_mutations(self):
        project = self.project()
        package = self.package('''import json,sys
request=json.load(sys.stdin)
print(json.dumps({"ok":True,"result":{},"requests":[{"method":"task.create","params":{"project_id":request["params"]["project_id"],"title":"Prevent writes from read operations"}}]}))
''', methods=["search"], read_only=["search"])
        self.install(package)
        response = self.run_plugin({"project_id": project}, method="search", ok=False)
        self.assertEqual(response["error"]["code"], "PLUGIN_PERMISSION_DENIED")
        self.assertEqual(self.rpc("task.list")["result"]["tasks"], [])

    def test_plugin_cannot_delete_or_restore_even_when_manifest_allows_it(self):
        project = self.project()
        task = self.rpc("task.create", {"project_id": project, "title": "Plugins cannot delete"})["result"]["task_id"]
        package = self.package('''import json,sys
params=json.load(sys.stdin)["params"]
first={"method":"task.create","params":{"project_id":params["project_id"],"title":"Must not be applied first"}}
print(json.dumps({"ok":True,"result":{},"requests":[first,{"method":params["method"],"params":params["target"]}]}))
''', allowed=["task.create", "task.delete", "project.delete", "backup.restore"])
        self.install(package)
        for method, target in [("task.delete", {"task_id": task}), ("project.delete", {"project_id": project, "with_tasks": True}),
                               ("backup.restore", {"path": str(self.directory / "missing.sqlite3")})]:
            response = self.run_plugin({"project_id": project, "method": method, "target": target},
                                       request_id=f"deny-{method}", ok=False)
            self.assertEqual(response["error"]["code"], "PLUGIN_PERMISSION_DENIED", method)
        tasks = self.rpc("task.list", {"project_id": project})["result"]["tasks"]
        self.assertEqual([t["id"] for t in tasks], [task], "Do not apply requests preceding a forbidden request")

    def wait_file(self, path):
        deadline = time.monotonic() + 5
        while not path.exists():
            self.assertLess(time.monotonic(), deadline, f"Plugin execution marker missing: {path}")
            time.sleep(0.02)
        return json.loads(path.read_text())

    @staticmethod
    def is_running(pid):
        result = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], text=True, capture_output=True, timeout=2)
        state = result.stdout.strip()
        return bool(state) and not state.startswith("Z")

    def test_large_unread_stdin_is_cancelled_and_descendants_are_stopped(self):
        package = self.package('''import json,os,subprocess,sys,time
from pathlib import Path
state=Path(os.environ["WORKBOARD_PLUGIN_DATA_DIR"])
state.mkdir(parents=True,exist_ok=True)
child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"])
(state/"started").write_text(json.dumps({"pid":os.getpid(),"child":child.pid}))
time.sleep(30)
''', methods=["hang"], timeout=20)
        self.install(package)
        process = subprocess.Popen(self.command("plugin", "run", "probe", "hang", "--params", json.dumps({"body": "x" * 120000})),
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.clients.append(process)
        pids = self.wait_file(self.data / "plugin-data/probe/started")
        self.plugin_groups.append(pids["pid"])
        started = time.monotonic()
        self.cli("plugin", "disable", "probe", timeout=3)
        stdout, stderr = process.communicate(timeout=3)
        self.assertLess(time.monotonic() - started, 2.5)
        self.assertEqual(json.loads(stdout)["error"]["code"], "PLUGIN_DISABLED", stderr)
        deadline = time.monotonic() + 2
        while any(self.is_running(pid) for pid in pids.values()):
            self.assertLess(time.monotonic(), deadline, "The plugin child process did not exit")
            time.sleep(0.03)
        self.cli("doctor")

    def test_stderr_limit_stops_plugin_and_leaves_core_healthy(self):
        self.install(self.package('''import sys,time
sys.stderr.write("x"*(3*1024*1024));sys.stderr.flush();time.sleep(20)
''', methods=["spam"], timeout=10))
        started = time.monotonic()
        response = self.run_plugin(method="spam", ok=False, timeout=4)
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(response["error"]["code"], "PLUGIN_OUTPUT_TOO_LARGE")
        self.assertFalse(list((self.data / "plugins").glob(".run-*")))
        self.cli("doctor")

    def test_timeout_stops_plugin_and_leaves_core_healthy(self):
        self.install(self.package("import time\ntime.sleep(20)\n", methods=["slow"], timeout=1))
        started = time.monotonic()
        response = self.run_plugin(method="slow", ok=False, timeout=4)
        self.assertGreaterEqual(time.monotonic() - started, 1)
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(response["error"]["code"], "PLUGIN_TIMEOUT")
        self.assertFalse(list((self.data / "plugins").glob(".run-*")))
        self.cli("doctor")

    def test_recursive_source_install_is_rejected_before_copying(self):
        self.package('print("{}")\n', directory=self.data)
        response = self.cli("plugin", "install", self.data, ok=False, timeout=3)
        self.assertIn("containing", response["error"]["message"])
        self.assertEqual(self.cli("plugin", "list")["result"]["plugins"], [])
        self.assertFalse(list((self.data / "plugins").glob(".install-*")))

    def test_excessive_depth_is_rejected_and_staging_is_removed(self):
        package = self.package('print("{}")\n')
        nested = package
        for _ in range(18):
            nested /= "nested"
        nested.mkdir(parents=True)
        response = self.cli("plugin", "install", package, ok=False, timeout=3)
        self.assertIn("nesting limit", response["error"]["message"])
        self.assertFalse(list((self.data / "plugins").glob(".install-*")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
