# Acceptance audit

Numbers follow [product requirements](product-requirements.md). Implementation and execution evidence were reviewed together. **Partial** does not mean complete. See [verification](verification.md) for counts and commands. Evidence below predates the English-only migration unless explicitly noted there.

## Core product

| Criterion | Result | Evidence and remaining scope |
| --- | --- | --- |
| MVP 1: CLI task visible in app | Verified | XCUITest `testCLITaskAppearsAndFollowsCLIStatusChanges` observes a CLI-created card in the actual app; actual-service BoardStore checks also pass. |
| MVP 2: one winner for concurrent claims | Verified | `actual_socket_claim_race_persistence_and_single_writer_lock` in `crates/workboard-service/tests/socket.rs` and concurrent CLI checks. |
| MVP 3: CLI changes reach app/widget | Verified | Native cards reflect CLI start/review. On a second Mac, the user observed a personal-team-signed Xcode desktop widget reflect CLI start/review/completion/deadline changes with the app stopped. |
| MVP 4: closed-window use and restart | Verified | XCUITest closes the actual window, creates a CLI task, stops/restarts app/service, and observes the same task. LaunchAgent/database restart checks also pass. |
| MVP 5: resume from artifacts/next action | Verified | E2E/core interruption, resume, and run/task-completion separation. Historical run corrections do not overwrite current next actions. |
| MVP 6: attachments/search/backup/export | Verified | Actual CLI/database and relative-path checks from another CLI directory. XCUITest creates SQLite backups/Markdown through real menus/save dialogs and attaches a URL. The restore picker/confirmation was not automated. |
| MVP 7: no Python/amem in core flow | Verified | Core E2E runs with an empty PATH. The bundle excludes Python/providers. A second Mac without amem/plugins verified CLI/service/app/widget without Python execution. |
| MVP 8: no Obsidian | Verified | No core/package dependency; empty-PATH E2E and actual desktop widget work without Obsidian. |
| MVP 9: subtasks and counts | Verified | Native creation, assignment, status, URL attachments, 0/1→1/1 counts, preserved To do parent, drag review/completion, and outcome recording. Actual DB reparent/detach checks also pass. |
| MVP 10: plugin-free distribution | Verified | Empty installed plugin list, core/ZIP separation, and complete plugin-free flow including widget. |
| MVP 11: persistent dates/time zones | Verified | Core storage/restore/migration and Swift actual-service editing/DST/all-day checks. |
| MVP 12: themes and import/export | Verified | Native dark/accent selection persists after relaunch; real theme save/open dialogs. Separate preferences preserve user settings. |

## Shared plugins

| Criterion | Result | Evidence and remaining scope |
| --- | --- | --- |
| Plugin 1: lifecycle | Verified | Actual CLI lifecycle and ZIP extraction→installation→disabled-default checks. |
| Plugin 2: no execution while absent/disabled | Verified | Execution markers, disabled defaults, and configuration/list calls that start neither provider nor service. |
| Plugin 3: error/incompatibility isolation | Partial | Actual process failures, timeout/output limits, and SIGINT/SIGTERM preserve the core. The actual widget host under these failures remains separate. |
| Plugin 4: preserve data on removal | Verified | Registry/packages are separate from task data; actual CLI removal regressions preserve tasks. |
| Plugin 5: cost and dependency separation | Partial | Bundle/ZIP inspection, CLI timing, and service RSS measured. Controlled GUI startup/idle-memory comparison remains. |

## Google Workspace

| Criterion | Result | Evidence and remaining scope |
| --- | --- | --- |
| Workspace 1: selected-service connection | Partial | Loopback OAuth/PKCE/state/scopes tested, plus disposable real Keychain write/read/delete. Actual Google consent/token exchange unverified. |
| Workspace 2: event/task/subtask import | Partial | Actual host/provider/core with mocked Google HTTP; real account results pending. |
| Workspace 3: creation/deduplication | Partial | Deterministic IDs, 409 checks, one external execution per request; actual Calendar writes pending. |
| Workspace 4: versions/conflicts/direction | Partial | ETag/If-Match/412, stale local revisions, schedule-only updates; real-account two-sided changes pending. |
| Workspace 5: all-day/time-zone behavior | Partial | Mock responses and actual board storage/editing verified; actual Calendar rendering pending. |
| Workspace 6: mail search/attach/import | Partial | Mock MIME, source links, task creation pass; actual Gmail pending. |
| Workspace 7: disconnect/remove/preserve | Partial | Per-service guards and host lifecycle checked; actual Google token disconnection pending. |

## agent-memory

| Criterion | Result | Evidence and remaining scope |
| --- | --- | --- |
| amem 1: configured CLI search/evidence | Verified | One real search/read/attachment; scope/provenance regressions use a fake executable. `verify` and replacement attachment checked against the installed engine in a disposable home. |
| amem 2: explicit selected capture | Partial | Consent, kind, private inbox, deduplication, and uncertain outcomes checked. One scoped capture verified with the installed engine in a disposable home; capture into the user's inbox and its review flow not run. |
| amem 3: no disabled execution/search | Verified | Host pre-execution guards, markers, and absent-plugin distribution checks. |
| amem 4: failures isolated from core | Partial | CLI/service missing/error/timeout cases checked; actual widget under those failures pending. |
| amem 5: preserve links after disconnect | Verified | Keep external sources external, retaining path/location/hash in task data; removal does not change the database. |

## Native verification and defects found

On the evening of October 15, 2026, all seven XCUITests passed on a second Mac with full Xcode 27 using `macos/Tests/run-ui-tests.sh`. Tests use temporary data/socket/preferences and avoid the user board and shared widget snapshot. The test build uses ad-hoc signing without App Group entitlements. These tests alone do not prove desktop widget behavior.

| Defect | Impact | Fix |
| --- | --- | --- |
| Widget failed Swift 6 concurrency checking | Xcode team-signed widget build blocked; Swift 5-mode Command Line Tools checks missed it. | Mark static widget configuration functions `@MainActor`. |
| Subtask row ignored clicks in blank space | Only text/arrow clicks opened the subtask. | Make the entire row a hit target. |
| Detail add buttons shared the label Add | Assistive tools could not distinguish subtasks from artifacts. | Use section-specific accessible labels such as Add subtask and Add artifacts and links. |
| Login service shared snapshot write denied | CLI changes failed to reach the widget; app data protection denied access without a prompt. | Resolve the shared container through its API before writing. |
| Widget did not reload with app stopped | Changes appeared after interaction or five minutes. | Service invokes the app's headless `--reload-widgets` mode. |
| Widget time omitted AM/PM | 7:43 PM appeared as 07:43. | Follow system time format; show dates for activity outside today. |
| Old widget process survived updates | Previous executable kept rendering. | Installer terminates the prior widget extension. |
| Command Line Tools widget cancelled in gallery | Team signing alone did not make it addable. | Use the full Xcode path in `scripts/build-xcode.sh`; the exact underlying cause was not isolated. |

## Repository and distribution

At the user's request, the incomplete project was first stored in the private [snuff12/agent-workboard](https://github.com/snuff12/agent-workboard) repository. It remains private. Source/document storage does not establish complete product acceptance.

Machine-specific absolute links were removed. Operational databases, logs, generated results, app bundles, OAuth clients, and signing material are ignored by Git. Regressions cover revision/run identity, paths, process termination, response size, connection caches, and configuration restoration.

Google accounts and notarized external distribution remain unverified. Desktop widget proof is limited to a personal-team-signed build on the second Mac, not arbitrary Macs/distribution signatures. Signed external distribution and notarization are separate from source hosting.
