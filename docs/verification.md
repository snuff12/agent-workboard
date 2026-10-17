# Implementation and verification record

This record distinguishes automated checks, offscreen rendering, native app interactions, actual desktop widgets, and real external accounts. Historical counts below describe their respective builds, not interchangeable proof of every later change.

## Review fixes after the October 16 merges

A review of the merged Orca card links, Linear, GitHub, and trash changes found six issues, fixed together. Each was reproduced before the fix where it could be: another agent's permanent deletion of a trashed task, `codex execpolicy check` allowing `task update --status canceled`, and, in a temporary keychain, `security -i` failing on `O'Brien` and running a second command from a label with a newline.

| Fix | Check |
| --- | --- |
| `trash delete`, `trash empty`, and `project delete --with-tasks` apply the live-task ownership rule to trashed tasks, which keep their assignee. | Rust: another agent gets `CLAIM_CONFLICT` for each; the holder and the user without an agent ID still delete. |
| `task cancel` is its own command, and Codex asks before it. With an agent ID, `task update --status` refuses `done` and `canceled`. | Python: rule decisions with `codex execpolicy check`; refusals, cancel, reopen, and the user's unchanged update path through the CLI. |
| Slack, Linear, and Google Workspace accept only Keychain account labels `[A-Za-z0-9._@-]{1,80}`, in the plugin before any Keychain command and in the app's settings. GitHub already did. | Python: eight unsafe labels never reach `security`; safe labels do. Swift: the settings refuse unsafe labels for all three plugins. |
| Linear and GitHub status comments use the board's status names, including Backlog and Canceled. | Python: GitHub layout and labels, Linear comment body. |
| Linear's suggested state maps Backlog and Canceled to Linear's `backlog` and `canceled` state types. | Swift: suggestions with and without those state types. |
| The package check verifies the plugin count and the disabled default of every installed package. | `scripts/verify-plugin-packages.sh` with six fresh archives. |

Rust 82, Python 295, the Swift app runner, format, clippy, and the English-only check passed. No real Slack, Linear, Google, or GitHub account and no user Keychain item was used.

A second, independent review found that the label check also blocked reading and disconnecting connections made earlier with other labels, which `security -i` had stored (a temporary keychain stored `two words`, `café`, and a 90-character label). The plugins now check the label only when storing a key and before a connection starts; reading and removal pass the label as its own argument. The app checks a label only when it changes. Python covers unsafe labels never stored or connected, saved labels read and disconnected without `security -i`, and safe labels stored; the Swift runner covers saving other settings with a saved label and refusing a changed one. The same review's claim that `plutil -extract result.plugins raw` cannot count an array was checked and is wrong: it prints the array's length, and a five-entry list fails the six-plugin check.

## Linear workflow states, card deletion, and the trash

On October 16, 2026, the board adopted Linear's default workflow (Backlog, Todo, In Progress, In Review, Done, Canceled), and deleting a card now moves it to a Trash with restore, permanent deletion, and Empty Trash. Database version 6 rebuilds the tasks table to widen its status constraint and add the trash columns; the wire and widget formats remain version 1.

| Check | Result |
| --- | --- |
| Rust | 81 passed (core 65, CLI 12, service 4). Tests cover version 5 boards and backups upgrading with tasks, runs, artifacts, dependencies, search, and foreign keys intact; Backlog staying out of ready lists; Canceled interrupting runs, refusing claim/start, and releasing dependents; and the trash: hidden from every live read and the widget, deletion groups restored together, subtasks waiting for a trashed parent, permanent deletion including earlier trashed subtasks, Empty Trash, retries, backup/restore, export, and project deletion. |
| Real-board migration | A read-only copy of this Mac's version 5 board (13 tasks, 6 runs, 20 artifacts) upgraded to version 6 with identical task ID/status/revision/title rows, clean integrity and foreign-key checks, and working search. A task moved to the trash and restored on that copy kept its rows. The copy's widget path setting was removed first, the copy was deleted afterward, and the real board remains version 5 until the installed service is updated. |
| Python | 153 passed, including CLI `trash list/restore/delete/empty`, project deletion with trashed tasks, Inbox links kept until permanent deletion, Codex rules that prompt for trash changes, and the agent protocol. |
| Swift runners | App, workflow, and planner runners passed against the actual service. A new check covers Backlog column drafts, cancel and reopen, refusal of a stale delete, Undo after deletion, restore, permanent deletion counts, and Empty Trash. |
| Widget | Compilation, entitlements, and the snapshot probe passed; due-today rows include Backlog deadlines, and Canceled work is never overdue. |
| Native UI | XCUITest drove the app on this Mac with an isolated board. Seven of eight tests passed. The Backlog/Cancel/Delete/Trash test covered a Backlog card from the CLI, the Backlog column's add button, cancel from the card menu, a canceled confirmation that kept the task, moving a parent with its subtask to Trash, Restore, Delete Permanently, and Empty Trash. The CLI status, drag/complete, subtask, window-close/relaunch, backup/Markdown, and task-link tests also passed. The subtask test needed its stale `Add artifacts and links` label fixed to `Add Artifacts and links`, and now waits for the details to show the started subtask before clicking a section button that the reload moves. The theme test fails at opening Settings with ⌘, both here and on the unmodified base commit, so that failure predates this work. A run while the Mac was in active use failed at launch for every test because macOS kept the test app in the background; the passing run was on an idle Mac. |
| Previews | Offscreen light/dark renders with real disposable data show the new columns, the canceled subtask icon, progress counts that exclude canceled work, and the Trash screen. |

## Plugin readiness audit

The October 15, 2026 follow-up checked all four current plugin packages with an isolated board. Actual amem search/read/evidence attachment and Orca worktree browsing/import/attachment passed. Google Workspace and Slack passed mocked provider/host checks and real missing-credential isolation checks; authenticated account operations remain unverified. The audit also reproduced and fixed loss of the calendar time zone when importing date-only events. See the [plugin readiness report](plugin-readiness.md) for exact coverage and remaining checks.

## English-only migration

Project documentation, UI, CLI help/errors, service diagnostics, plugin descriptions/messages, comments, examples, and fixtures were converted to English. App/widget development regions and owned date/weekday display use English while retaining actual time zones. User task data remains unrestricted; Unicode search and byte-boundary coverage are preserved with English/Latin-text and currency fixtures.

The migration passed Rust 71, Python 132, and installer 8 checks: **211 automated tests**, plus the actual-source Swift, Workflow, and Planner runners, WidgetKit compilation/snapshots, format, and clippy. Default English date/weekday assertions passed. A complete debug app bundle passed nested code signatures and plist checks. All four separate plugin archives installed disabled and left external providers/accounts untouched. Python AST comparison found no non-text behavior changes. Local documentation links and whitespace checks passed.

`python3 scripts/check-english.py` passed across 112 project text files. It also rejected a temporary new file containing a non-Latin letter, then passed again after that probe was removed. The contributor policy requires English project materials and commit messages. The check excludes ignored operational data and does not restrict the language of user tasks.

Disposable-service light/dark board, weekly planner, Inbox, Quick capture, settings, and editor renders were generated; representative images were inspected for English text and layout. These remain offscreen NSHostingView renders, not new native interaction or WidgetKit-host evidence. This migration did not install the app, modify user data, authenticate external accounts, or repeat the second Mac's native tests.

The requested history reset uses one parentless English initial commit and removes legacy remote branches/tags. A recovery Git bundle preserves original refs outside the source checkout. Existing clones must preserve local edits and move to the new main history; do not merge or repush legacy branches. Force-pushing changes reachable repository history, not independent clones or GitHub's internal cached objects.

## Integrated planning build

Planning was integrated with task/project deletion, Slack, and Orca in a separate worktree using disposable databases. User data and the installed app were not changed.

Integration review reproduced foreign-key failures when deleting tasks with new dependency/checklist/review/Inbox links. The fix cleans links in the same transaction and preserves their history. Surviving dependents and detached Inbox links receive new revisions to reject stale editors. Inbox source/note/processed state remain intact; reconversion does not recreate deleted work. Regression tests cover tree/project deletion, retry/restart, cross-project dependencies, restore, and revision watermarks.

Rust 71 checks (core 58, CLI 9, service 4), Python 132, format/clippy, Swift builds/runners, WidgetKit compile/snapshot checks, and four plugin ZIP installations/default-disabled checks passed. Orca arrived during integration, so Rust/Python and affected Swift/package checks were rerun. This does not establish real Google/Slack accounts or native interaction with the new screens.

## Planning extensions 1–6

Dependencies, templates, review checklists, Quick capture/Inbox, saved views, and weekly planning were implemented in an isolated worktree. Database version is 5; wire/widget format remains version 1.

| Feature | Verified scope |
| --- | --- |
| Dependencies | Reject self-reference/cycles, independent hierarchy, ready queries, all start/completion guards, retries, stale revisions through actual CLI/service/Swift Store. |
| Templates | Built-in/custom definitions, recursive atomic creation, individual checklists, identical retries, depth/count limits, delete/restart, selected-template revision conflicts. |
| Reviews | Required items and evidence editing, completion guards, all three decisions/reasons/run history, stale edit rejection. |
| Quick capture | Actual title-only UI parameters save to Inbox; source/note preservation, parent conversion, deduplication, dismissal/restart. Physical shortcut/panel interaction was not verified on this Mac. |
| Saved views | Typed/empty filters, unassigned, ready/blocked/stale conditions, layouts, FTS parity, revision conflicts, connection-generation and ABA guards. |
| Weekly planner | Actual-service overlap preview, self/completed exclusion, touching boundaries, 23/25-hour DST days, repeated-hour geometry/drop targets, all-day/time-zone preservation, calendar-level Google zone fallback. Historical invalid schedules remain unchanged and are returned with warnings. |

The feature-only stage passed Rust 66 (core 53/CLI 9/service 4), Python 81, installer 8: 155 automated tests. Existing Swift and new Workflow/Planner runners, WidgetKit compile/snapshot, Swift build, format, and clippy also passed. Backup/restore/JSON/Markdown and revision non-reuse cover the new tables.

Light/dark board, weekly planner, Inbox, and Quick capture previews render real disposable-service data:

```sh
cargo build --workspace
cargo test --workspace
python3 -m unittest discover -s tests -v
WORKBOARD_BIN="$PWD/target/debug/workboard" macos/Tests/run.sh
WORKBOARD_BIN="$PWD/target/debug/workboard" macos/Tests/run-workflows.sh
WORKBOARD_BIN="$PWD/target/debug/workboard" macos/Tests/run-planner.sh
python3 scripts/render-workflows.py
```

Previews are under `macos/.build/previews/`. They do not prove native clicks/drags. Selecting the installed app through this Mac's computer-control tool failed with `-10005: timeoutReached`, and full Xcode is unavailable here. New native shortcuts/clicks/drags and Google account checks remain separate. The second-Mac evidence below predates the planning extensions.

## Orca verification

On October 15, 2026, worktree/terminal browsing, task/subtask imports, attachments, and agent launches initially passed Rust 50, Python 87 including 15 Orca checks, actual-service Swift, format/clippy, and three ZIP installation/default checks. A debug bundle including the widget passed plist/nested signatures. It was not installed in the user's Applications directory.

With the actual running Orca runtime and an isolated board, three worktrees were listed, the current worktree imported, and `/usr/bin/true` launched in an Orca terminal using a board run ID. Identical retries reused the result and a single terminal; the task remained `in_progress` and its terminal attachment retained the run ID. Only that test terminal was closed and the isolated service stopped. User tasks/plugins were not modified. Actual Codex/Claude authentication/model calls and native Orca buttons were not tested.

Review then reproduced host interruption after successful terminal creation but before attachment. Saved attachment requests and per-run plugin-scoped keys now reuse service receipts. Tests cover concurrent recovery, historical links after task edits/new runs, key separation between plugins, conflicting payloads, and malformed keys. That stage passed Rust 50/Python 91 including 17 Orca checks, Swift, format/clippy, builds, and ZIP/source parity with no provider Python in the core.

Merging deletion/diagnostics/Slack added prevalidation of all operation permissions and keys so a malformed later operation cannot partially apply earlier ones. That integration passed Rust 53/Python 122, actual-service Swift, format/clippy, and four ZIP checks. See [Orca](orca-integration.md).

## Baseline evidence

On October 15, 2026, the Apple Silicon development build included the core app/CLI/service, subtasks, personalization, and plugins. Later that evening a second Mac with full Xcode 27 verified native app interaction and a personal-team-signed desktop widget. Neither run established real Google accounts or notarized external distribution.

| Area | Evidence and limits |
| --- | --- |
| Rust | Earlier 48-check stage covered concurrent claims, monotonic restore revisions, old-run guards, retries, hierarchy, dates/zones, migrations, sockets, journals over 64 MiB, and newline boundaries. |
| Integration/plugins | Earlier Python 72-check stage covered actual CLI/service/provider processes, relative paths, fragmented requests, responses over 8 MiB, retries, config reads, and SIGINT/SIGTERM cleanup. |
| Workspace host | Nine of those checks ran the actual provider externally with only HTTP/tokens mocked: latest task context, import, schedule-only pull, source conflicts, preserved error codes. |
| SwiftUI | Actual-service hierarchy/reparent/detach/counts, DST/all-day edits, equal-sequence connections, delayed responses, clone guards, restart recovery, Workspace config reload, cross-process themes, JSON round trips, timestamp conversion. |
| Images | NSHostingView light/dark board/settings/editors and small/medium/large widgets. These do not prove WidgetKit-host execution. |
| Native app | Seven XCUITests on the second Mac checked actual cards/CLI updates, drag completion/outcomes, hierarchy/assignment/status/URL attachments, closed-window use, app/service restart, theme relaunch, real save/open dialogs, backup/Markdown, and task links. Used disposable data/preferences and ad-hoc signing. |
| Full Xcode | Xcode 27 built successfully after fixing Swift 6 widget concurrency. Personal-team automatic signing through `build-xcode.sh` also succeeded without a provisioning profile. |
| Actual desktop widget | User observed gallery registration, medium-widget placement, CLI start/review/complete/create while app stopped, daily summary, excluded undated tasks, collapsing, and task links. Logs confirmed ToggleWidgetSectionIntent and accepted refresh requests. |
| WidgetKit | macOS 14 AppIntent/static compilation, extension linking, JSON/filter/order/link/staleness/plist checks. |
| Installer | Eight actual app/service/DB/socket takeover/locking/recovery tests; launchctl/LaunchServices simulated. |
| Actual installs | Updated `~/Applications/Agent Workboard.app`, `~/.local/bin/workboard`, and user LaunchAgent after backing up eight schema-3 tasks and checking integrity. Doctor reported schema 4/WAL/healthy; app/CLI/service hashes matched release. No plugins installed. The second Mac repeated installation/hash/doctor checks and task links opened the installed app. These schema values are historical. |
| Bundle/DMG | Nested ad-hoc signatures/plists and disk image checksum verified; not notarized distribution. |
| Actual amem | One isolated research search/read/attachment preserved location/hash. No source mutation, sync, or actual capture. On October 16, 2026, the installed amem engine with a disposable home and synthetic documents verified attachment fields, `verify` before and after a source edit and resync, replacement attachment, and one scoped inbox capture with retry deduplication. The user's amem data was not used. |
| Workspace Keychain | Disposable account/fake token real save/read/delete only; no real Google tokens/consent/refresh. |
| Plugin distribution | Initial two archives contained only manifest/executable, reproduced checksums, installed disabled, and started neither external providers nor the core service. Later stages expanded to four archives. |

Review fixes for restore, run identity, paths, process termination, response sizes, connection generations, and preferences were covered by regressions. The earlier 48 Rust/72 Python/8 installer total was 128. The second Mac later passed Rust 53/Python 74/installer 8, Swift/WidgetKit/format/clippy, plus seven XCUITests. Fixes included Xcode concurrency, subtask hit areas, accessible add labels, shared snapshot access, app-stopped reload, widget time format, and surviving old widget processes. See [acceptance audit](completion-audit.md).

Explicit capture consent, decision/procedure restriction, private inbox, retry deduplication, and uncertainty were tested with fake amem. Scoped capture and retry deduplication were also checked against the installed amem engine in a disposable home, not the user's memory storage. No test plugin was installed in the user's default board.

## Slack verification

Added search/source/thread reading, task/subtask attachment/import, selected status sends, and dedicated settings/use screens on October 15, 2026 without accessing a real account or installing in the user's board.

| Check | Result |
| --- | --- |
| Provider | 23 checks in `test_slack_plugin.py`: explicit flags, User Token/workspace, no token leakage, exact string timestamps/threads, source conflicts, pagination, scopes/rates, send content, and diagnostic preservation. HTTP/Keychain mocked. |
| Host | Five actual CLI/provider/service/DB checks: subtasks, retries, removal preservation, latest context, forged-body replacement, revisions, and uncertain-send protection. Only HTTP/Keychain mocked. |
| Regressions | At that stage, Python 100/Rust 50 passed; Slack contributed 28 Python checks. |
| Swift | Build and actual CLI checks for config/Boolean flags/timestamps/source versions/links, send-ID reuse, lost-response protection, ABA connection changes, and delayed responses. |
| ZIPs | Three packages at that stage contained only manifest/executable, installed disabled, and started no provider/service. |

Actual workspace permissions/search/read/sending and Slack Keychain items remain unverified. Swift build/request checks are not native interaction proof. See [Slack](slack.md).

## Linear verification

Added issue search/reading, task/subtask attachment/import, selected status comments, selected issue state changes, and dedicated settings/use screens on October 16, 2026 without accessing a real account or installing in the user's board.

| Check | Result |
| --- | --- |
| Provider | 32 checks in `test_linear_plugin.py`: explicit flags, personal API key/workspace, no key leakage, Keychain values without names, fixed GraphQL documents with variables, search filters/cursors, identifier lookups with full-text fallback, link verification, source conflicts, priority/due-date imports, error/rate-limit mapping, escaped comment content with blocking, comment deduplication, and state-change guards. HTTP/Keychain mocked. |
| Host | Six actual CLI/provider/service/DB checks: subtasks, retries, removal preservation, source edits, latest context, forged-body replacement, revisions, uncertain comments recovered without a second comment, no identity request before writes, and state changes recorded as evidence. Only HTTP/Keychain mocked. |
| Real API | One unauthenticated request with an invalid key confirmed the rejection shape: HTTP 401 with `AUTHENTICATION_ERROR`. No workspace data was read. |
| Regressions | Rust 74 (core 58, CLI 12, service 4) and Python 191 passed. Linear contributed 38 Python checks. |
| Swift | `swift build` and the app test runner against the actual CLI passed, including Linear configuration/Boolean flags, issue identity, source versions, links, write parameters, and state suggestions. |
| ZIPs | Five packages contained only manifest/executable, installed disabled, and started no provider/service. |

Actual workspace authentication, key permissions, search/read, comments, state changes, and Linear Keychain items remain unverified. Swift build/model checks are not native interaction proof; no Swift→CLI test drives the Linear screen. See [Linear](linear.md).

## GitHub verification

Added issue and pull request listing, scoped search, exact reads, task/subtask import and attachment, linked status, and separately enabled status comments and issue creation on October 16, 2026. The plugin was not installed in the user's board.

| Check | Result |
| --- | --- |
| Provider | 89 checks in `test_github_plugin.py` with HTTP, Keychain, and gh replaced: secret rejection, credentials, identity file, route allow-list, error mapping, renamed repositories versus moved items, scope and identity validation, exact search queries, pagination clamps, checks and reviews aggregation, import/attach requests, preview text and fence safety, write gating, pre-send versus uncertain writes, and the time limit. |
| Host | 12 actual CLI/provider/service/SQLite checks in `test_github_host.py`, with only GitHub HTTP and the gh sign-in replaced: subtask import retries, stale revisions, read-only refusal of mutations, host-read tasks, comment and issue links applied once, lost responses, revision changes during a write, disable/remove preservation, doctor, and no token under the data directory. |
| Regressions | Rust 74 and Python 254 passed, including the GitHub checks above. |
| Swift | `swift build`, the three Swift runners, and an unsigned Xcode `WorkboardApp` build passed. Runner checks cover configuration round trips, link validation, remote parsing, pending-write retention and persistence, and actual-CLI request ID reuse with a fake provider. |
| ZIPs | Five packages, including `github-0.1.0`, contained only manifest/executable, installed disabled, and started no provider or service. |

A read-only live check used the gh sign-in on this Mac (`auth: gh`) against the public `snuff12/agent-workboard` repository with a disposable board and socket. The installed package came from the built ZIP.

| Step | Result |
| --- | --- |
| Install and enable | Installed disabled; `plugin check` returned `PLUGIN_DISABLED` until enabled. |
| Check and authorize | Account `snuff12`, one accessible repository, no unmatched entries. gh-mode `authorize` recorded the login, and `identity_verified` became true. |
| List | Cursor paging across issues and pull requests, numbered pages for closed pull requests, and an empty issue-only list (the repository has no issues). |
| Search | Merged pull requests and a text search returned only repository rows with matching totals. A `repo:` qualifier was rejected before any request. |
| Read | Pull request #4 (merged, head commit, branches) by number and #5 by URL. An unconfigured repository returned `PLUGIN_SCOPE_MISMATCH`, and a missing number returned `INTEGRATION_NOT_FOUND`. |
| Status | #4 and #5 reported state, merged, no checks (`none`), and no reviews. #4 was unchanged against its read version. An unconfigured entry reported its own error. |
| Import and attach | #5 became a To do subtask without an assignee, with the plugin-written goal and a link carrying the locator and source version. An identical import request returned the same response. Attaching #4 succeeded once. A stale revision returned `PLUGIN_ERROR` with `REVISION_CONFLICT`, and a wrong source version returned `CONFLICT`. |
| Writes | `tasks.preview` rendered the comment and issue text, showed the public repository and posting login, and made no write. With writing off, `tasks.comment` and `tasks.create_issue` returned `INTEGRATION_DISABLED` with "No GitHub write was made." |
| Removal | Disabling and removing the plugin left tasks, revisions, and links unchanged, and doctor passed. The gh token appeared in no file under the disposable board. |

No GitHub comment or issue was created, and token-mode Keychain storage was not exercised with a real token. Native interaction with the GitHub screens remains unverified. See [GitHub](github.md).

## Commands

```sh
cargo build --workspace
cargo test --workspace
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
python3 scripts/check-english.py
python3 -m unittest discover -s tests -v
WORKBOARD_BIN="$PWD/target/debug/workboard" macos/Tests/run.sh
WORKBOARD_BIN="$PWD/target/debug/workboard" macos/Tests/run-workflows.sh
WORKBOARD_BIN="$PWD/target/debug/workboard" macos/Tests/run-planner.sh
macos/Tests/run-ui-tests.sh   # Full Xcode and UI automation setup required
scripts/verify-widget.sh
scripts/build-macos.sh
scripts/build-xcode.sh --team TEAMID   # Full Xcode and a development team required
python3 scripts/test-install.py
scripts/install-local.sh --start-service
scripts/create-dmg.sh
scripts/package-plugins.sh
scripts/verify-plugin-packages.sh
python3 scripts/measure-local.py
```

Standalone Swift runners compile actual sources where Command Line Tools lacks XCTest. Workspace unit tests use no Google account/Keychain. Follow [Workspace setup](google-workspace.md) when an OAuth client/account is available.

Core E2E CLI/service run with an empty PATH, covering projects/subtasks/claims/runs/evidence/resume/search/backup/restore/export without Python/amem/Obsidian execution. The Python test harness and optional fake providers are distinct from core runtime dependencies.

## Historical size and plugin costs

At 17:23, the release app's regular files totaled **9,880,769 bytes (~9.4 MiB)**. The later reviewed baseline bundle totaled **9,982,513 bytes (~9.5 MiB)**. It excluded the two integration packages then available and Python. Those installed packages/registry totaled about 35 KiB. These are historical baseline sizes, not measurements of the current expanded English build.

Fifteen board calls per state used the same isolated service and empty PATH, without invoking external capabilities. No plugin execution-data directory appeared.

| State | Median CLI round trip | Service RSS |
| --- | ---: | ---: |
| No plugins | 26.30 ms | 8,032 KiB |
| Two installed, disabled | 27.96 ms | 7,936 KiB |
| Two enabled, never invoked | 24.92 ms | 7,968 KiB |

These single-Mac development measurements ran alongside other checks. Small differences do not establish plugin performance effects. One startup-to-socket sample was 391.66 ms. Controlled GUI startup/idle memory and actual external-call cost remain unmeasured. Use `scripts/measure-local.py` to repeat.

## Service latency investigation

After roughly five idle minutes on the second Mac, two project-list calls each waited 35 seconds and ended with `Resource temporarily unavailable`; doctor immediately afterward responded normally. The service was unresponsive for at least 77 seconds and logged two late `Broken pipe` writes.

| Investigation | Result |
| --- | --- |
| Five reads after 75 seconds idle each | 0.06–0.14 seconds. |
| Three reads after mutations/widget reload and 330 seconds idle each | Under three seconds. |
| CPU load, `taskpolicy -b` versus normal service | Background policy roughly 2× slower normally, up to 4× under load; no 35-second pause reproduced. |
| System logs | No service exit/restart. syspolicyd/storage cleanup were busy but did not align exactly. Kernel background timer delay limit was 100 ms. |

The cause was not established. Two changes were made:

- Change LaunchAgent `ProcessType` from Background to Standard for user-triggered requests. Installed priority changed from 4 to 20.
- Log request arrival/lock/processing and accept-loop delays over two seconds with timestamps to `~/Library/Logs/AgentWorkboard/service-error.log`, to distinguish scheduling delays from internal blocking on recurrence.

## Agent automation verification, October 18, 2026

The first per-task development workflow is implemented. The following checks used isolated boards; no paid model or external account was used.

| Check | Evidence |
| --- | --- |
| Rust tests | `cargo test --workspace`: 94 tests passed (12 CLI, 78 core, 4 socket integration). Includes stage transitions, report/exit separation, rework limits, stale tokens, shared workspace ownership, required checklists, Trash, restore, deadlines, and executor changes while the service was stopped. |
| Rust build and static checks | `cargo build --workspace` and `cargo clippy --workspace --all-targets -- -D warnings` passed. |
| Full Python regression | `python3 -m unittest discover -s tests -q`: 303 tests passed. Includes seven automation checks with the actual service/host and harmless agent processes, disabled and malformed optional registries, nested submodule fingerprints, and existing provider/core regressions. |
| Swift | `swift build --package-path macos` and `WORKBOARD_BIN="$PWD/target/debug/workboard" macos/Tests/run-workflows.sh` passed. The actual service supplied workflow configuration, task/card metadata, revision conflicts, and disable behavior. |
| Separate plugin packages | All six ZIPs passed extraction, CLI installation, and disabled-default checks. Orca package version is 0.3.0. These checks started no optional executable or account connection. |
| Actual Orca runtime | `scripts/verify-automation-orca.py` used the installed local Orca runtime and an isolated board. Six synthetic stages ran exactly once: preflight, work, review requesting changes, rework, passing review, release preparation. All six reported and confirmed process exit; the task waited for final approval. All six test terminals were closed. Evidence: `.build/automation-live-final-20261018/evidence.json`. |
| Pixel QA | Actual isolated service data rendered in light and dark automation panels; both images were inspected. Evidence: `.build/automation-native/previews/automation-light.png` and `automation-dark.png`. These are NSHostingView render checks. |
| Native interaction limit | This Mac has Command Line Tools rather than full Xcode. Native test-window targeting returned `cgWindowNotFound`; automated button clicks were not verified. The isolated preview service and test defaults were cleaned up. |

Actual Codex/Claude authentication, sandbox permissions, model behavior, and paid calls remain unverified. The existing installed app and operational board were not updated. See [automation](automation.md) for configuration and recovery, and [Mac builds](macos-build.md) for installation requirements.

## Status rules, defaults, and installed rollout, October 18, 2026

The follow-up adds project defaults for new tasks, per-status rules, and required skills, prompts, instructions, and agent selection per rule or development stage. These checks supersede the automation-specific limits above; they do not verify every native widget, account, or distribution path.

| Check | Evidence |
| --- | --- |
| Rust | 101 tests passed (12 CLI, 85 core, 4 socket). Includes defaults inheritance, stale editors across restore including removal/recreation, true status edges, pending rules after confirmed exit, frozen stage settings, single-stage column preservation, and final changes requesting bounded rework. Build and clippy with warnings denied passed. |
| Full Python regression | 305 tests passed after rebuilding the embedded agent protocol. Includes nine service/host automation checks, project-default prompt delivery, sandbox handoff without a service socket, and all existing provider/core regressions. |
| Sandbox reporting | Orca supplies a private handoff directory. The agent's report command writes a mode-0600 file without a token or board connection. The executor submits it after process exit, then settles the exit separately. Python regression includes reporting with an absent service socket. |
| Actual Codex | Four real signed-in stages passed: preflight, work, independent review, release. All applied the required local smoke skill and included prompt/instruction markers, reported, and exited. State remained `awaiting_approval`. Evidence and per-stage logs: `.build/automation-real-codex-handoff/`. This was a small read-only transport task, not a substantive implementation benchmark. |
| Actual Claude | After the user renewed the expired CLI OAuth session, a real preflight status rule passed using Claude's auto permission mode. Skill, prompt, and instruction markers were recorded and the process exited. State became `waiting`. Evidence/log: `.build/automation-real-claude-auto/`. |
| Real Orca rework | The latest handoff executor completed six synthetic stages with a changes-requested/rework/review loop through the actual runtime. Evidence: `.build/automation-orca-handoff/evidence.json`. No model was called in this separate check. |
| Native app | A CUA-driven status-menu selection moved a card to In Progress and started one real Orca terminal with a synthetic agent. The app displayed the completed result after refresh. CUA also opened project defaults, edited required skills, prompt, and instructions, and saved values verified from the service. Evidence: `.build/automation-status-ui/evidence.json`. CUA drag attempts did not change the card, so drag interaction remains unverified. |
| Swift | Production app build and actual Store/service regression passed, including rule editor data, defaults inheritance, and status moves. Native form rendering was visually inspected. |
| Installation | A production bundle was built, signed locally, installed in the user's Applications directory, and registered with the user service. Orca was updated separately to 0.4.0 with its existing configuration preserved. Both agent kits were updated. The service returned healthy after migration from database version 5 to 7. All existing fields of the nine operational tasks matched the backup. The Agent Workboard project now applies enabled defaults to new cards: In Progress starts development; In Review runs a single independent review. Both use Codex in the current hippocamp worktree. Existing cards retain their own configuration. Rollout evidence: `.build/automation-rollout/evidence.json`. Backup: `~/orca/backups/agent-workboard/automation-status-rules-20261018/`. |

The first live agent attempts exposed sandbox socket restrictions and an expired Claude login. The final executor uses token-free file handoff instead of weakening the Codex sandbox; Claude uses its normal auto permission classifier. Failed runs and logs are kept separately from successful evidence. All successful smoke-test terminals were closed. Core source, account integrations, and the actual desktop widget require their existing independent checks.

## Per-card creation mode verification, October 18, 2026

New task and subtask forms now offer Project default, Use automation, and Manual work. Manual selection suppresses automation inheritance for the whole template-created task family; ordinary status changes remain manual. Explicit automation can use a saved configuration when project inheritance is off. Missing configuration and invalid modes reject the entire creation transaction.

- `cargo test --workspace`: 103 tests passed (12 CLI, 87 core, 4 socket); build and clippy with warnings denied passed.
- `python3 -m unittest discover -s tests -q`: 306 tests passed, including the actual CLI manual-creation override with an enabled project and zero executor launches.
- The actual Swift Store/service regression passed manual card creation and movement, manual template children, explicit automation, and default configuration reads.
- Six light/dark creation previews used an isolated real service. The manual light and automatic dark forms were inspected for readable controls and help text. Evidence: `.build/automation-creation-choice/previews/`. These are render checks, not native click evidence.
- The release bundle was installed, its signed CLI/service matched the staging bundle, and the installed service returned healthy. Evidence: `.build/automation-creation-choice/evidence.json`.

Current-stage badges and Stage history are unchanged. Automatic review projects a card into In Review; other development stages project it into In Progress, and final approval waits in In Review.

## Remaining checks

| Area | Current evidence | Next verification |
| --- | --- | --- |
| Desktop widget | Personal-team Xcode build works on the second Mac; Command Line Tools builds were purged even with team signing. | Staleness after 15-minute service stop, login startup, accent changes, other Macs/distribution signatures. |
| Google accounts | No Desktop OAuth client provided; mocked APIs/local callback only. | Actual consent/refresh, Calendar create/update/import, optional Gmail. |
| Native app | Seven baseline XCUITests on the second Mac. | New planning/plugin screens and shortcuts, menu bar, restore picker/confirmation; widget links were manually verified but not automated. |
| Slack accounts | Mocked provider/host and Swift checks. | Actual token/workspace permissions, search/read/sending, Keychain. |
| Linear accounts | Mocked provider/host and Swift model checks; invalid-key error shape from the real API. | Actual API key/workspace permissions, search/read, comments, state changes, Keychain. |
| GitHub writes | Mocked provider/host and Swift checks; live gh-mode reads on a public repository. | Actual status comment and issue creation, token-mode Keychain, fine-grained token permissions, native GitHub screens. |
| Orca agents | Real Codex four-stage smoke, real Claude single-stage smoke, real Orca synthetic rework loop, native status-menu trigger. | Substantive coding tasks, native drag interaction, and longer-running operational recovery. |
| External distribution | Local ad-hoc installation/DMG; personal-team widget proof. No Developer ID on the second Mac. | Developer ID/hardened runtime/notarization and target-Mac installation. |

Signing/container evidence is in [Mac builds](macos-build.md). No privacy/ACL bypass was used. [Acceptance audit](completion-audit.md) maps criteria to evidence. Do not mark the whole product complete before required checks are satisfied. Binary distribution/signing/notarization remain separate from source hosting.

## Reusable process presets (October 18)

Implemented the board-wide preset library, three read-only built-ins, custom ordered stages, conditional rework, task creation selection, project/card configuration, and agent selection with a recorded reason. Presets are stored through the service and frozen per configured task. The optional Orca executor is version 0.5.0.

| Evidence | Result |
| --- | --- |
| Rust 109 tests | Library CRUD and stale revisions, immutable built-ins, frozen task definitions after edits/deletion, restore revision watermarks, small process/rework limits, large process planning/verification/source preservation, authorized agent selection/report/exit, assignment/revision/active-process guards, existing workflows and socket checks passed. |
| Python 308 tests | Full suite passed. Actual service/CLI/host/Orca-plugin fixture checks exercised agent selection, the chosen small process and rework, CLI library operations, task overrides, and manual template children. Six separately packaged plugins passed extraction, installation, and disabled-default checks. |
| Swift | App build, existing model/service runner, and Workflow Store regression passed. The latter saved an editable preset, selected it during task creation, preserved skills/prompts, ignored a hidden selection for manual work, and retained the task copy after library deletion. |
| Actual native app | In a disposable release-bundle app, created a preset, moved a stage down and back up, saved skill/prompt/instructions, and selected that preset while creating a card. The real service retained the settings and had zero attempts after creation. Test app/service and temporary preferences were cleaned. Evidence: `.build/preset-native/evidence.json` and its SQLite snapshot. |
| Actual Codex through Orca | A real `select` process chose `small` with a concrete rationale, followed by real implementation and independent review processes. All three reports passed through the private file handoff, all processes confirmed exit, the workflow waited for human approval, and all three terminals closed. This smoke task deliberately required no source edits. Evidence: `.build/preset-real-codex/evidence.json`. |
| Visual review | Inspected the real SwiftUI light library, dark preset editor, and light creation form from an isolated service. Six light/dark renders are in `.build/preset-previews/`. This is offscreen pixel QA, separate from the native interaction above. |
| Installation | Updated the installed app/CLI/service and separate Orca 0.5.0 plugin; preserved its existing configuration. Updated both agent kits. The Agent Workboard project's future tasks now delegate preset selection (`auto`); existing status rules and executor settings remain. All nine existing task records were identical before/after. The installed bundle hashes match the verified release, doctor is healthy, and the installed app visibly opens the preset library. Evidence: `.build/preset-rollout/evidence.json`. Backup: `~/orca/backups/agent-workboard/process-presets-20261018/`. |

Format, clippy, diff whitespace, and English-only checks passed. The new automatic preset selection was verified with actual Codex. Existing real Claude stage evidence remains separate; a new real Claude preset-selection run was not performed. No widget gallery, Google account, deployment, merge, or task completion was inferred from these checks.

## Review before merging automation

The full automation change was reviewed before publication. These defects were reproduced before their fixes:

| Finding | Final behavior and regression evidence |
| --- | --- |
| CLI preset selection omitted the session agent ID. | Automation controls include identity and the service checks assignment. Task/template creation records the selecting agent. A real CLI/service test rejects another assignee and records the holder's selections. |
| Restore could discard an unresolved worker's resource lease and rewind workflow revisions. | Restore refuses unresolved processes, including disabled or trashed workflows. Workflow revision watermarks advance beyond live and restored values. Regression tests preserve an active callback after a refused restore and reject repeated revision reuse. Restored tokens are rotated for trashed workflows too. |
| Deleting an allowed candidate could make an ordinary task edit fail. | Task edits fence and reset using the frozen process. A new selection resolves current candidates only when explicitly resumed. A failing status-rule start rolls back its run and stage writes. Both cases have core regressions. |
| The stage process inherited executor callback credentials, and the agent policy allowed exit callbacks. | Orca removes the callback token from the agent environment. Offline reports require no token; submit/settle commands require approval in the Codex policy. Every synthetic stage asserts that it received no token, and the offline report test uses no credential. |
| Single-stage cards could display a different stage from their saved process. | Single-stage actions display their actual stage; a Swift model regression covers a review action on an implementation-first preset. |
| CLI mutation retries reread newer revisions and conflicted with their own successful request. | Revision-pinned core requests persist exact parameters before sending and recover the original response or request after interruption. CLI/service tests cover controls, preset save/delete, defaults, payload conflicts, and identity. External plugin pending calls remain non-replayable; a separate journal regression covers safe core recovery. |

No additional unresolved merge-blocking finding remained in the reviewed change. Final verification passed Rust 115 tests, Python 310 tests, format, clippy with warnings denied, the Swift model/service and Workflow Store runners, a signed local production app/widget build, and six separate plugin package checks. The final token-free agent environment also passed a fresh actual Codex selection/implementation/review run; all three processes exited and terminals closed. Evidence is in `.build/automation-review/real-codex/evidence.json`. The reviewed build and plugin were installed with nine task records and the Orca configuration preserved; `.build/automation-review/rollout.json` records their hashes and health. Publication details are recorded with the pull request. Earlier real-agent, native interaction, widget, and external-account evidence retains its stated scope.
