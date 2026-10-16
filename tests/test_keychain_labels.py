"""Keychain account labels in the Slack, Linear, and Google Workspace plugins never reach `security -i` unchecked."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
PLUGINS = ("slack", "linear", "google-workspace")
UNSAFE = ["O'Brien", "work\nlist-keychains", "two words", "", "café", "a" * 81, 'quote"d', "back\\slash"]
SAFE = ["default", "work-mail@example.com", "team_1.backup"]


def load(plugin):
    spec = importlib.util.spec_from_file_location("keychain_" + plugin.replace("-", "_"), ROOT / "plugins" / plugin / "plugin.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class KeychainLabels(unittest.TestCase):
    def test_unsafe_labels_are_rejected_before_any_keychain_command(self):
        for plugin in PLUGINS:
            module = load(plugin)
            with mock.patch.object(module.subprocess, "run") as run:
                for label in UNSAFE:
                    for call in (lambda: module.keychain(label, {"secret": "value"}), lambda: module.keychain(label),
                                 lambda: module.keychain(label, remove=True)):
                        with self.assertRaises(module.IntegrationError, msg=(plugin, label)) as caught:
                            call()
                        self.assertEqual(caught.exception.code, "INVALID_REQUEST")
                    request = {"protocol_version": 1, "request_id": "r", "method": "disconnect", "params": {},
                               "config": {"account": label}}
                    with self.assertRaises(module.IntegrationError, msg=(plugin, label)):
                        module.run(request)
                run.assert_not_called()

    def test_safe_labels_still_reach_the_keychain(self):
        for plugin in PLUGINS:
            module = load(plugin)
            for label in SAFE:
                with mock.patch.object(module.subprocess, "run",
                                       return_value=subprocess.CompletedProcess([], 44, "", "")) as run:
                    self.assertIsNone(module.keychain(label, remove=True))
                args = run.call_args.args[0]
                self.assertEqual(args[args.index("-a") + 1], label, plugin)


if __name__ == "__main__":
    unittest.main()
