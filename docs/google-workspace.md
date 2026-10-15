# Google Workspace plugin

Connect Calendar events and kanban tasks, with Gmail reading only when separately enabled. Calendar and Gmail are the implemented Workspace services. The package is excluded from the core app/CLI; core task management needs no Google account or Python.

## Capabilities

| Feature | Behavior |
| --- | --- |
| Calendars | List calendars and read/write roles. |
| Events | Read a selected range, expanding recurring events into individual occurrences. |
| Import | Create a task/subtask and attach its original event link. |
| Apply event to existing task | Update only due date, scheduled start/end, and zone; preserve title, goal, assignee, and status. |
| Create event | Date-only deadlines become all-day events; meetings use their start/end. |
| Update event | Change title, description, and time only with a matching source ETag. |
| Optional Gmail | Search/read messages, import tasks, and attach to existing tasks. |

The service validates returned `task.create`, `task.update`, and `task.attach` requests. The plugin never accesses the task database directly. It does not send mail, add attendees, send invitations, synchronize automatically, or collect in the background. Calendar writes run only through explicitly selected commands/buttons.

## Installation and authentication

This optional plugin needs Python 3.9+ and macOS Keychain, with no pip packages.

1. Enable Google Calendar API in a Google Cloud project; enable Gmail API only if needed.
2. Configure consent and create a **Desktop app** OAuth client. In testing mode, register the account as a test user.
3. Store client JSON privately outside the repository and app bundle.
4. Install the plugin and configure services and the JSON path.

Extract `AgentWorkboard-plugin-google-workspace-0.1.0.zip` and select the `google-workspace-0.1.0` directory containing `plugin.json` and `plugin.py`. Replace the source directory below with that extracted path when using a release ZIP. Do not install the ZIP itself. Rebuild archives with `scripts/package-plugins.sh`; core apps/DMGs exclude provider code.

```sh
workboard plugin install ./plugins/google-workspace
workboard plugin enable google-workspace --config '{"credentials_file":"/absolute/path/desktop-client.json","account":"personal","calendar_enabled":true,"gmail_enabled":false}'
workboard plugin run google-workspace authorize
workboard plugin check google-workspace
```

New installations are disabled. Services require literal JSON `true`, not the string `"true"`. Calendar-only configuration requests no Gmail scopes and calls no Gmail API. Enabling Gmail later requires `authorize` again with the new scopes.

| Service | OAuth scopes |
| --- | --- |
| Calendar | `calendar.events`, `calendar.calendarlist.readonly` |
| Gmail | `gmail.readonly` |

Calendar scopes permit event reads/creation/updates and calendar listing, not calendar deletion or sharing changes. Gmail is read-only. Workspace administrator policy and OAuth publication status may restrict consent/use. See [Calendar authorization](https://developers.google.com/workspace/calendar/api/auth) and [Gmail messages.get](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/get) for scope/review rules.

Authentication uses the system browser, PKCE S256, random `state`, and an ephemeral `127.0.0.1` port. Reject incorrect state. Store tokens by account label under Keychain service `local.agentworkboard.google-workspace`, never in task data or configuration JSON. Do not automatically read/migrate legacy `gmail` package tokens. See [Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app).

## Calendar commands

```sh
workboard plugin run google-workspace calendar.list
workboard plugin run google-workspace events.list --params '{"calendar_id":"primary","time_min":"2026-10-15T00:00:00+09:00","time_max":"2026-10-22T00:00:00+09:00"}'
workboard plugin run google-workspace events.get --params '{"calendar_id":"primary","event_id":"EVENT_ID"}'
workboard plugin run google-workspace events.import --params '{"calendar_id":"primary","event_id":"EVENT_ID","project_id":"PROJECT_ID","parent_id":"OPTIONAL_PARENT_ID"}'
```

Replace uppercase IDs with actual values; omit `parent_id` for a standalone task. The plugin's `events.import` imports an event **into the board**, not Google's `events.import` API. It reads Calendar and requests task creation/source attachment from the board service.

`calendar.list` returns `calendars` entries with `id`, `title`, `time_zone`, `access_role`, and `primary`. `events.list` returns `events` with `id`, `calendar_id`, `title`, `description`, `url`, `etag`, `start`, `end`, `time_zone`, and `status`. Dates are date-only or RFC3339 strings. Pass returned `next_page_token` as `page_token` on the next call. Default limit is 30, maximum 100. See [events.list](https://developers.google.com/calendar/api/v3/reference/events/list).

Apply a previously read event to an existing task with its ETag:

```sh
workboard plugin run google-workspace events.pull --task TASK_ID --params '{"calendar_id":"primary","event_id":"EVENT_ID","etag":"\"GOOGLE_ETAG\""}'
```

Read the latest event and reject changed ETags with `CONFLICT`. Otherwise update only deadline, schedule, and zone and attach the source. The service also checks local revisions, preventing concurrent overwrite. Preserve title/goal/assignee/status and do not write Google. Use the event's named time zone when present. Otherwise read its calendar's zone with [CalendarList.get](https://developers.google.com/workspace/calendar/api/v3/reference/calendarList/get), using the existing `calendar.calendarlist.readonly` scope. This also applies to date-only events, whose start/end normally omit a named zone. Listing uses the response's calendar zone. Preserve timestamp offsets; if calendar metadata cannot provide a valid zone, fail before changing the board rather than assigning UTC or the old task's zone.

The following command actually creates an external event; select the intended task/calendar before running it:

```sh
workboard plugin run google-workspace events.create --params '{"calendar_id":"primary","task":{"id":"TASK_ID","title":"Review screen","goal":"Check kanban behavior","revision":7,"due_at":"2026-10-16","time_zone":"Asia/Seoul"}}'
```

For existing tasks, the host reads current state from the service. Supplied task objects are replaced with current data; stale supplied revisions conflict before external writes.

```sh
workboard plugin run google-workspace events.create --task TASK_ID --params '{"calendar_id":"primary"}'
workboard plugin run google-workspace events.update --task TASK_ID --params '{"calendar_id":"primary","event_id":"EVENT_ID","etag":"\"GOOGLE_ETAG\""}'
```

Specify both meeting endpoints, including seconds and offsets, such as `2026-10-16T10:00:00+09:00`. Use an IANA zone such as `Asia/Seoul`.

| Task time | Calendar representation |
| --- | --- |
| Date-only due date | All-day event ending the following day. |
| Timed due date | Thirty-minute event from the deadline, unless explicit meeting times take precedence. |
| Date-only start/end | All-day event with exclusive end date. |
| Timed start/end | Event at the specified endpoints. |
| Calendar→task | Preserve endpoints; all-day due date is the day before exclusive end, timed due date is the end instant. |

Reject missing endpoints, end≤start, or offset-free timestamps before writes. Store task ID/revision in private event properties and include the workboard link in its description.

Event IDs use base32hex SHA-256 of account/calendar/task identity. Retries reuse IDs. On HTTP 409, read and verify the existing event belongs to the same task and is not cancelled. Return `reused:true` for a matching event without overwriting its contents; otherwise conflict. See [events.insert](https://developers.google.com/workspace/calendar/api/v3/reference/events/insert) for IDs and notification options.

Updates require the previously read ETag:

```sh
workboard plugin run google-workspace events.update --params '{"calendar_id":"primary","event_id":"EVENT_ID","etag":"\"GOOGLE_ETAG\"","task":{"id":"TASK_ID","title":"Updated title","goal":"Review notes","revision":8,"due_at":"2026-10-17","time_zone":"Asia/Seoul"}}'
```

Read and compare ETags, then PATCH managed fields with `If-Match`. A racing HTTP 412 returns `CONFLICT`, never automatic overwrite. Preserve existing attendees and other apps' private properties. Add no attendees and use `sendUpdates=none`. Do not update entire recurring series or special birthday/out-of-office events here. See [ETags](https://developers.google.com/workspace/calendar/api/guides/version-resources) and the [event reference](https://developers.google.com/workspace/calendar/api/v3/reference/events).

Calendar writes and board source-link storage are separate transactions. Google may succeed before a board revision/storage failure. Inspect the latest external event. Creation can retry the same task ID; updates require rereading the ETag and user confirmation.

## Optional Gmail

```sh
workboard plugin enable google-workspace --config '{"gmail_enabled":true}'
workboard plugin run google-workspace authorize
workboard plugin run google-workspace gmail.search --params '{"query":"is:unread","limit":5}'
workboard plugin run google-workspace gmail.read --params '{"message_id":"MESSAGE_ID"}'
workboard plugin run google-workspace gmail.import --params '{"message_id":"MESSAGE_ID","project_id":"PROJECT_ID"}'
workboard plugin run google-workspace gmail.attach --params '{"message_id":"MESSAGE_ID","task_id":"TASK_ID"}'
```

Search reads lists, subjects, senders, and snippets. `read`/`import` reread selected bodies. Show plain text; strip HTML tags when no plain part exists. Exclude scripts/styles and do not download remote images or attachments. Bodies are limited to 32,000 characters with `body_truncated:true` when clipped. Imports/attachments preserve source Gmail links and message IDs. See [message MIME data](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages).

## Disconnect and verification

```sh
workboard plugin run google-workspace disconnect
workboard plugin disable google-workspace
# Also remove installed files:
workboard plugin remove google-workspace
```

`disconnect` deletes this plugin's local Keychain token, not the Google account, mail, or events. Disabling/removing preserves tasks/subtasks and Calendar/Gmail links. Revoke app permissions in Google's connected-app settings if needed.

```sh
python3 -m unittest discover -s tests -p test_workspace_plugin.py -v
```

The original Python 3.9.6 run passed 24 checks for mocked HTTP listing/import/schedule-only pull/create/conditional updates/409/412/service guards/Gmail text/token refresh. OAuth tests use a real local loopback server with incorrect/correct state and PKCE validation. Google network/login/writes, token exchange, and Keychain calls are mocked in these tests. Verify actual consent, refresh, calendar permissions, and writes separately.

Nine `test_workspace_host.py` checks connect the real Rust CLI/service and provider process, replacing only HTTP/tokens. They verify creation, schedule application, revision references, retries/conflicts, and preserved reauthorization codes. No user Desktop OAuth client is currently available. See [verification](verification.md).
