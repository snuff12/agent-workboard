"""Explicit setup runs independently of board service and normal plugin enablement."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "target/debug/workboard"


def provider(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_") + "_onboarding", ROOT / "plugins" / name / "plugin.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SetupHost(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="awb-setup-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.data, self.sock = self.root / "data", self.root / "s.sock"
        package = self.root / "package"
        self.package = package
        package.mkdir()
        (package / "plugin.json").write_text(json.dumps({"id": "probe", "name": "Setup probe", "version": "1.0.0",
            "protocol_version": 1, "executable": "plugin.py", "methods": ["check"],
            "setup_methods": ["discover", "forbidden", "hang"], "allowed_requests": ["task.create"]}))
        (package / "plugin.py").write_text("#!" + sys.executable + "\n" + r'''
import json, os, time
from pathlib import Path
request=json.load(__import__('sys').stdin)
state=Path(os.environ['WORKBOARD_PLUGIN_DATA_DIR'])
state.mkdir(parents=True,exist_ok=True)
(state/'called').write_text(request['method'])
if request['method']=='hang': time.sleep(20)
response={'ok':True,'result':{'available':True,'config':{'executable':'/detected/tool'}}}
if request['method']=='forbidden': response['requests']=[{'method':'task.create','params':{'title':'Must not exist'}}]
print(json.dumps(response))
''')
        (package / "plugin.py").chmod(0o700)
        self.cli("plugin", "install", package)

    def cli(self, *args, ok=True):
        completed = subprocess.run([str(CLI), "--json", "--data-dir", str(self.data), "--socket", str(self.sock),
                                    *map(str, args)], text=True, capture_output=True, timeout=8)
        response = json.loads(completed.stdout)
        self.assertEqual(response["ok"], ok, response)
        self.assertEqual(completed.returncode == 0, ok, response)
        return response

    def test_install_list_config_and_normal_calls_do_not_discover(self):
        self.cli("plugin", "list")
        self.cli("plugin", "config", "probe")
        self.assertEqual(self.cli("plugin", "check", "probe", ok=False)["error"]["code"], "PLUGIN_DISABLED")
        self.assertFalse((self.data / "plugin-data").exists())
        self.assertFalse(self.sock.exists())

    def test_explicit_discovery_keeps_plugin_disabled_and_service_stopped(self):
        before = (self.data / "plugins/registry.json").read_bytes()
        response = self.cli("rpc", "plugin.setup", "--params", '{"id":"probe","method":"discover"}')["result"]
        self.assertTrue(response["result"]["available"])
        self.assertEqual(response["config"], {})
        self.assertTrue(response["generation"])
        self.assertEqual((self.data / "plugins/registry.json").read_bytes(), before)
        self.assertFalse(self.sock.exists())
        self.assertFalse((self.data / "workboard.sqlite3").exists())

    def test_undeclared_setup_is_rejected_without_execution(self):
        result = self.cli("plugin", "setup", "probe", "capture", ok=False)
        self.assertEqual(result["error"]["code"], "PLUGIN_METHOD_NOT_FOUND")
        self.assertFalse((self.data / "plugin-data").exists())

    def test_setup_cannot_return_board_mutations(self):
        response = self.cli("plugin", "setup", "probe", "forbidden", ok=False)
        self.assertEqual(response["error"]["code"], "PLUGIN_PERMISSION_DENIED")
        self.assertFalse(self.sock.exists())
        self.assertFalse((self.data / "workboard.sqlite3").exists())

    def test_config_generation_guards_discovery_and_enable(self):
        generation = self.cli("plugin", "setup", "probe")["result"]["generation"]
        self.cli("plugin", "disable", "probe")
        marker = self.data / "plugin-data/probe/called"
        marker.unlink()
        result = self.cli("plugin", "setup", "probe", "--expected-generation", generation, ok=False)
        self.assertEqual(result["error"]["code"], "CONFLICT")
        self.assertFalse(marker.exists())
        result = self.cli("plugin", "enable", "probe", "--expected-generation", generation, ok=False)
        self.assertEqual(result["error"]["code"], "CONFLICT")
        self.assertFalse(self.cli("plugin", "list")["result"]["plugins"][0]["enabled"])

    def test_disabling_during_setup_stops_the_process(self):
        process = subprocess.Popen([str(CLI), "--json", "--data-dir", str(self.data), "--socket", str(self.sock),
                                    "plugin", "setup", "probe", "hang"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not (self.data / "plugin-data/probe/called").exists():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.02)
            self.cli("plugin", "disable", "probe")
            stdout, _ = process.communicate(timeout=3)
            self.assertEqual(json.loads(stdout)["error"]["code"], "PLUGIN_DISABLED")
        finally:
            if process.poll() is None:
                process.kill(); process.wait()

    def test_package_update_preserves_configuration_and_enabled_state(self):
        settings = {"executable": "/custom/tool", "unknown_option": {"retained": True}}
        self.cli("plugin", "enable", "probe", "--config", json.dumps(settings))
        old = self.cli("plugin", "setup", "probe")["result"]["generation"]
        manifest = json.loads((self.package / "plugin.json").read_text())
        manifest["version"] = "2.0.0"
        (self.package / "plugin.json").write_text(json.dumps(manifest))
        updated = self.cli("plugin", "install", self.package, "--replace")["result"]
        self.assertTrue(updated["enabled"])
        self.assertEqual(updated["version"], "2.0.0")
        self.assertEqual(self.cli("plugin", "config", "probe")["result"]["config"], settings)
        self.assertNotEqual(self.cli("plugin", "setup", "probe")["result"]["generation"], old)
        self.cli("plugin", "disable", "probe")
        updated = self.cli("plugin", "install", self.package, "--replace")["result"]
        self.assertFalse(updated["enabled"])
        self.assertEqual(self.cli("plugin", "config", "probe")["result"]["config"], settings)

    def test_rejected_package_update_preserves_installed_executable(self):
        before = (self.data / "plugins/probe/plugin.py").read_bytes()
        (self.package / "unexpected").symlink_to("/tmp")
        self.cli("plugin", "install", self.package, "--replace", ok=False)
        self.assertEqual((self.data / "plugins/probe/plugin.py").read_bytes(), before)
        self.assertTrue(self.cli("plugin", "setup", "probe")["result"]["result"]["available"])


class LocalDiscovery(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="awb-discovery-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)

    def executable(self, name):
        path = self.home / ".local/bin" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o700)
        return path

    def test_amem_discovers_common_location_without_source_or_capture_reads(self):
        memory = provider("agent-memory")
        executable = self.executable("amem")
        with mock.patch.object(memory.Path, "home", return_value=self.home), mock.patch.object(memory, "invoke", return_value="help") as invoke:
            result = memory.discover({})["result"]
        self.assertTrue(result["available"])
        self.assertEqual(result["config"], {"executable": str(executable)})
        invoke.assert_called_once_with(str(executable), ["--help"])

    def test_orca_detects_repository_matching_board_directory(self):
        orca = provider("orca")
        executable = self.executable("orca")
        rows = [{"id": "a", "displayName": "First", "path": "/repo/first"},
                {"id": "b", "displayName": "Board project", "path": "/repo/selected"},
                {"id": "remote", "path": "/repo/remote", "hostId": "remote"}]
        with mock.patch.object(orca.Path, "home", return_value=self.home), mock.patch.object(orca.Orca, "call", return_value={"repos": rows}) as call:
            result = orca.discover({}, {"project_paths": ["/repo/selected"]})["result"]
        self.assertEqual(result["config"], {"executable": str(executable), "repos": ["id:b"]})
        self.assertEqual(len(result["repositories"]), 2)
        call.assert_called_once_with("repo", "list")

    def test_orca_preselects_the_repository_of_every_board_project(self):
        orca = provider("orca")
        executable = self.executable("orca")
        rows = [{"id": "a", "path": "/repo/first"}, {"id": "b", "path": "/repo/second"}, {"id": "c", "path": "/repo/third"}]
        with mock.patch.object(orca.Path, "home", return_value=self.home), mock.patch.object(orca.Orca, "call", return_value={"repos": rows}):
            result = orca.discover({}, {"project_paths": ["/repo/third/", "/repo/first", "/not/in/orca"]})["result"]
        self.assertEqual(result["config"], {"executable": str(executable), "repos": ["id:a", "id:c"]})

    def test_multiple_orca_repositories_require_selection(self):
        orca = provider("orca")
        self.executable("orca")
        rows = [{"id": "a", "path": "/repo/first"}, {"id": "b", "path": "/repo/second"}]
        with mock.patch.object(orca.Path, "home", return_value=self.home), mock.patch.object(orca.Orca, "call", return_value={"repos": rows}):
            result = orca.discover({}, {})["result"]
        self.assertNotIn("repos", result["config"])
        self.assertTrue(result["available"])

    def test_orca_custom_path_and_saved_repository_are_preserved(self):
        orca = provider("orca")
        executable = self.executable("custom-orca")
        rows = [{"id": "a", "path": "/repo/first"}, {"id": "b", "path": "/repo/second"}]
        with mock.patch.object(orca.Orca, "call", return_value={"repos": rows}):
            result = orca.discover({"executable": str(executable), "repo": "path:/repo/second"}, {"project_paths": ["/repo/first"]})["result"]
        self.assertEqual(result["config"], {"executable": str(executable), "repos": ["id:b"]},
                         "saved repositories, including the earlier single setting, win over board folders")
        with mock.patch.object(orca.Orca, "call", return_value={"repos": rows}):
            result = orca.discover({"executable": str(executable), "repos": ["id:a", "path:/repo/second"]}, {})["result"]
        self.assertEqual(result["config"]["repos"], ["id:a", "id:b"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
