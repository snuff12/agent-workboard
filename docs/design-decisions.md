# Design decisions

Recorded on October 15, 2026. User requirements are distinct from initial implementation choices.

## User requirements

- Direct CLI integration with agents.
- A native Mac widget for current and upcoming work.
- A standalone desktop kanban app.
- Subtasks with individual state, assignees, and results.
- A TaskForge-like system adapted to this work environment, with optional agent-memory.
- Core CLI, kanban, and widget use without agent-memory; integrations disabled by default.
- Separately installed integrations, including agent-memory and Google Workspace; no dedicated integration code or dependencies in the core distribution.
- Calendar-centered Google Workspace integration for deadlines and meetings, plus Gmail search and task attachments.
- Slack search, source verification, attachments/imports, and selected task-status sending.
- Linear issue search, source verification, attachments/imports, selected status comments, and selected issue state changes.
- GitHub issue and pull request browsing, imports/attachments, read-only linked status, and separately enabled status comments and issue creation.
- A simple UI with personal themes, accents, text size, density, and visibility settings.
- An Orca project for the collected design material, with optional worktree and agent integration.
- English-only project materials and a fresh English-only Git history.

## Technical decisions

| Decision | Reason | Reconsider when |
| --- | --- | --- |
| Rust core and CLI | Executable distribution, long-lived services, strict state modeling. | Build or app-integration complexity materially obstructs core features. |
| SwiftUI and WidgetKit | Native Mac behavior. | Another operating system becomes an actual requirement. |
| SQLite as task source | Transactional claims, state, and history. | Direct human editing of source state becomes the priority. |
| One service owns writes | Consistent validation and centralized change handling. | Measured operating complexity exceeds direct database access. |
| Local sockets and JSON | Explicit language-independent boundary. | Serialization cost or system restrictions justify narrow function bindings. |
| Widget snapshots | Match short widget execution and system refresh budgets. | Snapshot recovery or display requirements require another read model. |
| Subtasks are ordinary linked tasks | Reuse state, assignment, criteria, and artifact rules. | Hierarchy depth or deletion requirements change. |
| Separate plugin packages | Avoid integration costs in core size/startup/idle memory. | Distribution costs and failure-isolation evidence support another approach. |
| amem through an optional CLI plugin | Preserve standalone use and existing memory policy. | Add other memory providers through the same boundary. |
| Calendar and Gmail in Workspace plugin | Install only when needed; choose per-service permissions. | Real-account workflows and conflict tests identify changes. |
| Slack package with imported User Token | Reuse the shared contract, isolate user search permissions, separately enable sending with host-read tasks. | Real workspace search/sending justify broader OAuth installation or refresh support. |
| Linear package with imported personal API key | Reuse the Slack pattern; keep comments and state changes separately enabled; deduplicate comments by task revision and guard state changes with read versions. | Shared team use or real-account limits justify a Linear OAuth application. |
| GitHub package with gh sign-in or imported token | Reuse an existing gh sign-in or a personal access token in Keychain without OAuth app setup; scope every call to configured repositories; separately enable previewed writes with a verified account. | GitHub Enterprise, GitHub App installation, or real-account use justify another authentication path. |
| Isolate plugin failure/disable/removal | Keep tasks resumable and preserve data without integrations. | Every added integration must continue passing standalone checks. |
| Separate Rust port of Python amem | Avoid coupling board delivery to memory-engine compatibility. | Measurements and search-quality checks demonstrate a benefit. |
| Optional Obsidian | Independent CLI/app and portable Markdown. | A vault-centered source becomes an actual user requirement. |
| English-only project | Consistent documentation, UI, diagnostics, examples, and contributions. | Only an explicit product-language decision changes this policy. |

These choices established the initial build direction. Verify versions, minimum macOS, signing, App Groups, and asynchronous runtime needs through prototypes and tests.

## Earlier alternatives

The first proposal considered a Swift core, Swift Argument Parser, GRDB, and XPC. The Rust discussion changed the core, CLI, database access, and transport; SwiftUI and WidgetKit remained. Optional agent-memory evolved into an independently installed plugin alongside Google Workspace. Plugins remain disabled after installation.

## Agent automation, October 18, 2026

The board owns the versioned development workflow, stage evidence, resource claims, and pending launches in SQLite. A generic service worker invokes separately enabled executor plugins outside database transactions. The first executor reuses Orca's existing terminal CLI with fresh one-shot agent processes and separate result/exit receipts. This keeps the workflow reusable with other executors while preserving the existing task service as the only writer.

Automatic review passes are stage outcomes. The existing final approval request still completes the task only after release preparation and ordinary completion checks. The initial implementation used a fixed template. Project defaults, status rules, and editable process presets now extend it, as described below.

## Implementation status

The Rust core/service/CLI, SwiftUI app, WidgetKit extension, and separate plugins are implemented and being verified. Transactions, real socket/CLI connections, builds, and local installation have been checked. A second Mac with full Xcode and personal-team signing verified the actual desktop widget and baseline native app interactions. New planning/plugin screens and real Google/Slack/Linear accounts, and real GitHub writes retain their own unverified scope. See [verification](verification.md); the memory engine has not been ported.

## Status-driven agent rules and project defaults

Project defaults live in the persistent board SQLite settings under project-scoped keys. The service inherits a frozen configuration for newly created tasks, including template children and Inbox promotions. Existing cards remain independently configurable. A saved revision prevents competing project editors from overwriting each other, including after restore.

The service compares status before and after each ordinary mutation. A true edge can launch one configured rule. Development projections bypass this trigger, preventing review/rework loops caused by internal column changes. Single-stage actions preserve task status and wait after their report and process exit. A manual transition during an unresolved attempt queues the new rule and fences late results until exit confirmation.

Each attempt stores selected skills, prompt, instructions, and agent settings. Optional stage overrides support the development workflow. Executors pass required skill names or paths to the selected agent; missing skills must block the stage. The core does not discover or install agent skills.

Sandboxed agents write a private token-free report handoff instead of opening the board socket. The executor submits the result after the real process exits, then records that exit separately. This keeps ordinary agent sandbox settings while preserving the service's stage evidence and exit checks.

## Reusable process presets and agent selection

The shared preset library uses persistent SQLite settings and the same service mutation boundary as tasks. Built-ins are virtual read-only definitions; custom definitions have monotonically increasing revisions, including after restore. No plugin or new database schema is needed for the library.

Each configured task freezes its explicit selected definition. Automatic selection freezes allowed candidates when the selection attempt starts. A normal evidence report names the selected candidate and reason; only report acceptance plus real process exit can advance. The execution cursor identifies each ordered step, so repeated kinds retain distinct settings and evidence. Library edits never rewrite active plans. Conditional rework resumes downstream of the nearest implementation, with the lower preset/project loop limit. Finishing any selected process still requires human final approval.

Agents can inspect and apply presets through the CLI to inactive, unassigned or self-assigned tasks. Selection checks task and workflow revisions and does not launch an executor. Creating a manual task omits process selection. Older configurations without a preset keep the legacy engine.
