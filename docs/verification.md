# Implementation and verification record

This record distinguishes automated checks, offscreen rendering, native app interactions, actual desktop widgets, and real external accounts. Historical counts below describe their respective builds, not interchangeable proof of every later change.

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

## Remaining checks

| Area | Current evidence | Next verification |
| --- | --- | --- |
| Desktop widget | Personal-team Xcode build works on the second Mac; Command Line Tools builds were purged even with team signing. | Staleness after 15-minute service stop, login startup, accent changes, other Macs/distribution signatures. |
| Google accounts | No Desktop OAuth client provided; mocked APIs/local callback only. | Actual consent/refresh, Calendar create/update/import, optional Gmail. |
| Native app | Seven baseline XCUITests on the second Mac. | New planning/plugin screens and shortcuts, menu bar, restore picker/confirmation; widget links were manually verified but not automated. |
| Slack accounts | Mocked provider/host and Swift checks. | Actual token/workspace permissions, search/read/sending, Keychain. |
| Linear accounts | Mocked provider/host and Swift model checks; invalid-key error shape from the real API. | Actual API key/workspace permissions, search/read, comments, state changes, Keychain. |
| Orca agents | Isolated actual runtime and harmless terminal launch. | Actual agent authentication/model calls and native launch controls. |
| External distribution | Local ad-hoc installation/DMG; personal-team widget proof. No Developer ID on the second Mac. | Developer ID/hardened runtime/notarization and target-Mac installation. |

Signing/container evidence is in [Mac builds](macos-build.md). No privacy/ACL bypass was used. [Acceptance audit](completion-audit.md) maps criteria to evidence. Do not mark the whole product complete before required checks are satisfied. Binary distribution/signing/notarization remain separate from source hosting.
