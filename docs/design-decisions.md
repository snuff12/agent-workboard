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

## Implementation status

The Rust core/service/CLI, SwiftUI app, WidgetKit extension, and separate plugins are implemented and being verified. Transactions, real socket/CLI connections, builds, and local installation have been checked. A second Mac with full Xcode and personal-team signing verified the actual desktop widget and baseline native app interactions. New planning/plugin screens and real Google/Slack/Linear accounts, and real GitHub writes retain their own unverified scope. See [verification](verification.md); the memory engine has not been ported.
