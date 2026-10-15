# Product research and references

Research on October 15, 2026 examined macOS widgets, agent integration, and kanban apps. Requirements were then narrowed to direct CLI integration, current/upcoming work in widgets, and a desktop kanban app.

Descriptions below reflect official documentation and sales pages reviewed at the time. Prices are historical US-dollar observations, may change, and do not imply hands-on installation.

## Comparable products

| Product | Observed features | Design reference |
| --- | --- | --- |
| TaskForge | Direct CLI/JSON, local Markdown tasks, status kanban, per-list macOS widgets | A shared CLI/app/widget workflow; the closest comparison to the original request. |
| Kan Do | Bundled kando CLI and MCP, desktop kanban, smart-list widgets | Tag-based lists for current/upcoming work. |
| AgentPeek | Separate board automatically grouping sessions as active, needing attention, or ended | Distinguish task state from run state; response-turn exit is not task completion. |
| Webstarted Toolbox | Menu-bar kanban, detached persistent windows, MCP card management | A small always-visible workspace. Direct CLI and native widget support require separate confirmation. |
| Kanban Planner | Mac kanban, task/checklist widgets, Claude Code MCP | Personal planning and widgets; direct task CLI support was not established in this research. |

## Prices observed at the time

TaskForge listed widgets and kanban in Premium at $49.99 once or $1.99/month with a one-week trial. Kan Do listed $2.99 once. AgentPeek listed $14.99 once for one Mac with a three-day trial. Webstarted Toolbox was a free beta. Kanban Planner Pro listed $8.99 once.

## Product direction

Use TaskForge's CLI/app/widget relationship as a reference while keeping tasks and runs separate. Attach completion criteria, next actions, artifacts, and evidence; divide goals into subtasks. The core remains independent. External integrations such as agent-memory and Google Workspace ship as separate plugins. Reuse amem search/review only after installation and enabling.

Obsidian is not a runtime dependency. SQLite remains the task source; opening Markdown in Obsidian is optional.

## Original sources

- [TaskForge CLI](https://taskforge.md/cli/)
- [TaskForge Mac app](https://taskforge.md/mac/)
- [TaskForge widgets](https://taskforge.md/widgets/)
- [TaskForge kanban](https://taskforge.md/kanban/)
- [TaskForge pricing](https://taskforge.md/pricing/)
- [Kan Do CLI and MCP](https://kandotasks.app/wiki/ai-assistants-mcp/)
- [Kan Do smart lists](https://kandotasks.app/wiki/custom-smart-lists/)
- [Kan Do Mac app and widgets](https://kandotasks.app/wiki/mac/)
- [AgentPeek session board](https://agentpeek.app/agent-board/)
- [AgentPeek pricing and platform](https://agentpeek.app/)
- [Webstarted kanban](https://tools.webstarted.com/toolbox/kanban-board/)
- [Webstarted MCP](https://tools.webstarted.com/toolbox/mcp/)
- [Kanban Planner](https://kanban.kristmanntechnologies.de/en)
- [Kanban Planner pricing](https://kanban.kristmanntechnologies.de/en/pricing)

## Calendar and task workflows

The additional user requirement made Calendar the center of the Workspace plugin. Store deadlines and meeting times on the board and explicitly link selected calendar events. Linear's issue properties, due-date presentation, and per-account integration settings informed the UI.

Linear's official Google Calendar integration describes user status updates from out-of-office events. That page alone does not establish bidirectional task-deadline or meeting synchronization. This project's calendar scope follows its own user requirements.

- [Linear Google Calendar integration](https://linear.app/integrations/google-calendar)
- [Linear issue properties and due dates](https://linear.app/docs/issue-properties-home)
- [Google Calendar creation and deduplication IDs](https://developers.google.com/workspace/calendar/api/guides/create-events)
- [Google Calendar versions and ETags](https://developers.google.com/workspace/calendar/api/guides/version-resources)
