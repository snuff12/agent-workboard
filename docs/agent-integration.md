# Agent integration

Claude Code and Codex sessions can use the board without the user repeating instructions. The integration is optional and separate from the app: the board, CLI, app, and widget work without it.

## What connects automatically

| Step | Mechanism | Changes board data |
| --- | --- | --- |
| Know the board | A session-start hook adds a short summary: the agent ID, the project for this directory, the agent's tasks, work in progress, reviews, ready tasks, and open inbox items. | No |
| Know the rules | The `workboard` skill carries the [agent protocol](../integrations/agents/protocol.md). `workboard agent brief` prints the same text, and Orca launch prompts include it. | No |
| Act on work | The agent claims, starts, updates, attaches, pauses, and requests review with the CLI when the user's request matches a board task. Other follow-ups go to the inbox. | Yes, through the service |
| Decide | The user approves, requests changes, or rejects reviews in the app. The widget shows reviews that wait. | Yes, by the user |

Hooks never change task state. A response ending is not task completion, so no hook completes, reviews, or pauses work.

## Agent identity

Commands that act for an agent add `agent_id` automatically when it is not given. The ID comes from, in order:

1. `WORKBOARD_AGENT`, set by the Claude Code hook (`claude:<session>`) or by an Orca launch (`orca:codex`, `orca:claude`).
2. `CODEX_THREAD_ID`, which Codex sets in its shell commands (`codex:<thread>`).

`workboard rpc` stays explicit and never adds an ID. People using the CLI without these variables act as before.

## Project lookup

`workboard agent context` matches board projects by repository. A linked worktree (for example an Orca workspace) maps to the project whose directory is the main checkout, because both share one git directory. A project also matches when its directory contains the current directory. The lookup reads `.git` files and runs no external program.

## Install

The kit is a local marketplace in `integrations/agents` with one plugin per tool.

```sh
scripts/install-agent-kit.sh            # every installed tool
scripts/install-agent-kit.sh --codex    # one tool
scripts/install-agent-kit.sh --uninstall
```

| Tool | Installed parts | One-time step |
| --- | --- | --- |
| Claude Code | `workboard@agent-workboard` plugin: skill and SessionStart hook. The hook writes `WORKBOARD_AGENT` through `CLAUDE_ENV_FILE`. | None |
| Codex | `workboard@agent-workboard` plugin: skill and SessionStart hook. `~/.codex/rules/workboard.rules`. | Run `/hooks` in Codex and trust the hook. |

The installer adds plugins through each tool's plugin manager and leaves `~/.claude/settings.json` and `~/.codex/hooks.json` unchanged. Other tools, such as Orca, keep their own hooks there.

## Codex sandbox

The Codex sandbox blocks the Unix socket of the board service, so board commands fail inside it. `workboard.rules` runs ordinary board commands outside the sandbox without a prompt: project, task, inbox, template, view, board, events, doctor, and agent commands. The service still validates claims, revisions, and retries. Codex asks the user first for task deletion, completion, and review decisions; project, template, and view deletion; inbox promotion and dismissal; and `rpc`, backup, export, plugin, and serve. The installer repeats the rules for the absolute paths of the installed executable.

Rules match the command as typed, so agents put options after the subcommand (`workboard task show <id> --json`). Check a command with:

```sh
codex execpolicy check --rules ~/.codex/rules/workboard.rules -- workboard task show TASK --json
```

## Failure behavior

The hook uses only a running service, waits at most two seconds, prints nothing when the board is unavailable, and always exits successfully. It never starts the service. Sessions continue normally without board context.

## Verification

`tests/test_agent_kit.py` checks that the skills and `agent brief` carry the protocol, the plugin manifests and hooks, identity on claims and inbox captures, worktree project lookup, hook output and fail-open behavior, and, when Codex is installed, the rule decisions.
