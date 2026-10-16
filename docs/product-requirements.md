# Product requirements

People and CLI-based agents share the same task state. The user sees current and upcoming work on the Mac desktop and reviews goals, evidence, and outcomes in a desktop kanban app. Core workflows and subtasks work without integration plugins.

## User requirements

| Requirement | Behavior |
| --- | --- |
| CLI integration | List, create, edit, assign, start, request review, and complete tasks. Return JSON results. |
| Mac widget | Show current work, upcoming work, and tasks needing user review. |
| Desktop kanban | Open task cards in a standalone app, move them between columns, and filter by project. |
| Subtasks | Create subtasks with individual status, assignee, completion criteria, and artifacts. Show the list and progress in the parent task. |
| Deadlines and schedules | Store due dates, scheduled start/end, and time zones without a calendar plugin. Distinguish date-only deadlines from timed meetings. |
| Simple UI and personalization | Prioritize information needed to assess work. Save themes, accent colors, text size, density, and display settings. Import and export themes. |
| Standalone operation | Use the CLI, board, widget, search, backup, and export without plugins, Python, agent-memory, or a Google account. |
| Plugin extension | Install integrations separately. Exclude integration code and dedicated dependencies from the core distribution. Keep newly installed plugins disabled. |
| agent-memory | Search documents and memories and attach verified sources when installed and enabled. Failure, disconnection, and removal must not block core features. |
| Google Workspace | Center on Calendar: create deadlines or scheduled work and import selected meetings as kanban tasks. Search, attach, or import Gmail messages. Enable services independently. |
| Slack | Search and read messages, attach them, or import tasks/subtasks. Separately enable sending to post selected task status to a specified channel. |
| Linear | Search and read issues, attach them, or import tasks/subtasks. Separately enable status comments on a selected issue and changes to its workflow state. No automatic sync. |
| Orca | Browse local worktrees and terminals, import tasks/subtasks, and launch agents from the board. Preserve assignees, run IDs, retries, and terminal links. Terminal exit does not complete a task. |
| GitHub | Browse and search issues and pull requests in connected repositories, import tasks/subtasks or attach items, and check linked status without changing task status. Separately enable writing to comment task status or create an issue after a preview. |
| Obsidian | No runtime dependency. Reading Markdown through Obsidian is optional. |
| Project language | Documentation, source comments, UI, CLI help, diagnostics, examples, fixtures, and commits use English. User task data may use any language. |

First run asks only for information needed to create projects and tasks. Plugin installation and account setup are not prerequisites for using the app. Show plugin status and errors in plugin settings or the feature that uses the plugin.

## Core versus plugins

| Distribution | Features |
| --- | --- |
| Core | Tasks and subtasks, deadlines and schedules, runs, CLI, personalized kanban app, widget, task search, file/URL attachments, backups, exports |
| Separate plugins | agent-memory, Google Workspace, Slack, Linear, Orca, GitHub, and future external services |

The core contains only plugin state management and the shared request boundary. Uninstalled or disabled plugins must not load or execute code, discover executables, access accounts, synchronize, or run background work.

Disabling or removing a plugin preserves tasks, subtasks, artifacts, evidence paths, and last verified metadata. Reading external content again requires an installed, enabled plugin. Measure installation size, startup time, and idle memory to check that optional integrations do not impose costs on core users. Establish numeric budgets from the first prototype.

## Main screens

Default columns are `To do → In progress → Review → Done`. Show blocking reasons with next actions. A separate Blocked column remains a UI decision.

Task details show the goal, completion criteria, assignee, current run, next action, artifacts, evidence, and change history. Show agent implementation details only when they help the user assess work.

Parent tasks show subtasks and completed/total counts. Subtask details link back to the parent. Cards show relevant deadlines and meetings, with a separate view for today's schedule. Persist system/light/dark appearance, accent, text size, density, and visibility settings; support theme JSON import/export.

The widget defaults to a daily summary:

- **In progress:** active tasks and assignees.
- **Due today:** unfinished tasks due today or overdue, plus tasks whose schedule overlaps today. Show due time or Overdue. Exclude undated tasks.
- **Completed today:** tasks completed today and their completion times.
- **Needs review:** show only when review requests exist.

Tap a section heading to collapse or expand it. Persist the choice on this Mac. Widget settings also offer single views for current work, upcoming tasks, and review requests.

Selecting a widget task opens its app details. Show the last refresh time and a stale indicator. Read detailed conversations and source evidence in the app.

## Parent tasks and subtasks

Break a large goal into subtasks. For example, `Build Agent Workboard` can contain `Implement storage`, `Implement CLI`, `Implement Mac kanban app`, and `Implement widget`.

Each subtask has its own ID, status, assignee, completion criteria, runs, and artifacts. The CLI and app manage the same hierarchy. Subtask completion does not automatically complete the parent; verify the parent's own criteria and outcome. The service rejects hierarchy cycles. Deletion requires explicit options when a parent contains subtasks.

## Tasks versus runs

A task is a goal to accomplish; a run is one attempt by an agent. Multiple interrupted or resumed runs can belong to one task.

An agent finishing its response does not complete the task. Verify completion criteria and artifacts before changing task status. Preserve task state and resume summaries when a run stops.

## Data model

| Entity | Main fields |
| --- | --- |
| Project | ID, name, working directory, default search scope |
| Task | ID, optional parent ID, title, goal, completion criteria, status, priority, assignee, next action, due date, schedule start/end, time zone, revision |
| Run | ID, agent type, task ID, start/end timestamps, status, resume context |
| Artifact | Path or URL, kind, description, linked task and run |
| Evidence link | File/URL, location, verification time; optional amem provider, collection, content hash |
| Change event | Sequence, request ID, task ID, change data, actor, timestamp |

Flag expired claims for confirmation. Inactivity alone must not complete tasks or automatically reassign them.

## Core MVP acceptance criteria

1. A task created through the CLI appears in the app.
2. Two simultaneous agents cannot both claim the same task.
3. CLI status changes appear in the app and widget.
4. CLI requests work with the app window closed; tasks recover after restart.
5. Another run can resume interrupted work from artifacts and next actions.
6. Attach files/URLs and use search, backup, and export.
7. Perform these workflows without agent-memory or Python.
8. Perform them without Obsidian installed or running.
9. Create subtasks in the CLI and app with individual status, assignees, and results; show completed/total counts in the parent.
10. Perform them using a core distribution with no integration plugins installed.
11. Preserve deadlines, meeting times, and time zones across restart.
12. Persist personal themes and display settings across relaunch; import and export themes.

## Plugin acceptance criteria

1. Independently install, enable, disable, and remove only the required plugins.
2. No code loading, external calls, synchronization, or background activity for absent or disabled plugins.
3. Plugin failures and incompatibility do not interrupt tasks, service, app, or widget.
4. Disabling/removing preserves tasks, subtasks, artifacts, and existing evidence links.
5. Compare distribution size, startup, and idle memory before/after installation; confirm integration-only dependencies are absent from the core.

These criteria are separate from core MVP acceptance.

## Google Workspace acceptance criteria

1. Install separately, choose Calendar/Gmail capabilities, and connect an account. The core requires no Google account or dedicated dependencies.
2. Read selected calendars and import meetings as tasks or subtasks, preserving start/end, time zones, and source links.
3. Create deadlines or scheduled work in a selected calendar without duplicates on retry.
4. Check source versions before updates. Expose conflicts when both sides changed; let the user choose the update direction.
5. Verify date-only deadlines, timed meetings, time zone conversion, and exclusive all-day end dates.
6. Search selected mail and attach its source link or import a task.
7. Disabling/removing stops external calls and preserves existing tasks, dates, and source links.

Verify actual Calendar/Gmail authentication and API behavior with a prepared OAuth client and user account. Mocks and plugin builds do not prove real-account integration.

## agent-memory acceptance criteria

1. After installation, enabling, and path configuration, search amem evidence and verify original paths and locations.
2. Even while enabled, save only decisions explicitly requested by the user as memory candidates.
3. While disabled, do not discover/invoke executables, search memories, or synchronize.
4. Missing executables, errors, and timeouts do not disrupt task creation/editing/search/resume, app, or widget.
5. Disconnection preserves tasks, artifacts, and evidence links. External rereads require reconnection.

## Planning acceptance criteria

The requested six extensions use persistent SQLite and the existing service contract, revision checks, and retry protection. They retain core workflows without external accounts or plugins.

1. **Dependencies:** add/remove prerequisites independently of hierarchy. Reject missing tasks, self-reference, and cycles. Check incomplete prerequisites at every start/completion entry point. Expose ready tasks in the CLI and app.
2. **Templates:** provide built-in bug fix, feature development, and document research templates and user templates. Preserve goals, completion criteria, required checklists, and recursive children. Apply atomically with new IDs; retries do not duplicate tasks.
3. **Review checklists:** edit required/optional items, checked state, and evidence. Reject completion or approval while required items are unchecked. Record approve/request-changes/reject decisions, reasons, and consistent task/run state.
4. **Quick capture and Inbox:** capture a title through a global shortcut while the app runs, even with its window closed. Source URL/path and note are optional and never read automatically. Later choose project and optional parent, preserving source and note. Retries do not duplicate converted tasks.
5. **Saved views and staleness:** save/edit/delete project, status, assignee, readiness, blocking, stale-days, and search filters with board/list/week layouts. CLI and app interpret filters identically. Never complete or reassign due to inactivity.
6. **Weekly planner:** view schedules, place/move/unschedule tasks, and preview overlaps before saving. Allow explicit conflict acceptance. Preserve all-day dates, exclusive end dates, IANA zones, and DST. Explicitly read Google events through an enabled Workspace plugin and retain existing update-direction controls.

Include all new tables in backup, restore, JSON, and Markdown exports. Never reuse revisions for tasks, templates, Inbox items, or views that disappear and reappear through restore. Connection changes must prevent old editors, responses, and selections from affecting another board.

## Later scope

Cross-device synchronization, team collaboration, a built-in agent runner, automatic long-term memory extraction, and a Rust port of amem are separate from the initial implementation. Validate core workflows first.
