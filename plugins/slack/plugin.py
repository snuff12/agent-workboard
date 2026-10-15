#!/usr/bin/env python3
"""Optional Slack messages and explicit task status sending; no board DB access."""
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

SERVICE = "local.agentworkboard.slack"
METHODS = {"check", "authorize", "disconnect", "messages.search", "messages.read",
           "messages.thread", "messages.import", "messages.attach", "tasks.send"}
API_METHODS = {"auth.test", "search.messages", "conversations.replies", "chat.getPermalink", "chat.postMessage"}


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


def timestamp(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{1,12}\.[0-9]{6}", value):
        raise IntegrationError("ts must be a Slack message timestamp string.", "INVALID_REQUEST")
    return value


def channel(values):
    value = required(values, "channel_id")
    if not re.fullmatch(r"[CGD][A-Z0-9]{2,31}", value):
        raise IntegrationError("Specify a channel ID (C… / G… / D…).", "INVALID_REQUEST")
    return value


def valid_token(value):
    # Search requires a user token. Never persist a bot/app token as a successful connection.
    if not isinstance(value, str) or not re.fullmatch(r"xoxp-[A-Za-z0-9-]+", value):
        raise IntegrationError("A Slack User OAuth Token (xoxp-) is required.", "AUTHORIZATION_REQUIRED")
    return value


def keychain(account, value=None, remove=False):
    if value is not None:
        # Token material goes over stdin, never process arguments or diagnostic output.
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
        raise IntegrationError("Check the Slack Keychain connection. You can run ‘Connect token’ again.",
                               "AUTHORIZATION_REQUIRED")
    return json.loads(result.stdout) if value is None and not remove else None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise IntegrationError("The Slack API redirected to another address. Check the connection.")


def http_open(request):
    return urllib.request.build_opener(NoRedirect).open(request, timeout=15)


def rate_limit(headers):
    retry = headers.get("Retry-After", "") if headers else ""
    suffix = " Retry after %s seconds." % retry if re.fullmatch(r"[0-9]{1,6}", retry) else " Retry shortly."
    return IntegrationError("Slack rate limit reached." + suffix, "INTEGRATION_RATE_LIMITED")


def api(method, token, params=None, body=None):
    if method not in API_METHODS:
        raise IntegrationError("This Slack API is not allowed.", "INVALID_REQUEST")
    url = "https://slack.com/api/" + method
    if params:
        url += "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
    headers = {"Authorization": "Bearer " + token}
    if body is not None:
        headers["Content-Type"] = "application/json; charset=utf-8"
    request = urllib.request.Request(url, headers=headers,
        data=json.dumps(body, ensure_ascii=False).encode() if body is not None else None)
    try:
        with http_open(request) as response:
            raw = response.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024:
                raise IntegrationError("Slack response is too large. Narrow the query scope.")
            result = json.loads(raw)
    except urllib.error.HTTPError as error:
        if error.code == 429:
            raise rate_limit(error.headers) from None
        if error.code in (401, 403):
            raise IntegrationError("Check the Slack token and read permissions.", "AUTHORIZATION_REQUIRED") from None
        raise IntegrationError("Slack request failed (HTTP %d)." % error.code) from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise IntegrationError("Could not connect to Slack. Check your network.") from None
    except IntegrationError:
        raise
    except (ValueError, UnicodeError):
        raise IntegrationError("Could not read the Slack response.") from None
    if not isinstance(result, dict):
        raise IntegrationError("Invalid Slack response format.")
    if result.get("ok") is not True:
        error = result.get("error")
        if error in {"ratelimited", "rate_limited"}:
            raise rate_limit({})
        if error in {"invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive"}:
            raise IntegrationError("Slack authentication expired or was revoked. Reconnect the token.", "AUTHORIZATION_REQUIRED")
        if error in {"missing_scope", "not_allowed_token_type", "no_permission", "access_denied"}:
            raise IntegrationError("Check the Slack User Token’s search, conversation read, and send permissions.", "AUTHORIZATION_REQUIRED")
        if error in {"message_not_found", "thread_not_found", "channel_not_found", "not_in_channel"}:
            raise IntegrationError("The message is missing or inaccessible to this account.", "INTEGRATION_NOT_FOUND")
        # Do not echo arbitrary server content, tokens or request URLs.
        raise IntegrationError("Could not process the Slack request. Check the connection and access permissions.")
    return result


def identity(result, expected_team):
    team_id = required(result, "team_id")
    if team_id != expected_team:
        raise IntegrationError("The token’s workspace differs from the configured workspace.", "AUTHORIZATION_REQUIRED")
    return {"team_id": team_id, "team": result.get("team", ""), "user_id": result.get("user_id", "")}


def connection(config, account, team_id):
    stored = keychain(account)
    if not isinstance(stored, dict) or stored.get("team_id") != team_id:
        raise IntegrationError("Connect a token for this workspace first.", "AUTHORIZATION_REQUIRED")
    return valid_token(stored.get("access_token"))


def message_info(message, channel_id, team_id, preview=False):
    ts = timestamp(message.get("ts"))
    text = message.get("text", "")
    if not isinstance(text, str):
        raise IntegrationError("Invalid Slack message body format.")
    thread_ts = message.get("thread_ts")
    if thread_ts:
        timestamp(thread_ts)
    version = hashlib.sha256(json.dumps({"text": text, "edited": message.get("edited"),
        "thread_ts": thread_ts, "files": message.get("files", []), "blocks": message.get("blocks", [])},
        sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    return {"channel_id": channel_id, "team_id": team_id, "ts": ts, "thread_ts": thread_ts,
            "user": message.get("user", message.get("bot_id", "")), "text": text[:1000] if preview else text,
            "text_truncated": preview and len(text) > 1000, "version": version,
            "reply_count": message.get("reply_count", 0)}


def read_message(params, token, team_id):
    channel_id, ts = channel(params), timestamp(params.get("ts"))
    parent = timestamp(params["thread_ts"]) if params.get("thread_ts") else ts
    # Bound by BOTH timestamps and verify exact identity: never attach a nearby message.
    page = api("conversations.replies", token, {"channel": channel_id, "ts": parent,
               "oldest": ts, "latest": ts, "inclusive": "true", "limit": 1})
    message = next((m for m in page.get("messages", []) if m.get("ts") == ts), None)
    if not message or message.get("subtype") in {"message_deleted", "tombstone"}:
        raise IntegrationError("Could not find the selected message. Check the source again.", "INTEGRATION_NOT_FOUND")
    item = message_info(message, channel_id, team_id)
    expected = params.get("expected_version")
    if expected is not None and expected != item["version"]:
        raise IntegrationError("The message was edited. Read the source again before attaching it.", "CONFLICT")
    link = api("chat.getPermalink", token, {"channel": channel_id, "message_ts": ts})
    url = required(link, "permalink")
    parsed = urllib.parse.urlsplit(url)
    host = parsed.hostname or ""
    if parsed.scheme != "https" or not host.endswith(".slack.com") or parsed.username or parsed.password:
        raise IntegrationError("Could not verify the original Slack message link.")
    item["url"] = url
    return item


def status_text(task):
    states = {"todo": "To do", "in_progress": "In progress", "review": "Review", "done": "Done", "blocked": "Blocked"}
    # Only selected status fields leave the board; goals, artifacts and evidence remain local.
    lines = ["Agent Workboard · Task status", str(task.get("title", ""))[:300],
             "Status: " + states.get(task.get("status"), str(task.get("status", ""))),
             "Assignee: " + str(task.get("assignee") or "Unspecified")[:160]]
    if task.get("next_action"):
        lines.append("Next action: " + str(task["next_action"])[:500])
    if task.get("due_at"):
        lines.append("Due: " + str(task["due_at"])[:80])
    lines.append("Task ID: %s · Revision: %s" % (task["id"], task["revision"]))
    return "\n".join(lines)


def run(request):
    if not isinstance(request, dict) or request.get("protocol_version", 1) != 1:
        raise IntegrationError("Unsupported plugin request protocol.", "INVALID_REQUEST")
    config, params, method = request.get("config", {}), request.get("params", {}), request.get("method")
    if not isinstance(config, dict) or not isinstance(params, dict):
        raise IntegrationError("Check plugin configuration and the request.", "INVALID_REQUEST")
    if any(key in config for key in ("token", "access_token", "bot_token", "user_token")):
        raise IntegrationError("Do not put tokens in configuration JSON. Connect them through credentials_file.", "INVALID_REQUEST")
    if method == "discover":
        return {"ok": True, "result": {"available": True,
            "message": "Connect a Slack User OAuth token. Your workspace is detected automatically.",
            "config": {"account": str(config.get("account") or "default"),
                       "messages_enabled": True, "send_enabled": config.get("send_enabled") is True}}}
    if method == "connect":
        filename = Path(required(params, "credentials_file")).expanduser()
        try:
            if filename.stat().st_size > 16384:
                raise ValueError()
            data = json.loads(filename.read_text())
            token = valid_token(data.get("access_token") if isinstance(data, dict) else None)
        except (OSError, ValueError):
            raise IntegrationError("Check the Slack User OAuth token.", "AUTHORIZATION_REQUIRED") from None
        response = api("auth.test", token)
        team_id = required(response, "team_id")
        if config.get("team_id") and config["team_id"] != team_id:
            raise IntegrationError("This token belongs to a different workspace. Use Advanced settings to change workspaces.", "AUTHORIZATION_REQUIRED")
        result = identity(response, team_id)
        account = str(config.get("account") or "default")
        keychain(account, {"access_token": token, **result})
        return {"ok": True, "result": {"connected": True, **result, "config": {
            "account": account, "team_id": team_id, "messages_enabled": True,
            "send_enabled": config.get("send_enabled") is True}}}
    if method not in METHODS:
        raise IntegrationError("Check plugin configuration and the request.", "INVALID_REQUEST")
    account = required(config, "account")
    if method == "disconnect":
        keychain(account, remove=True)
        return {"ok": True, "result": {"connected": False, "token_revoked": False}}
    if config.get("messages_enabled") is not True:
        raise IntegrationError("Enable Slack message reading first.", "INTEGRATION_DISABLED")
    team_id = required(config, "team_id")
    if params.get("team_id", team_id) != team_id:
        raise IntegrationError("This message was read from another workspace. Search again.", "CONFLICT")
    if method == "authorize":
        filename = Path(required(config, "credentials_file")).expanduser()
        try:
            if filename.stat().st_size > 16384:
                raise ValueError()
            data = json.loads(filename.read_text())
            token = valid_token(data.get("access_token") if isinstance(data, dict) else None)
        except (OSError, ValueError):
            raise IntegrationError("Check the JSON file containing the User OAuth Token access_token.", "AUTHORIZATION_REQUIRED") from None
        result = identity(api("auth.test", token), team_id)
        keychain(account, {"access_token": token, **result})
        return {"ok": True, "result": {"connected": True, **result}}

    if method == "tasks.send":
        if config.get("send_enabled") is not True:
            raise IntegrationError("Enable Slack task status sending separately.", "INTEGRATION_DISABLED")
        if params.get("confirmed_by_user") is not True:
            raise IntegrationError("Only user-selected task status can be sent.", "INVALID_REQUEST")
        channel(params)
        task = params.get("task")
        if not isinstance(task, dict) or not task.get("id") or type(task.get("revision")) is not int:
            raise IntegrationError("Task information read by the host is required.", "INVALID_REQUEST")
        if params.get("expected_revision", task["revision"]) != task["revision"]:
            raise IntegrationError("The task changed. Read it again before sending.", "CONFLICT")

    # Validate mutation targets before reading credentials or sending any external requests.
    if method == "messages.import":
        required(params, "project_id")
        for key in ("title", "parent_id"):
            if key in params:
                required(params, key)
    if method == "messages.attach":
        required(params, "task_id")
        if "expected_revision" in params and (type(params["expected_revision"]) is not int or params["expected_revision"] < 1):
            raise IntegrationError("expected_revision must be a positive integer.", "INVALID_REQUEST")
    if method in {"messages.read", "messages.thread", "messages.import", "messages.attach"}:
        channel(params)
        timestamp(params.get("ts"))
        if params.get("thread_ts"):
            timestamp(params["thread_ts"])
    if method == "messages.search":
        required(params, "query")
        bounded_integer(params, "limit", 10, 20)
        bounded_integer(params, "page", 1, 10000)
    if method == "messages.thread":
        bounded_integer(params, "limit", 15, 15)
    token = connection(config, account, team_id)
    if method == "check":
        return {"ok": True, "result": {"connected": True, **identity(api("auth.test", token), team_id)}}
    if method == "tasks.send":
        # Confirm workspace before an outbound write, even if the Keychain item was replaced.
        identity(api("auth.test", token), team_id)
        text = status_text(params["task"])
        fallback = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        result = api("chat.postMessage", token, body={"channel": channel(params), "text": fallback,
            "blocks": [{"type": "section", "text": {"type": "plain_text", "text": text, "emoji": False}}],
            "mrkdwn": False, "parse": "none", "link_names": False, "unfurl_links": False, "unfurl_media": False})
        return {"ok": True, "result": {"sent": True, "channel_id": required(result, "channel"),
            "ts": timestamp(result.get("ts")), "task_id": params["task"]["id"], "task_revision": params["task"]["revision"]}}
    if method == "messages.search":
        page = api("search.messages", token, {"query": required(params, "query"), "highlight": "false",
            "sort": "timestamp", "sort_dir": "desc", "count": params.get("limit", 10), "page": params.get("page", 1)})
        messages = page.get("messages", {})
        rows = []
        for message in messages.get("matches", []):
            row = message_info(message, required(message.get("channel", {}), "id"), team_id, preview=True)
            row["channel_name"] = message.get("channel", {}).get("name", "")
            rows.append(row)
        paging = messages.get("paging", {})
        return {"ok": True, "result": {"messages": rows, "total": messages.get("total", paging.get("total", 0)),
            "page": paging.get("page", params.get("page", 1)),
            "next_page": paging.get("page", 1) + 1 if paging.get("page", 1) < paging.get("pages", 1) else None}}
    if method == "messages.thread":
        channel_id = channel(params)
        page = api("conversations.replies", token, {"channel": channel_id, "ts": params["ts"],
            "limit": params.get("limit", 15), "cursor": params.get("cursor")})
        return {"ok": True, "result": {"messages": [message_info(m, channel_id, team_id, preview=True)
            for m in page.get("messages", [])], "next_cursor": page.get("response_metadata", {}).get("next_cursor"),
            "has_more": page.get("has_more", False)}}
    item = read_message(params, token, team_id)
    if method == "messages.read":
        return {"ok": True, "result": item}
    requests = []
    if method == "messages.import":
        creation = {"project_id": params["project_id"], "title": params.get("title") or (item["text"].splitlines() or [""])[0].strip()[:160] or "Slack message",
                    "goal": item["text"] + "\n\n" + item["url"]}
        if params.get("parent_id"):
            creation["parent_id"] = params["parent_id"]
        requests.append({"method": "task.create", "params": creation})
        task_id = {"$result": "/0/task_id"}
    else:
        task_id = required(params, "task_id")
    attachment = {"task_id": task_id, "path": item["url"], "kind": "url", "description": "Slack: " + item["text"][:160],
                  "provider": "slack",
                  "verified_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                  "metadata": {k: item[k] for k in ("team_id", "channel_id", "ts", "thread_ts", "user")}}
    attachment["metadata"]["source_version"] = item["version"]
    if method == "messages.attach" and "expected_revision" in params:
        attachment["expected_revision"] = params["expected_revision"]
    requests.append({"method": "task.attach", "params": attachment})
    return {"ok": True, "result": item, "requests": requests}


if __name__ == "__main__":
    try:
        output = run(json.load(sys.stdin))
    except IntegrationError as error:
        output = {"ok": False, "error": {"code": error.code, "message": str(error)}}
    except Exception:
        output = {"ok": False, "error": {"code": "INTEGRATION_UNAVAILABLE", "message": "Could not process the Slack request. Check connection settings and input."}}
    print(json.dumps(output, ensure_ascii=False))
