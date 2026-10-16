# CLI contract

The command is `workboard`. The commands and JSON below describe the implemented initial contract. Agents manage tasks through the same service validation as the app. The app uses this CLI's `rpc` path and never writes the database directly.

## Basic commands

```text
workboard project list --json
workboard project add --name <name> --directory <path> --json
workboard task add --project <project-id> --title <title> --next-action <action> --json
workboard task add --project <project-id> --parent <task-id> --title <title> --json
workboard task list --project <project-id> --status todo --json
workboard task list --parent <task-id> --json
workboard task show <task-id> --json
workboard task update <task-id> --expected-revision <revision> --next-action <action> --json
workboard task update <task-id> --expected-revision <revision> --due-at 2026-10-16 --time-zone Asia/Seoul --json
workboard task claim <task-id> --agent <agent-id> --request-id <request-id> --json
workboard task start <task-id> --run <run-id> --request-id <request-id> --json
workboard task review <task-id> --run <run-id> --summary <summary> --request-id <request-id> --json
workboard task complete <task-id> --run <run-id> --summary <summary> --request-id <request-id> --json
workboard task resume-context <task-id> --json
workboard task heartbeat <task-id> --json
workboard task pause <task-id> --run <run-id> --summary <state> --next-action <action> --json
workboard task release <task-id> --json
workboard agent context --json
workboard agent brief
workboard events --after <sequence> --json
workboard task attach <task-id> --source <path-or-url> --json
workboard task delete <task-id> --expected-revision <revision> --json
workboard task delete <task-id> --with-subtasks --json
workboard project delete <project-id> --with-tasks --agent <agent-id> --json
workboard doctor --json
```

Commands that act for an agent (claim, start, review, complete, pause, heartbeat, release, update, attach, and deletion) add `agent_id` from `WORKBOARD_AGENT`, or from `CODEX_THREAD_ID` as `codex:<thread>`, when `--agent` is omitted. `inbox capture` uses the same ID as its source. `rpc` never adds it. `agent context` summarizes board work for the current directory, `agent brief` prints the agent protocol, and `agent hook --client claude|codex` is the session-start hook. See [Agent integration](agent-integration.md).

Subtasks created with `--parent` use ordinary task commands for state, assignment, and artifacts. Parent details include child lists and completed counts. Missing mutation inputs return structured errors an agent can act on.

Deletion removes tasks, their runs, and artifact links. Without explicit inclusion flags, children produce `HAS_SUBTASKS` and project tasks produce `HAS_TASKS`. Use `--with-subtasks` or `--with-tasks`. For either deletion command, `--agent` rejects any included task held by another agent with `CLAIM_CONFLICT`. Task `--expected-revision` protects against concurrent changes. Projects have no revision and reject that option. Deletion events retain removed task/run/artifact data. Revision tombstones never regress across restore/retry.

Deletion also removes checklist/review/dependency references and retains them in history. Surviving dependents lose the removed prerequisite and receive new revisions. Inbox source/note/processed state are preserved; only the deleted task link is cleared. Reconversion does not recreate deleted work automatically.

Plugins are restricted to approved task reads/mutations. Deletion, restore, and widget configuration are refused even if declared in a manifest. Validate all response operations before applying any.

## Dependencies and reviews

Incomplete prerequisite IDs appear in `blocked_by`. A task is `ready` when its status is To do and it has neither incomplete prerequisites nor an explicit blocking reason. Reject dependency cycles. Check prerequisites for start/completion, including `task update --status`.

```sh
workboard task dependency add TASK_ID --on PREREQUISITE_ID --expected-revision 1 --request-id link-1 --json
workboard task dependency remove TASK_ID --on PREREQUISITE_ID --expected-revision 2 --json
workboard task ready --project PROJECT_ID --json
workboard task list --blocked --json
```

Checklists belong to individual tasks. Unchecked required items prevent completion. Edits require the current task `--expected-revision`. `check`/`uncheck` change checked state; `update` edits text, requirement, or evidence.

```sh
workboard task checklist add TASK_ID --text 'Verify actual execution' --expected-revision 3 --json
workboard task checklist add TASK_ID --text 'Organize references' --optional --expected-revision 4 --json
workboard task checklist check TASK_ID ITEM_ID --evidence 'Seven checks passed' --expected-revision 5 --json
workboard task checklist uncheck TASK_ID ITEM_ID --expected-revision 6 --json
workboard task checklist update TASK_ID ITEM_ID --text 'Regression check' --required true --checked false --clear-evidence --expected-revision 7 --json
workboard task checklist remove TASK_ID ITEM_ID --expected-revision 8 --json
```

Tasks in Review accept approval, requested changes, or rejection. Approval checks requirements/dependencies and completes the task. Requested changes return it to To do and record the summary as next action. Rejection returns it to To do with a blocking reason; clear that reason with `task update --blocked-reason ''` once resolved. `task show` includes `review_decisions`.

```sh
workboard task decide TASK_ID --decision approve --summary 'Completion criteria verified' --expected-revision 9 --json
workboard task decide TASK_ID --decision request-changes --summary 'Add conflict cases' --expected-revision 9 --json
workboard task decide TASK_ID --decision reject --summary 'External approval required' --expected-revision 9 --json
```

Optionally include `--run RUN_ID` and `--agent AGENT_ID`. Ordinary completion/status edits cannot bypass required checks.

## Templates

Built-in bug fix, feature development, and document research templates create tasks, recursive subtasks, and individual checklists atomically. Identical retries return the same IDs. Do not copy checked state, assignees, runs, or artifacts.

```sh
workboard template list --json
workboard template apply builtin-feature --project PROJECT_ID --title 'Search feature' --request-id feature-1 --json
workboard template save --name 'My release procedure' --file definition.json --json
workboard template save --name 'Reuse current task' --from-task TASK_ID --json
workboard template apply TEMPLATE_ID --project PROJECT_ID --parent PARENT_ID --json
workboard template delete TEMPLATE_ID --expected-revision 1 --json
```

Read `--file` relative to the CLI's working directory. The file contains the definition object itself. The service validates the whole tree and leaves no partial tasks on failure. Update an existing template with `save --id TEMPLATE_ID --expected-revision REVISION`.

```json
{
  "title": "Release feature",
  "goal": "Verify completion criteria",
  "completion_criteria": "Check after deployment",
  "priority": 1,
  "checklist": [{"text": "Final verification", "required": true}],
  "children": [{"title": "Implementation"}, {"title": "Regression check"}]
}
```

## Inbox and saved views

Inbox collects notes before choosing a project. `source` is a path/URL string; its content is not read. Conversion uses the note as task goal and attaches the source. Converted items remain `processed`; repeated conversion does not duplicate tasks. `dismiss` archives as `dismissed`.

```sh
workboard inbox capture --title 'Check this later' --source 'https://example.com/item' --note 'Reason to investigate' --request-id capture-1 --json
workboard inbox list --status pending --json
workboard inbox promote ITEM_ID --project PROJECT_ID --parent PARENT_ID --expected-revision 1 --request-id promote-1 --json
workboard inbox dismiss ITEM_ID --expected-revision 1 --json
```

Views store filters and `board`, `list`, or `week` layouts. `task list --view` applies saved filters; explicit flags override them. `--ready false` or `--blocked false` clears that view condition. `--stale-days N` selects tasks last changed more than N days ago. No extra file or plugin is needed.

```sh
workboard view save --name 'My ready tasks' --project PROJECT_ID --assignee codex --ready --layout board --json
workboard view save --name 'Stale tasks' --stale-days 7 --layout list --json
workboard view list --json
workboard task list --view VIEW_ID --status todo --json
workboard view delete VIEW_ID --expected-revision 1 --json
```

`view save --id VIEW_ID` replaces existing filters with the complete supplied set. Templates/views/Inbox items have revisions and reject stale expected values with `REVISION_CONFLICT`. New mutations accept `--request-id` and `--expected-revision`; omit expected revision for creation when no previous version exists.

## Schedule preview

Preview does not save. Exclude completed tasks and the edited task's own schedule. Date-only schedules are all-day in their IANA zone with exclusive end dates. Timed schedules use offset-bearing RFC3339 to distinguish repeated DST times.

```sh
workboard task schedule-preview TASK_ID --starts 2026-11-01T01:30:00-04:00 --ends 2026-11-01T01:30:00-05:00 --time-zone America/New_York --json
workboard task schedule-preview --starts 2026-11-01 --ends 2026-11-02 --time-zone Asia/Seoul --json
workboard task update TASK_ID --starts 2026-11-01 --ends 2026-11-02 --time-zone Asia/Seoul --expected-revision 10 --json
```

The result includes `{has_conflicts,conflicts}`, with IDs, titles, scheduled times, and zones. After reviewing, save separately as shown. Concurrent changes mean preview is neither a reservation nor automatic rescheduling.

RPC methods are `task.dependency.add/remove`, `task.checklist.add/update/remove`, `task.review.decide`, `template.list/save/delete/apply`, `inbox.list/capture/promote/dismiss`, `view.list/save/delete`, and `task.schedule.preview`. `board.snapshot` includes `templates`, `views`, and `inbox`. Backup/restore/export preserve planning data.

## Plugin commands

Core commands do not depend on plugin installation or execution.

```text
workboard plugin list --json
workboard plugin config <plugin-id> --json
workboard plugin install <plugin-package> --json
workboard plugin enable agent-memory --executable <amem-path> --json
workboard plugin disable agent-memory --json
workboard plugin run agent-memory search --task <task-id> --query <query> --collection <collection> --json
workboard plugin run agent-memory read --params '{"ref":"<search-ref>","collection":"<collection>"}' --json
workboard plugin run agent-memory attach --task <task-id> --query <query> --params '{"ref":"<search-ref>","collection":"<collection>"}' --json
workboard plugin run agent-memory verify --params '{"artifact":<artifact-from-task-get>}' --json
workboard plugin check agent-memory --json
workboard plugin remove agent-memory --json
```

The core ships without integrations. Installed plugins remain disabled. Return `PLUGIN_NOT_INSTALLED`, `PLUGIN_DISABLED`, or `PLUGIN_INCOMPATIBLE` without running the provider. Enabled external failures return `INTEGRATION_UNAVAILABLE` or a specific error for that call and preserve core service/task behavior.

Core `doctor` judges only core health. Absent/disabled/failed integrations do not fail it. Explicit `plugin check` checks enabled external connections. `plugin list` returns installation/enabled metadata without configuration. `plugin config <id>` / RPC `plugin.config {id}` returns `{id,config}`, including while disabled. Neither read starts the provider or task service.

Use identical `project`/`domain` parameters for scoped searches and reads. `--params` accepts a JSON object. Workspace, Slack, Orca, and GitHub share lifecycle rules; see their guides for capabilities.

## Shared RPC and widget paths

```sh
workboard rpc board.snapshot --params '{}' --json
workboard rpc widget.configure --params '{"snapshot_path":"/absolute/group-container/widget-snapshot.json"}' --json
workboard rpc run.finish --params '{"task_id":"TASK_ID","run_id":"RUN_ID","agent_id":"AGENT_ID","summary":"This run ended"}' --json
```

`run.finish` ends only a run. `widget.configure` persists a shared snapshot path across app/service restarts. Continue updating both default and shared snapshots. `snapshot_path:null` clears the saved shared path; environment configuration remains independent.

Review/completion requests should include the started `run_id` and task `expected_revision`. Late old-run review/completion/pause cannot change current task state. Historical summary/next-action corrections affect only that run and preserve the task's current next action.

Resolve relative backup/restore/export paths against the CLI's current directory before sending them to the service, independent of its startup directory. Restore revisions remain above every previously observed version.

## Responses and transport

```json
{
  "schema_version": 1,
  "request_id": "example-request",
  "ok": true,
  "result": {
    "task_id": "example-task",
    "revision": 2,
    "event_sequence": 17
  }
}
```

Write JSON to stdout and human diagnostics to stderr. Noninteractive calls must not wait for answers. Errors include a stable code, readable message, and retryability.

Each socket frame is one newline-terminated JSON object. Requests, including the newline, are at most 1 MiB. Aggregate responses can be larger; the CLI must not truncate them. Queries/exports consume memory proportional to data; pagination remains later optimization. External plugin output retains its separate 2 MiB limit.

Exit codes: 0 success, 1 processing failure, 2 CLI argument error. Stable JSON error codes distinguish input, state conflict, service connection, absent/disabled/incompatible plugins, and external failures. Treat external error text as data, never control commands.

Journal plugin mutation requests first. Identical completed ID/input pairs reuse results; changed input conflicts. If external execution succeeded but board application failed, retry the frozen prepared result. Return `PLUGIN_RESULT_UNCERTAIN` rather than repeating uncertain external writes.

## Mutation rules

- Identify all retries by request ID.
- Include the captured expected revision when editing user-visible state.
- A run without the required claim cannot start another assignee's task.
- Separate completion from response-turn exit; verify criteria and outcome summaries.
- Validate hierarchy and reject cycles; child completion never completes the parent automatically.
- Apply the same service validation to plugin mutations.
- Treat memory capture as an explicit request for selected content.
- Invoke executables with argument arrays instead of assembling shell commands.

## Compatibility

The Rust CLI is a service client, never an alternate direct database writer. Version the wire contract independently from database schema. Reject incompatibility before mutation.

## Plugin package contract

A package contains `plugin.json` and its executable. The manifest defines `id`, `name`, `version`, `protocol_version:1`, relative `executable`, and `methods`. `allowed_requests` restricts service requests. `read_only_methods` may not return mutations. `task_context_methods` require host-read current data: the host replaces supplied `task`, `task_runs`, and `board_connection {executable,data_dir,socket}`. Runs are oldest first, latest last. Providers cannot bypass validation with supplied task/run/connection data. See [Orca](orca-integration.md) for launch/recovery.

The host sends `{protocol_version,request_id,method,params,config}` on stdin. Return one `{ok:true,result,requests?}` or `{ok:false,error:{code,message}}` object on stdout; diagnostics go to stderr. `requests` may contain only allowed methods. Reference preceding results with JSON Pointers such as `{"$result":"/0/task_id"}`.

An operation may include `idempotency_key`: a nonblank, NUL-free string of 1–200 bytes. The host hashes plugin ID plus key into a service request ID. Different top-level requests can retry the same operation; another plugin's same key remains distinct. Reusing a key with different method/parameters conflicts. Without a key, use parent request ID plus operation index. For attachment recovery after external execution, durably retain and return the original attachment parameters and key.

The default timeout is 30 seconds; interactive OAuth may declare `timeout_seconds` up to 180. Absent/disabled code does not run. Disabling/removing terminates the active process group. Enforce output/package size and depth limits. Process isolation is for failure handling, not an OS security sandbox for arbitrary untrusted programs. Install only trusted plugins.

On SIGINT/SIGTERM, terminate the provider's process-group descendants and stop new core mutations. This does not roll back external writes; retain pending/prepared journals. SIGKILL, power loss, and children deliberately escaping the process group are outside this signal-cleanup guarantee.

The initial distribution supports local packages. A public registry, automatic updates, and OS sandboxing of third-party code are later scope.
