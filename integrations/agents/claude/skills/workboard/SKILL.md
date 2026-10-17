---
name: workboard
description: Use the local Agent Workboard when the user's work matches a board task, when the user asks about tasks or the board, or when follow-up work should be captured for the user. Covers claiming, updating, attaching results, requesting review, and handing work off.
---

# Agent Workboard protocol

The board is the shared record of work for people and agents on this Mac. Use the `workboard` CLI. Put options after the subcommand, for example `workboard task show <task-id> --json`. Commands that accept `--agent` use your agent ID automatically.

## Automated stages

When `WORKBOARD_AUTOMATION_ATTEMPT` is present, the user has enabled a workflow and the launch prompt names one stage. Follow that stage's scope and reporting instructions instead of ordinary task claim/start/review commands. Read the task and prior reports, submit evidence with `workboard automation report --source-dir <checkout>`, then end the process. The executor separately confirms process exit. Orca keeps callback credentials in its wrapper and removes them from the agent environment; the private report handoff requires no token. Do not settle your own process, approve a review, complete the task, deploy, or merge. Selection, preflight, planning, verification, review, and release stages must preserve the source version it received. Do not print or attach the attempt token.

## Choose a process preset

When a task needs automation, inspect `workboard automation preset list --json` and `workboard automation preset show PRESET_ID --json`. Choose according to scope, uncertainty, and verification needs: small has implementation and review; standard adds preflight and release preparation; large adds explicit planning and verification. Custom presets include `when_to_use` guidance. Use the simplest process that covers the task's risks and completion criteria.

For an inactive, configured task that you hold or that is unassigned, use `workboard automation preset apply TASK_ID --preset PRESET_ID --reason "<why this process fits>" --json`. This records your choice without starting an agent. To delegate selection, use `--preset auto`. When creating an automated task, use `workboard task add ... --process-preset PRESET_ID --preset-reason "<why>"`; saved project executor defaults are required. Choose `--automation manual` for work that needs no automated process. Do not change an active process or another agent's assignment.

During a `select` stage, read only the task and authorized preset candidates in the launch prompt. Report the selected ID with `--preset-id PRESET_ID --selection-reason "<why>"`, evidence, and the normal source fingerprint. Do not create or edit presets, start tasks, or launch another agent. The service accepts only an authorized candidate and advances after process exit. Configured tasks keep a frozen copy of the selected stages.

## Start of work

- Read the board context that the session start added, or run `workboard agent context`. It shows your agent ID, the project for this directory, your tasks, work in progress, reviews, and ready tasks.
- Work on a board task only when the user's request clearly matches it or the user asks you to. Then claim and start it, and keep the returned run ID:
  `workboard task claim <task-id>` and `workboard task start <task-id> --json`.
- Do not take over a task that another agent holds. Tell the user instead.
- Backlog holds work the user has not planned yet, and ready lists skip it. Leave Backlog and Canceled tasks alone unless the user points you to one.
- Except for work from a source message (below), do not create, claim, or change tasks for ordinary requests that do not match board work. When you find follow-up work outside the current request, capture it for the user to sort: `workboard inbox capture --title "<follow-up>" --note "<context>"`.

## Work from a Slack message or another source

When the user asks for work based on a Slack message, email, issue, or document, keep its link on the board so the user and the next agent can find the source. The Slack plugin is not needed.

- Record the permalink, such as `https://<workspace>.slack.com/archives/<channel>/p<timestamp>`, with a one-line summary. Do not copy the message body into the board.
- If a board task matches the work, attach the link: `workboard task attach <task-id> --source <permalink> --kind url --description "Slack: <one-line summary>"`.
- If no task matches and the board context shows a project for this directory, create the task, attach the link, then claim and start it: `workboard task add --project <project-id> --title "<work>" --goal "<what the message asks>" --next-action "<first step>" --json`.
- If no project matches, capture it for the user to sort: `workboard inbox capture --title "<work>" --source <permalink> --note "<one-line summary>"`. Promoting the item to a task attaches the link.

## While working

- Read the latest task before you change it: `workboard task show <task-id> --json`. Pass `--expected-revision <revision>` when you update it.
- Keep the next action current: `workboard task update <task-id> --expected-revision <revision> --next-action "<next step>"`.
- Attach what the next agent or the user needs, such as files, commits, pull requests, and URLs: `workboard task attach <task-id> --source <path-or-url> --kind <file|url> --description "<why it matters>"`.
- During long work, refresh your claim: `workboard task heartbeat <task-id>`.

## Finishing

- A response ending does not complete a task. When the completion criteria are met and verified, request review with what you verified and what remains: `workboard task review <task-id> --run <run-id> --summary "<verified results and open decisions>"`.
- Do not complete tasks or decide reviews unless the user explicitly asks. The user approves reviews in the app.
- If you stop before the work is done, pause the task with its state and next action: `workboard task pause <task-id> --run <run-id> --summary "<current state>" --next-action "<next step>"`.
- If you will not continue a task you hold, release it: `workboard task release <task-id>`.

## Evidence and memory

- Use your own memory tools for background lookups.
- When evidence must stay with the task for the next agent, attach the verified source to the task.
- Do not save conversations or search results as long-term memory unless the user asks.

## Never

Do not cancel or delete tasks, restore or empty the trash, delete other board data, restore backups, run or change plugins, or edit the board database unless the user explicitly asks. When the user asks, cancel with `workboard task cancel <task-id> --expected-revision <revision>`. With an agent ID, `task update --status` cannot set `done` or `canceled`.

A stage report can return `report_file` and `submitted: false`. This is a successful private handoff. End the stage process; the executor submits the file and confirms exit. Do not run `automation submit-report` or `automation settle` yourself.
