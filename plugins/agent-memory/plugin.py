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

# amem accepts one memory scope: global, project:<name>, or domain:<name>.
SCOPE_NAME = re.compile(r"[^\s:]{1,128}")


class IntegrationError(ValueError):
    def __init__(self, message, code="INTEGRATION_UNAVAILABLE"):
        super().__init__(message)
        self.code = code


class ExecutableUnavailable(IntegrationError):
    """amem could not be started or did not answer, so nothing about the source is known."""


def invalid(message):
    return IntegrationError(message, "INVALID_REQUEST")


def invoke(executable, args, stdin=None):
    try:
        completed = subprocess.run([executable, *args], input=stdin, capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        raise ExecutableUnavailable("amem did not respond within 20 seconds.") from None
    except OSError as error:
        raise ExecutableUnavailable("Could not run the configured amem executable: %s" % error.strerror) from None
    if completed.returncode:
        raise IntegrationError(completed.stderr.strip()[:1500] or "The amem request failed.")
    return completed.stdout.strip()


def scope_args(params):
    return [value for flag, key in [("--project", "project"), ("--domain", "domain")]
            if params.get(key) for value in [flag, str(params[key])]]


def search(executable, params):
    try:
        limit = min(10, max(1, int(params.get("limit", 3))))
    except (TypeError, ValueError):
        raise invalid("limit must be an integer.") from None
    # Use --explain so searching does not save automatic feedback either.
    raw = invoke(executable, ["search", str(params["query"]), "--collection", str(params["collection"]),
                              "--limit", str(limit), "--json", "--explain", "--memory-status", "reviewed",
                              *scope_args(params)])
    try:
        return json.loads(raw)
    except ValueError:
        raise IntegrationError("amem returned a malformed search response.") from None


def read_source(executable, ref, params):
    """Read a ref and return the provenance headers amem printed before the source body, and its location."""
    raw = invoke(executable, ["read", str(ref), "--max-tokens", "1600",
                              "--memory-status", "reviewed", *scope_args(params)])
    boundary = re.search(r"^--- (.+?) \| ref .+? ---$", raw, re.MULTILINE)
    if not boundary:
        raise IntegrationError("Could not verify the source path and location. Search and read the source again.")
    provenance = re.findall(r"^(path|collection|sha256): (.+)$", raw[:boundary.start()], re.MULTILINE)
    if len({key for key, _ in provenance}) != len(provenance):
        raise IntegrationError("The source path and verification header are ambiguous. Check the source again.")
    headers = dict(provenance)
    if not all(headers.get(k) for k in ("path", "collection", "sha256")):
        raise IntegrationError("Could not verify the source path and content hash. Search and read the source again.")
    return headers, boundary.group(1)


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def verify(executable, params):
    artifact = params.get("artifact")
    if not isinstance(artifact, dict) or not isinstance(artifact.get("metadata"), dict):
        raise invalid("Pass the attached artifact, including its metadata, as artifact.")
    metadata = artifact["metadata"]
    if metadata.get("provider") != "agent-memory":
        raise invalid("Only evidence attached by agent-memory can be verified.")
    if not all(isinstance(metadata.get(k), str) and metadata[k] for k in ("ref", "collection", "source_sha256")):
        raise invalid("The artifact metadata needs ref, collection, and source_sha256.")
    scope = metadata.get("scope") if isinstance(metadata.get("scope"), dict) else {}
    result = {"artifact_id": artifact.get("id"), "path": artifact.get("path"), "checked_at": now(),
              "recorded_sha256": metadata["source_sha256"]}
    try:
        headers, locator = read_source(executable, metadata["ref"], scope)
    except ExecutableUnavailable:
        raise
    except IntegrationError as error:
        # An expired ref is the expected result after amem reindexes a changed source.
        result.update(status="unreadable", detail=str(error))
    else:
        result["current_sha256"] = headers["sha256"]
        unchanged = (headers["sha256"] == metadata["source_sha256"] and headers["collection"] == metadata["collection"]
                     and headers["path"] == artifact.get("path"))
        result["status"] = "current" if unchanged else "changed"
        result["locator"] = locator
    query = params.get("query") or metadata.get("query")
    if result["status"] != "current":
        if query:
            try:
                found = search(executable, dict(scope, query=query, collection=metadata["collection"], limit=5))
                result["candidates"] = [dict(hit, same_path=hit.get("path") == artifact.get("path"))
                                        for hit in found.get("results", []) if isinstance(hit, dict)]
            except IntegrationError as error:
                result["rediscovery_error"] = str(error)
        result["next_step"] = ("Read a replacement candidate and attach it." if result.get("candidates")
                               else "Search the collection again with the same scope, then attach the current source.")
    return result


def capture_scope(params):
    if params.get("project") and params.get("domain"):
        raise invalid("A memory candidate takes one scope. Specify project or domain, not both.")
    for key in ("project", "domain"):
        if params.get(key):
            if not SCOPE_NAME.fullmatch(str(params[key])):
                raise invalid("The %s scope must be 1 to 128 characters without spaces or colons." % key)
            return "%s:%s" % (key, params[key])
    return "global"


def capture_source(params):
    parts = [str(params.get("source") or "Agent Workboard")]
    if params.get("task_id"):
        parts.append("task " + str(params["task_id"]))
    if params.get("artifact_path"):
        parts.append("artifact " + str(params["artifact_path"]))
    return "; ".join(parts)


def run(request):
    params = request.get("params", {})
    executable = request.get("config", {}).get("executable")
    if not executable:
        raise IntegrationError("Set the amem executable path in plugin configuration.")
    method = request["method"]
    if method == "check":
        invoke(executable, ["--help"])
        return {"ok": True, "result": {"available": True}}
    if method == "search":
        if not params.get("collection") or not params.get("query"):
            raise invalid("Specify collection and query.")
        return {"ok": True, "result": search(executable, params)}
    if method == "verify":
        return {"ok": True, "result": verify(executable, params)}
    if method in ("read", "attach"):
        if not params.get("ref"):
            raise invalid("Specify the ref returned by the search result.")
        if method == "read":
            raw = invoke(executable, ["read", str(params["ref"]), "--max-tokens", "1600",
                                      "--memory-status", "reviewed", *scope_args(params)])
            return {"ok": True, "result": {"text": raw}}
        if not params.get("task_id"):
            raise invalid("A task_id is required for attachment.")
        headers, locator = read_source(executable, params["ref"], params)
        if params.get("collection") and headers["collection"] != params["collection"]:
            raise IntegrationError("The search scope and source collection do not match.")
        verified_at = now()
        metadata = {"provider": "agent-memory", "collection": headers["collection"],
                    "locator": locator, "source_sha256": headers["sha256"], "ref": params["ref"],
                    "verified_at": verified_at,
                    "scope": {k: params[k] for k in ("project", "domain") if params.get(k)}}
        if params.get("query"):
            # Keep the search wording so verify can rediscover the source after its ref expires.
            metadata["query"] = str(params["query"])
        return {"ok": True, "result": metadata, "requests": [{"method": "task.attach", "params": {
            "task_id": params["task_id"], "path": headers["path"], "kind": "evidence",
            "description": params.get("description", "amem verified source evidence"),
            "provider": "agent-memory", "locator": locator, "verified_at": verified_at, "metadata": metadata}}]}
    if method == "capture":
        if params.get("confirmed_by_user") is not True:
            raise invalid("Only decisions and procedures explicitly requested by the user can be captured.")
        if params.get("kind") not in ("decision", "procedure") or not params.get("title") or not params.get("body"):
            raise invalid("kind (decision/procedure), title, and body are required.")
        scope = capture_scope(params)
        state = Path(os.environ["WORKBOARD_PLUGIN_DATA_DIR"])
        state.mkdir(parents=True, exist_ok=True, mode=0o700)
        identifier = hashlib.sha256(request["request_id"].encode()).hexdigest()
        fingerprint = hashlib.sha256(json.dumps({"params": params, "executable": executable}, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        record = state / (identifier + ".json")
        if record.exists():
            prior = json.loads(record.read_text())
            if prior.get("fingerprint") != fingerprint:
                raise IntegrationError("A request ID cannot be reused for different saved content.", "REQUEST_ID_CONFLICT")
            if prior.get("complete"):
                return prior["response"]
            raise IntegrationError("The external save result is uncertain. Check the amem inbox first.", "PLUGIN_RESULT_UNCERTAIN")
        descriptor = os.open(record, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump({"complete": False, "fingerprint": fingerprint}, handle)
        # Pass user text as --option=value, and the body on standard input, so leading dashes stay literal.
        raw = invoke(executable, ["capture", "--kind", params["kind"], "--title=" + str(params["title"]),
                                  "--source=" + capture_source(params), "--scope=" + scope,
                                  "--no-sync", "--sensitivity", "private"], stdin=str(params["body"]))
        response = {"ok": True, "result": {"inbox_result": raw, "scope": scope}}
        record.write_text(json.dumps({"complete": True, "response": response, "fingerprint": fingerprint}, ensure_ascii=False))
        return response
    raise invalid("Unsupported feature.")


if __name__ == "__main__":
    try:
        response = run(json.load(sys.stdin))
    except IntegrationError as error:
        response = {"ok": False, "error": {"code": error.code, "message": str(error)}}
    except Exception as error:
        response = {"ok": False, "error": {"code": "INTEGRATION_UNAVAILABLE", "message": str(error)}}
    print(json.dumps(response, ensure_ascii=False))
