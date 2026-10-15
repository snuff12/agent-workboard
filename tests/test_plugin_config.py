"""Configuration reads return saved values without starting plugins or the service."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "target/debug/workboard"


class PluginConfig(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="awb-config-", dir="/tmp")
        self.directory = Path(self.temp.name)
        self.data = self.directory / "data"
        self.socket = self.directory / "s.sock"
        self.marker = self.directory / "executed"
        package = self.directory / "probe"
        package.mkdir()
        (package / "plugin.json").write_text(json.dumps({
            "id": "probe", "name": "config probe", "version": "1.0.0", "protocol_version": 1,
            "executable": "run.sh", "methods": ["check"]}))
        executable = package / "run.sh"
        executable.write_text('#!/bin/sh\ntouch "' + str(self.marker) + '"\nexit 1\n')
        executable.chmod(0o700)
        self.call("plugin", "install", str(package))

    def tearDown(self):
        self.assertFalse(self.marker.exists(), "Configuration read executed the provider")
        self.assertFalse(self.socket.exists(), "Configuration read started the board service")
        self.temp.cleanup()

    def call(self, *arguments, ok=True):
        result = subprocess.run([str(CLI), "--json", "--data-dir", str(self.data), "--socket", str(self.socket), *arguments],
                                text=True, capture_output=True, timeout=8)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["ok"], ok, payload)
        self.assertEqual(result.returncode == 0, ok, payload)
        return payload

    def test_disabled_settings_roundtrip_without_execution_or_default_list_disclosure(self):
        self.assertEqual(self.call("plugin", "config", "probe")["result"]["config"], {})
        settings = {"calendar_enabled": False, "gmail_enabled": True, "account": "work-account",
                    "credentials_file": "/path/to/client.json", "future_setting": {"nested": [1, 2]},
                    "private_example": "TEST_ONLY_NOT_A_CREDENTIAL"}
        self.call("plugin", "enable", "probe", "--config", json.dumps(settings))
        self.call("plugin", "disable", "probe")
        registry = self.data / "plugins/registry.json"
        before = registry.read_bytes()
        response = self.call("rpc", "plugin.config", "--params", '{"id":"probe"}')
        self.assertEqual(response["result"], {"id": "probe", "config": settings})
        self.assertEqual(registry.read_bytes(), before)
        listing = self.call("plugin", "list")
        self.assertFalse(listing["result"]["plugins"][0]["enabled"])
        self.assertNotIn("config", listing["result"]["plugins"][0])
        self.assertNotIn(settings["private_example"], json.dumps(listing))

    def test_missing_plugin_is_reported_without_creating_or_enabling_it(self):
        response = self.call("plugin", "config", "missing", ok=False)
        self.assertEqual(response["error"]["code"], "PLUGIN_NOT_INSTALLED")
        self.assertEqual(len(self.call("plugin", "list")["result"]["plugins"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
