#!/usr/bin/env python3
"""Isolated installer checks. launchctl is simulated; HOME is never changed."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Installer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory(prefix="awbisrc-", dir="/tmp")
        cls.source = Path(cls.shared.name) / "source.app"
        seed = os.environ.get("WORKBOARD_INSTALL_TEST_APP")
        if seed:
            subprocess.run(["ditto", seed, str(cls.source)], check=True)
        else:
            # Signing and bundle replacement need a valid app, not a running GUI.
            # Build a minimal fixture so this suite also runs on a clean checkout.
            (cls.source / "Contents/MacOS").mkdir(parents=True)
            (cls.source / "Contents/Resources").mkdir()
            (cls.source / "Contents/Helpers").mkdir()
            with (cls.source / "Contents/Info.plist").open("wb") as output:
                plistlib.dump({"CFBundleIdentifier": "local.agentworkboard.install-tests",
                    "CFBundleExecutable": "WorkboardApp", "CFBundlePackageType": "APPL",
                    "CFBundleVersion": "1", "CFBundleName": "Agent Workboard"}, output)
        helpers = cls.source / "Contents/Helpers"
        subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-O2", str(ROOT / "scripts/install-lock.c"), "-o", str(helpers / "workboard-install-lock")], check=True)
        if not seed:
            shutil.copy2(helpers / "workboard-install-lock", cls.source / "Contents/MacOS/WorkboardApp")
        for name in ("workboard", "workboard-service"):
            shutil.copy2(ROOT / "target/debug" / name, helpers / name)
        for name in ("workboard", "workboard-service", "workboard-install-lock"):
            subprocess.run(["codesign", "--force", "--sign", "-", str(helpers / name)], check=True, capture_output=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(cls.source)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.shared.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="awbi-", dir="/tmp")
        self.base = Path(self.temporary.name)
        self.destination = self.base / "apps"
        self.app = self.destination / "Agent Workboard.app"
        self.data, self.socket = self.base / "data", self.base / "s.sock"
        self.bin = self.base / "bin"
        self.state = self.base / "launch-state.json"
        self.agents = self.base / "agents"
        self.label = "local.agentworkboard.test." + self.base.name
        self.processes = []
        tools = self.base / "tools"
        tools.mkdir()
        launchctl = tools / "launchctl"
        launchctl.write_text('''#!/usr/bin/env python3
import json, os, pathlib, plistlib, signal, socket, subprocess, sys, time, uuid
state = pathlib.Path(os.environ["WORKBOARD_INSTALL_TEST_STATE"])
if sys.argv[1] == "print":
    if not state.exists(): sys.exit(113)
    info = json.loads(state.read_text())
    print("program = " + info["program"])
    print("pid = " + str(info["pid"]))
elif sys.argv[1] == "bootout":
    if not state.exists(): sys.exit(113)
    info = json.loads(state.read_text())
    try: os.kill(info["pid"], signal.SIGTERM)
    except ProcessLookupError: pass
    state.unlink()
elif sys.argv[1] == "bootstrap":
    if os.environ.get("WORKBOARD_INSTALL_BOOTSTRAP_FAIL") == "1": sys.exit(81)
    with open(sys.argv[3], "rb") as source: config = plistlib.load(source)
    process = subprocess.Popen(config["ProgramArguments"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, start_new_session=True, env={**os.environ, **config.get("EnvironmentVariables", {})})
    state.write_text(json.dumps({"pid": process.pid, "program": config["ProgramArguments"][0]}))
    failure = state.with_suffix(".failed")
    if os.environ.get("WORKBOARD_INSTALL_FAIL_AFTER_START") == "1" and not failure.exists():
        endpoint = config["ProgramArguments"][4]
        def rpc(method, params):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(10)
                connection.connect(endpoint)
                request = {"schema_version": 1, "request_id": str(uuid.uuid4()), "method": method, "params": params}
                connection.sendall((json.dumps(request) + "\\n").encode())
                response = connection.makefile("rb").readline()
                result = json.loads(response)
                if not result["ok"]: raise RuntimeError(result)
                return result["result"]
        for attempt in range(200):
            try:
                health = rpc("doctor", {})
                break
            except OSError: time.sleep(0.1)
        else: raise RuntimeError("New service did not become ready")
        project = rpc("project.list", {})["projects"][0]["id"]
        rpc("task.create", {"project_id": project, "title": "Accepted after migration"})
        failure.write_text(json.dumps(health))
        sys.exit(81)
else: sys.exit(2)
''')
        launchctl.chmod(0o755)
        register = tools / "lsregister"
        register.write_text('#!/bin/sh\nif [ "${WORKBOARD_INSTALL_REGISTER_FAIL:-0}" = 1 ]; then exit 82; fi\nexit 0\n')
        register.chmod(0o755)
        self.environment = {**{key: value for key, value in os.environ.items() if not key.startswith("WORKBOARD_")}, "PATH": str(tools) + ":" + os.environ["PATH"],
                            "WORKBOARD_INSTALL_TEST_STATE": str(self.state)}
        self.environment.pop("WORKBOARD_DATA_DIR", None)
        self.environment.pop("WORKBOARD_SOCKET", None)

    def tearDown(self):
        # Kill only writers that have this test's exact service.lock open.
        lock = self.data / "service.lock"
        if lock.exists():
            output = subprocess.run(["lsof", "-a", "-u", str(os.getuid()), "-t", str(lock)], capture_output=True, text=True).stdout
            for value in output.split():
                try: os.kill(int(value), signal.SIGTERM)
                except ProcessLookupError: pass
        for process in self.processes:
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        self.temporary.cleanup()

    def install(self, *extra, source=None, env=None, success=True):
        command = [str(ROOT / "scripts/install-local.sh"), "--app", str(source or self.source),
            "--destination", str(self.destination), "--bin-dir", str(self.bin), "--data-dir", str(self.data),
            "--socket", str(self.socket), "--service-label", self.label, "--agent-dir", str(self.agents),
            "--log-dir", str(self.base / "logs"), *extra]
        result = subprocess.run(command, env=env or self.environment, capture_output=True, text=True, timeout=120)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def start_manual(self, binary=None):
        binary = binary or self.source / "Contents/Helpers/workboard-service"
        process = subprocess.Popen([str(binary), "--data-dir", str(self.data), "--socket", str(self.socket)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=self.environment)
        self.processes.append(process)
        self.wait_socket()
        return process

    def wait_socket(self):
        for _ in range(100):
            if self.socket.exists(): return
            time.sleep(0.04)
        self.fail("The test service socket was not created")

    def rpc(self, method, params):
        output = subprocess.run([str(self.bin / "workboard"), "--data-dir", str(self.data), "--socket", str(self.socket),
            "--json", "rpc", method, "--params", json.dumps(params)], capture_output=True, text=True, timeout=10)
        result = json.loads(output.stdout)
        self.assertTrue(result["ok"], result)
        return result["result"]

    def test_same_source_destination_remains_complete(self):
        self.install("--skip-register")
        self.install("--skip-register", source=self.app)
        self.assertTrue((self.app / "Contents/Helpers/workboard-install-lock").is_file())
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(self.app)], check=True)
        self.assertEqual(Path(os.readlink(self.bin / "workboard")).resolve(), (self.app / "Contents/Helpers/workboard").resolve())

    def test_manual_service_handover_keeps_tasks_and_one_writer(self):
        self.install("--skip-register")
        old = self.start_manual()
        project = self.rpc("project.create", {"name": "Preservation check"})["project_id"]
        self.rpc("task.create", {"project_id": project, "title": "Preserved after service replacement"})
        self.install("--skip-register", "--start-service")
        old.wait(timeout=5)
        self.assertNotEqual(json.loads(self.state.read_text())["pid"], old.pid)
        self.assertEqual(len(self.rpc("task.list", {})["tasks"]), 1)
        with (self.agents / (self.label + ".plist")).open("rb") as source:
            config = plistlib.load(source)
        self.assertEqual(config["ProgramArguments"][1:], ["--data-dir", str(self.data.resolve()), "--socket", str(self.socket)])
        self.assertEqual(config["KeepAlive"], {"SuccessfulExit": False})
        self.assertNotIn("EnvironmentVariables", config)

    def test_managed_update_restarts_only_the_same_board(self):
        self.install("--skip-register", "--start-service")
        old = json.loads(self.state.read_text())["pid"]
        self.install("--skip-register")
        self.assertNotEqual(json.loads(self.state.read_text())["pid"], old)
        self.assertTrue(self.rpc("doctor", {})["healthy"])

    def test_managed_pid_mismatch_is_not_signalled(self):
        self.install("--skip-register", "--start-service")
        info = json.loads(self.state.read_text())
        old_pid = info["pid"]
        info["pid"] = os.getpid()
        self.state.write_text(json.dumps(info))
        result = self.install("--skip-register", success=False)
        self.assertIn("The LaunchAgent PID differs", result.stderr)
        os.kill(old_pid, 0)

    def test_auto_start_waits_for_install_lock(self):
        self.data.mkdir()
        marker = self.base / "lock-held"
        holder = subprocess.Popen([str(self.source / "Contents/Helpers/workboard-install-lock"), "--lock", str(self.data / "install.lock"),
            "--", "/bin/bash", "-c", 'touch "$1"; sleep 1.2', "bash", str(marker)])
        self.processes.append(holder)
        for _ in range(100):
            if marker.exists(): break
            time.sleep(0.02)
        self.assertTrue(marker.exists())
        cli = subprocess.Popen([str(self.source / "Contents/Helpers/workboard"), "--data-dir", str(self.data), "--socket", str(self.socket),
            "--json", "doctor"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(cli)
        time.sleep(0.2)
        self.assertFalse(self.socket.exists(), "Automatic startup must wait for the installation lock")
        holder.wait(timeout=5)
        output, error = cli.communicate(timeout=10)
        self.assertEqual(cli.returncode, 0, output + error + ((self.data / "service.log").read_text() if (self.data / "service.log").exists() else ""))
        self.assertTrue(json.loads(output)["ok"])

    def test_registration_failure_restores_app_links_and_manual_service(self):
        self.install("--skip-register")
        marker = self.app / "Contents/Resources/previous-marker"
        marker.write_text("previous")
        subprocess.run(["codesign", "--force", "--sign", "-", str(self.app)], check=True, capture_output=True)
        old = self.start_manual(self.app / "Contents/Helpers/workboard-service")
        self.install("--start-service", env={**self.environment, "WORKBOARD_INSTALL_REGISTER_FAIL": "1"}, success=False)
        old.wait(timeout=5)
        self.wait_socket()
        self.assertEqual(marker.read_text(), "previous")
        self.assertTrue(self.rpc("doctor", {})["healthy"])
        self.assertFalse(self.state.exists())
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(self.app)], check=True)

    def test_bootstrap_failure_keeps_compatible_app_and_recovers_manual_access(self):
        self.install("--skip-register")
        old = self.start_manual(self.app / "Contents/Helpers/workboard-service")
        result = self.install("--start-service", "--skip-register", env={**self.environment, "WORKBOARD_INSTALL_BOOTSTRAP_FAIL": "1"}, success=False)
        old.wait(timeout=5)
        self.wait_socket()
        self.assertTrue(self.rpc("doctor", {})["healthy"])
        self.assertTrue((self.agents / (self.label + ".plist")).exists())
        self.assertIn("automatic downgrade is unsafe", result.stderr)
        self.assertTrue(list(self.destination.glob(".workboard-install.*/previous.app")))

    def test_failure_after_migration_preserves_new_app_and_new_writes(self):
        self.install("--skip-register")
        marker = self.app / "Contents/Resources/previous-marker"
        marker.write_text("previous")
        subprocess.run(["codesign", "--force", "--sign", "-", str(self.app)], check=True, capture_output=True)
        old = self.start_manual(self.app / "Contents/Helpers/workboard-service")
        project = self.rpc("project.create", {"name": "Upgrade recovery"})["project_id"]
        self.rpc("task.create", {"project_id": project, "title": "Present before migration"})
        old.terminate()
        old.wait(timeout=10)
        # Reconstruct the previous schema only in this stopped, disposable fixture.
        with sqlite3.connect(self.data / "workboard.sqlite3") as database:
            database.executescript("DROP TRIGGER task_completion_transition; ALTER TABLE tasks DROP COLUMN completed_at; PRAGMA user_version=7;")
        result = self.install("--start-service", "--skip-register",
            env={**self.environment, "WORKBOARD_INSTALL_FAIL_AFTER_START": "1"}, success=False)
        self.assertEqual(json.loads(self.state.with_suffix(".failed").read_text())["database_version"], 8)
        self.assertFalse(marker.exists(), "An old app was restored over the migrated database")
        self.assertIn("The new task service is healthy", result.stderr)
        self.assertEqual({task["title"] for task in self.rpc("task.list", {})["tasks"]},
                         {"Present before migration", "Accepted after migration"})
        archives = list(self.destination.glob(".workboard-install.*/previous.app/Contents/Resources/previous-marker"))
        self.assertEqual(len(archives), 1, "The previous app recovery copy was discarded")
        self.install("--start-service", "--skip-register")
        self.assertEqual(len(self.rpc("task.list", {})["tasks"]), 2)

    def test_unrecognized_service_path_is_not_signalled(self):
        foreign = self.base / "foreign/workboard-service"
        foreign.parent.mkdir()
        shutil.copy2(self.source / "Contents/Helpers/workboard-service", foreign)
        process = self.start_manual(foreign)
        result = self.install("--start-service", "--skip-register", success=False)
        self.assertIn("service executable managed by this installation could not be verified", result.stderr)
        self.assertIsNone(process.poll())
        self.assertFalse(self.app.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
