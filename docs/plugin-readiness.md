# Plugin readiness report

Date: October 15, 2026. Branch: `verify/plugin-readiness`, based on the English-only initial snapshot.

The four plugins work within the verified scope below. Google Workspace and Slack are not yet verified with authenticated accounts. No plugin was installed or enabled in the user's default board.

## Results by plugin

| Plugin | Actual integration checked | Automated coverage | Remaining verification |
| --- | --- | --- | --- |
| agent-memory | Installed amem: reviewed `research` search, selected source read, verified path/location/hash attachment, identical retry without duplicate evidence. | 15 provider process checks, plus shared host/runtime checks: project/domain scope, malformed provenance, failures, capture consent, and uncertain capture outcomes. | Actual capture was not run. It changes the external inbox and requires an explicit request to save a decision or procedure. |
| Orca | Running local app/CLI: repository check, three worktrees listed, selected worktree read, subtask import, attachment to an existing task, terminal metadata listing, import/attachment retries. | 17 provider/host checks: scope, current task/run claims, launch deduplication, crash recovery, uncertain outcomes, timeouts, and data preservation. | No Codex/Claude model call or new terminal was launched during this audit. Native app button interactions remain separate. |
| Google Workspace | Unconfigured account returns a connection error without breaking core doctor or task operations. | 27 provider and 10 actual Rust host/service checks: OAuth/PKCE, selected scopes, dates/zones, Calendar import/create/update/pull, source conflicts, retries, Gmail parsing/import, and board-write isolation. HTTP/token access is mocked. | A Desktop OAuth client and test account are needed for Calendar and optional Gmail. Actual consent, refresh, permissions, Calendar writes and mail reads remain unverified. |
| Slack | Unconfigured account returns `AUTHORIZATION_REQUIRED` without breaking core doctor or task operations. | 23 provider and 5 actual Rust host/service checks: User Token/workspace checks, exact messages/threads, scopes/rates, subtasks, source conflicts, status sends, retries and uncertain sends. HTTP/Keychain access is mocked. | A workspace app and User OAuth Token with the documented scopes are needed. Real search/read/channel permissions and status sending remain unverified. |

No amem capture or sync, Google authentication or Calendar write, mail send, Slack send, or external agent launch was performed. Real source text, tokens and terminal output were not retained in the audit report. The temporary board/service was removed after the check.

## Calendar defect found and fixed

An all-day event covering October 16-17 on an `America/Los_Angeles` calendar imported with `time_zone: UTC`. The event's date-only start/end omitted `timeZone`; the old import used a UTC fallback. Applying the event to an existing task could instead retain that task's unrelated zone.

The provider now uses the event's named zone when supplied, the list response's calendar zone for list entries, and a [CalendarList.get](https://developers.google.com/workspace/calendar/api/v3/reference/calendarList/get) lookup for individual events without a named zone. This requires no additional OAuth scope. Missing or invalid calendar metadata stops import/pull before any board writes. Timestamp offsets, exclusive all-day end dates, and inclusive due dates are preserved.

The new regression first failed with `UTC != America/Los_Angeles`. Provider checks now cover all-day list/detail/import/pull, timed events without an explicit zone, and missing/invalid calendar metadata. Actual Rust host/service checks verify both stored calendar zones and unchanged board data after invalid metadata.

## Package and isolation checks

All four ZIPs were rebuilt. Each contained only `plugin.json` and executable `plugin.py`, extracted with executable permission, installed into a disposable board, and remained disabled until explicitly enabled. Disabled calls returned `PLUGIN_DISABLED`.

Final regression results: Rust 71 and Python 136 tests passed, for 207 automated checks. Separate package verification, the English-only check across 113 project text files, and whitespace checks also passed.

After actual amem/Orca checks and missing-credential checks, all four packages were disabled and removed. Two test tasks and three source attachments remained identical. Core doctor and task creation still worked. These checks used separate SQLite data and a separate socket; they did not change the user's plugin configuration or tasks.

## Repeatable checks

```sh
cargo build --workspace
cargo test --workspace
python3 -m unittest discover -s tests -v
scripts/package-plugins.sh
scripts/verify-plugin-packages.sh "$PWD/target/debug/workboard"
python3 scripts/check-english.py
git diff --check
```

For account validation, follow [Google Workspace setup](google-workspace.md) and [Slack setup](slack.md) using a disposable board and selected test resources. Run external writes only when explicitly requested. CLI/provider checks do not establish native settings/use-screen behavior.

The local redacted live-run report is `.build/plugin-readiness/live-results.json` in the audit worktree. It contains only outcomes and counts, and is excluded from Git. Historical test totals elsewhere describe their respective builds.
