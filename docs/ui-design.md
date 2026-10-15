# macOS UI and personalization

The SwiftUI app selects projects in a sidebar and moves cards through `To do → In progress → Review → Done`. A right-side detail view shows the goal, completion criteria, assignee, next action, subtasks, artifacts, runs, and events. Do not present sample tasks as real user work. All authored interface text is English; user task content is unrestricted.

## Visual principles

Task titles and next actions take priority. Separate columns/cards with thin borders and restrained backgrounds. Status colors remain consistent: gray for To do, blue for In progress, orange for Review, green for Done. Apply the user's accent to selection and primary actions. Pair colors with names and icons.

Show ordinary tasks as cards and subtasks in details. Offer a setting to include subtasks on the board, and include them in search. Show completion counts on parent cards/details. Complete the parent separately after verifying its outcome. Moving a task to Done requires an outcome summary.

## Personalization

| Preference | Values |
| --- | --- |
| Appearance | System, Light, Dark |
| Accent | Seven preset colors and a custom color |
| Card density | Comfortable, Compact |
| Text size | 85%–130% in 5% steps |
| Board visibility | Sidebar, Done column, subtasks |
| Theme files | Import/export JSON, restore defaults |

Store themes and connection paths in UserDefaults, separately from task data. Theme JSON contains only version, name, appearance, accent, density, text size, and visibility. Exclude paths, accounts, and task bodies. Validate version, color, and size limits before importing.

## App and service

The app uses the common contract through `workboard rpc`; it never reads/writes SQLite directly. Resolve the CLI from explicit settings, `WORKBOARD_BIN`, the app bundle, then adjacent development builds. Do not discover optional plugin executables along this path.

The active app checks the board every second and replaces task lists when the sequence changes. Edits send the captured revision; conflicts trigger a fresh read. `workboard://task/<ID>` opens task details. App Group-capable distributions pass `WORKBOARD_WIDGET_SNAPSHOT` to the CLI.

Compare event sequences only within the same connection. If executable/data/socket identity changes, invalidate lists, selection, and sequence and read the new board. Configuration changes immediately close editors and completion dialogs without waiting for outstanding responses. Do not save until the new board loads. Reject delayed lists/details from old connections. Recheck connection identity and generation after awaiting details/widget requests, including A→B→A changes.

## Keyboard and data

| Action | Shortcut/location |
| --- | --- |
| New task | ⌘N |
| New project | ⇧⌘N |
| Refresh | ⌘R |
| Quick capture | Control+Shift+Space by default; configurable |
| Search | Toolbar search field |
| Backup/export | Board menu |
| Restore | Settings → Connection; choose a file and confirm |

Link files/URLs at their original locations without requiring plugins. The menu bar shows up to three in-progress and three review tasks and opens the selected task on the board.

## Dates and calendars

Tasks have optional due dates, scheduled start/end, and IANA time zones. The editor handles date-only or timed deadlines, timed meetings, and all-day schedules. Date-only values retain their calendar date across display zones. Show the last all-day date inclusively to the user while sending an exclusive end date through the Calendar contract.

Keep the original time zone when editing. Title-only edits resend the original date strings. Date pickers and all-day calculations use the selected zone. A zone change must not automatically shift all-day dates or meeting instants. Offer original, device, and common IANA zones. Timed cards display device-local times; details also identify the original schedule zone.

Show deadline/meeting times on cards and overdue unfinished work in red. Today's schedule lists tasks overlapping today in start order, including subtasks.

Google Workspace is optional. Enable Calendar and optionally Gmail in settings; connect an account and choose calendars/ranges in its screen. Import selected events or add selected task deadlines/meetings. Choose direction separately for existing links. Calendar→task updates only deadline, schedule, and time zone, preserving title, goal, assignee, and status. Confirm changes and check ETags/task revisions. Editing a task does not automatically update external events.

Plugin requests use a client separate from the core board client, so slow OAuth/external calls do not block the core request queue. Show errors in the affected plugin screen.

Opening plugin settings first reads saved data through read-only `plugin.config`. Disable saving until loaded. Restore Calendar/Gmail Boolean flags, account labels, and paths. Preserve unknown/unshown keys on save. Reading disabled plugin configuration neither runs providers nor accesses accounts.

## Planning and review

Dependencies and checklists appear in task details. Capture revisions when editors open and reject stale changes. Templates create recursive task/checklist trees without copying execution state. Saved views combine filters with board/list/week layouts. The weekly planner previews overlaps and preserves all-day, time-zone, DST, and repeated-hour placement rules.

Quick capture accepts a title with optional source/note while the app runs with its main window closed. Do not automatically read dropped files or URLs. Inbox conversion preserves source/note and rejects stale connection context.

## Verification and limits

`swift build --package-path macos` targets macOS 14. Command Line Tools lacks XCTest, so `WORKBOARD_BIN="$PWD/target/debug/workboard" macos/Tests/run.sh` compiles the actual models, transport, and store and connects them to an isolated Rust service. It checks themes, JSON arguments, errors, hierarchy, deadlines/all-day meetings, today views, runs, attachments, completion, and resume.

Additional regressions verify cross-process preferences, real JSON import/export, reparent/detach behavior, counts, preserved parent state, same-sequence DB changes, delayed responses, A→B→A switches, and cloned DBs with identical IDs/revisions. Temporary CLI wrappers delay actual snapshot/detail requests to verify immediate invalidation. Actual service restarts and injected failure responses verify recovery. Actual plugin install/config RPCs verify unknown-key preservation and no provider execution.

`macos/Tests/run-workflows.sh` and `run-planner.sh` add real-store planning/review/filter checks and DST/layout/quick-capture regressions.

`macos/Tests/render-previews.sh` renders real service data through the same BoardView/SettingsView in NSHostingView. `scripts/render-workflows.py` adds disposable planning fixtures. Inspect light/dark PNGs and source JSON under `macos/.build/previews/`. Isolated preferences prevent user-data changes. Pixel/layout evidence does not replace native click/drag or WidgetKit-process validation. Baseline native interactions were verified separately on a second Mac; new screens and real Google behavior retain separate checks.
