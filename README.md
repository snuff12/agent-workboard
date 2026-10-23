# Agent Workboard

A local macOS workboard for people and coding agents. Manage the same tasks through a Rust CLI, a desktop kanban app, and a native desktop widget. Break large goals into subtasks, keep results and next actions attached, and install only the integrations you need.

The project is `agent-workboard`. Its Rust service and CLI, SwiftUI app, and WidgetKit extension are implemented and undergoing integration verification. An Xcode build signed with a personal development team has displayed the actual desktop widget and reflected CLI changes. Google account integration and notarized external distribution still require separate verification.

## Core requirements

1. Agents and shell scripts can list, create, and update tasks through the CLI.
2. A native macOS desktop widget shows current work and upcoming tasks.
3. A standalone Mac app provides the kanban board.
4. Each task can contain subtasks with their own status, assignee, and results.
5. All core features work without installing integration plugins.

agent-memory, Google Workspace, Slack, Linear, Orca, and GitHub integrations are separate plugin packages. The core app contains neither their executable code nor dedicated dependencies. Installed plugins remain disabled until the user enables them. Attach ordinary files, URLs, and artifacts without any plugin.

The agent-memory plugin searches existing documents and memories and submits explicitly selected decisions as memory candidates. Google Workspace centers on Calendar deadlines and meetings, with optional Gmail search and attachments. Orca browses local worktrees and run terminals, imports work as tasks, and launches board tasks through Codex or Claude.

Slack provides message search, source reading, attachments, and task imports. Separately enable sending to post a selected task's status to a specified channel. See [Slack setup](docs/slack.md). Real-account search and sending have not yet been verified.

Linear provides issue search, source reading, attachments, and task/subtask imports. Separately enable status comments to post a selected task's status on an issue, and state changes to move an issue to a chosen workflow state. See [Linear setup](docs/linear.md). Real-account use has not yet been verified.

GitHub browses and searches issues and pull requests in connected github.com repositories, imports or attaches them to tasks, and checks the status of linked items without changing task status. Separately enable writing to comment a task's status or create an issue after previewing the exact text. See [GitHub](docs/github.md). Real-account comments and issue creation have not been performed.

The default UI is a simple kanban board with Linear's workflow columns: Backlog, Todo, In Progress, In Review, Done, and Canceled. Deleted cards wait in Trash until you restore them or empty it. Save light, dark, or system appearance, accent color, text size, card density, and display preferences. Import and export custom themes as JSON.

## Planning workflows

Project defaults and status rules in opt-in [agent automation](docs/automation.md) select agents, required skills, prompts, and instructions. Reusable process presets select a short or extended stage sequence per task. People or agents can choose a preset, or a selection stage can choose and explain it automatically. Built-ins cover small, standard, and large tasks; custom presets save stage order and execution settings. The board owns stage state and evidence; the separately installed Orca executor launches fresh agent processes. Final approval stays with the user.

These six features work without external accounts:

| Feature | Behavior |
| --- | --- |
| Task dependencies | Link prerequisites separately from parent/subtask relationships. Find ready tasks. Reject cycles and attempts to start or complete tasks with unfinished prerequisites. |
| Task and subtask templates | Create a task tree from built-in bug fix, feature development, and document research templates, or save your own. |
| Review checklists | Check required items before completion. Record approval, requested changes, rejection, reasons, and history. |
| Quick capture and Inbox | Capture ideas, URLs, and file paths using a global shortcut. Convert them to project tasks while preserving sources and notes. |
| Saved views | Save project, assignee, status, readiness, staleness, and search filters with board, list, or week layouts. |
| Weekly planner | Place tasks on a weekly calendar and preview conflicts before saving. Explicitly read or update Google events through an enabled Workspace plugin. |

The default Quick capture shortcut is Control+Shift+Space. It works while the app is running, including with the board window closed. Change or disable it in Quick capture settings. Captured URLs and file paths are not read automatically.

## Build and run

On a Mac with Rust and Swift installed:

```sh
cargo build --workspace
./target/debug/workboard project list --json
swift build --package-path macos
scripts/build-xcode.sh --team TEAMID   # Full Xcode required for the desktop widget
scripts/install-local.sh --start-service
```

`TEAMID` is the 10-character development team ID added to Xcode. A free personal team is sufficient for local use. Without full Xcode, `scripts/build-macos.sh` builds the app and CLI, but its widget does not appear in the macOS widget gallery. The last command installs the app in the user's Applications directory and registers the CLI and user service. See [Mac build and installation](docs/macos-build.md) for requirements and verified coverage.

Data defaults to `~/Library/Application Support/AgentWorkboard`. Use `--data-dir` and `--socket` for isolated development data. See the [CLI contract](docs/cli-contract.md) and [Google Workspace guide](docs/google-workspace.md).

`scripts/package-plugins.sh` creates plugin ZIPs separately from the core app, named `dist/AgentWorkboard-plugin-<id>-<version>.zip` (for example `AgentWorkboard-plugin-orca-0.5.0.zip`). Extract only the packages you need. In the app, choose Install in plugin settings and select a directory containing `plugin.json`. The CLI equivalent is `workboard plugin install /path/to/orca-0.5.0`. Installation leaves the plugin disabled; follow its guide to configure it.

`scripts/verify-plugin-packages.sh` checks the two files in each ZIP, extracts and installs it through an isolated CLI, and verifies the disabled default. It does not use the user's board or external accounts.

Run `python3 scripts/verify.py` for the complete local regression checks, or add `--scope core` for Rust and plugin fixtures only. The runner builds executables before testing, clears inherited board connection settings, and stops at the first failed check. GitHub Actions uses the same runner on macOS. Python is a development test dependency, not a core installation requirement. Desktop widget hosting and real account connections require separate evidence.

## Technology

| Component | Technology |
| --- | --- |
| Task core and local service | Rust, Cargo |
| CLI | Rust, clap |
| Requests and responses | serde, serde_json, versioned JSON |
| Task storage | SQLite, rusqlite, WAL |
| Process communication | Unix domain socket |
| Mac app and menu bar | SwiftUI, with AppKit where needed |
| Native desktop widget | WidgetKit, App Intents, App Groups |
| Integrations | Separately installed executable packages, manifests, standard-input/output JSON |
| agent-memory | User-configured amem CLI |
| Google Workspace | Calendar deadlines and events, Gmail, Desktop OAuth, Keychain |
| Slack | Message search and attachments, explicitly enabled status sending |
| Linear | Issue search and attachments, explicitly enabled status comments and state changes |
| Orca | User-configured Orca CLI, local worktrees and terminals, agent launches |
| GitHub | Issues and pull requests through the GitHub REST API, gh sign-in or Keychain token, explicitly enabled writes |

Obsidian is optional. SQLite is the source of truth for tasks and runs. Keep descriptions, decisions, and results in Markdown or export them for reading in other tools. An optional Obsidian vault connection can be considered separately.

The new Rust workboard and a possible port of Python amem are separate projects. The core workboard requires neither Python nor amem. Only an enabled integration invokes amem. Any Rust memory-engine port needs its own measurements and compatibility checks.

## Documentation

| Guide | Contents |
| --- | --- |
| [Product requirements](docs/product-requirements.md) | Subtasks, plugin principles, tasks versus runs, MVP criteria |
| [Technology choices](docs/technology-stack.md) | Rust and Swift roles, storage, communication, development and distribution |
| [Architecture](docs/architecture.md) | Sources of truth, single writer, plugin boundaries, app/widget refresh |
| [CLI contract](docs/cli-contract.md) | Commands, JSON output, conflicts, retries |
| [agent-memory](docs/agent-memory-integration.md) | Optional installation, failure isolation, evidence, memory capture |
| [Implementation plan](docs/implementation-plan.md) | Stages, deliverables, validation, remaining decisions |
| [Product research](docs/product-research.md) | Comparable tools and original sources |
| [Design decisions](docs/design-decisions.md) | Requirements, choices, alternatives, reconsideration criteria |
| [UI and personalization](docs/ui-design.md) | Screens, themes, display settings, verification |
| [Mac build and installation](docs/macos-build.md) | App/widget builds, local installation, verified scope |
| [Google Workspace](docs/google-workspace.md) | Calendar, Gmail, account setup, verification limits |
| [Slack](docs/slack.md) | Search, source reading, task attachments, sending, tokens |
| [Linear](docs/linear.md) | Issue search, task attachments, status comments, state changes, API keys |
| [Orca](docs/orca-integration.md) | Worktrees, terminals, imports, attachments, launches |
| [GitHub](docs/github.md) | Issues, pull requests, scoped search, linked status, status comments, tokens |
| [Agent integration](docs/agent-integration.md) | Claude Code and Codex session context, protocol, identity, sandbox rules |
| [Agent automation](docs/automation.md) | Development stages, Orca execution, review/rework, pause, recovery, and final approval |
| [Verification](docs/verification.md) | Passing checks, installation evidence, remaining external checks |

## Everyday workflow

Create projects and subtasks through the CLI without plugins. Park unplanned work in Backlog, where agents' ready lists skip it. Assign a task and start a run to show it as In Progress in the app. The widget shows current work, tasks due today, and work completed today. Another agent can continue from artifacts, next actions, and attached files or URLs.

The shared plugin host and all six integration packages are implemented. Plugin failures, disabling, and removal preserve existing task data. See the verification record for the tested scope.

Claude Code and Codex sessions can connect to the board with the optional agent kit: `scripts/install-agent-kit.sh` installs a plugin per tool that adds board context at session start and the agent protocol as a skill. See [Agent integration](docs/agent-integration.md).

The widget shows its last update time. The service requests a refresh when it changes the snapshot, and macOS controls the actual refresh schedule. While active, the app periodically checks the service's change sequence.

## English-only contributions

Write documentation, interface text, diagnostics, comments, examples, fixtures, and commit messages in English. Run `python3 scripts/check-english.py` before committing. This source-language policy does not restrict the language of user task data.
