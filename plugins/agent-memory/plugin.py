#!/usr/bin/env python3
"""Optional amem bridge. Never imports or edits the external memory engine."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def invoke(executable, args):
    completed = subprocess.run([executable, *args], capture_output=True, text=True, timeout=20)
    if completed.returncode:
        raise ValueError(completed.stderr.strip()[:1500] or "The amem request failed.")
    return completed.stdout.strip()


def scope_args(params):
    return [value for flag, key in [("--project", "project"), ("--domain", "domain")]
            if params.get(key) for value in [flag, str(params[key])]]


def discover(config):
    home = Path.home()
    candidates = [config.get("executable"), str(home / ".local/bin/amem"),
                  str(home / ".cargo/bin/amem"), "/opt/homebrew/bin/amem", "/usr/local/bin/amem"]
    candidates.extend(str(Path(folder) / "amem") for folder in os.get_exec_path() if Path(folder).is_absolute())
    for value in dict.fromkeys(filter(None, candidates)):
        path = Path(value).expanduser()
        if path.is_absolute() and path.is_file() and os.access(path, os.X_OK):
            invoke(str(path), ["--help"])
            return {"ok": True, "result": {"available": True, "config": {"executable": str(path)},
                "message": "Found the installed amem CLI. Ready to connect."}}
    return {"ok": True, "result": {"available": False, "config": {},
        "message": "Install agent-memory, then try again. You can also choose a custom path in Advanced settings."}}


def run(request):
    params = request.get("params", {})
    if request.get("method") == "discover":
        return discover(request.get("config", {}))
    executable = request.get("config", {}).get("executable")
    if not executable:
        raise ValueError("Set the amem executable path in plugin configuration.")
    method = request["method"]
    if method == "check":
        invoke(executable, ["--help"])
        return {"ok": True, "result": {"available": True}}
    if method == "search":
        collection = params.get("collection")
        if not collection or not params.get("query"):
            raise ValueError("Specify collection and query.")
        # Use --explain so searching does not save automatic feedback either.
        raw = invoke(executable, ["search", str(params["query"]), "--collection", str(collection),
                                  "--limit", str(min(10, max(1, int(params.get("limit", 3))))),
                                  "--json", "--explain", "--memory-status", "reviewed", *scope_args(params)])
        return {"ok": True, "result": json.loads(raw)}
    if method in ("read", "attach"):
        if not params.get("ref"):
            raise ValueError("Specify the ref returned by the search result.")
        raw = invoke(executable, ["read", str(params["ref"]), "--max-tokens", "1600",
                                  "--memory-status", "reviewed", *scope_args(params)])
        result = {"text": raw}
        if method == "read":
            return {"ok": True, "result": result}
        boundary = re.search(r"^--- (.+?) \| ref .+? ---$", raw, re.MULTILINE)
        if not boundary:
            raise ValueError("Could not verify the source path and location. Search and read the source again.")
        provenance = re.findall(r"^(path|collection|sha256): (.+)$", raw[:boundary.start()], re.MULTILINE)
        if len({key for key, _ in provenance}) != len(provenance):
            raise ValueError("The source path and verification header are ambiguous. Check the source again.")
        headers = dict(provenance)
        if not all(headers.get(k) for k in ("path", "collection", "sha256")):
            raise ValueError("Could not verify the source path and content hash. Search and read the source again.")
        if params.get("collection") and headers["collection"] != params["collection"]:
            raise ValueError("The search scope and source collection do not match.")
        locator = re.search(r"^--- (.+?) \| ref ", raw, re.MULTILINE)
        metadata = {"provider": "agent-memory", "collection": headers["collection"],
                    "locator": locator.group(1) if locator else str(params["ref"]),
                    "source_sha256": headers["sha256"], "ref": params["ref"],
                    "verified_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    "scope": {k: params[k] for k in ("project", "domain") if params.get(k)}}
        if not params.get("task_id"):
            raise ValueError("A task_id is required for attachment.")
        return {"ok": True, "result": metadata, "requests": [{"method": "task.attach", "params": {
            "task_id": params["task_id"], "path": headers["path"], "kind": "evidence",
            "description": params.get("description", "amem verified source evidence"), "metadata": metadata}}]}
    if method == "capture":
        if params.get("confirmed_by_user") is not True:
            raise ValueError("Only decisions and procedures explicitly requested by the user can be captured.")
        if params.get("kind") not in ("decision", "procedure") or not params.get("title") or not params.get("body"):
            raise ValueError("kind (decision/procedure), title, and body are required.")
        state = Path(os.environ["WORKBOARD_PLUGIN_DATA_DIR"])
        state.mkdir(parents=True, exist_ok=True, mode=0o700)
        identifier = hashlib.sha256(request["request_id"].encode()).hexdigest()
        fingerprint = hashlib.sha256(json.dumps({"params": params, "executable": executable}, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        record = state / (identifier + ".json")
        if record.exists():
            prior = json.loads(record.read_text())
            if prior.get("fingerprint") != fingerprint:
                raise ValueError("A request ID cannot be reused for different saved content.")
            if prior.get("complete"):
                return prior["response"]
            raise ValueError("The external save result is uncertain. Check the amem inbox first.")
        descriptor = os.open(record, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump({"complete": False, "fingerprint": fingerprint}, handle)
        raw = invoke(executable, ["capture", "--kind", params["kind"], "--title", str(params["title"]),
                                  "--body", str(params["body"]), "--source", str(params.get("source", "Agent Workboard")),
                                  "--no-sync", "--sensitivity", "private"])
        response = {"ok": True, "result": {"inbox_result": raw}}
        record.write_text(json.dumps({"complete": True, "response": response, "fingerprint": fingerprint}, ensure_ascii=False))
        return response
    raise ValueError("Unsupported feature.")


if __name__ == "__main__":
    try:
        response = run(json.load(sys.stdin))
    except Exception as error:
        response = {"ok": False, "error": {"code": "INTEGRATION_UNAVAILABLE", "message": str(error)}}
    print(json.dumps(response, ensure_ascii=False))
