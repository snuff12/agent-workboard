# Agent automation

The board runs status rules for explicitly armed tasks. A rule can start a selected process preset or run one stage. The standard process is:

```text
Preflight -> Implementation -> Review -> Release preparation -> Final approval
                                 |
                          Changes requested
                                 v
                               Rework -> Review
```

Workflow stages are separate from kanban columns, tasks, and agent runs. The board service owns workflow state and stage evidence in the persistent SQLite database. An optional executor plugin starts each agent. The first executor is Orca; the core contains no Orca code, Python dependency, agent SDK, or account setup. Project defaults apply to new tasks and subtasks. Each card keeps a frozen copy and can override or disable it. Updating defaults does not change existing cards.

## Use in the app

1. Install and enable the Orca 0.5.0 plugin. Configure its executable and connected repositories as described in [Orca](orca-integration.md).
2. Set the task's goal and completion criteria. Link the worktree in the task's **Orca worktree** section.
3. In **Automation**, choose **Configure automation**. Select the worktree, implementation agent, review agent, rework limit, and stage deadline. Edit the status rules and optional development stage overrides. Each rule and stage can select an agent, required skills, a prompt, and instructions.
4. Choose **Arm automation**. Arming saves configuration without launching an agent.
5. Start the workflow, or move the task to a status that matches its rule. The service starts the selected process even with the board window closed.
6. Read stage reports and evidence in **Stage history**. Review findings trigger rework up to the configured limit. The process ends in In Review, waiting for the user's final approval.

Codex and Claude run in fresh one-shot processes. The review session is separate from the implementation session. Review and release stages must preserve the preceding source version. Release preparation produces a readiness report; it does not deploy or merge.

The CLI's own authentication, sandbox, and permission settings still apply. Configure a command suitable for unattended use. The default Codex command uses the workspace-write sandbox; Claude uses its auto permission mode, where its classifier checks actions against the request. Custom commands can retain another policy; an unavailable mode or denied action blocks the stage. See [Claude permissions](https://code.claude.com/docs/en/permissions). The handoff avoids giving the agent direct socket access for reporting. Install the updated [agent kit](agent-integration.md) when using Codex so its board reporting commands can reach the local socket. Missing credentials or a failed command block the stage without passing it.

## Choose automatic or manual work when creating a card

The task and subtask creation form has an **Execution** selector:

| Choice | Result |
| --- | --- |
| Project default | Use the project's current setting. Enabled defaults arm the new card; disabled or absent defaults create manual work. |
| Use automation | Arm the saved project configuration for this card, even when inheritance is disabled. Save project defaults first. |
| Manual work | Create the card without automation. Moving it between columns does not launch an agent. |

The choice also applies to every child created from a selected task template. Separately created subtasks have their own creation choice. Creation never starts an agent by itself. A manual card can be configured later in its Automation section. For an existing automated card, choose Disable to switch off its rules.

The CLI supports the same choices:

```sh
workboard task add --project PROJECT_ID --title 'Manual follow-up' --automation manual --json
workboard task add --project PROJECT_ID --title 'Automated change' --automation automatic --json
workboard template apply TEMPLATE_ID --project PROJECT_ID --automation manual --json
```

Cards display their current automation stage. The Automation section shows the full stage history and results. During the development workflow, review attempts project the card into In Review; preflight, implementation, rework, and release preparation project it into In Progress. Final approval waits in In Review.

## Reusable process presets

Choose **Process presets** (the list button in the board header) to create, duplicate, edit, reorder, or delete a reusable process. This library works without an executor plugin. Each preset has a description and **When should an agent choose this?** guidance, one to twenty ordered stages, and conditional rework settings. Each stage can save its own title, kind, agent, required skills, prompt, and instructions.

| Built-in preset | Ordered stages | Rework limit |
| --- | --- | --- |
| Small task (`small`) | Implementation → Review | 1 |
| Standard task (`standard`) | Preflight → Implementation → Review → Release preparation | 2 |
| Large task (`large`) | Preflight → Plan → Implementation → Verification → Review → Release preparation | 3 |

Built-ins are read-only; duplicate one to customize it. The stage kind defines its contract: implementation and rework can edit source; selection, preflight, planning, verification, review, and release inspect and report. Repeated kinds are supported with distinct stage IDs. A verification failure blocks for inspection. A review's `changes_requested` runs the preset's rework stage, then repeats stages after the nearest preceding implementation through the review. A process without an earlier implementation blocks instead. The lower of the preset and project rework limits applies. Every process, including one without release preparation, still requires human final approval.

Project defaults and each task's configuration have a **Process preset** picker. The creation form can inherit that choice, select a particular preset, or choose **Let an agent choose**. Selecting a preset for a new card implies automation and needs saved project executor defaults. **Manual work** skips the process, including when a preset was previously selected. Template children receive the same creation choice; independent child creation can use another process.

**Let an agent choose** first launches a read-only `select` stage. The agent receives the task and permitted preset definitions, chooses an ID and a concrete reason, and reports both. The service rejects IDs outside that attempt's candidates and advances only after an accepted report and confirmed exit. The configuration's `allowed_presets` optionally restricts choices; an empty list permits all saved presets. Candidates are frozen when selection starts. An explicitly selected process is frozen when configured. Editing or deleting library definitions never changes those frozen stages, skills, prompts, or instructions. New selections use the current library. Update project defaults if a deleted preset was referenced by ID.

Cards show the current stage number and title. Task details show the chosen preset, selection reason, ordered stages, and each attempt's saved settings and evidence. Status rules still apply: review stages project into In Review and the other process stages into In Progress.

Implemented CLI examples:

```sh
workboard automation preset list --json
workboard automation preset show small --json
workboard automation preset save --file /path/to/preset.json --json
workboard automation preset delete CUSTOM_PRESET_ID --json
workboard automation preset apply TASK_ID --preset small --reason 'A narrow, well-defined fix' --json
workboard automation preset apply TASK_ID --preset auto --reason 'Choose according to task scope' --json
workboard task add --project PROJECT_ID --title 'Small fix' --process-preset small --preset-reason 'One isolated change' --json
workboard template apply TEMPLATE_ID --project PROJECT_ID --process-preset auto --json
```

The `save` file is a preset object: `id`, `name`, `description`, `when_to_use`, `steps`, `rework`, and `max_reworks`. Each step needs `id`, `title`, and `kind`; `agent`, `skills`, `prompt`, and `instructions` are optional. Duplicate the output's `preset` object from `show` and change its ID. An optional `--expected-preset-revision` pins library edits; the CLI otherwise reads the current revision. Deleting and recreating a preset advances its revision. SQLite backup/restore includes the library and advances restored library revisions. Snapshots and JSON export include `process_presets`.

Agents can inspect the library and apply a preset, with a reason, to an inactive configured task that is unassigned or assigned to that agent. The service checks task and workflow revisions and rejects active processes or someone else's assignment. Applying does not launch an agent. Configurations use `process_preset: "small" | "standard" | "large" | "auto" | CUSTOM_ID`; omitting it preserves the legacy development process for older tasks. Per-task CLI configuration also accepts `--process-preset` and `--allowed-presets`.

During a selection stage, add `--preset-id ID --selection-reason 'why this fits'` to the normal report command. These fields pass through the private handoff file. Non-selection stages cannot replace the process. Nonempty preset stage settings override corresponding development stage and status rule settings. Other fields inherit those settings.

## Project defaults and status rules

Select a project in the app, then choose the gear button labeled **Project automation defaults** beside the board controls. Save a worktree, agents, status rules, required skills, prompts, and instructions. **Apply defaults to new tasks** arms new cards without starting them. Creation, including creation directly in a matching column, never launches an agent; a later status transition is required. Existing cards keep their own configuration. Disable project defaults to stop inheritance; disable a card separately to stop its rules.

One rule is allowed per status: Backlog, Todo, In Progress, In Review, Done, or Canceled. **Development workflow** is available for In Progress. **Single stage** can run preflight, planning, implementation, verification, review, rework, or release preparation in any column. A single stage preserves the card's column, records the result and process exit, and waits for another status change. It does not decide a final review or complete a parent task. Review findings in a single stage are recorded for the user; only the development workflow automatically cycles through rework.

Rules run on actual status transitions through the service, including native drag and drop, status menus, CLI updates, and enabled plugins. Saving the same status again, retrying the same request, and the development workflow's own projected column changes do not trigger another rule. A manual transition during an active stage fences its result and queues the matching rule until the old process confirms exit. Further transitions replace the pending rule; disabling the card cancels it. If no rule matches, the normal task-edit protection applies. Pause/resume and uncertain-exit handling still apply.

Skills are required names from the selected agent's installed skill catalog or explicit SKILL.md paths. This configuration does not install skills. The prompt requires the agent to read and apply each selected skill and report blocked if it cannot. Rule settings are copied into each attempt for inspection in Stage history. Development stage overrides replace selected rule fields; unspecified fields inherit the rule. Custom text supplements the stage's reporting and source-preservation contract.

The CLI can save the same full configuration from a JSON file:

```sh
workboard automation set-defaults PROJECT_ID --configuration /path/to/configuration.json --json
workboard automation defaults PROJECT_ID --json
workboard automation set-defaults PROJECT_ID --configuration /path/to/configuration.json --enabled false --json
```

Example configuration (replace worktree and skill paths):

```json
{
  "plugin_id": "orca",
  "method": "automation.start",
  "resource_key": "WORKTREE_ID",
  "params": {"worktree_id": "WORKTREE_ID", "agent": "codex", "reviewer": "claude"},
  "max_reworks": 2,
  "process_preset": "auto",
  "allowed_presets": [],
  "timeout_seconds": 1800,
  "rules": [
    {"id": "implement", "status": "in_progress", "action": "development", "skills": [], "prompt": "Deliver the card's acceptance criteria", "instructions": "Preserve unrelated changes"},
    {"id": "manual-review", "status": "review", "action": "stage", "stage": "review", "agent": "claude", "skills": ["/path/to/review/SKILL.md"], "prompt": "Review correctness and missing checks", "instructions": "Report concrete findings with file locations"}
  ],
  "stage_settings": {"release": {"prompt": "Prepare a concise release readiness report"}}
}
```

Per-task `automation configure` also accepts `--rules` (a JSON array) and `--stage-settings` (a JSON object). Omitting rules preserves the original In Progress development trigger. An empty rules array allows explicit development starts only. Project default updates check `expected_defaults_revision`; the CLI reads the current revision unless an explicit value is supplied. Defaults are included in snapshots, JSON export, and SQLite backup/restore. Restore advances their revisions to reject stale editors.

## CLI

These commands are implemented. Replace task and worktree IDs with actual values from this board and its enabled Orca plugin.

```sh
workboard automation configure TASK_ID --executor orca \
  --resource-key WORKTREE_ID \
  --params '{"worktree_id":"WORKTREE_ID","agent":"codex","reviewer":"claude"}' \
  --max-reworks 2 --timeout-seconds 1800 --json
workboard automation start TASK_ID --json
workboard automation show TASK_ID --json
workboard automation list --json
workboard automation pause TASK_ID --json
workboard automation resume TASK_ID --json
workboard automation disable TASK_ID --json
```

Controls read the task and workflow revisions before sending a transactional request. Existing workflows require both captured revisions. Agent sessions include their identity, and the service rejects control changes on another agent's assigned task. An explicit global `--expected-revision` checks the caller's task version. The app supplies both captured task and workflow revisions. Request IDs protect identical retries. The CLI persists the original task, workflow, defaults, or preset revisions before sending a mutation, so retries reuse the same request after lost replies or later state changes.

The agent's launch environment supplies its task ID, attempt ID, and private report path. Orca keeps callback credentials in its wrapper and removes the token from the agent process environment. The offline report command needs no token; direct executor callbacks still require one. The agent reports an outcome, summary, and one or more real source paths, URLs, or verification notes:

```sh
workboard automation report --source-dir /path/to/checkout \
  --outcome pass --summary 'Implementation and required checks passed' \
  --evidence /path/outside/checkout/verification.txt --json
```

Allowed outcomes are `pass`, `blocked`, and, during review, `changes_requested`. Reporting does not advance a stage. Orca supplies `WORKBOARD_AUTOMATION_REPORT_FILE`, so the report command writes a private, token-free handoff file without opening the board socket. A `submitted: false` response means the handoff succeeded. After the agent exits, the wrapper submits that report through the service and submits `automation settle` with its exit code and a fresh checkout fingerprint. Only a successful process exit with a matching accepted report advances the workflow. An answer, an idle terminal, or process exit alone is insufficient.

The fingerprint includes HEAD, staged and unstaged changes, untracked files and symlink targets, and initialized submodule contents. Store reports and generated evidence outside the checkout, or in an appropriate ignored output directory, so a review does not change the source it is checking. Git must be available for the Orca executor's fingerprint callbacks; ordinary core tasks require no Git installation. Evidence paths and URLs are also attached to the task's artifacts with the stage and source version. These links record agent-reported verification; the service does not read their contents automatically.

## Pause, failures, and recovery

Before restoring a backup, confirm that all automation agents have exited, including disabled or trashed workflows. The service refuses to discard unresolved resource leases. Restored workflow revisions advance beyond live and saved versions, and restored attempt tokens change. Failed status-rule starts roll back their run and stage writes while retaining the requested card status and an explanation. Deleting a referenced selection candidate can prevent a new selection, but never blocks ordinary task edits; update the configuration before resuming selection.

**Pause after stage** prevents new stages. An active agent can finish and its accepted result is retained. Resume continues from that result after process exit, or lets the same still-active stage finish. It does not start a duplicate agent.

Disabling a workflow, editing its task, canceling/deleting the task, or disabling/removing/reconfiguring its executor fences further stage results. A previously launched agent may continue in Orca. Inspect its recorded terminal before restarting. A task edit restarts from preflight after exit is confirmed. Historical terminal receipts can still be attached, and exit receipts can retire old attempts, without changing the current stage.

Deadlines and uncertain launches block the workflow. They do not claim that a process stopped. Do not delete launch journals or force another attempt while the old agent might still edit files. After inspecting and stopping that agent, record an explicit observation:

```sh
workboard automation resolve TASK_ID --confirm-stopped \
  --summary 'Checked the recorded Orca terminal and confirmed the agent exited' --json
workboard automation resume TASK_ID --json
```

The app offers **Verify agent exit** for the same operation. This records a user observation, not a process-kill request. Disable and configure again to start a new workflow definition; settled stage history is preserved.

Only one unresolved attempt can own a configured executor resource at a time, including when its workflow is disabled or its task is in Trash. Orca requires the resource key to equal the worktree ID. Other tasks wait until the existing attempt confirms exit. Rework limits apply to automatic cycles; reaching the limit requires user attention.

The service resumes queued launches after restart. Stable per-attempt request IDs, the shared plugin journal, and Orca launch records prevent duplicate terminals. An uncertain external result is never automatically repeated. Settled terminal tabs remain in Orca for inspection and can be closed there. Backup/restore preserves workflow history; restore blocks unfinished workflows and rotates attempt tokens so pre-restore agents cannot modify restored work. JSON export includes workflow reports without secret tokens. Task completion and parent-task completion still follow their existing requirements and review rules.

## Implementation and verification

The development template is versioned as `development-v1`. The service saves stage transitions and pending launches together. A background host uses the ordinary plugin boundary outside the database lock. Executors receive a host-read current task, frozen configuration, and authorized attempt context. Plugin generation checks fence callbacks after configuration changes or disabling. No optional executable is discovered or invoked for absent or disabled plugins.

Run the relevant checks from the repository:

```sh
cargo test --workspace
cargo build --workspace
python3 tests/test_automation.py
python3 tests/test_orca_plugin.py
python3 tests/test_plugin_runtime.py
WORKBOARD_BIN="$PWD/target/debug/workboard" macos/Tests/run-workflows.sh
swift build --package-path macos
python3 scripts/check-english.py
```

The automation integration suite uses an actual board service and plugin host, a fake Orca CLI, and harmless agent processes. It covers status triggers, the rework loop, independent source versions, separate report/exit receipts, early completion guards, disabled executors, pause/resume, and fingerprints. These checks do not establish paid Codex/Claude authentication or native button behavior. Keep real Orca runtime checks and native interaction evidence separate in [verification](verification.md).

To verify an installed Orca runtime without calling a model, use a fresh ignored output directory:

```sh
python3 scripts/verify-automation-orca.py --orca /path/to/orca \
  --worktree WORKTREE_ID --output .build/automation-runtime-check
```

The script creates an isolated board and six harmless synthetic stage processes in the selected existing worktree. It leaves final approval pending, closes only its own test terminals, and writes `evidence.json`. It does not edit project source. Its saved board and reports remain available for inspection.

For a real signed-in agent check, use the installed CLI and a fresh ignored output directory. This uses the selected account and may consume its allowance:

```sh
python3 scripts/verify-automation-agents.py --cli /path/to/workboard --orca /path/to/orca --worktree WORKTREE_ID --agent codex --output .build/real-codex-check
```

The Codex check runs the four-stage happy path. The Claude check runs one custom preflight rule. Both apply project defaults, require a local skill plus prompt/instruction markers, preserve source, and leave final task approval to the user. The verifier records agent logs and results separately from synthetic transport evidence.
