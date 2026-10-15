"""Only publisher Desktop client metadata belongs in a Google plugin package."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("prepare_google_oauth", ROOT / "scripts/prepare-google-oauth.py")
prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare)


class OAuthPackage(unittest.TestCase):
    def test_packaging_drops_tokens_and_unrelated_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / "input.json", Path(directory) / "oauth-client.json"
            client = {"client_id": "12345-publisher.apps.googleusercontent.com", "client_secret": "desktop-public-value"}
            source.write_text(json.dumps({"installed": {**client, "refresh_token": "NEVER_PACKAGE"}, "access_token": "NEVER_PACKAGE"}))
            prepare.prepare(source, target)
            self.assertEqual(json.loads(target.read_text()), {"installed": client})

    def test_web_or_invalid_clients_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / "input.json", Path(directory) / "oauth-client.json"
            for value in [{"web": {"client_id": "web", "client_secret": "CONFIDENTIAL"}}, [], {"installed": None},
                          {"installed": {"client_id": "invalid"}}]:
                source.write_text(json.dumps(value))
                with self.subTest(value=value), self.assertRaises(ValueError):
                    prepare.prepare(source, target)
                self.assertFalse(target.exists())
