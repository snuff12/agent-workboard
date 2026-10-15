# Orca plugin

Browse local Orca worktrees/terminals, import a selected worktree as a task/subtask, attach it to existing work, or launch Codex/Claude in an Orca terminal. Only the board service changes task data.

The optional plugin requires Orca app/CLI and Python 3. The core contains neither provider code nor Python. Installation leaves it disabled. Launches require a current board build supporting host-provided `task_runs` and `board_connection`.

## Installation and app workflow

After installing, choose **Connect** in plugin settings. The connection step detects the CLI in standard installation locations or the saved custom path and reads Orca's registered repositories. A unique match for the selected board project's directory is selected automatically; otherwise choose a project by name. No executable path or `id:` selector is required in the normal flow. The user-requested connection can open Orca if needed. Advanced settings retain custom paths and selectors.

```sh
scripts/package-plugins.sh
unzip dist/AgentWorkboard-plugin-orca-0.2.0.zip -d /tmp/workboard-orca
workboard plugin install /tmp/workboard-orca/orca-0.2.0
workboard plugin enable orca --executable /path/to/orca \
  --config '{"repo":"path:/path/to/registered-repo"}'
workboard plugin check orca --json
```

Replace the executable with an absolute Orca CLI path. `repo` accepts registered `id:…`, `path:…`, or `name:…` selectors. No automatic executable discovery. Only local repositories/worktrees on this Mac are supported; remote environments and Orca orchestration Run task synchronization are not.

In **Settings → Plugins → Install**, select the extracted directory. **Configure and enable** accepts executable/repository. Choose **Use** and a worktree:

| Feature | Behavior |
| --- | --- |
| Browse | Show worktrees, branches, and workspace status; separately load run terminals and connection state. |
| Import | Create a task in the selected project, or a subtask of the selected board task. |
| Attach | Save worktree path, source ID/instance, branch, commit, and verification time. |
| Launch | Run the selected task with Codex/Claude and optional extra instructions. Agent installation/authentication follows that CLI's settings. |
| Output | Explicit **Read output** reads up to 200 lines. Lists omit terminal previews and draft input. |

Imports start in To do. Orca `done` and terminal exit do not complete board work. Do not overwrite existing goals, assignees, or criteria from external status. Observations are point-in-time, not automatic sync.

## CLI workflow

Replace uppercase IDs with actual values. `WORKTREE_ID` is the complete `id` from `worktrees.list`.

```sh
workboard plugin run orca worktrees.list --json
workboard plugin run orca worktrees.get --params '{"worktree_id":"WORKTREE_ID"}' --json
workboard plugin run orca worktrees.import --request-id IMPORT_REQUEST_ID \
  --params '{"worktree_id":"WORKTREE_ID","project_id":"BOARD_PROJECT_ID","parent_id":"PARENT_TASK_ID"}' --json
workboard plugin run orca worktrees.attach --task TASK_ID \
  --params '{"worktree_id":"WORKTREE_ID","expected_revision":REVISION}' --json
workboard plugin run orca terminals.list --params '{"worktree_id":"WORKTREE_ID"}' --json
workboard plugin run orca terminals.read \
  --params '{"worktree_id":"WORKTREE_ID","terminal":"TERMINAL_HANDLE","limit":80,"cursor":0}' --json
```

Include `parent_id` only for subtasks. Replace `REVISION` with the current integer. Identical import request IDs/parameters reuse tasks/attachments; new request IDs create separate tasks.

Create a board run before launching. Pass its returned `run_id`:

```sh
workboard rpc task.start --request-id START_REQUEST_ID \
  --params '{"task_id":"TASK_ID","agent_id":"orca:codex","expected_revision":REVISION}' --json
workboard plugin run orca agents.start --task TASK_ID --request-id LAUNCH_REQUEST_ID \
  --params '{"worktree_id":"WORKTREE_ID","run_id":"RUN_ID","agent":"codex","prompt":"Additional instructions"}' --json
```

For Claude, use assignee `orca:claude` and agent `claude`. Reject new terminals for another assignee or an obsolete run. A successful previous launch may recover only its existing result/attachment. The app uses the same two stages and reuses the current run when appropriate.

```mermaid
sequenceDiagram
    participant B as Board app/CLI
    participant S as Board service
    participant P as Orca plugin
    participant O as Orca CLI
    B->>S: task.start with claim/revision checks
    S-->>B: Run ID
    B->>P: agents.start with host-read current task/runs
    P->>P: Persist per-run pending record
    P->>O: Create terminal in selected worktree
    O-->>P: Terminal handle
    P-->>B: Terminal data and attachment request
    B->>S: Attach worktree/terminal to run
```

The agent receives goals, criteria, next action, and board CLI/data/socket paths. Quote the prompt as one shell argument. Instruct it to reread current work, record verification and next actions, and request review instead of completing merely because its response ended.

Default agent commands are `codex` and `claude`. Override paths/options through `agent_commands`; array elements are literal arguments and the prompt is appended last. Shell pipelines/command strings are not accepted.

```json
{"executable":"/path/to/orca","repo":"id:ORCA_REPO_ID","agent_commands":{"codex":["/path/to/codex"],"claude":["/path/to/claude"]}}
```

## Failures and retries

The same board run ID never creates another terminal, even with a new top-level request ID. To change worktree/instructions, inspect the old run and create a new one. Do not delete plugin `launches` records to retry.

Success records retain the board attachment request. If the host stops after terminal creation, a new request for the same run recovers that attachment. Per-run `idempotency_key` makes concurrent recovery apply it only once. Even if task contents changed or another run started, recover only the historical link without overwriting current goals/run state.

Persist pending before terminal creation. Timeout/interruption with an uncertain outcome blocks relaunch. Inspect `Workboard RUN_ID` in Orca. Failed external creation still leaves the board run as an attempt record. Use `task.pause` to record blocking reasons/next actions if needed. Check existing agents before starting another run.

Disabling/removing stops later calls and preserves tasks/subtasks/runs/links. Already launched Orca terminals/agents may continue; inspect and stop them in Orca. Integration errors do not fail core doctor.

## Verification

`python3 tests/test_orca_plugin.py` combines fake Orca executables with a real board service to verify scope, provenance, subtasks, request retries, claims/revisions, concurrent launch deduplication, uncertain outcomes, timeouts, and preservation after disable/remove.

An installed Orca runtime was also checked with an isolated board: repository/worktree/terminal reads, import, a `/usr/bin/true` test terminal, retry, and run attachment. The created terminal was closed. This does not verify actual Codex/Claude authentication, paid model calls, or native app buttons.
