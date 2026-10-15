# Slack plugin

Search/read Slack messages, attach them to existing tasks, or import tasks/subtasks. Separately enable sending to post selected task status to a specified channel. The core app/CLI excludes this provider and its Python dependency and works without it.

## Capabilities

| Feature | Behavior |
| --- | --- |
| Search | Slack query syntax, short previews, explicitly requested pages. |
| Read source | Reread the exact channel ID and string timestamp `ts`; verify its source link. |
| Threads | Up to 15 messages per page; use `next_cursor`. |
| Attach | Save source URL, workspace/channel/message IDs, source version, and verification time. |
| Import | Use selected message text/link as a task goal; optional `parent_id` creates a subtask. |
| Send status | Send title, status, assignee, next action, due date, ID, and revision to a selected channel. |

Use service `task.create`/`task.attach` requests; never direct database access. No automatic collection/sync, background notifications, or slash commands. Sends use the connected User Token account.

## Installation and authentication

Requires Python 3.9+ and macOS Keychain, with no pip dependencies. Authentication imports a user-created app's **User OAuth Token (`xoxp-`)**. Browser installation OAuth and automatic token refresh are not implemented. Bot/App tokens cannot authenticate search.

1. Create an internal workspace app at [Slack app management](https://api.slack.com/apps); follow organization approval requirements.
2. Add required **User Token Scopes** in OAuth & Permissions and install the app.
3. Privately store `{"access_token":"YOUR_USER_OAUTH_TOKEN"}` outside the repository. Restrict it with `chmod 600 /absolute/path/slack.credentials.json`. Do not pass the token directly as a CLI argument or configuration value.
4. Identify the workspace ID (`T…`), for example from `app.slack.com/client/T…/C…`.
5. Install the extracted package directory and configure it.

| Feature | User Token scopes |
| --- | --- |
| Search | `search:read` |
| Public messages/threads | `channels:history` |
| Private channels | `groups:history` when needed |
| DMs/group DMs | `im:history`, `mpim:history` when needed |
| Status sending | `chat:write` only when used |

Reinstall the Slack app after scope changes and connect the updated token. Conversation access follows account/workspace policy. See [search.messages](https://docs.slack.dev/reference/methods/search.messages/), [conversations.replies](https://docs.slack.dev/reference/methods/conversations.replies/), and [chat.postMessage](https://docs.slack.dev/reference/methods/chat.postMessage/).

```sh
workboard plugin install ./plugins/slack
workboard plugin enable slack --config '{"account":"work","team_id":"T123","credentials_file":"/absolute/path/slack.credentials.json","messages_enabled":true,"send_enabled":false}'
workboard plugin run slack authorize
workboard plugin check slack
```

Build `dist/AgentWorkboard-plugin-slack-0.1.0.zip` with `scripts/package-plugins.sh`. Extract and select `slack-0.1.0` in the app/CLI, not the ZIP itself.

Installation leaves the plugin disabled. `messages_enabled`/`send_enabled` require Boolean `true`, not `"true"` or `1`. Sending requires both features enabled.

`authorize` checks the file token with `auth.test`, verifies the configured workspace, then stores it in Keychain. Reads/sends subsequently use Keychain. The original JSON is not automatically deleted. `plugin check` verifies authentication/workspace; detailed scope checks occur at the relevant API call.

## App workflow

Install in plugin settings, enter token JSON/account/workspace ID, enable reading, and save. Choose **Use → Connect token**, then search.

Selecting a message rereads its source. With a board task selected, attach it or import a subtask; new tasks use the chosen project. If content changes after reading, stop attachment/import and ask the user to review again.

To send, enable **Send selected task status to Slack**. Select a board task, expand **Send selected task status**, enter a channel ID, and choose **Send status to Slack**. Goals and artifact/evidence bodies are not sent. Messages are plain text with link previews disabled.

After failure, **Check the same send again** reuses the request ID; task/revision/channel cannot change. Before a new send, inspect Slack and choose **Prepare a new send after checking Slack**. Also inspect prior messages after closing the screen or switching boards. Connection changes invalidate old requests and delayed responses.

## CLI workflow

Replace example IDs with actual results. Keep `ts`/`thread_ts` as **strings** with six fractional digits.

```sh
workboard plugin run slack messages.search --query 'in:general deadline' --json
workboard plugin run slack messages.search --params '{"query":"in:general deadline","page":2}' --json
workboard plugin run slack messages.read --params '{"channel_id":"C123","ts":"1792034000.000123"}' --json
workboard plugin run slack messages.thread --params '{"channel_id":"C123","ts":"1792034000.000123","limit":15}' --json
workboard plugin run slack messages.import --request-id slack-import-1 --params '{"channel_id":"C123","ts":"1792034000.000123","project_id":"PROJECT_ID","parent_id":"PARENT_TASK_ID"}' --json
workboard plugin run slack messages.attach --task TASK_ID --request-id slack-attach-1 --params '{"channel_id":"C123","ts":"1792034000.000123","expected_revision":3}' --json
```

Include `thread_ts` for a known parent timestamp. Pass `next_cursor` as `cursor` for the next thread page. Calls read one page, never automatically collect all messages.

Pass read `version` as `expected_version` to detect source changes; the app does so automatically. If omitted in the CLI, use the source reread at execution. Supplied `team_id` guards against using a message read from another workspace.

Enable permissions/settings before sending. Use the current task revision. The host replaces supplied task bodies with service-read data.

```sh
workboard plugin enable slack --config '{"send_enabled":true}'
workboard plugin run slack tasks.send --task TASK_ID --request-id slack-status-1 --params '{"channel_id":"C123","expected_revision":3,"confirmed_by_user":true}' --json
```

The result includes `sent`, channel, message `ts`, task ID, and revision. It does not change task status. Use a new request ID for a new send and identical ID/parameters for the same send's retry.

## Retries and disconnection

The shared journal preserves successful create/attach/send results. Identical retries return them; changed content with the same ID returns `REQUEST_ID_CONFLICT`. A new import ID creates a separate task.

Lost responses or interrupted sends can leave uncertain results. Identical retries return `PLUGIN_RESULT_UNCERTAIN` rather than repeating the external write. **Inspect the actual Slack message before deciding to send again.** Never build an automatic new-ID retry loop.

HTTP 429/`Retry-After` returns `INTEGRATION_RATE_LIMITED` without immediate retry. Limits can depend on app distribution type; see [Slack rate limits](https://docs.slack.dev/apis/web-api/rate-limits/).

```sh
workboard plugin run slack disconnect
workboard plugin disable slack
workboard plugin remove slack
```

`disconnect` deletes only the local Keychain token, not Slack authorization. Revoke through Slack app management if needed. Disable/remove does not run providers; disconnect first to delete Keychain data. Disabled/removed plugins perform no token reads, calls, or sends. Preserve tasks/subtasks/source links.

## Verification limits

`test_slack_plugin.py` mocks HTTP/Keychain. `test_slack_host.py` connects actual Rust CLI/provider/service/database and replaces only HTTP/Keychain. They cover authentication/permissions/rate limits, source conflicts, subtasks, retries, uncertain sends, and data preservation.

Actual workspace authentication, Keychain, search/read/sending remain separate checks. Mock success and app builds do not establish real-account verification.
