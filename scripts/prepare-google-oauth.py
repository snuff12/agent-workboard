#!/usr/bin/env python3
"""Package publisher-owned Desktop OAuth metadata; never copy tokens or web secrets."""
import json
from pathlib import Path
import re
import sys


def prepare(source, destination):
    document = json.loads(Path(source).read_text())
    client = document.get("installed", {}) if isinstance(document, dict) else {}
    if not isinstance(client, dict):
        raise ValueError("A Desktop OAuth client is required.")
    identifier = client.get("client_id")
    if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9._-]+\.apps\.googleusercontent\.com", identifier):
        raise ValueError("Provide the publisher's Google Desktop app OAuth client JSON.")
    result = {"client_id": identifier}
    if client.get("client_secret"):
        if not isinstance(client["client_secret"], str):
            raise ValueError("Invalid Desktop client secret format.")
        result["client_secret"] = client["client_secret"]
    Path(destination).write_text(json.dumps({"installed": result}, indent=2) + "\n")


if __name__ == "__main__":
    try:
        prepare(*sys.argv[1:])
    except (ValueError, OSError, TypeError):
        raise SystemExit("Could not package Google Desktop OAuth metadata. Check the publisher client file.")
