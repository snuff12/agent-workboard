#!/usr/bin/env python3
"""Optional Calendar-first Workspace plugin. Standard library only; no DB access."""
import base64
import datetime as dt
import hashlib
from html.parser import HTMLParser
import http.server
import json
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

SERVICE = "local.agentworkboard.google-workspace"
CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar.events"
CALENDAR_LIST_SCOPE = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
CALENDAR_API = "https://www.googleapis.com/calendar/v3/"
GMAIL_API = "https://gmail.googleapis.com/gmail/v1/users/me/"


class IntegrationError(ValueError):
    def __init__(self, message, code="INTEGRATION_UNAVAILABLE"):
        super().__init__(message)
        self.code = code


class GoogleHTTPError(IntegrationError):
    def __init__(self, status):
        code = "CONFLICT" if status in (409, 412) else "INTEGRATION_UNAVAILABLE"
        message = ("The event changed elsewhere. Read and review the latest event."
                   if status == 412 else "Google request failed (HTTP %s). Check the connection and permissions." % status)
        super().__init__(message, code)
        self.status = status


def enabled(config, name):
    # Explicit booleans only: a string such as 'false' must never enable access.
    return config.get(name + "_enabled") is True


def scopes(config):
    selected = []
    if enabled(config, "calendar"):
        selected += [CALENDAR_SCOPE, CALENDAR_LIST_SCOPE]
    if enabled(config, "gmail"):
        selected.append(GMAIL_SCOPE)
    if not selected:
        raise IntegrationError("Enable the Calendar or Gmail connection first.", "INTEGRATION_DISABLED")
    return selected


def keychain(account, token=None, remove=False):
    if token is not None:
        # Send token material over stdin, never process arguments or stdout.
        line = "add-generic-password -U -s %s -a %s -w %s\n" % tuple(
            shlex.quote(v) for v in (SERVICE, account, json.dumps(token)))
        result = subprocess.run(["/usr/bin/security", "-i"], input=line, text=True, capture_output=True)
    elif remove:
        result = subprocess.run(["/usr/bin/security", "delete-generic-password", "-s", SERVICE, "-a", account],
                                text=True, capture_output=True)
    else:
        result = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", SERVICE, "-a", account, "-w"],
                                text=True, capture_output=True)
    if remove and result.returncode == 44:
        return None
    if result.returncode:
        raise IntegrationError("Workspace connection details are missing. Connect an account." if token is None else "Could not save to Keychain.")
    return json.loads(result.stdout) if token is None and not remove else None


def token_request(data):
    request = urllib.request.Request("https://oauth2.googleapis.com/token",
        data=urllib.parse.urlencode(data).encode(), method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    except (urllib.error.HTTPError, urllib.error.URLError):
        raise IntegrationError("Google authentication failed. Check the OAuth client and account permissions.") from None


def credentials(config):
    filename = config.get("credentials_file") or config.get("credential_file") or Path(__file__).with_name("oauth-client.json")
    try:
        data = json.loads(Path(filename).expanduser().read_text())
    except (OSError, ValueError):
        raise IntegrationError("Google sign-in is not configured in this plugin build. Install a Workspace plugin with the publisher's OAuth client.", "AUTHORIZATION_REQUIRED") from None
    client = data.get("installed") if isinstance(data, dict) else None
    if not isinstance(client, dict) or not isinstance(client.get("client_id"), str) or not client["client_id"].strip():
        raise IntegrationError("An OAuth client JSON file for a Desktop app is required.")
    return client


def authorize(config, account):
    selected = scopes(config)
    client = credentials(config)
    state, verifier = secrets.token_urlsafe(32), secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    received = {}

    class Callback(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(url.query)
            if url.path != "/oauth/callback" or query.get("state", [""])[0] != state:
                self.send_error(400)
                return
            received.update({key: values[0] for key, values in query.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write("<p>Agent Workboard received the authentication response. Return to the app.</p>".encode())

        def log_message(self, *args):
            pass

    with http.server.HTTPServer(("127.0.0.1", 0), Callback) as server:
        server.timeout = 1
        redirect = "http://127.0.0.1:%d/oauth/callback" % server.server_port
        url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
            "client_id": client["client_id"], "redirect_uri": redirect, "response_type": "code",
            "scope": " ".join(selected), "state": state, "code_challenge": challenge,
            "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent select_account"})
        subprocess.run(["/usr/bin/open", url], check=True, capture_output=True)
        deadline = time.monotonic() + 150
        while not received and time.monotonic() < deadline:
            server.handle_request()
    if not received.get("code"):
        raise IntegrationError("Workspace connection was cancelled or authentication timed out.")
    token = token_request({"code": received["code"], "client_id": client["client_id"],
        "client_secret": client.get("client_secret", ""), "redirect_uri": redirect,
        "grant_type": "authorization_code", "code_verifier": verifier})
    granted = set(token.get("scope", " ".join(selected)).split())
    if not set(selected).issubset(granted):
        raise IntegrationError("Not all permissions for the selected features were granted. Check connection settings.")
    token["workspace_scopes"] = sorted(granted)
    token["workspace_client_id"] = client["client_id"]
    token["expires_at"] = time.time() + token.get("expires_in", 3600)
    keychain(account, token)
    return {"connected": True, "calendar_enabled": enabled(config, "calendar"),
            "gmail_enabled": enabled(config, "gmail"), "scopes": sorted(granted)}


def access_token(config, account):
    required_scopes = scopes(config)
    token = keychain(account)
    granted = set(token.get("workspace_scopes", token.get("scope", "").split()))
    if not set(required_scopes).issubset(granted):
        raise IntegrationError("Connection settings changed. Reconnect the account with permissions for the selected features.", "AUTHORIZATION_REQUIRED")
    if time.time() + 60 >= token.get("expires_at", 0):
        if not token.get("refresh_token"):
            raise IntegrationError("Workspace authentication expired. Reconnect the account.")
        client = credentials(config)
        if token.get("workspace_client_id", client["client_id"]) != client["client_id"]:
            raise IntegrationError("Google sign-in settings changed. Reconnect your account.", "AUTHORIZATION_REQUIRED")
        updated = token_request({"client_id": client["client_id"], "client_secret": client.get("client_secret", ""),
            "refresh_token": token["refresh_token"], "grant_type": "refresh_token"})
        token.update(updated)
        token["expires_at"] = time.time() + updated.get("expires_in", 3600)
        keychain(account, token)
    return token["access_token"]


def api(service, path, token, params=None, method="GET", body=None, etag=None):
    base = CALENDAR_API if service == "calendar" else GMAIL_API
    url = base + path
    if params:
        url += "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v is not None}, doseq=True)
    headers = {"Authorization": "Bearer " + token}
    if etag is not None:
        headers["If-Match"] = etag
    if body is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, headers=headers, method=method,
        data=json.dumps(body, ensure_ascii=False).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise GoogleHTTPError(error.code) from None
    except urllib.error.URLError:
        raise IntegrationError("Could not connect to Google. Check your network.") from None


def quoted(value):
    return urllib.parse.quote(str(value), safe="")


def required(params, name):
    value = params.get(name)
    if not isinstance(value, str) or not value.strip():
        raise IntegrationError("Specify a value for %s." % name, "INVALID_REQUEST")
    return value


def event_path(calendar_id, event_id=None):
    return "calendars/" + quoted(calendar_id) + "/events" + ("/" + quoted(event_id) if event_id else "")


def event_info(event, calendar_id, calendar_zone=None):
    start, end = event.get("start", {}), event.get("end", {})
    return {"id": event["id"], "calendar_id": calendar_id,
        "title": event.get("summary", "Untitled event"), "summary": event.get("summary", "Untitled event"),
        "description": event.get("description", ""), "detail": event.get("description", ""),
        "url": event.get("htmlLink") or "https://calendar.google.com/calendar/u/0/r",
        "etag": event.get("etag"), "start": start.get("dateTime", start.get("date")),
        "end": end.get("dateTime", end.get("date")), "time_zone": start.get("timeZone") or calendar_zone,
        "status": event.get("status", "confirmed"), "location": event.get("location", "")}


def parse_time(value):
    if not isinstance(value, str):
        raise IntegrationError("Specify an event date or timestamp.", "INVALID_REQUEST")
    try:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            return dt.date.fromisoformat(value)
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})", value):
            raise ValueError()
        result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if result.utcoffset() is None:
            raise ValueError()
        return result
    except ValueError:
        raise IntegrationError("Use YYYY-MM-DD for dates and RFC3339 with a time zone offset for timestamps.", "INVALID_REQUEST") from None


def task_event(task):
    task_id, title = required(task, "id"), required(task, "title")
    start, end = task.get("scheduled_start"), task.get("scheduled_end")
    if bool(start) != bool(end):
        raise IntegrationError("Specify both meeting start and end.", "INVALID_REQUEST")
    if start and end:
        parsed_start, parsed_end = parse_time(start), parse_time(end)
        if type(parsed_start) is not type(parsed_end) or parsed_end <= parsed_start:
            raise IntegrationError("Event end must be after start and use the same date format.", "INVALID_REQUEST")
    else:
        parsed_start = parse_time(task.get("due_at"))
        parsed_end = parsed_start + (dt.timedelta(minutes=30) if isinstance(parsed_start, dt.datetime) else dt.timedelta(days=1))
    zone = task.get("time_zone")
    if zone:
        try:
            ZoneInfo(zone)
        except (ZoneInfoNotFoundError, ValueError, TypeError):
            raise IntegrationError("Specify a valid IANA time zone name.", "INVALID_REQUEST") from None
    key = "dateTime" if isinstance(parsed_start, dt.datetime) else "date"
    begin, finish = {key: parsed_start.isoformat()}, {key: parsed_end.isoformat()}
    if zone and key == "dateTime":
        begin["timeZone"], finish["timeZone"] = zone, zone
    private = {"workboard_task_id": task_id, "workboard_revision": str(task.get("revision", ""))}
    return {"summary": title, "description": (task.get("goal") or "") + "\n\nAgent Workboard: workboard://task/" + quoted(task_id),
        "start": begin, "end": finish, "extendedProperties": {"private": private}}


def event_attachment(item, task_id, revision=None):
    params = {"task_id": task_id, "path": item["url"], "kind": "calendar", "description": item["title"],
        "provider": "google-workspace", "verified_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "metadata": {"provider": "google-workspace", "service": "calendar", "event_id": item["id"],
                     "calendar_id": item["calendar_id"], "etag": item["etag"], "start": item["start"], "end": item["end"]}}
    if revision is not None:
        params["expected_revision"] = revision
    return {"method": "task.attach", "params": params}


def stable_event_id(account, calendar_id, task_id):
    digest = hashlib.sha256((account + "\0" + calendar_id + "\0" + task_id).encode()).digest()
    # base32hex uses exactly the alphabet accepted by Google event IDs.
    encoded = base64.b32encode(digest).decode()
    return encoded.translate(str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567", "0123456789ABCDEFGHIJKLMNOPQRSTUV")).lower().rstrip("=")


def schedule_from_event(item):
    start, end = parse_time(item["start"]), parse_time(item["end"])
    if type(start) is not type(end) or end <= start:
        raise IntegrationError("The event to import has an invalid start or end.", "INVALID_REQUEST")
    return {"scheduled_start": item["start"], "scheduled_end": item["end"],
        "due_at": (end - dt.timedelta(days=1)).isoformat() if type(end) is dt.date else item["end"],
        "time_zone": item["time_zone"]}


def resolve_event_zone(item, token):
    if item["time_zone"] or item["status"] == "cancelled" or not item["start"] or not item["end"]:
        return
    # Date-only events omit start.timeZone. Use their calendar's zone, not UTC
    # or the previously linked task's zone. The existing calendar-list scope suffices.
    calendar = api("calendar", "users/me/calendarList/" + quoted(item["calendar_id"]), token)
    zone = calendar.get("timeZone")
    try:
        ZoneInfo(zone)
    except (ZoneInfoNotFoundError, ValueError, TypeError):
        raise IntegrationError("The calendar did not provide a valid IANA time zone.") from None
    item["time_zone"] = zone


def calendar_run(method, params, token, account):
    if method == "calendar.list":
        page = api("calendar", "users/me/calendarList", token,
            {"maxResults": 100, "pageToken": params.get("page_token")})
        calendars = [{"id": item["id"], "title": item.get("summary", "Untitled calendar"),
            "summary": item.get("summary", ""), "time_zone": item.get("timeZone"),
            "access_role": item.get("accessRole"), "primary": item.get("primary", False)} for item in page.get("items", [])]
        return {"ok": True, "result": {"calendars": calendars, "next_page_token": page.get("nextPageToken")}}
    calendar_id = str(params.get("calendar_id") or "primary")
    path = event_path(calendar_id)
    if method == "events.list":
        minimum = params.get("time_min") or dt.datetime.now(dt.timezone.utc).isoformat()
        maximum = params.get("time_max")
        start = parse_time(minimum)
        if not isinstance(start, dt.datetime):
            raise IntegrationError("Use RFC3339 timestamps with time zone offsets for the query range.", "INVALID_REQUEST")
        if maximum:
            end = parse_time(maximum)
            if not isinstance(end, dt.datetime) or end <= start:
                raise IntegrationError("Query end must be an RFC3339 timestamp after start.", "INVALID_REQUEST")
        page = api("calendar", path, token, {"timeMin": minimum, "timeMax": maximum,
            "singleEvents": "true", "orderBy": "startTime", "showDeleted": "false",
            "maxResults": min(100, max(1, int(params.get("limit", 30)))), "pageToken": params.get("page_token")})
        return {"ok": True, "result": {"events": [event_info(item, calendar_id, page.get("timeZone")) for item in page.get("items", [])],
            "next_page_token": page.get("nextPageToken"), "time_zone": page.get("timeZone")}}
    if method in ("events.get", "events.import", "events.pull"):
        event = api("calendar", event_path(calendar_id, required(params, "event_id")), token)
        item = event_info(event, calendar_id)
        if method == "events.get":
            resolve_event_zone(item, token)
            return {"ok": True, "result": item}
        if item["status"] == "cancelled":
            raise IntegrationError("Cancelled events cannot be imported as tasks.", "INVALID_REQUEST")
        if method == "events.pull":
            if event.get("etag") != required(params, "etag"):
                raise IntegrationError("The event changed elsewhere. Read and review the latest event.", "CONFLICT")
            task = params.get("task")
            if not isinstance(task, dict) or type(task.get("revision")) is not int:
                raise IntegrationError("Specify the task ID and revision for attachment.", "INVALID_REQUEST")
        schedule = schedule_from_event(item)
        resolve_event_zone(item, token)
        schedule["time_zone"] = item["time_zone"]
        if method == "events.pull":
            update = {"task_id": required(task, "id"), "expected_revision": task["revision"],
                      **schedule}
            return {"ok": True, "result": item, "requests": [{"method": "task.update", "params": update},
                event_attachment(item, task["id"], {"$result": "/0/task/revision"})]}
        creation = {"project_id": required(params, "project_id"), "title": params.get("title") or item["title"],
            "goal": item["description"], **schedule}
        if params.get("parent_id"):
            creation["parent_id"] = params["parent_id"]
        return {"ok": True, "result": item, "requests": [{"method": "task.create", "params": creation},
            event_attachment(item, {"$result": "/0/task_id"})]}
    if method not in ("events.create", "events.update"):
        raise IntegrationError("Unsupported Calendar feature.", "INVALID_REQUEST")
    task = params.get("task")
    if not isinstance(task, dict):
        raise IntegrationError("Specify the task information for attachment.", "INVALID_REQUEST")
    body = task_event(task)
    reused = False
    if method == "events.create":
        body["id"] = stable_event_id(account, calendar_id, task["id"])
        try:
            event = api("calendar", path, token, {"sendUpdates": "none"}, method="POST", body=body)
        except GoogleHTTPError as error:
            if error.status != 409:
                raise
            event = api("calendar", event_path(calendar_id, body["id"]), token)
            linked_id = event.get("extendedProperties", {}).get("private", {}).get("workboard_task_id")
            if linked_id != task["id"] or event.get("status") == "cancelled":
                raise IntegrationError("A different event uses the same ID. Check the existing event.", "CONFLICT") from None
            reused = True
    else:
        target = event_path(calendar_id, required(params, "event_id"))
        etag = required(params, "etag")
        previous = api("calendar", target, token)
        if previous.get("etag") != etag:
            raise IntegrationError("The event changed elsewhere. Read and review the latest event.", "CONFLICT")
        if previous.get("recurrence") or previous.get("eventType", "default") != "default":
            raise IntegrationError("Recurring series and special events cannot be edited here.", "INVALID_REQUEST")
        private = dict(previous.get("extendedProperties", {}).get("private", {}))
        private.update(body["extendedProperties"]["private"])
        body["extendedProperties"]["private"] = private
        # Patch only our fields; preserve attendees, recurrence and other calendar data.
        event = api("calendar", target, token, {"sendUpdates": "none"}, method="PATCH", body=body, etag=etag)
    item = event_info(event, calendar_id)
    item["reused"] = reused
    return {"ok": True, "result": item, "requests": [event_attachment(item, task["id"], task.get("revision"))]}


class TextOnlyHTML(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts, self.hidden = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.hidden += 1
        if tag in ("p", "br", "div", "li") and not self.hidden:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.hidden = max(0, self.hidden - 1)

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def mail_body(payload):
    plain, html = [], []

    def visit(part):
        data = part.get("body", {}).get("data")
        if data and not part.get("filename"):
            text = base64.urlsafe_b64decode(data + "=" * (-len(data) % 4)).decode("utf-8", errors="replace")
            if part.get("mimeType") == "text/plain":
                plain.append(text)
            elif part.get("mimeType") == "text/html":
                parser = TextOnlyHTML()
                parser.feed(text)
                html.append("".join(parser.parts))
        for child in part.get("parts", []):
            visit(child)
    visit(payload)
    content = "\n".join(plain or html).strip()
    return content[:32000], len(content) > 32000


def message_info(message, include_body=False):
    payload = message.get("payload", {})
    headers = {item["name"].lower(): item["value"] for item in payload.get("headers", [])}
    item = {"id": message["id"], "thread_id": message.get("threadId"), "subject": headers.get("subject", "Untitled"),
        "from": headers.get("from", ""), "date": headers.get("date", ""), "snippet": message.get("snippet", ""),
        "url": "https://mail.google.com/mail/u/0/#all/" + quoted(message["id"])}
    if include_body:
        item["body"], item["body_truncated"] = mail_body(payload)
    return item


def gmail_run(method, params, token):
    if method == "gmail.search":
        page = api("gmail", "messages", token, {"q": params.get("query", ""),
            "maxResults": min(20, max(1, int(params.get("limit", 5)))), "pageToken": params.get("page_token")})
        messages = [message_info(api("gmail", "messages/" + quoted(item["id"]), token,
            {"format": "metadata", "metadataHeaders": ["Subject", "From", "Date"]})) for item in page.get("messages", [])]
        return {"ok": True, "result": {"messages": messages, "next_page_token": page.get("nextPageToken")}}
    message_id = required(params, "message_id")
    item = message_info(api("gmail", "messages/" + quoted(message_id), token, {"format": "full"}), True)
    if method == "gmail.read":
        return {"ok": True, "result": item}
    requests = []
    if method == "gmail.import":
        creation = {"project_id": required(params, "project_id"), "title": params.get("title") or item["subject"],
            "goal": (item.get("body") or item["snippet"]) + "\n\n" + item["url"]}
        if params.get("parent_id"):
            creation["parent_id"] = params["parent_id"]
        requests.append({"method": "task.create", "params": creation})
        task_id = {"$result": "/0/task_id"}
    elif method == "gmail.attach":
        task_id = required(params, "task_id")
    else:
        raise IntegrationError("Unsupported Gmail feature.", "INVALID_REQUEST")
    requests.append({"method": "task.attach", "params": {"task_id": task_id, "path": item["url"], "kind": "email",
        "description": item["subject"], "provider": "google-workspace", "verified_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "metadata": {"provider": "google-workspace", "service": "gmail", "message_id": item["id"], "thread_id": item["thread_id"]}}})
    return {"ok": True, "result": item, "requests": requests}


METHODS = {"calendar.list", "events.list", "events.get", "events.import", "events.pull", "events.create", "events.update",
           "gmail.search", "gmail.read", "gmail.import", "gmail.attach"}


def run(request):
    config, params, method = request.get("config", {}), request.get("params", {}), request.get("method")
    if not isinstance(config, dict) or not isinstance(params, dict):
        raise IntegrationError("config and params must be JSON objects.", "INVALID_REQUEST")
    if method == "authorize" and "connection_config" in params:
        choices = params["connection_config"]
        if not isinstance(choices, dict) or set(choices) - {"account", "calendar_enabled", "gmail_enabled"}:
            raise IntegrationError("Check the selected Google services.", "INVALID_REQUEST")
        config = {**config, **choices}
    if method == "discover":
        try:
            credentials(config)
            ready, message = True, "Sign in with Google to connect your calendar."
        except IntegrationError as error:
            ready, message = False, str(error)
        return {"ok": True, "result": {"available": ready, "message": message,
            "config": {"account": str(config.get("account") or "default"),
                       "calendar_enabled": config.get("calendar_enabled", True) is True,
                       "gmail_enabled": config.get("gmail_enabled", False) is True}}}
    account = str(config.get("account", "default"))
    if method == "disconnect":
        keychain(account, remove=True)
        return {"ok": True, "result": {"connected": False}}
    if method == "authorize":
        result = authorize(config, account)
        result["config"] = {"account": account, "calendar_enabled": enabled(config, "calendar"), "gmail_enabled": enabled(config, "gmail")}
        return {"ok": True, "result": result}
    if method not in METHODS and method != "check":
        raise IntegrationError("Unsupported feature.", "INVALID_REQUEST")
    scopes(config)
    if (method.startswith("calendar.") or method.startswith("events.")) and not enabled(config, "calendar"):
        raise IntegrationError("Calendar connection is disabled.", "INTEGRATION_DISABLED")
    if method.startswith("gmail.") and not enabled(config, "gmail"):
        raise IntegrationError("Gmail connection is disabled.", "INTEGRATION_DISABLED")
    token = access_token(config, account)
    if method == "check":
        result = {"connected": True, "calendar_enabled": enabled(config, "calendar"), "gmail_enabled": enabled(config, "gmail")}
        if enabled(config, "calendar"):
            result["calendar_count"] = len(api("calendar", "users/me/calendarList", token, {"maxResults": 100}).get("items", []))
        if enabled(config, "gmail"):
            result["email"] = api("gmail", "profile", token).get("emailAddress")
        return {"ok": True, "result": result}
    return gmail_run(method, params, token) if method.startswith("gmail.") else calendar_run(method, params, token, account)


if __name__ == "__main__":
    try:
        output = run(json.load(sys.stdin))
    except IntegrationError as error:
        output = {"ok": False, "error": {"code": error.code, "message": str(error)}}
    except Exception:
        output = {"ok": False, "error": {"code": "INTEGRATION_UNAVAILABLE", "message": "Could not process the Workspace request. Check connection settings and input."}}
    print(json.dumps(output, ensure_ascii=False))
