"""Real CLI/service/provider process groups; no external service is called."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get("WORKBOARD_TEST_CLI", ROOT / "target/debug/workboard"))
SERVICE = Path(os.environ.get("WORKBOARD_TEST_SERVICE", ROOT / "target/debug/workboard-service"))

PROVIDER = '''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
request = json.load(sys.stdin)
params = request["params"]
grandchild_code = """import os,pathlib,sys,time
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
time.sleep(1.1)
pathlib.Path(sys.argv[2]).write_text('orphan external effect')
time.sleep(30)
"""
child = subprocess.Popen([sys.executable, "-c", grandchild_code, params["grandchild_ready"], params["marker"]])
deadline = time.monotonic() + 5
while not pathlib.Path(params["grandchild_ready"]).exists() and time.monotonic() < deadline:
    time.sleep(0.01)
pathlib.Path(params["ready"]).write_text(json.dumps({"provider":os.getpid(),"grandchild":child.pid,
    "provider_group":os.getpgrp(),"grandchild_group":os.getpgid(child.pid)}))
child.wait()
print(json.dumps({"ok":True,"result":{},"requests":[{"method":"task.create","params":{
    "project_id":params["project_id"],"title":"Task that must not be created after cancellation"}}]}))
'''


class PluginSignals(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="awb-signal-", dir="/tmp")
        self.base = Path(self.temporary.name)
        self.data, self.socket = self.base / "data", self.base / "s.sock"
        self.host = None
        self.group = None
        self.environment = dict(os.environ)
        self.environment.pop("WORKBOARD_WIDGET_SNAPSHOT", None)
        self.server = subprocess.Popen([str(SERVICE), "--data-dir", str(self.data), "--socket", str(self.socket)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=self.environment)
        for _ in range(100):
            if self.socket.exists(): break
            if self.server.poll() is not None: self.fail("Isolated service startup failed")
            time.sleep(0.02)
        self.assertTrue(self.socket.exists())
        self.project = self.rpc("project.create", {"name": "Termination signal checks"})["result"]["project_id"]
        package = self.base / "signal-probe"
        package.mkdir()
        (package / "plugin.json").write_text(json.dumps({"id": "signal-probe", "name": "Signal probe", "version": "1.0.0",
            "protocol_version": 1, "executable": "plugin.py", "methods": ["effect"], "allowed_requests": ["task.create"], "timeout_seconds": 30}))
        executable = package / "plugin.py"
        executable.write_text(PROVIDER)
        executable.chmod(0o755)
        self.cli("plugin", "install", package)
        self.cli("plugin", "enable", "signal-probe")

    def tearDown(self):
        if self.group is not None:
            try: os.killpg(self.group, signal.SIGKILL)
            except ProcessLookupError: pass
        if self.host is not None and self.host.poll() is None:
            self.host.kill()
            self.host.communicate(timeout=5)
        self.server.terminate()
        self.server.wait(timeout=5)
        self.temporary.cleanup()

    def command(self, *arguments):
        return [str(CLI), "--json", "--data-dir", str(self.data), "--socket", str(self.socket), *map(str, arguments)]

    def cli(self, *arguments, success=True):
        output = subprocess.run(self.command(*arguments), env=self.environment, capture_output=True, text=True, timeout=10)
        value = json.loads(output.stdout)
        if success:
            self.assertEqual(output.returncode, 0, output.stdout + output.stderr)
            self.assertTrue(value["ok"], value)
        else:
            self.assertFalse(value["ok"], value)
        return value

    def rpc(self, method, params):
        return self.cli("rpc", method, "--params", json.dumps(params))

    def wait_file(self, path):
        for _ in range(200):
            if path.exists():
                try: return json.loads(path.read_text())
                except json.JSONDecodeError: pass
            if self.host.poll() is not None:
                output, error = self.host.communicate()
                self.fail("CLI exited before readiness: " + output + error)
            time.sleep(0.01)
        self.fail("Provider and grandchild readiness timed out")

    def assert_reaped(self, pid):
        for _ in range(200):
            try: os.kill(pid, 0)
            except ProcessLookupError: return
            time.sleep(0.01)
        state = subprocess.run(["ps", "-p", str(pid), "-o", "stat=,ppid=,comm="], capture_output=True, text=True).stdout
        self.fail("Process remained after termination: " + state)

    def exercise_signal(self, signum):
        request_id = "cancel-" + str(signum)
        ready, marker, grandchild_ready = self.base / "ready.json", self.base / "external-effect", self.base / "grandchild-ready"
        params = {"ready": str(ready), "marker": str(marker), "grandchild_ready": str(grandchild_ready), "project_id": self.project}
        command = self.command("--request-id", request_id, "plugin", "run", "signal-probe", "effect", "--params", json.dumps(params))
        self.host = subprocess.Popen(command, env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        processes = self.wait_file(ready)
        self.group = processes["provider_group"]
        self.assertEqual(processes["provider"], self.group)
        self.assertEqual(processes["grandchild_group"], self.group)
        self.assertNotEqual(self.group, os.getpgrp())
        self.assertFalse(marker.exists())
        os.kill(self.host.pid, signum)
        output, error = self.host.communicate(timeout=5)
        self.assertNotEqual(self.host.returncode, 0)
        response = json.loads(output)
        self.assertEqual(response["error"]["code"], "PLUGIN_CANCELLED", output + error)
        self.assert_reaped(processes["provider"])
        self.assert_reaped(processes["grandchild"])
        time.sleep(1.2)
        self.assertFalse(marker.exists(), "An external action ran after host termination")
        self.assertEqual(self.rpc("task.list", {})["result"]["tasks"], [])
        record = self.data / "plugin-journal" / (hashlib.sha256(request_id.encode()).hexdigest() + ".json")
        self.assertEqual(json.loads(record.read_text())["phase"], "pending")
        original = ready.stat().st_mtime_ns
        retry = self.cli("--request-id", request_id, "plugin", "run", "signal-probe", "effect", "--params", json.dumps(params), success=False)
        self.assertEqual(retry["error"]["code"], "PLUGIN_RESULT_UNCERTAIN")
        self.assertEqual(ready.stat().st_mtime_ns, original)

    def test_sigint_cancels_provider_and_grandchild_without_core_writes(self):
        self.exercise_signal(signal.SIGINT)

    def test_sigterm_cancels_provider_and_grandchild_without_core_writes(self):
        self.exercise_signal(signal.SIGTERM)


if __name__ == "__main__":
    unittest.main(verbosity=2)
