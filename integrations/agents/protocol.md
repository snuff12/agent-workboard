# Agent Workboard protocol

The board is the shared record of work for people and agents on this Mac. Use the `workboard` CLI. Put options after the subcommand, for example `workboard task show <task-id> --json`. Commands that accept `--agent` use your agent ID automatically.

## Start of work

- Read the board context that the session start added, or run `workboard agent context`. It shows your agent ID, the project for this directory, your tasks, work in progress, reviews, and ready tasks.
- Work on a board task only when the user's request clearly matches it or the user asks you to. Then claim and start it, and keep the returned run ID:
  `workboard task claim <task-id>` and `workboard task start <task-id> --json`.
- Do not take over a task that another agent holds. Tell the user instead.
- Do not create, claim, or change tasks for ordinary requests that do not match board work. When you find follow-up work outside the current request, capture it for the user to sort: `workboard inbox capture --title "<follow-up>" --note "<context>"`.

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

Do not delete board data, restore backups, run or change plugins, or edit the board database unless the user explicitly asks.
