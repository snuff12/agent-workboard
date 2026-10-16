#!/usr/bin/env python3
"""Optional Linear issues, explicit status comments and state changes; no board DB access."""
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

SERVICE = "local.agentworkboard.linear"
ENDPOINT = "https://api.linear.app/graphql"
METHODS = {"check", "authorize", "disconnect", "teams.list", "issues.search", "issues.read",
           "issues.import", "issues.attach", "issues.comment", "issues.update_state"}
CLOSED_STATES = ["completed", "canceled", "duplicate"]
# Linear priority 1 (urgent) to 4 (low) mapped to board High/Normal/Low; 0 (none) keeps the board default.
PRIORITIES = {1: 3, 2: 3, 3: 1, 4: 0}
STATES = "states(first: 50) { nodes { id name type position } }"
BASE_FIELDS = ("id identifier title description url priority priorityLabel dueDate updatedAt archivedAt "
               "state { id name type } assignee { id name displayName } parent { id identifier }")
LIST_FIELDS = BASE_FIELDS + " team { id key name }"
DETAIL_FIELDS = BASE_FIELDS + " team { id key name %s }" % STATES
PAGE = "nodes { %s } pageInfo { hasNextPage endCursor }" % LIST_FIELDS
# Only these fixed documents are sent. User input travels in variables, never in query text.
QUERIES = {
    "viewer": "query Viewer { viewer { id name displayName organization { id name urlKey } } }",
    "teams": "query Teams { teams(first: 100) { nodes { id key name } pageInfo { hasNextPage } } }",
    "issue": "query Issue($id: String!) { issue(id: $id) { %s } }" % DETAIL_FIELDS,
    "issues": "query Issues($filter: IssueFilter, $first: Int, $after: String) "
              "{ issues(filter: $filter, first: $first, after: $after, orderBy: updatedAt) { %s } }" % PAGE,
    "search": "query Search($term: String!, $filter: IssueFilter, $first: Int, $after: String) "
              "{ searchIssues(term: $term, filter: $filter, first: $first, after: $after) { %s } }" % PAGE,
    "comment": "query Comment($id: String) { comment(id: $id) { id url issue { id } } }",
    "comment_create": "mutation CommentCreate($input: CommentCreateInput!) "
                      "{ commentCreate(input: $input) { success comment { id url issue { id } } } }",
    "issue_update": "mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) "
                    "{ issueUpdate(id: $id, input: $input) { success issue { %s } } }" % DETAIL_FIELDS,
}
UUID = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
IDENTIFIER = r"[A-Za-z0-9]{1,16}-[0-9]{1,9}"
SAFE_ID = r"[A-Za-z0-9-]{1,64}"


class IntegrationError(ValueError):
    def __init__(self, message, code="INTEGRATION_UNAVAILABLE"):
        super().__init__(message)
        self.code = code


def required(values, name):
    value = values.get(name)
    if not isinstance(value, str) or not value.strip():
        raise IntegrationError("Specify a value for %s." % name, "INVALID_REQUEST")
    return value.strip()


def bounded_integer(params, name, default, maximum):
    value = params.get(name, default)
    if type(value) is not int or not 1 <= value <= maximum:
        raise IntegrationError("%s must be an integer between 1 and %d." % (name, maximum), "INVALID_REQUEST")
    return value


def boolean(params, name):
    value = params.get(name, False)
    if type(value) is not bool:
        raise IntegrationError("%s must be true or false." % name, "INVALID_REQUEST")
    return value


def identifier(params, name, pattern, description):
    value = required(params, name)
    if not re.fullmatch(pattern, value):
        raise IntegrationError("Specify %s for %s." % (description, name), "INVALID_REQUEST")
    return value


def issue_ref(params):
    value = identifier(params, "issue_id", "(%s)|(%s)" % (UUID, IDENTIFIER), "an issue UUID or identifier such as ENG-123")
    return value.lower() if re.fullmatch(UUID, value) else value.upper()


def workspace_key(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", value.strip()):
        raise IntegrationError("Specify the Linear workspace URL key, such as acme in linear.app/acme.", "INVALID_REQUEST")
    return value.strip().lower()


def valid_key(value):
    # Only personal API keys are accepted; they are sent without a Bearer prefix.
    if not isinstance(value, str) or not re.fullmatch(r"lin_api_[A-Za-z0-9_-]{16,256}", value):
        raise IntegrationError("A Linear personal API key (lin_api_…) is required.", "AUTHORIZATION_REQUIRED")
    return value


# `security -i` reads one command per line and splits adjacent quoted segments, so Keychain
# account labels are limited to characters that need no quoting.
ACCOUNT = r"[A-Za-z0-9._@-]{1,80}"


def account_label(value):
    if not isinstance(value, str) or not re.fullmatch(ACCOUNT, value):
        raise IntegrationError("Connecting stores the key under the account label, which must be 1 to 80 ASCII letters, "
                               "digits, periods, underscores, at signs, or hyphens. Disconnect, change the label, and "
                               "connect again.", "INVALID_REQUEST")
    return value


def keychain(account, value=None, remove=False):
    if value is not None:
        # Only storing passes the label inside a `security -i` command line. Reading and removal pass it as
        # its own argument, so a connection made with an earlier label can still be read and disconnected.
        account_label(account)
        # Key material goes over stdin, never process arguments or diagnostic output.
        command = "add-generic-password -U -s %s -a %s -w %s\n" % tuple(
            shlex.quote(v) for v in (SERVICE, account, json.dumps(value)))
        result = subprocess.run(["/usr/bin/security", "-i"], input=command, text=True,
                                capture_output=True, timeout=10)
    else:
        args = ["/usr/bin/security", "delete-generic-password" if remove else "find-generic-password",
                "-s", SERVICE, "-a", account]
        if not remove:
            args.append("-w")
        result = subprocess.run(args, text=True, capture_output=True, timeout=10)
    if remove and result.returncode == 44:
        return None
    if result.returncode:
        raise IntegrationError("Check the Linear Keychain connection. You can run ‘Connect API key’ again.",
                               "AUTHORIZATION_REQUIRED")
    return json.loads(result.stdout) if value is None and not remove else None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise IntegrationError("The Linear API redirected to another address. Check the connection.")


def http_open(request):
    return urllib.request.build_opener(NoRedirect).open(request, timeout=15)


def rate_limit(headers):
    seconds = None
    retry = (headers.get("Retry-After") or "") if headers else ""
    if re.fullmatch(r"[0-9]{1,6}", retry):
        seconds = int(retry)
    else:
        for kind in ("Requests", "Complexity"):
            reset = (headers.get("X-RateLimit-%s-Reset" % kind) or "") if headers else ""
            if headers and headers.get("X-RateLimit-%s-Remaining" % kind) == "0" and re.fullmatch(r"[0-9]{10,16}", reset):
                # Linear reports reset times as UTC epoch milliseconds.
                seconds = max(1, int(int(reset) / 1000 - time.time()) + 1)
                break
    suffix = " Retry after %d seconds." % seconds if seconds is not None and seconds <= 86400 else " Retry shortly."
    return IntegrationError("Linear rate limit reached." + suffix, "INTEGRATION_RATE_LIMITED")


def read_json(response):
    raw = response.read(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024:
        raise IntegrationError("Linear response is too large. Narrow the query scope.")
    return json.loads(raw)


def graphql_error(errors, headers):
    codes, messages = set(), []
    for error in errors if isinstance(errors, list) else []:
        if isinstance(error, dict):
            extensions = error.get("extensions") if isinstance(error.get("extensions"), dict) else {}
            codes.add(str(extensions.get("code", "")).upper())
            messages.append(str(error.get("message", "")).lower())
    if "RATELIMITED" in codes:
        return rate_limit(headers)
    if "AUTHENTICATION_ERROR" in codes:
        return IntegrationError("Linear authentication failed or the API key was revoked. Reconnect the key.", "AUTHORIZATION_REQUIRED")
    if "FORBIDDEN" in codes:
        return IntegrationError("This Linear account cannot access the requested issue or action.", "AUTHORIZATION_REQUIRED")
    if "ENTITY_NOT_FOUND" in codes or any(message.startswith("entity not found") for message in messages):
        return IntegrationError("The Linear item is missing or inaccessible to this account.", "INTEGRATION_NOT_FOUND")
    # Do not echo arbitrary server content, keys or request bodies.
    return IntegrationError("Could not process the Linear request. Check the connection and access permissions.")


def api(name, key, variables=None):
    body = json.dumps({"query": QUERIES[name], "variables": variables or {}}, ensure_ascii=False).encode()
    request = urllib.request.Request(ENDPOINT, data=body, method="POST",
                                     headers={"Authorization": key, "Content-Type": "application/json"})
    try:
        with http_open(request) as response:
            headers, result = response.headers, read_json(response)
    except urllib.error.HTTPError as error:
        headers = error.headers
        try:
            # Linear reports GraphQL failures, including rate limits, in 4xx response bodies.
            result = read_json(error)
        except Exception:
            # The error body is optional context; the status code still decides the failure.
            result = None
        if not isinstance(result, dict) or not result.get("errors"):
            if error.code == 429:
                raise rate_limit(headers) from None
            if error.code in (401, 403):
                raise IntegrationError("Check the Linear API key and its access.", "AUTHORIZATION_REQUIRED") from None
            raise IntegrationError("Linear request failed (HTTP %d)." % error.code) from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise IntegrationError("Could not connect to Linear. Check your network.") from None
    except IntegrationError:
        raise
    except (ValueError, UnicodeError):
        raise IntegrationError("Could not read the Linear response.") from None
    if not isinstance(result, dict):
        raise IntegrationError("Invalid Linear response format.")
    if result.get("errors"):
        raise graphql_error(result["errors"], headers)
    data = result.get("data")
    if not isinstance(data, dict):
        raise IntegrationError("Invalid Linear response format.")
    return data


def node(value, name):
    item = value.get(name) if isinstance(value, dict) else None
    if not isinstance(item, dict):
        raise IntegrationError("Invalid Linear response format.")
    return item


def identity(data, workspace):
    viewer = node(data, "viewer")
    organization = node(viewer, "organization")
    key = required(organization, "urlKey")
    if key.lower() != workspace:
        raise IntegrationError("The API key belongs to a different Linear workspace than the configured one.", "AUTHORIZATION_REQUIRED")
    return {"workspace": key.lower(), "organization_id": identifier(organization, "id", SAFE_ID, "an organization ID"),
            "organization": organization.get("name", ""), "user_id": identifier(viewer, "id", SAFE_ID, "a user ID"),
            "user": viewer.get("displayName") or viewer.get("name", "")}


def connection(account, workspace):
    stored = keychain(account)
    if (not isinstance(stored, dict) or stored.get("workspace") != workspace
            or not isinstance(stored.get("organization_id"), str) or not stored["organization_id"]):
        raise IntegrationError("Connect an API key for this workspace first.", "AUTHORIZATION_REQUIRED")
    valid_key(stored.get("api_key"))
    return stored


def linear_url(value, workspace, issue_identifier):
    parsed = urllib.parse.urlsplit(value if isinstance(value, str) else "")
    parts = parsed.path.split("/")
    if (parsed.scheme != "https" or parsed.hostname != "linear.app" or parsed.port or parsed.username
            or parsed.password or len(parts) < 4 or parts[1].lower() != workspace or parts[2] != "issue"
            or parts[3].upper() != issue_identifier.upper()):
        raise IntegrationError("Could not verify the Linear issue link.")
    return value


def team_states(team):
    states = team.get("states", {}).get("nodes", []) if isinstance(team.get("states"), dict) else []
    rows = [{"id": s["id"], "name": s.get("name", ""), "type": s.get("type", ""), "position": s.get("position", 0)}
            for s in states if isinstance(s, dict) and isinstance(s.get("id"), str)]
    return sorted(rows, key=lambda s: (s["position"] if isinstance(s["position"], (int, float)) else 0, s["name"]))


def issue_info(issue, workspace, preview=False):
    if not isinstance(issue, dict):
        raise IntegrationError("Invalid Linear issue format.")
    state, team = node(issue, "state"), node(issue, "team")
    assignee, parent = issue.get("assignee") or {}, issue.get("parent") or {}
    title, description = issue.get("title"), issue.get("description") or ""
    if not isinstance(assignee, dict) or not isinstance(parent, dict) or not isinstance(title, str) or not isinstance(description, str):
        raise IntegrationError("Invalid Linear issue format.")
    issue_identifier = identifier(issue, "identifier", IDENTIFIER, "a Linear issue identifier")
    due = issue.get("dueDate")
    if due is not None and not (isinstance(due, str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", due)):
        raise IntegrationError("Invalid Linear due date format.")
    priority = issue.get("priority", 0)
    priority = int(priority) if type(priority) in (int, float) and priority in (0, 1, 2, 3, 4) else 0
    fields = {"title": title, "description": description, "state_id": required(state, "id"),
              "assignee_id": assignee.get("id"), "priority": priority, "due_date": due,
              "parent_id": parent.get("id"), "team_id": required(team, "id"), "archived_at": issue.get("archivedAt")}
    version = hashlib.sha256(json.dumps(fields, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    item = {"id": identifier(issue, "id", UUID, "a Linear issue UUID").lower(), "identifier": issue_identifier,
            "title": title, "description": description[:1000] if preview else description,
            "description_truncated": preview and len(description) > 1000,
            "url": linear_url(issue.get("url"), workspace, issue_identifier), "workspace": workspace,
            "team_id": fields["team_id"], "team_key": team.get("key", ""), "team_name": team.get("name", ""),
            "state_id": fields["state_id"], "state_name": state.get("name", ""), "state_type": state.get("type", ""),
            "assignee": assignee.get("displayName") or assignee.get("name") or "", "assignee_id": assignee.get("id"),
            "priority": priority, "priority_label": issue.get("priorityLabel", ""), "due_date": due,
            "parent_id": parent.get("id"), "parent_identifier": parent.get("identifier"),
            "updated_at": issue.get("updatedAt"), "archived": bool(issue.get("archivedAt")), "version": version}
    if "states" in team:
        item["team_states"] = team_states(team)
    return item


def read_issue(params, key, workspace):
    reference = issue_ref(params)
    item = issue_info(node(api("issue", key, {"id": reference}), "issue"), workspace)
    if re.fullmatch(UUID, reference) and item["id"] != reference:
        raise IntegrationError("Linear returned a different issue. Check the source again.", "CONFLICT")
    expected = params.get("expected_version")
    if expected is not None and expected != item["version"]:
        raise IntegrationError("The issue changed in Linear. Read it again before continuing.", "CONFLICT")
    return item


def writable(item):
    if item["archived"]:
        raise IntegrationError("Archived Linear issues cannot be imported, attached or changed here.", "INVALID_REQUEST")
    return item


def search(params, key, workspace):
    conditions = {}
    if params.get("team_id"):
        conditions["team"] = {"id": {"eq": identifier(params, "team_id", UUID, "a team UUID").lower()}}
    if boolean(params, "assigned_to_me"):
        conditions["assignee"] = {"isMe": {"eq": True}}
    if not boolean(params, "include_closed"):
        conditions["state"] = {"type": {"nin": CLOSED_STATES}}
    variables = {"filter": conditions or None, "first": params.get("limit", 20), "after": params.get("cursor")}
    term = params.get("query", "").strip()
    if re.fullmatch(IDENTIFIER, term) and "assignee" not in conditions and not params.get("cursor"):
        # A term shaped like ENG-123 reads that issue directly when it matches the filters.
        # Words such as utf-8 or covid-19 find no issue and fall through to full-text search.
        try:
            item = issue_info(node(api("issue", key, {"id": term.upper()}), "issue"), workspace, preview=True)
        except IntegrationError as error:
            if error.code == "INTEGRATION_RATE_LIMITED":
                raise
            item = None
        if (item and not item["archived"] and ("team" not in conditions or item["team_id"].lower() == conditions["team"]["id"]["eq"])
                and ("state" not in conditions or item["state_type"] not in CLOSED_STATES)):
            item.pop("team_states", None)
            return {"issues": [item], "next_cursor": None}
    data = api("search", key, {**variables, "term": term}) if term else api("issues", key, variables)
    page = node(data, "searchIssues" if term else "issues")
    info = page.get("pageInfo") if isinstance(page.get("pageInfo"), dict) else {}
    return {"issues": [issue_info(row, workspace, preview=True) for row in page.get("nodes", [])],
            "next_cursor": info.get("endCursor") if info.get("hasNextPage") is True else None}


def attachment(item, task_id, description=None):
    return {"method": "task.attach", "params": {
        "task_id": task_id, "path": item["url"], "kind": "url", "provider": "linear",
        "description": description or ("Linear %s: %s" % (item["identifier"], item["title"]))[:200],
        "verified_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "metadata": {"workspace": item["workspace"], "issue_id": item["id"], "identifier": item["identifier"],
                     "team_id": item["team_id"], "state_id": item["state_id"], "state_name": item["state_name"],
                     "state_type": item["state_type"], "updated_at": item["updated_at"], "source_version": item["version"]}}}


def markdown_text(value, limit):
    text = " ".join(str(value).split())[:limit]
    # Escape Markdown so board text cannot add links, mentions or formatting to the comment.
    return re.sub(r"([\\`*_{}\[\]()#+\-.!<>|~@:])", r"\\\1", text)


def status_body(task):
    # The board's status names, as the app shows them.
    states = {"backlog": "Backlog", "todo": "Todo", "in_progress": "In Progress", "review": "In Review", "done": "Done",
              "canceled": "Canceled", "blocked": "Blocked"}
    # Only selected status fields leave the board; goals, artifacts and evidence remain local.
    lines = ["**Agent Workboard · Task status**", "", "- Title: " + markdown_text(task.get("title", ""), 300),
             "- Status: " + markdown_text(states.get(task.get("status"), task.get("status", "")), 40)]
    # Blocking is tracked apart from status, so report it on its own line.
    if str(task.get("blocked_reason") or "").strip():
        lines.append("- Blocked: " + markdown_text(task["blocked_reason"], 300))
    elif task.get("blocked_by"):
        lines.append("- Blocked: waiting on %d unfinished prerequisite tasks" % len(task["blocked_by"]))
    lines.append("- Assignee: " + markdown_text(task.get("assignee") or "Unspecified", 160))
    if task.get("next_action"):
        lines.append("- Next action: " + markdown_text(task["next_action"], 500))
    if task.get("due_at"):
        lines.append("- Due: " + markdown_text(task["due_at"], 80))
    lines.append("- Task ID: %s · Revision: %s" % (markdown_text(task["id"], 80), task["revision"]))
    return "\n".join(lines)


def stable_comment_id(organization_id, issue_id, task):
    # One comment per issue and task revision, so a retry under a new request ID cannot post twice.
    digest = bytearray(hashlib.sha256("\0".join((organization_id, issue_id, task["id"], str(task["revision"]))).encode()).digest()[:16])
    digest[6] = (digest[6] & 0x0F) | 0x40
    digest[8] = (digest[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(digest)))


def comment(params, key, workspace, organization_id):
    # The issue link already proves the key's workspace, so no separate identity request is needed.
    item = writable(read_issue(params, key, workspace))
    task = params["task"]
    comment_id = stable_comment_id(organization_id, item["id"], task)
    try:
        payload = node(api("comment_create", key, {"input": {"id": comment_id, "issueId": item["id"], "body": status_body(task)}}), "commentCreate")
        if payload.get("success") is not True:
            raise IntegrationError("Linear did not confirm the comment. Check the issue before posting again.")
        posted, reused = node(payload, "comment"), False
    except IntegrationError as error:
        if error.code in {"AUTHORIZATION_REQUIRED", "INTEGRATION_RATE_LIMITED"}:
            raise
        # An earlier attempt for this task revision may already have created the comment.
        try:
            posted = node(api("comment", key, {"id": comment_id}), "comment")
        except IntegrationError:
            raise error from None
        if posted.get("id") != comment_id or (posted.get("issue") or {}).get("id") != item["id"]:
            raise error from None
        reused = True
    url = urllib.parse.urlsplit(posted.get("url") if isinstance(posted.get("url"), str) else "")
    if url.scheme != "https" or url.hostname != "linear.app" or url.username or url.password:
        raise IntegrationError("Could not verify the Linear comment link.")
    return {"posted": True, "reused": reused, "comment_id": comment_id, "comment_url": posted["url"],
            "issue_id": item["id"], "identifier": item["identifier"], "task_id": task["id"], "task_revision": task["revision"]}


def update_state(params, key, workspace):
    item = writable(read_issue(params, key, workspace))
    task, state_id = params["task"], params["state_id"].strip().lower()
    target = next((state for state in item.get("team_states", []) if state["id"].lower() == state_id), None)
    if target is None:
        raise IntegrationError("Choose a workflow state from this issue’s team.", "INVALID_REQUEST")
    context = {"task_id": task["id"], "task_revision": task["revision"]}
    if item["state_id"].lower() == state_id:
        return {"ok": True, "result": {**item, **context, "changed": False}}
    payload = node(api("issue_update", key, {"id": item["id"], "input": {"stateId": target["id"]}}), "issueUpdate")
    if payload.get("success") is not True:
        raise IntegrationError("Linear did not confirm the state change. Read the issue before trying again.")
    updated = issue_info(node(payload, "issue"), workspace)
    if updated["id"] != item["id"] or updated["state_id"].lower() != state_id:
        raise IntegrationError("Linear reported a different state after the change. Read the issue again.", "CONFLICT")
    description = ("Linear %s state: %s" % (updated["identifier"], updated["state_name"]))[:200]
    return {"ok": True, "result": {**updated, **context, "changed": True},
            "requests": [attachment(updated, task["id"], description)]}


def host_task(params):
    if params.get("confirmed_by_user") is not True:
        raise IntegrationError("Only user-selected task changes can be sent to Linear.", "INVALID_REQUEST")
    task = params.get("task")
    if not isinstance(task, dict) or not task.get("id") or type(task.get("revision")) is not int:
        raise IntegrationError("Task information read by the host is required.", "INVALID_REQUEST")
    if params.get("expected_revision", task["revision"]) != task["revision"]:
        raise IntegrationError("The task changed. Read it again before sending.", "CONFLICT")
    return task


def run(request):
    if not isinstance(request, dict) or request.get("protocol_version", 1) != 1:
        raise IntegrationError("Unsupported plugin request protocol.", "INVALID_REQUEST")
    config, params, method = request.get("config", {}), request.get("params", {}), request.get("method")
    if not isinstance(config, dict) or not isinstance(params, dict) or method not in METHODS:
        raise IntegrationError("Check plugin configuration and the request.", "INVALID_REQUEST")
    account = required(config, "account")
    if any(name in config for name in ("api_key", "key", "token", "access_token")):
        raise IntegrationError("Do not put API keys in configuration JSON. Connect them through credentials_file.", "INVALID_REQUEST")
    if method == "disconnect":
        keychain(account, remove=True)
        return {"ok": True, "result": {"connected": False, "key_revoked": False}}
    if config.get("issues_enabled") is not True:
        raise IntegrationError("Enable Linear issue reading first.", "INTEGRATION_DISABLED")
    workspace = workspace_key(config.get("workspace"))
    if "workspace" in params and workspace_key(params["workspace"]) != workspace:
        raise IntegrationError("This issue was read from another workspace. Search again.", "CONFLICT")
    if method == "authorize":
        account_label(account)
        filename = Path(required(config, "credentials_file")).expanduser()
        try:
            if filename.stat().st_size > 16384:
                raise ValueError()
            data = json.loads(filename.read_text())
            key = valid_key(data.get("api_key") if isinstance(data, dict) else None)
        except (OSError, ValueError):
            raise IntegrationError("Check the JSON file containing the Linear api_key.", "AUTHORIZATION_REQUIRED") from None
        result = identity(api("viewer", key), workspace)
        # Store only key material and validated identifiers; names may contain characters `security -i` cannot parse.
        keychain(account, {"api_key": key, **{name: result[name] for name in ("workspace", "organization_id", "user_id")}})
        return {"ok": True, "result": {"connected": True, **result}}

    # Validate gates and mutation targets before reading credentials or sending any external requests.
    if method == "issues.comment":
        if config.get("comments_enabled") is not True:
            raise IntegrationError("Enable Linear status comments separately.", "INTEGRATION_DISABLED")
        host_task(params)
    if method == "issues.update_state":
        if config.get("state_changes_enabled") is not True:
            raise IntegrationError("Enable Linear issue state changes separately.", "INTEGRATION_DISABLED")
        host_task(params)
        identifier(params, "state_id", UUID, "a workflow state UUID")
        required(params, "expected_version")
    if method == "issues.import":
        required(params, "project_id")
        for name in ("title", "parent_id"):
            if name in params:
                required(params, name)
    if method == "issues.attach":
        required(params, "task_id")
        if "expected_revision" in params and (type(params["expected_revision"]) is not int or params["expected_revision"] < 1):
            raise IntegrationError("expected_revision must be a positive integer.", "INVALID_REQUEST")
    if method.startswith("issues.") and method != "issues.search":
        issue_ref(params)
        if "expected_version" in params:
            required(params, "expected_version")
    if method == "issues.search":
        if not isinstance(params.get("query", ""), str) or len(params.get("query", "")) > 256:
            raise IntegrationError("query must be text of at most 256 characters.", "INVALID_REQUEST")
        if params.get("team_id"):
            identifier(params, "team_id", UUID, "a team UUID")
        for name in ("assigned_to_me", "include_closed"):
            boolean(params, name)
        bounded_integer(params, "limit", 20, 50)
        if "cursor" in params and (not isinstance(params["cursor"], str) or not 0 < len(params["cursor"]) <= 1024):
            raise IntegrationError("cursor must be the next_cursor value from a previous search.", "INVALID_REQUEST")
    stored = connection(account, workspace)
    key = stored["api_key"]
    if method == "check":
        return {"ok": True, "result": {"connected": True, **identity(api("viewer", key), workspace)}}
    if method == "teams.list":
        page = node(api("teams", key), "teams")
        info = page.get("pageInfo") if isinstance(page.get("pageInfo"), dict) else {}
        return {"ok": True, "result": {"teams": [{"id": required(team, "id"), "key": team.get("key", ""), "name": team.get("name", "")}
                                                 for team in page.get("nodes", []) if isinstance(team, dict)],
                                       "has_more": info.get("hasNextPage") is True}}
    if method == "issues.search":
        return {"ok": True, "result": search(params, key, workspace)}
    if method == "issues.comment":
        return {"ok": True, "result": comment(params, key, workspace, stored["organization_id"])}
    if method == "issues.update_state":
        return update_state(params, key, workspace)
    item = read_issue(params, key, workspace)
    if method == "issues.read":
        return {"ok": True, "result": item}
    writable(item)
    requests = []
    if method == "issues.import":
        goal = (item["description"] + "\n\n" if item["description"] else "") + item["identifier"] + " · " + item["url"]
        creation = {"project_id": params["project_id"], "title": params.get("title") or item["title"].strip()[:300] or item["identifier"],
                    "goal": goal}
        if item["due_date"]:
            creation["due_at"] = item["due_date"]
        if item["priority"] in PRIORITIES:
            creation["priority"] = PRIORITIES[item["priority"]]
        if params.get("parent_id"):
            creation["parent_id"] = params["parent_id"]
        requests.append({"method": "task.create", "params": creation})
        task_id = {"$result": "/0/task_id"}
    else:
        task_id = required(params, "task_id")
    link = attachment(item, task_id)
    if method == "issues.attach" and "expected_revision" in params:
        link["params"]["expected_revision"] = params["expected_revision"]
    requests.append(link)
    return {"ok": True, "result": item, "requests": requests}


if __name__ == "__main__":
    try:
        output = run(json.load(sys.stdin))
    except IntegrationError as error:
        output = {"ok": False, "error": {"code": error.code, "message": str(error)}}
    except Exception:
        output = {"ok": False, "error": {"code": "INTEGRATION_UNAVAILABLE", "message": "Could not process the Linear request. Check connection settings and input."}}
    print(json.dumps(output, ensure_ascii=False))
