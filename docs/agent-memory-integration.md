# agent-memory plugin

agent-memory is a separately installed plugin, excluded from the core and disabled after installation. Tasks, subtasks, CLI, board, widget, search, attachments, backup, and export work without it. The core installs and runs without Python or amem.

After installation and enabling, the plugin uses the amem CLI for external memory search/capture. The board always owns task state and resume context. See the shared [plugin boundary](architecture.md#plugin-boundary).

## Setup and disconnection

Configure an executable path when enabling the integration; never hardcode a particular user's path. Core users need no memory configuration.

Extract `AgentWorkboard-plugin-agent-memory-0.1.0.zip`. Select the `agent-memory-0.1.0` directory containing `plugin.json` and `plugin.py` in the app, or pass that directory to the CLI. Do not install the ZIP itself. Rebuild packages with `scripts/package-plugins.sh`. Installation alone leaves the plugin disabled.

```sh
workboard plugin install ./plugins/agent-memory
workboard plugin enable agent-memory --config '{"executable":"/absolute/path/to/amem"}'
workboard plugin check agent-memory
workboard plugin disable agent-memory
```

| State | Behavior |
| --- | --- |
| Not installed | No integration code/dependencies in the core; no loading or external executable discovery. |
| Disabled | No executable discovery/invocation or memory configuration/data reads; core tasks remain available. |
| Enabled | Only requested searches/reads and explicitly selected memory captures. |
| Connection failure | Show an integration error and last verified state; preserve core CLI/app/widget workflows. |
| Disconnected | Stop new external calls; preserve tasks, artifacts, evidence locations, and last verification metadata. |
| Removed | Apply the same preservation rules and remove the package; core remains usable. |

Enabling alone neither imports all memories nor saves conversations. Default health reporting shows configuration and last-known state without invoking external tools. Detailed connection checks run only on explicit request.

## External resources

| Resource | Example |
| --- | --- |
| Installed CLI | `~/.local/bin/amem` or a user-selected executable |
| Implementation | Separately maintained agent-memory project |
| Agent contract | External `docs/agent-contract.md` |
| Memory lifecycle | External `docs/memory-lifecycle.md` |
| Memory schema | External `vault/SCHEMA.md` |

The existing engine is Python-based. A Rust board can retain its CLI boundary and search rules without reading or modifying the index tables directly. These resources need not exist for core operation.

## Search and evidence

A task can start with only a goal, completion criteria, and next action. Ordinary file/URL attachments require no memory connection. When explicitly requested with the integration enabled:

1. Choose a collection appropriate to the project and question.
2. Select relevant sources from a small result set.
3. Read the source and location with `amem read`.
4. Attach the original path, collection, location, and verification metadata. Pass the search query too, so a later check can rediscover the source.

The plugin does not update external indexes automatically. Follow existing amem administration procedures when source refresh is needed.

```sh
workboard plugin run agent-memory search --params '{"collection":"research","query":"specific evidence needed for this task","limit":3}'
workboard plugin run agent-memory read --params '{"ref":"SEARCH_REF"}'
workboard plugin run agent-memory attach --params '{"task_id":"TASK_ID","ref":"SEARCH_REF","collection":"research","query":"specific evidence needed for this task"}'
workboard plugin run agent-memory verify --params '{"artifact":ARTIFACT_FROM_TASK_GET}'
```

`attach` sets the artifact's `provider`, `locator`, and `verified_at` fields and keeps the same values in its metadata.

Apply identical project/domain scopes to search and read. Use reviewed memory by default and distinguish inbox candidates in review workflows.

## Durable links

amem refs belong to source generations. Failure after a source changes is expected. Store more than the temporary ref:

- Collection and canonical path.
- Page, line, or section location.
- Verified content hash or source version.
- Verification time and attachment reason.
- Optional rediscovery query and scope.

`verify` is read-only. Pass it an attached artifact as `task get` returns it. It rereads the stored ref with the stored scope and reports one of these states:

| Status | Meaning |
| --- | --- |
| `current` | amem returns the same path, collection, and content hash. |
| `changed` | The ref still reads, but the path, collection, or hash differs. |
| `unreadable` | amem rejected the ref, usually because the source was reindexed. `detail` holds the amem message. |

For `changed` or `unreadable`, `verify` searches the same collection and scope again. It uses the stored query, or a `query` passed to `verify` for evidence attached before queries were stored. Candidates on the original path carry `same_path: true`. Read a candidate and `attach` it to record the current source. Without a query, `verify` does not search. If amem cannot start or times out, `verify` fails with `INTEGRATION_UNAVAILABLE` instead of reporting a source state.

`verify` compares against amem's current index. It does not refresh the index; follow the existing amem procedures for that. The board does not yet store a stale flag on the earlier artifact, because the service has no artifact update request. The earlier artifact keeps its last verified metadata. Never guess or construct refs manually. While disabled, show last verified metadata and paths without external reads.

## Results and memory candidates

Artifacts/resume summaries are operational board data. Only user-requested decisions/procedures are sent to `amem capture` as inbox candidates when enabled. While disabled, keep results in the board. Completed tasks and conversations do not automatically become reviewed long-term memory.

Candidates link source task/artifact paths, project scope, creation time, and selected content. `capture` accepts `task_id` and `artifact_path` and records them in the amem `source` field, for example `Agent Workboard; task TASK_ID; artifact PATH`. It maps `project` or `domain` to the amem scope `project:<name>` or `domain:<name>`, and uses `global` when neither is given. A candidate takes one scope, so passing both is rejected. amem records the creation time. The body is sent on standard input and other user text as `--option=value`, so text that starts with a dash stays literal. Promotion follows the existing provenance, sensitivity, expiry, and conflict review policies.

Board writes and external capture are not one atomic transaction. The host journal and plugin record reuse completed responses for identical requests. If the external outcome is uncertain, refuse automatic recapture and ask for inbox verification. This does not add idempotent storage to amem itself.

## Failure isolation

Handle missing executables, permissions, malformed responses, and timeouts without blocking core create/edit/search/resume or app/widget startup. Do not hold core write transactions during external calls. Request board changes through the service, never direct database writes.

Absent plugins return `PLUGIN_NOT_INSTALLED`; disabled plugins return `PLUGIN_DISABLED`. Do not install/enable automatically. An enabled plugin returns `INVALID_REQUEST` for missing or malformed input, before it runs amem. A missing executable, timeout, amem failure, or malformed amem response returns `INTEGRATION_UNAVAILABLE`. A capture request ID reused for different content returns `REQUEST_ID_CONFLICT`, and an earlier capture with an unknown outcome returns `PLUGIN_RESULT_UNCERTAIN`. Reinstallation/reconnection adds memory features to existing tasks without importing or converting them.

## Obsidian

Obsidian optionally reads/edits linked Markdown. Existing agent-memory also supports PDF, code, and other sources. Neither the board nor amem requires Obsidian or its plugins.

## Verification

Fifteen fake-executable checks originally covered scope preservation, source headers, errors, explicit capture, and deduplication. A disposable board also verified one real research search, source read, and evidence attachment with hash/location using installed amem. External sources were not changed; sync and actual capture were not run. No plugin was installed in the user's default board. See [verification](verification.md).

On October 16, 2026, the fake-executable suite grew to 24 checks covering `verify`, capture scope and source links, literal leading dashes, and error codes. A second check used the installed amem engine with a disposable amem home (`amem --home`, synthetic demo documents) and a disposable board:

- `attach` filled the artifact's `provider`, `locator`, and `verified_at` fields and stored the search query.
- `verify` reported `current`. After the synthetic source was edited and the disposable home resynced, it reported `unreadable` with amem's "Document changed since search" message and found a candidate on the same path.
- Attaching that candidate added a second artifact with the new hash, and `verify` reported `current` for it.
- `capture` wrote one private inbox card with scope `project:agent-workboard`, a source naming the task and artifact, and the literal title `-verbose` and body `--help`. A retry with the same request ID wrote nothing new. Passing both `project` and `domain` returned `INVALID_REQUEST`.

The user's amem home, index, and inbox were not used. Capture into a real user inbox and its review flow remain unverified.

## Rust port criteria

Verify standalone board operation first and ship the existing Python-CLI plugin separately. A memory-engine port requires separate startup/search/indexing/memory measurements and must not block board installation or release.

After any port, verify commands/responses, multilingual search, evidence locations, scopes, expired refs, and review policies. Preserve originals and rebuild comparison indexes separately. Do not use operational indexes or durable feedback stores as experimental data.

## References

The external project is not vendored here. Refer to its:

- CLI: `src/agent_memory/cli.py`.
- Architecture/ref rules: `docs/architecture.md`.
- Memory capture contract: `docs/memory-lifecycle.md`.
