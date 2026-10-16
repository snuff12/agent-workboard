#!/usr/bin/env python3
"""Optional, local Orca CLI bridge; never opens either application's database."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time


class IntegrationError(Exception):
    def __init__(self, message, code="INTEGRATION_UNAVAILABLE"):
        super().__init__(message)
        self.code = code


def required(data, key):
    value = data.get(key)
    if not isinstance(value, str) or not value.strip() or "\x00" in value:
        raise IntegrationError(key + " is required.", "PLUGIN_INVALID_PARAMS")
    return value


def bounded_integer(params, key, default, maximum):
    value = params.get(key, default)
    if type(value) is not int or value < 0:
        raise IntegrationError(key + " must be a nonnegative integer.", "PLUGIN_INVALID_PARAMS")
    return min(maximum, value)


def repository_selectors(config):
    # `repos` lists every connected repository. `repo` is the earlier single-repository setting.
    values = config.get("repos", [])
    if not isinstance(values, list) or len(values) > 50:
        raise IntegrationError("repos must be a list of at most 50 repository selectors.", "PLUGIN_INVALID_PARAMS")
    if "repo" in config:
        values = [config["repo"], *values]
    selectors = []
    for value in values:
        if not isinstance(value, str) or "\x00" in value or not any(
                value.startswith(prefix) and value[len(prefix):].strip() for prefix in ("id:", "path:", "name:")):
            raise IntegrationError("Each repository must use an id:, path:, or name: selector.", "PLUGIN_INVALID_PARAMS")
        if value not in selectors:
            selectors.append(value)
    if not selectors:
        raise IntegrationError("Connect at least one Orca repository.", "PLUGIN_INVALID_PARAMS")
    return selectors


def same_path(left, right):
    return os.path.realpath(os.path.expanduser(left)) == os.path.realpath(os.path.expanduser(right))


class Orca:
    def __init__(self, config):
        self.executable = required(config, "executable")
        if not Path(self.executable).is_absolute():
            raise IntegrationError("Specify the absolute path to the Orca executable.", "PLUGIN_INVALID_PARAMS")
        self.selectors = repository_selectors(config)
        self.deadline = time.monotonic() + 24

    def call(self, *args):
        # The host strips Orca session/environment variables. Explicit selectors
        # keep this independent of the active tab and the package's working dir.
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise IntegrationError("Orca response timed out.", "PLUGIN_TIMEOUT")
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as error:
            try:
                result = subprocess.run([self.executable, *args, "--json"], stdin=subprocess.DEVNULL,
                                        stdout=output, stderr=error, timeout=min(8, remaining))
            except subprocess.TimeoutExpired as exc:
                raise IntegrationError("Orca response timed out.", "PLUGIN_TIMEOUT") from exc
            if output.tell() > 4 * 1024 * 1024:
                raise IntegrationError("Orca response is too large. Narrow the query scope.", "PLUGIN_INVALID_RESPONSE")
            output.seek(0)
            try:
                response = json.load(output)
            except (ValueError, UnicodeError) as exc:
                raise IntegrationError("Could not read Orca’s JSON response. Check the CLI path and runtime status.",
                                       "PLUGIN_INVALID_RESPONSE") from exc
        if not isinstance(response, dict):
            raise IntegrationError("Invalid Orca response format.", "PLUGIN_INVALID_RESPONSE")
        if result.returncode or response.get("ok") is not True:
            detail = response.get("error", {})
            message = detail.get("message") if isinstance(detail, dict) else None
            raise IntegrationError(str(message or "Orca request failed. Check that the Orca app is running.")[:1500])
        payload = response.get("result")
        if not isinstance(payload, dict):
            raise IntegrationError("Orca result is not an object.", "PLUGIN_INVALID_RESPONSE")
        return payload

    def repositories(self):
        """Resolves the configured selectors with one listing; returns connected and unmatched ones."""
        rows = self.call("repo", "list").get("repos")
        if not isinstance(rows, list) or len(rows) > 1000:
            raise IntegrationError("Could not read Orca’s registered repositories.", "PLUGIN_INVALID_RESPONSE")
        local = [row for row in rows if isinstance(row, dict) and isinstance(row.get("id"), str) and row["id"]
                 and "::" not in row["id"] and row.get("hostId", "local") in (None, "local")
                 and isinstance(row.get("path"), str) and Path(row["path"]).is_absolute()]
        connected, unmatched = [], []
        for selector in self.selectors:
            kind, value = selector.split(":", 1)
            matches = [row for row in local if (row["id"] == value if kind == "id" else
                       same_path(row["path"], value) if kind == "path" else row.get("displayName") == value)]
            if len(matches) != 1:
                unmatched.append({"selector": selector, "reason": "matches several repositories" if matches
                                  else "not registered in Orca on this Mac"})
            elif all(row["id"] != matches[0]["id"] for row in connected):
                connected.append(matches[0])
        if not connected:
            raise IntegrationError("None of the configured repositories is registered in Orca on this Mac: "
                                   + ", ".join(entry["selector"] for entry in unmatched)[:1000])
        return connected, unmatched

    def worktree(self, params, repos):
        identifier = required(params, "worktree_id")
        repo = next((row for row in repos if identifier.startswith(row["id"] + "::")), None)
        if repo is None:
            raise IntegrationError("Only worktrees in connected Orca repositories can be used.", "PLUGIN_SCOPE_MISMATCH")
        item = self.call("worktree", "show", "--worktree", "id:" + identifier).get("worktree")
        validate_worktree(item, repo["id"])
        if item["id"] != identifier:
            raise IntegrationError("The returned worktree ID does not match.", "PLUGIN_SCOPE_MISMATCH")
        return item, repo


def validate_worktree(item, repo_id):
    if not isinstance(item, dict) or item.get("repoId") != repo_id:
        raise IntegrationError("The returned repository differs from the requested Orca repository.", "PLUGIN_SCOPE_MISMATCH")
    required(item, "id")
    if not item["id"].startswith(repo_id + "::"):
        raise IntegrationError("The worktree ID does not match the repository.", "PLUGIN_SCOPE_MISMATCH")
    if item.get("hostId") != "local" or not Path(required(item, "path")).is_absolute():
        raise IntegrationError("This plugin currently supports only local worktrees on this Mac.", "PLUGIN_SCOPE_MISMATCH")


def worktree_info(item, repo):
    info = {key: item.get(source) for key, source in (
        ("id", "id"), ("repo_id", "repoId"), ("project_id", "projectId"), ("host_id", "hostId"),
        ("instance_id", "instanceId"), ("path", "path"), ("branch", "branch"), ("head", "head"),
        ("title", "displayName"), ("comment", "comment"), ("workspace_status", "workspaceStatus"),
        ("archived", "isArchived"))}
    return {**info, "repo_name": repo.get("displayName") or repo["path"], "repo_path": repo["path"]}


def repository_info(repo):
    return {"id": repo["id"], "name": repo.get("displayName") or repo["path"], "path": repo["path"]}


def terminal_list(orca, item):
    result = orca.call("terminal", "list", "--worktree", "id:" + item["id"], "--limit", "100")
    rows = result.get("terminals")
    if not isinstance(rows, list) or any(not isinstance(row, dict) or row.get("worktreeId") != item["id"] for row in rows):
        raise IntegrationError("Could not verify the terminal’s worktree scope.", "PLUGIN_SCOPE_MISMATCH")
    return result


def attachment(item, repo, task_id, revision=None):
    observed = dt.datetime.now(dt.timezone.utc).isoformat()
    params = {"task_id": task_id, "path": item["path"], "kind": "workspace",
              "description": "Orca · " + (item.get("displayName") or item["path"]),
              "provider": "orca", "locator": item["id"], "verified_at": observed,
              "metadata": {"provider": "orca", "observed_at": observed, **worktree_info(item, repo)}}
    if revision is not None:
        params["expected_revision"] = revision
    return {"method": "task.attach", "params": params}


def replay_launch(record, fingerprint, run_id):
    try:
        prior = json.loads(record.read_text())
    except (ValueError, OSError) as exc:
        raise IntegrationError("Could not verify the run record. Check the run in Orca first.",
                               "PLUGIN_EXTERNAL_RESULT_UNKNOWN") from exc
    if prior.get("fingerprint") != fingerprint:
        raise IntegrationError("This run cannot use a different worktree or instructions. Start a new run.", "PLUGIN_RUN_CONFLICT")
    if prior.get("phase") == "complete":
        return {"ok": True, "result": {**prior["result"], "already_started": True},
                "requests": prior.get("requests", [])}
    raise IntegrationError("The external launch result is uncertain. First check the ‘Workboard " + run_id
                           + "’ terminal in Orca. It will not be relaunched automatically.", "PLUGIN_EXTERNAL_RESULT_UNKNOWN")


def start_agent(orca, item, repo, params, config):
    task = params["task"]
    agent = required(params, "agent")
    commands = config.get("agent_commands", {"codex": ["codex"], "claude": ["claude"]})
    command = commands.get(agent) if isinstance(commands, dict) else None
    if not isinstance(command, list) or not command or any(not isinstance(arg, str) or not arg or "\x00" in arg for arg in command):
        raise IntegrationError("Select an agent registered in agent_commands.", "PLUGIN_INVALID_PARAMS")
    run_id = required(params, "run_id")
    runs = params.get("task_runs")
    if not isinstance(runs, list) or not any(run.get("id") == run_id and run.get("agent_id") == "orca:" + agent for run in runs):
        raise IntegrationError("Specify the orca:" + agent + " run ID recorded on this task.", "PLUGIN_RUN_CONFLICT")
    extra = params.get("prompt", "")
    if not isinstance(extra, str) or len(extra) > 12000 or "\x00" in extra:
        raise IntegrationError("Additional instructions must be a string of at most 12000 characters.", "PLUGIN_INVALID_PARAMS")
    connection = params.get("board_connection", {})
    cli = [required(connection, "executable"), "--data-dir", required(connection, "data_dir"),
           "--socket", required(connection, "socket")]
    read = shlex.join([*cli, "task", "show", task["id"], "--json"])
    # WORKBOARD_AGENT below makes these commands act as the run's assignee.
    review = shlex.join([*cli, "task", "review", task["id"], "--run", run_id,
                         "--summary", "Replace with verified results and remaining decisions", "--json"])
    protocol = params.get("agent_protocol")
    protocol = protocol if isinstance(protocol, str) and len(protocol) <= 20000 else ""
    prompt = ("Perform the board task.\nTask ID: " + task["id"] + "\nRun ID: " + run_id
              + "\nTitle: " + task.get("title", "") + "\nGoal: " + task.get("goal", "")
              + "\nCompletion criteria: " + task.get("completion_criteria", "") + "\nNext action: " + task.get("next_action", "")
              + "\n\nRead the latest task before starting and before changing its status:\n" + read
              + "\n\nDo not complete a task merely because a response ended. Record verification results and the next action, then request review."
              + " Replace the summary in the following command with actual values:\n" + review
              + ("\n\n" + protocol if protocol else "")
              + "\n\nAdditional instructions:\n" + extra)
    environment = ["env", "WORKBOARD_AGENT=orca:" + agent, "WORKBOARD_DATA_DIR=" + connection["data_dir"],
                   "WORKBOARD_SOCKET=" + connection["socket"]]
    shell_command = shlex.join([*environment, *command, prompt])
    # Mutable board text must not prevent recovering an already launched run's
    # original link after the task is edited or a newer run has started.
    fingerprint = hashlib.sha256(json.dumps({"command": command, "prompt": extra, "connection": cli,
        "task_id": task["id"], "run_id": run_id, "worktree_id": item["id"],
        "instance_id": item.get("instanceId"), "executable": orca.executable}, sort_keys=True).encode()).hexdigest()
    directory = Path(os.environ["WORKBOARD_PLUGIN_DATA_DIR"]) / "launches"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    record = directory / (hashlib.sha256(run_id.encode()).hexdigest() + ".json")
    if record.exists():
        return replay_launch(record, fingerprint, run_id)
    if (task.get("status") != "in_progress" or task.get("assignee") != "orca:" + agent
            or not runs or runs[-1].get("id") != run_id or runs[-1].get("status") != "running"):
        raise IntegrationError("First start this task as orca:" + agent + " and specify the latest run_id.", "PLUGIN_RUN_CONFLICT")
    try:
        descriptor = os.open(record, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        return replay_launch(record, fingerprint, run_id)
    with os.fdopen(descriptor, "w") as handle:
        json.dump({"phase": "pending", "fingerprint": fingerprint}, handle)
        handle.flush()
        os.fsync(handle.fileno())
    sync_directory(directory)
    response = orca.call("terminal", "create", "--worktree", "id:" + item["id"],
                         "--title", "Workboard " + run_id, "--command", shell_command)
    terminal = response.get("terminal")
    if not isinstance(terminal, dict) or not terminal.get("handle") or terminal.get("worktreeId") != item["id"]:
        raise IntegrationError("Could not verify the created terminal. Check the launch request in Orca.", "PLUGIN_EXTERNAL_RESULT_UNKNOWN")
    result = {"task_id": task["id"], "run_id": run_id, "agent": agent, "terminal": {
        k: terminal.get(k) for k in ("handle", "title", "worktreeId")}, "worktree": worktree_info(item, repo)}
    link = attachment(item, repo, task["id"])
    link["idempotency_key"] = "launch-link:" + hashlib.sha256(run_id.encode()).hexdigest()
    link["params"]["run_id"] = run_id
    link["params"]["metadata"]["terminal_handle"] = terminal["handle"]
    with tempfile.NamedTemporaryFile(mode="w", dir=directory, delete=False) as handle:
        temporary = Path(handle.name)
        json.dump({"phase": "complete", "fingerprint": fingerprint, "result": result, "requests": [link]}, handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, record)
    sync_directory(directory)
    return {"ok": True, "result": result, "requests": [link]}


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def run(request):
    if not isinstance(request, dict) or request.get("protocol_version") != 1:
        raise IntegrationError("Unsupported plugin protocol.", "PLUGIN_INVALID_PARAMS")
    config, params = request.get("config", {}), request.get("params", {})
    if not isinstance(config, dict) or not isinstance(params, dict):
        raise IntegrationError("config and params must be objects.", "PLUGIN_INVALID_PARAMS")
    method = request.get("method")
    methods = {"check", "worktrees.list", "worktrees.get", "worktrees.import", "worktrees.attach", "terminals.list", "terminals.read", "agents.start"}
    if method not in methods:
        raise IntegrationError("Unsupported Orca feature.", "PLUGIN_METHOD_NOT_FOUND")
    # Validate mutations before accessing the external runtime.
    if method == "worktrees.import":
        required(params, "project_id")
        for key in ("title", "parent_id"):
            if key in params:
                required(params, key)
    if method in ("worktrees.attach", "agents.start"):
        required(params, "task_id")
        task = params.get("task")
        if not isinstance(task, dict) or task.get("id") != params["task_id"] or type(task.get("revision")) is not int:
            raise IntegrationError("Current task information verified by the host is required.", "PLUGIN_INVALID_PARAMS")
    if method == "terminals.read":
        required(params, "terminal")
        limit = max(1, bounded_integer(params, "limit", 80, 200))
        cursor = bounded_integer(params, "cursor", 0, 2**53 - 1)
    if method == "worktrees.list":
        limit = max(1, bounded_integer(params, "limit", 50, 100))
        if "repo_id" in params:
            required(params, "repo_id")
    orca = Orca(config)
    repos, unmatched = orca.repositories()
    if method == "check":
        return {"ok": True, "result": {"available": True, "repos": [repository_info(repo) for repo in repos],
                                       "unmatched": unmatched}}
    if method == "worktrees.list":
        selected = [repo for repo in repos if repo["id"] == params["repo_id"]] if "repo_id" in params else repos
        if not selected:
            raise IntegrationError("Choose a connected Orca repository.", "PLUGIN_SCOPE_MISMATCH")
        worktrees, truncated, total = [], False, 0
        for repo in selected:
            result = orca.call("worktree", "list", "--repo", "id:" + repo["id"], "--limit", str(limit))
            rows = result.get("worktrees")
            if not isinstance(rows, list):
                raise IntegrationError("Unexpected Orca worktree list format.", "PLUGIN_INVALID_RESPONSE")
            for row in rows:
                validate_worktree(row, repo["id"])
            worktrees.extend(worktree_info(row, repo) for row in rows)
            truncated = truncated or result.get("truncated", False) is True
            count = result.get("totalCount", len(rows))
            total += count if type(count) is int else len(rows)
        return {"ok": True, "result": {"worktrees": worktrees[:limit], "truncated": truncated or len(worktrees) > limit,
                "total_count": total, "repos": [repository_info(repo) for repo in selected]}}
    item, repo = orca.worktree(params, repos)
    info = worktree_info(item, repo)
    if method == "agents.start":
        return start_agent(orca, item, repo, params, config)
    if method == "worktrees.get":
        return {"ok": True, "result": info}
    if method in ("terminals.list", "terminals.read"):
        terminals = terminal_list(orca, item)
        if method == "terminals.list":
            # Avoid collecting prompts, draft input or output previews during discovery.
            rows = [{k: row.get(k) for k in ("handle", "title", "agentIdentity", "connected", "writable", "worktreeId")}
                    for row in terminals["terminals"]]
            return {"ok": True, "result": {"terminals": rows, "truncated": terminals.get("truncated", False)}}
        if not any(row.get("handle") == params["terminal"] for row in terminals["terminals"]):
            raise IntegrationError("Specify a terminal handle in the selected worktree.", "PLUGIN_SCOPE_MISMATCH")
        output = orca.call("terminal", "read", "--terminal", params["terminal"], "--limit", str(limit), "--cursor", str(cursor)).get("terminal")
        if not isinstance(output, dict) or output.get("handle") != params["terminal"]:
            raise IntegrationError("The terminal read response has a different handle.", "PLUGIN_SCOPE_MISMATCH")
        # Return emitted output, never UI draft/composer fields.
        return {"ok": True, "result": {k: output[k] for k in ("handle", "status", "tail", "oldestCursor", "nextCursor", "latestCursor", "source", "truncated", "limited") if k in output}}
    if method == "worktrees.attach":
        requests = [attachment(item, repo, params["task_id"], params["task"]["revision"])]
    else:
        creation = {"project_id": params["project_id"], "title": params.get("title") or item.get("displayName") or item["path"],
                    "goal": item.get("comment") or "Check the Orca worktree’s task goal and completion criteria.",
                    "next_action": "Check the Orca run results and define the next action and completion criteria."}
        if params.get("parent_id"):
            creation["parent_id"] = params["parent_id"]
        requests = [{"method": "task.create", "params": creation}, attachment(item, repo, {"$result": "/0/task_id"})]
    # A workspace/terminal state is an observation, never a board completion signal.
    return {"ok": True, "result": info, "requests": requests}


if __name__ == "__main__":
    try:
        response = run(json.load(sys.stdin))
    except Exception as error:
        response = {"ok": False, "error": {"code": getattr(error, "code", "INTEGRATION_UNAVAILABLE"), "message": str(error)}}
    print(json.dumps(response, ensure_ascii=False))
