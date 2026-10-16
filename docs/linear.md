# Linear plugin

Search and read Linear issues, attach them to existing tasks, or import them as tasks/subtasks. Separately enable status comments to post a selected task's status on an issue, and state changes to move an issue to a chosen workflow state. The core app/CLI excludes this provider and works without it.

## Capabilities

| Feature | Behavior |
| --- | --- |
| Search | Linear full-text search, or recently updated issues when the query is empty. Filter by team, assigned to me, and closed issues. One page per call with a cursor. A term shaped like `ENG-123` reads that issue directly when it matches the filters; otherwise, such as `utf-8`, it falls back to full-text search. |
| Read source | Reread one issue by UUID or identifier; verify its `linear.app` link for the configured workspace; return the team's workflow states. |
| Attach | Save the issue URL, workspace, issue UUID/identifier, team, state, source version, and verification time. |
| Import | The issue title becomes the task title; the description and link become the goal; the due date and priority carry over. Optional `parent_id` creates a subtask. |
| Status comment | Post title, status, blocking, assignee, next action, due date, ID, and revision as a comment on a selected issue. |
| State change | Move a selected issue to a workflow state of its team after checking that the issue has not changed since it was read. |

Use service `task.create`/`task.attach` requests; never direct database access. There is no automatic sync, background polling, or webhook. Board status never changes Linear automatically, and Linear changes never change board status. Comments and state changes use the account that owns the connected API key.

Priorities map as Urgent/High → High, Medium → Normal, Low → Low. Issues without a priority keep the board default.

## Installation and authentication

Requires Python 3.9+ and macOS Keychain, with no pip dependencies. Authentication imports a Linear **personal API key** (`lin_api_…`). OAuth applications are not supported.

1. In Linear, open **Settings → Account → Security & Access** and create a personal API key. Workspace admins can stop members from creating keys.
2. Grant **Read** for search, reading, attachments, and imports. Add **Create comments** for status comments and **Write** for state changes, only when used. You can limit the key to specific teams.
3. Privately store `{"api_key":"YOUR_PERSONAL_API_KEY"}` outside the repository. Restrict it with `chmod 600 /absolute/path/linear.credentials.json`. Do not pass the key directly as a CLI argument or configuration value.
4. Find the workspace URL key, for example `acme` in `linear.app/acme/…`.
5. Install the extracted package directory and configure it.

```sh
workboard plugin install ./plugins/linear
workboard plugin enable linear --config '{"account":"work","workspace":"acme","credentials_file":"/absolute/path/linear.credentials.json","issues_enabled":true,"comments_enabled":false,"state_changes_enabled":false}'
workboard plugin run linear authorize
workboard plugin check linear
```

The account label names the Keychain item. Use 1 to 80 ASCII letters, digits, periods, underscores, at signs, or hyphens; the plugin and the app refuse other labels before touching Keychain.

Build `dist/AgentWorkboard-plugin-linear-0.1.0.zip` with `scripts/package-plugins.sh`. Extract and select `linear-0.1.0` in the app/CLI, not the ZIP itself.

Installation leaves the plugin disabled. `issues_enabled`, `comments_enabled`, and `state_changes_enabled` require Boolean `true`, not `"true"` or `1`. Comments and state changes also require issue reading.

`authorize` checks the file key with the `viewer` query, verifies that its organization URL key matches the configured workspace, then stores the key with the workspace, organization ID, and user ID in Keychain. Later calls use Keychain. Every issue link must belong to the configured workspace, so comments and state changes need no separate identity request. The original JSON is not deleted automatically. `plugin check` verifies authentication and the workspace; missing key permissions surface at the call that needs them.

## App workflow

Install in plugin settings, enter the key JSON file, account label, and workspace URL key, enable issue reading, and save. Choose **Use → Connect API key**, then search.

Selecting an issue rereads its source. With a board task selected, attach the issue or import it as a subtask; new tasks use the chosen project. If the issue changes after reading, stop attachment/import and review it again.

To post status, enable **Post selected task status as Linear comments**. Select a board task and an issue, expand **Post selected task status to Linear**, and choose **Post status comment**. A blocked task reports its blocked reason, or the number of unfinished prerequisites, on its own line. Goals and artifact/evidence bodies are not sent. Board text is escaped so it cannot add links, mentions, or formatting.

To change state, enable **Change Linear issue state from the board**. Select a board task and an issue, expand **Change Linear issue state**, pick a state, and choose **Change state in Linear**. The picker suggests a state from the board status: Backlog → backlog, Todo → unstarted, In Progress/In Review → started, Done → completed, Canceled → canceled.

Each click uses a new request ID, which is safe for both writes. Posting the same task revision again finds the existing comment instead of creating another. After a failed state change, the screen reads the issue again and keeps the error visible, so the next attempt starts from the issue's current state; a change that already reached Linear shows as the current state. Connection changes invalidate old requests and delayed responses.

## CLI workflow

Replace example IDs with actual results.

```sh
workboard plugin run linear teams.list --json
workboard plugin run linear issues.search --params '{"query":"login timeout","assigned_to_me":true}' --json
workboard plugin run linear issues.search --params '{"team_id":"TEAM_UUID","include_closed":true,"cursor":"NEXT_CURSOR"}' --json
workboard plugin run linear issues.read --params '{"issue_id":"ENG-123"}' --json
workboard plugin run linear issues.import --request-id linear-import-1 --params '{"issue_id":"ENG-123","project_id":"PROJECT_ID","parent_id":"PARENT_TASK_ID"}' --json
workboard plugin run linear issues.attach --task TASK_ID --request-id linear-attach-1 --params '{"issue_id":"ENG-123","expected_revision":3}' --json
```

Pass the read `version` as `expected_version` to detect source changes; the app does so automatically. If omitted in the CLI, the issue reread at execution is used. Supplied `workspace` guards against using an issue read from another workspace. Calls read one page and never collect all issues automatically.

Enable the write permissions before comments or state changes. Use the current task revision. The host replaces supplied task bodies with service-read data. `issues.read` returns `team_states` with the state IDs for `issues.update_state`; `teams.list` returns team IDs for search filters and reports `has_more` beyond 100 teams.

```sh
workboard plugin enable linear --config '{"comments_enabled":true,"state_changes_enabled":true}'
workboard plugin run linear issues.comment --task TASK_ID --request-id linear-status-1 --params '{"issue_id":"ENG-123","expected_revision":3,"confirmed_by_user":true}' --json
workboard plugin run linear issues.update_state --task TASK_ID --request-id linear-state-1 --params '{"issue_id":"ENG-123","state_id":"STATE_UUID","expected_version":"VERSION_FROM_READ","expected_revision":3,"confirmed_by_user":true}' --json
```

A comment result includes `posted`, `reused`, the comment ID and URL, the issue, task ID, and revision. It does not change the task. A state change requires `expected_version` from a read. Its result includes the updated issue and `changed`; a real change also attaches the updated issue to the task as evidence. Moving an issue to its current state changes nothing.

## Retries and disconnection

The shared journal preserves successful import/attach/comment/state results. Identical retries return them; changed content with the same ID returns `REQUEST_ID_CONFLICT`. A new import ID creates a separate task.

Lost responses or interrupted writes can leave uncertain results. Identical retries return `PLUGIN_RESULT_UNCERTAIN` rather than repeating the external write. **Inspect the issue in Linear before trying again.** Never build an automatic new-ID retry loop.

Each status comment uses an ID derived from the workspace, issue, task, and task revision. When a new request ID repeats the same comment, the provider finds the existing comment and returns `reused: true` instead of posting again. To post again, the task must change first. A state change after an uncertain result returns `CONFLICT` if the earlier change was applied, because the issue no longer matches the read version.

Linear rate limits return `INTEGRATION_RATE_LIMITED`, with a wait time when Linear reports one, without immediate retry. Search is limited by Linear to 30 requests per minute. See [Linear rate limiting](https://linear.app/developers/rate-limiting).

```sh
workboard plugin run linear disconnect
workboard plugin disable linear
workboard plugin remove linear
```

`disconnect` deletes only the local Keychain item, not the key in Linear. Revoke it in Linear's security settings if needed. Disable/remove does not run providers; disconnect first to delete Keychain data. Disabled/removed plugins perform no key reads, calls, comments, or state changes. Tasks, subtasks, and source links are preserved.

## Verification limits

`test_linear_plugin.py` mocks HTTP/Keychain. `test_linear_host.py` connects the actual Rust CLI/provider/service/database and replaces only HTTP/Keychain. They cover authentication and workspace checks, failures and rate limits, source conflicts, subtasks, comment deduplication, state changes, retries, uncertain writes, and data preservation.

An unauthenticated request to the real API confirmed the error shape for a rejected key (HTTP 401, `AUTHENTICATION_ERROR`). Actual workspace authentication, Keychain, search/read, comments, and state changes remain separate checks. Mock success and app builds do not establish real-account verification.
