# CLI contract

The command is `workboard`. The commands and JSON below describe the implemented initial contract. Agents manage tasks through the same service validation as the app. The app uses this CLI's `rpc` path and never writes the database directly.

## Basic commands

```text
workboard project list --json
workboard project add --name <name> --directory <path> --json
workboard task add --project <project-id> --title <title> --next-action <action> --json
workboard task add --project <project-id> --parent <task-id> --title <title> --json
workboard task add --project <project-id> --title <title> --status backlog --json
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
workboard task cancel <task-id> --expected-revision <revision> --json
workboard agent context --json
workboard agent brief
workboard events --after <sequence> --json
workboard task attach <task-id> --source <path-or-url> --json
workboard task delete <task-id> --expected-revision <revision> --json
workboard task delete <task-id> --with-subtasks --json
workboard trash list --json
workboard trash restore <task-id> --json
workboard trash delete <task-id> --json
workboard trash empty --json
workboard project delete <project-id> --with-tasks --agent <agent-id> --json
workboard doctor --json
```

Commands that act for an agent (claim, start, review, complete, pause, heartbeat, release, update, attach, deletion, and trash actions) add `agent_id` from `WORKBOARD_AGENT`, or from `CODEX_THREAD_ID` as `codex:<thread>`, when `--agent` is omitted. `inbox capture` uses the same ID as its source. `rpc` never adds it. `agent context` summarizes board work for the current directory, `agent brief` prints the agent protocol, and `agent hook --client claude|codex` is the session-start hook. See [Agent integration](agent-integration.md).

## Statuses

Task statuses follow Linear's default workflow: `backlog`, `todo`, `in_progress`, `review`, `done`, and `canceled`. The app shows them as Backlog, Todo, In Progress, In Review, Done, and Canceled.

- New tasks start in `todo`. `task add`, `template apply`, and `inbox promote` accept `--status backlog` or `--status todo`; other initial statuses return `INVALID_PARAMS`. Runs, reviews, and outcomes move tasks forward.
- Backlog tasks are never `ready`, so `task ready` and `agent context` skip them until someone moves them to Todo. Starting a Backlog task directly is allowed.
- `task update --status canceled`, or `task cancel`, ends a running run as interrupted and keeps the assignee. With an agent ID from `WORKBOARD_AGENT` or `CODEX_THREAD_ID`, `task update --status` refuses `done` and `canceled` with `INVALID_PARAMS`; agents use `task review`, `task complete`, or `task cancel`, which the Codex rules ask the user to approve. A canceled task rejects `claim` and `start` with `INVALID_STATE` until it is updated back to `backlog` or `todo`. Canceling needs no completion summary.
- Done and Canceled close a task. Closed prerequisites leave `blocked_by`, schedule previews ignore closed tasks, and `task show` reports `canceled_child_count` beside `child_count` and `completed_child_count`.
- Database version 6 adds Backlog and Canceled. The service upgrades an older board when it opens it and restores older backups through a private upgraded copy. Earlier service versions cannot open a version 6 board.

Subtasks created with `--parent` use ordinary task commands for state, assignment, and artifacts. Parent details include child lists and completed counts. Missing mutation inputs return structured errors an agent can act on.

## Trash

`task delete` moves a task to the trash. Without `--with-subtasks`, a task with subtasks returns `HAS_SUBTASKS`; with it, the subtasks move too and form one trash entry. `--agent` rejects any included task held by another agent with `CLAIM_CONFLICT`, and `--expected-revision` protects against concurrent changes. Running runs end as interrupted. The app deletes through the same request after a confirmation, sending the revision it showed and `with_subtasks` when it listed subtasks.

A trashed task keeps its runs, artifacts, checklist, review history, dependency links, and Inbox link. Every live read skips it: lists, search, `task show` (`NOT_FOUND` saying the task is in the trash), parent details, readiness, schedule previews, and the widget. A trashed prerequisite no longer blocks its dependents. Trashed tasks cannot be changed, used as parents, or linked. Dependents of trashed or restored tasks receive new revisions, so stale editors are rejected.

- `trash list` returns one item per deletion with the deleted task, the subtasks deleted with it, `deleted_at`, `deleted_by`, and whether it can be restored. `board.snapshot` and JSON/Markdown exports include the same items; the widget snapshot does not.
- `trash restore <task-id>` restores that deletion with its subtasks. A subtask deleted with its parent is restored through the parent (`INVALID_STATE`). A task whose parent is still in the trash waits for the parent (`INVALID_STATE`).
- `trash delete <task-id>` deletes that entry permanently, including subtasks that were moved to the trash earlier on their own.
- `trash empty` deletes everything in the trash permanently.
- A trashed task keeps its assignee. With an agent ID, `trash delete`, `trash empty`, and `project delete --with-tasks` return `CLAIM_CONFLICT` when they include a trashed or live task held by another agent, as `task delete` does for live tasks. Without an agent ID, the user can delete anything.

Permanent deletion removes tasks, runs, artifact links, and checklist/review/dependency references, and keeps them in the `task.purged` or `trash.emptied` event. Surviving dependents lose the removed prerequisite and receive new revisions. Inbox source/note/processed state are preserved; only the deleted task link is cleared. Reconversion does not recreate deleted work automatically. Revision tombstones never regress across restore/retry. Nothing leaves the trash automatically.

`project delete` stays permanent. Without `--with-tasks`, live or trashed tasks produce `HAS_TASKS`; with it, both are deleted permanently. Projects have no revision and reject `--expected-revision`.

Plugins are restricted to approved task reads/mutations. Deletion, the trash, restore, and widget configuration are refused even if declared in a manifest. Validate all response operations before applying any.

## Dependencies and reviews

Opt-in development workflows use the `automation` command group and `automation.*` requests. See [agent automation](automation.md) for implemented commands, revision checks, scoped stage tokens, and separate report/exit receipts. Automatic stage review results do not invoke `task.review.decide`; that request still represents final task review.

IDs of prerequisites that are neither Done nor Canceled appear in `blocked_by`. A task is `ready` when its status is Todo and it has neither open prerequisites nor an explicit blocking reason. Reject dependency cycles. Check prerequisites for start/completion, including `task update --status`.

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

Tasks in Review accept approval, requested changes, or rejection. Approval checks requirements/dependencies and completes the task. Requested changes return it to Todo and record the summary as next action. Rejection returns it to Todo with a blocking reason; clear that reason with `task update --blocked-reason ''` once resolved. `task show` includes `review_decisions`.

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

Use identical `project`/`domain` parameters for scoped searches and reads. `--params` accepts a JSON object. Workspace, Slack, Linear, Orca, and GitHub share lifecycle rules; see their guides for capabilities.

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

### Project automation defaults and status rules

`automation.defaults.get` reads a project's defaults. `automation.defaults.set` requires `project_id`, `configuration`, `enabled`, and `expected_defaults_revision` (zero for a new definition). New tasks and subtasks inherit enabled defaults without launching. Snapshots and JSON export include `automation_defaults`. Per-card overrides preserve historical attempts.

Configurations accept `rules` (one per status, up to six) and `stage_settings`. Rules use `id`, `status`, `action` (`development` or `stage`), `stage`, `agent`, `skills`, `prompt`, and `instructions`. Development rules require In Progress. Single-stage rules preserve the column and return to `waiting`. Internal workflow projections do not recursively trigger rules. Each attempt freezes its settings. See [automation](automation.md).

`automation report --report-file PATH` or `WORKBOARD_AUTOMATION_REPORT_FILE` writes a new mode-0600 handoff file without connecting to the service or storing its token. Executors use `automation submit-report PATH` with the authorized attempt environment before settling the actual process exit. The service still checks tokens, executor generation, revisions, source versions, and stage deadlines.

Task creation and template application accept `automation_mode`: `inherit` (default), `automatic`, or `manual`. Manual creation skips defaults for every task created by that request. Explicit automatic creation uses the saved project configuration even when inheritance is disabled; without saved configuration the service rejects and rolls back the entire creation. Invalid modes also roll back. The CLI exposes this as `task add --automation` and `template apply --automation`.

## Process preset requests

The service exposes `automation.presets.list`, `automation.presets.get` (`preset_id`), `automation.presets.save` (`preset`, `expected_preset_revision`), and `automation.presets.delete` (`preset_id`, `expected_preset_revision`). Built-ins cannot be edited. Library mutations are transactional and retry-safe. Preset revisions never repeat after deletion/recreation or restore.

`automation.preset.apply` accepts `task_id`, `expected_revision`, `expected_automation_revision`, `preset_id`, and a nonempty `reason`. Agent callers may select only for unassigned or self-assigned inactive tasks. Selection saves a frozen definition and does not start execution. A process already running or awaiting approval cannot be replaced.

Task creation and template application accept `process_preset` (a saved ID or `auto`) and optional `preset_reason`. An explicit selection implies automatic mode and requires project executor defaults. Combining it with manual mode is invalid. Configurations accept optional `process_preset` and `allowed_presets`; omitted selections preserve legacy workflows.

In a `select` stage, `automation.report` requires an authorized `preset_id` and nonempty `selection_reason` for `pass`. A blocked report need not select. The executor handoff preserves these fields. Process exit remains a separate receipt. The task workflow's public `process` includes its frozen selected definition, candidate definitions, cursor, selector, and reason. Snapshot and JSON export include the `process_presets` library. See [automation](automation.md) for stage semantics and CLI commands.

Automation control requests against an existing workflow require both `expected_revision` and `expected_automation_revision`. The CLI includes its session agent ID for task controls, preset selection, and task/template creation; the service validates assignment for controls. Backup restore rejects unresolved agent processes before replacing any automation state. Workflow revisions use a live monotonic watermark, including across repeated restores.
