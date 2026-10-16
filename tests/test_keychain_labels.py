"""Keychain account labels in the Slack, Linear, and Google Workspace plugins never reach `security -i` unchecked,
while connections made with an earlier label can still be read and disconnected."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
PLUGINS = ("slack", "linear", "google-workspace")
UNSAFE = ["O'Brien", "work\nlist-keychains", "two words", "", "café", "a" * 81, 'quote"d', "back\\slash"]
# Labels that `security -i` stored before labels were checked; reading and removal pass them as one argument.
SAVED = ["two words", "café", "a" * 90, "O'Brien", "work\nlist-keychains"]
SAFE = ["default", "work-mail@example.com", "team_1.backup"]
CONFIG = {"slack": {"team_id": "T123", "credentials_file": "/nonexistent/token.json", "messages_enabled": True},
          "linear": {"workspace": "acme", "credentials_file": "/nonexistent/key.json", "issues_enabled": True},
          "google-workspace": {"credentials_file": "/nonexistent/client.json", "calendar_enabled": True}}
# The first step of each connection after the label check; it must never run for an unsafe label.
CONNECT_STEP = {"slack": "api", "linear": "api", "google-workspace": "authorize"}


def load(plugin):
    spec = importlib.util.spec_from_file_location("keychain_" + plugin.replace("-", "_"), ROOT / "plugins" / plugin / "plugin.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def request(plugin, method, label):
    return {"protocol_version": 1, "request_id": "r", "method": method, "params": {},
            "config": dict(CONFIG[plugin], account=label)}


class KeychainLabels(unittest.TestCase):
    def test_unsafe_labels_are_never_stored_or_connected(self):
        for plugin in PLUGINS:
            module = load(plugin)
            with mock.patch.object(module.subprocess, "run") as run, \
                    mock.patch.object(module, CONNECT_STEP[plugin]) as connect:
                for label in UNSAFE:
                    with self.assertRaises(module.IntegrationError, msg=(plugin, label)) as caught:
                        module.keychain(label, {"secret": "value"})
                    self.assertEqual(caught.exception.code, "INVALID_REQUEST")
                    if not label.strip():
                        continue
                    with self.assertRaises(module.IntegrationError, msg=(plugin, label)) as caught:
                        module.run(request(plugin, "authorize", label))
                    self.assertIn("account label", str(caught.exception))
                run.assert_not_called()
                connect.assert_not_called()

    def test_saved_labels_can_still_be_read_and_disconnected(self):
        for plugin in PLUGINS:
            module = load(plugin)
            for label in SAVED:
                with mock.patch.object(module.subprocess, "run",
                                       return_value=subprocess.CompletedProcess([], 0, '{"k": "v"}', "")) as run:
                    self.assertEqual(module.keychain(label), {"k": "v"})
                    module.run(request(plugin, "disconnect", label))
                for call in run.call_args_list:
                    args = call.args[0]
                    self.assertNotIn("-i", args, "reading and removal never use the interactive command line")
                    self.assertEqual(args[args.index("-a") + 1], label, plugin)
                self.assertIn("delete-generic-password", run.call_args_list[-1].args[0])

    def test_safe_labels_still_reach_the_keychain(self):
        for plugin in PLUGINS:
            module = load(plugin)
            for label in SAFE:
                with mock.patch.object(module.subprocess, "run",
                                       return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
                    module.keychain(label, {"secret": "value"})
                self.assertEqual(run.call_args.args[0], ["/usr/bin/security", "-i"])
                self.assertIn(" -a %s " % label, run.call_args.kwargs["input"], plugin)


if __name__ == "__main__":
    unittest.main()
