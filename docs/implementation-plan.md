# Implementation plan

The first goal is shared tasks and subtasks across the CLI, Mac app, and native widget without plugins. Validate standalone operation, then the shared plugin boundary and optional integration packages.

## Current status

| Scope | Status |
| --- | --- |
| Rust core, CLI, real sockets | Implemented and automatically tested. |
| SwiftUI board, subtasks, personalization | Implemented; real-service integration and image checks pass. Baseline native interactions passed on a second Mac. New screens require separate native interaction checks. |
| WidgetKit | Compilation, bundle, and image checks pass. Actual personal-team-signed desktop behavior passed on a second Mac. |
| Shared plugin host | Separate processes, manifests/JSON, installation, disabling, retries, interruption tested. |
| agent-memory | Separate package and fake-executable tests; real CLI search/read/evidence attachment verified. No actual capture performed. |
| Google Workspace | Calendar-centered features, optional Gmail, real host/provider boundary tested with mocked APIs. Real OAuth client unavailable. |
| Slack | Separate package, host/provider and Swift request checks pass. Real workspace authentication/search/sending pending. |
| Linear | Separate package, host/provider and Swift model checks pass. Real workspace authentication/search/comments/state changes pending. |
| Orca | Separate package and recoverable launch links implemented; isolated real-runtime worktree import and a harmless terminal launch verified. Actual model calls and new native UI pending. |
| Local distribution | App installation, CLI link, LaunchAgent takeover tested. Developer ID signing/notarization remain separate. |
| Planning extensions | Dependencies, templates, review checklists, Inbox, saved views, and weekly planning implemented with service and Swift regressions. |

Use [verification](verification.md) for precise commands, evidence, and limits. The stages below remain acceptance criteria rather than claims that all external validation is complete.

## Stage 0: environment and transport

- Prepare Xcode/signing and establish the minimum macOS target.
- Verify Unix socket requests between Rust executables and the Swift app.
- Prototype LaunchAgent registration/restart, App Group paths, and widget extension access.
- Check widget refresh after CLI changes with the Swift host running and stopped.

The first Apple Silicon environment used Rust 1.99.0 and Swift 6.3.3 Command Line Tools without full Xcode or valid signing certificates. A second environment later verified Xcode 27 and personal-team signing. See [Mac builds](macos-build.md) for container-access failures and the working signing path.

## Stage 1: Rust core and CLI

Store projects, task hierarchy, runs, assignments, and events. The service owns writes. The CLI creates/lists/assigns/starts/reviews/completes tasks and subtasks.

Test simultaneous claims, identical retries, stale revisions, hierarchy cycles, individual subtask state/assignment, service restart, and backup/restore. Use disposable databases without touching operational data.

## Stage 2: Mac kanban app

Build columns, task details, and project views. Show subtasks and counts in the parent, and navigate into each subtask. The active app polls the board and recovers current snapshots after reconnect. App edits use the same rules as CLI edits.

Verify that run exit does not remove a task and that another run can continue from artifacts and next actions.

## Stage 3: native desktop widget

Provide current, upcoming, and review views. Selecting a task opens its app details. Native widgets and small persistent app windows have distinct refresh mechanisms.

Test snapshot-generation failure and staleness. Verify refresh and restart outside the Xcode debugger. App screenshots alone do not establish native widget acceptance.

## Stage 4: standalone acceptance

Without plugins, Python, agent-memory, or Google accounts, create projects/tasks/subtasks, assign agents, attach files/URLs, interrupt, resume, review, and complete work. Check search, backup, and export. Confirm consistent CLI/app/widget state and demonstrate actual widget refresh behavior.

Confirm the core distribution excludes integration code/dependencies and performs no external executable discovery, account access, or synchronization. Core doctor must succeed without plugin/account setup. Measure size, startup, and idle memory. This stage defines the core MVP.

## Stage 5: shared plugin host

Define distribution/execution, IDs, versions, compatibility, capabilities, and permissions. Implement install/enable/disable/remove/status. Use the same service mutation contract and keep plugin code/dependencies outside the core package.

Verify no loading/execution/external/background work while absent or disabled. Incompatibility, failure, and timeouts must not block core features. Preserve task data after removal and reject late mutations after disabling. Compare size/startup/idle memory before and after installation.

## Stage 6: agent-memory

Ship a separate, disabled-by-default package. After installation/enabling, invoke the configured amem path, preserve task search scopes, verify source reads, and attach original locations. Explicit decision capture is a separate action.

Reproduce missing executables, permission failures, expired refs, malformed responses, and timeouts. Core create/edit/search/resume, app, and widget must remain usable. Disconnection preserves tasks/artifacts/evidence and stops automatic calls.

Verify no automatic conversation capture and safe handling of uncertain external saves. Neither plugin implementation nor memory-engine porting may block core installation/use.

## Stage 7: Google Workspace

Ship separately. Import Calendar meetings, create/update deadlines and scheduled work, and provide optional Gmail search/read/attachments/imports. Enable only needed services; authenticate through Desktop OAuth/PKCE and store tokens in Keychain.

Verify absent/disabled isolation, connection failure, and data preservation after removal. Check all-day/time-zone semantics, deterministic IDs, and ETag conflicts. After mocked API tests, verify real account connection, imports, creation, and updates. The core remains installable without Google dependencies/accounts.

## Separate stage: memory-engine port

Porting Python amem to Rust is independent. Measure startup, search latency, indexing, and memory first. Separate CLI, search core, and format extractors. Do not replace production until search quality and policy compatibility pass.

## Remaining decisions

| Decision | Criteria |
| --- | --- |
| Product and CLI naming | Review initial screens; current names are Agent Workboard and workboard. |
| Minimum macOS and signing | macOS 14 implementation; local personal-team proof exists. External signed/notarized distribution still needs verification. |
| Tokio | Current synchronous sockets with per-connection threads; change only after load measurements. |
| Dedicated Blocked column | Decide through board/review-widget usability. |
| Hierarchy depth and deletion | Nested relationships and cycle rejection exist. Task/project deletion now requires explicit descendant/task flags. Revisit depth limits when needed. |
| Plugin distribution/compatibility | Local executable packages and protocol 1 exist. A public registry and automatic updates are later scope. |
| Google real accounts | Verify Calendar/Gmail and disconnect with a prepared Desktop OAuth client/account. |
| Memory save recovery | Identical requests reuse responses; uncertain results do not rerun. Manual inbox confirmation remains necessary. |
| Obsidian vault | Add only for a concrete document-management need. |
| Cross-device sync | Design separately after single-Mac core acceptance. |
