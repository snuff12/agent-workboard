"""Verify backup, restore, and export from a CLI directory different from the persistent service’s startup directory."""
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "target/debug/workboard"
SERVICE = ROOT / "target/debug/workboard-service"


class ClientPaths(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="awb-paths-", dir="/tmp")
        self.directory = Path(self.temp.name)
        self.source = self.directory / "service-cwd"
        self.current = self.directory / "client-cwd"
        self.source.mkdir()
        self.current.mkdir()
        self.data = self.directory / "data"
        self.socket = self.directory / "s.sock"
        self.server = subprocess.Popen([str(SERVICE), "--data-dir", str(self.data), "--socket", str(self.socket)],
                                       cwd=self.source, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 5
        while True:
            self.assertIsNone(self.server.poll(), "The isolated service exited")
            try:
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.connect(str(self.socket))
                break
            except OSError:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.02)

    def tearDown(self):
        if self.server.poll() is None:
            self.server.terminate()
        self.server.wait(timeout=5)
        self.temp.cleanup()

    def call(self, *arguments):
        result = subprocess.run([str(CLI), "--json", "--data-dir", str(self.data), "--socket", str(self.socket), *arguments],
                                cwd=self.current, text=True, capture_output=True, timeout=10)
        payload = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0, payload)
        self.assertTrue(payload["ok"], payload)
        return payload["result"]

    def rpc(self, method, params=None):
        return self.call("rpc", method, "--params", json.dumps(params or {}))

    def test_relative_backup_restore_and_export_follow_the_current_client_directory(self):
        self.rpc("project.create", {"name": "A only"})
        self.call("backup", "create", str(self.source / "same.sqlite3"))
        original = (self.source / "same.sqlite3").read_bytes()
        self.rpc("project.create", {"name": "B added"})
        self.call("backup", "create", "same.sqlite3")
        self.assertTrue((self.current / "same.sqlite3").is_file())
        self.assertEqual((self.source / "same.sqlite3").read_bytes(), original)
        self.rpc("project.create", {"name": "C after backup"})
        self.call("backup", "restore", "same.sqlite3")
        self.assertEqual({p["name"] for p in self.rpc("project.list")["projects"]}, {"A only", "B added"})
        self.call("export", "--path", "board.json", "--format", "json")
        self.assertTrue(json.loads((self.current / "board.json").read_text())["projects"])
        self.assertFalse((self.source / "board.json").exists())

    def test_raw_file_rpcs_also_resolve_at_the_client_boundary(self):
        self.rpc("project.create", {"name": "RPC saved"})
        self.rpc("backup.create", {"path": "rpc.sqlite3"})
        self.assertTrue((self.current / "rpc.sqlite3").is_file())
        self.rpc("project.create", {"name": "RPC unsaved"})
        self.rpc("backup.restore", {"path": "rpc.sqlite3"})
        self.assertEqual([p["name"] for p in self.rpc("project.list")["projects"]], ["RPC saved"])
        self.rpc("export", {"path": "board.md", "format": "markdown"})
        self.assertIn("RPC saved", (self.current / "board.md").read_text())
        self.assertFalse((self.source / "rpc.sqlite3").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
