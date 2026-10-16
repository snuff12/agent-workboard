# Technology choices

Implement the workboard core and CLI in Rust, with Swift technologies for the Mac app and native widget. The core works without plugins, Python, or Google accounts. agent-memory and Google Workspace are separately installed plugins; memory-engine porting is independent.

## Product stack

| Area | Choice | Rationale |
| --- | --- | --- |
| Task core | Rust, Cargo workspace | Shared types for task state, assignments, and revisions across the CLI and service. |
| CLI | clap | Consistent subcommands, options, help, and exit codes. |
| Requests/responses | serde, serde_json | Validate versioned JSON and request IDs with Rust types; Swift uses the same field contract. |
| Local service | Rust executable, user LaunchAgent | Handle requests independently of GUI windows; own all task writes. |
| Registration | User LaunchAgent initially; SMAppService later | Independent operation; verify release signing and Login Items separately. |
| Transport | Unix domain socket | Language-independent requests between the CLI and Swift app on one Mac. |
| Database | SQLite, rusqlite | Transactional state and history; bundled SQLite and online backup support. |
| Concurrency | WAL, single writer | Separate reads and writes and serialize mutations. Validate business conflicts through revisions and claims. |
| Task search | SQLite FTS5 | Search titles, descriptions, and resume summaries locally. Add amem document/memory search only when enabled. |
| Mac app | Swift 6, SwiftUI | Kanban, task details, project views, keyboard interaction. |
| Mac-specific UI | AppKit where needed | Menu bar, small persistent windows, and window control. |
| Desktop widget | WidgetKit, App Intents | Current work, upcoming tasks, review requests, configurable views. |
| Widget data | App Groups, JSON snapshots | Read only display data; include database sequence and generation time. |
| Plugin host | Separate executable packages, standard-input/output JSON, manifests, journal | Keep integration code optional, avoid execution while absent/disabled, and isolate failures. |
| agent-memory | User-configured amem CLI | Reuse existing search and memory policies; separately packaged and disabled by default. |
| Google Workspace | Python standard library, Google REST APIs, Desktop OAuth/PKCE, Keychain | Separate Calendar/Gmail implementation, permissions, and authentication from the core; choose scopes per service. |
| Slack | Python standard library, Slack Web API, imported User OAuth Token, Keychain | Separate search/reading/attachments and explicitly enabled sending; journal retries. |
| Linear | Python standard library, Linear GraphQL API, imported personal API key, Keychain | Separate issue reading/attachments from explicitly enabled comments and state changes; journal retries. |
| Orca | Python standard library, user-configured Orca CLI | Browse local worktrees/terminals and import tasks; distinguish agent launches from attachment recovery using run IDs and durable journals. |
| GitHub | Python standard library, GitHub REST API, user-configured gh CLI or imported token in Keychain | Browse, import, and attach issues and pull requests in configured repositories; read linked status; separately enabled writes with journal-protected uncertain results. |
| Personalization | UserDefaults, versioned theme JSON | Separate task data from presentation; import/export themes. |
| Documents/export | Markdown, JSON, local file links | Human-readable and portable; link artifacts at their original locations. |

Pin and verify library and minimum macOS versions through builds. The initial target is Apple Silicon, with macOS 14 as the app baseline. Distribution must account for native desktop-widget support. The core installs no Python environment, amem, or vault.

## Development and operations

| Area | Direction | Reason |
| --- | --- | --- |
| Notifications | UserNotifications | Planned delivery of review, blocked, and completion notifications. |
| Display preferences | UserDefaults | Keep presentation independent of task data. |
| Diagnostics | Swift OSLog and structured Rust diagnostics | Trace failures; retain task history separately in SQLite. Choose any additional Rust logging library during implementation. |
| Backup | SQLite online backup, Markdown/JSON export | Consistent database copies and independently readable task content. |
| Core checks | cargo test | State transitions, concurrent claims, retries, migrations. |
| Swift checks | Swift Testing, XCTest, XCUITest | Request contracts, interactions, app/widget integration. Standalone runners support Command Line Tools environments. |
| Build | Cargo, Xcode, Swift Package Manager | Package Rust executables, Swift app, and widget in one release. |
| Version control | Git | Track design and implementation together. Project materials and commits use English. |
| Distribution | App bundle containing CLI/service/widget, DMG; separate plugin packages | Keep component versions aligned. External distribution requires Developer ID signing and notarization. Integration dependencies remain in their plugins. |

## Why Rust

Rust suits frequently invoked CLIs and long-running local services. Executable-based distribution and strict state/concurrency modeling are useful. Measure actual startup, memory, and processing performance.

Existing amem uses SQLite search and PDFium extraction, so Python does not execute all underlying work. A language change alone does not establish an overall speedup. Verify search quality, source locations, and memory policy compatibility as well.

Start with process communication rather than broad Swift/Rust function bindings. Logged requests are reproducible and each implementation can change independently. This adds JSON serialization and reconnection costs.

## Changes from the initial Swift proposal

| Earlier option | Current direction |
| --- | --- |
| Swift core and Swift Argument Parser | Rust core and clap |
| GRDB database access | rusqlite database access |
| XPC-centered transport | Unix sockets and versioned JSON |
| SwiftUI app and WidgetKit | Retained |
| Python amem CLI connection | Separate installable plugin, disabled by default; any Rust port is independent |

Choose Tokio only after measuring concurrent-connection or subscription needs. The current synchronous socket service and per-connection threads can be sufficient. Preserve the SQLite source and external request contract if the core implementation changes.

## References

- [Rust CLI guide](https://doc.rust-lang.org/book/ch12-00-an-io-project.html)
- [clap](https://docs.rs/clap/latest/clap/)
- [Serde](https://serde.rs/)
- [rusqlite](https://github.com/rusqlite/rusqlite/blob/master/README.md)
- [Rust Unix sockets](https://doc.rust-lang.org/std/os/unix/net/index.html)
- [Tokio UnixListener](https://docs.rs/tokio/latest/tokio/net/struct.UnixListener.html)
- [SQLite WAL](https://sqlite.org/wal.html)
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [WidgetKit shared data](https://developer.apple.com/documentation/WidgetKit/Developing-a-WidgetKit-strategy)
- [WidgetKit refresh](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
