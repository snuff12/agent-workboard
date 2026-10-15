//! Agent session support: identity, project lookup by repository, session context, and
//! session-start hooks for Claude Code and Codex. Everything here only reads the board.
use crate::Client;
use clap::{Subcommand, ValueEnum};
use serde_json::{json, Value};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The protocol that agents follow. Skills and launch prompts use this same text.
pub const PROTOCOL: &str = include_str!("../../../integrations/agents/protocol.md");

/// Requests that act for an agent. The CLI adds the session's agent ID when none is given.
pub const IDENTIFIED_METHODS: [&str; 13] = [
    "task.claim",
    "task.start",
    "task.review",
    "task.complete",
    "task.pause",
    "task.heartbeat",
    "task.release",
    "task.update",
    "task.attach",
    "task.delete",
    "project.delete",
    "run.update",
    "run.finish",
];

#[derive(Subcommand)]
pub enum AgentCommand {
    #[command(about = "Summarize board work for the current directory and agent")]
    Context {
        #[arg(long, help = "Directory to match with a board project")]
        cwd: Option<PathBuf>,
    },
    #[command(about = "Print the protocol that agents follow")]
    Brief,
    #[command(
        about = "Session-start hook for an agent tool. Reads the hook JSON on stdin and never fails"
    )]
    Hook {
        #[arg(long, value_enum)]
        client: HookClient,
    },
}

#[derive(Clone, Copy, ValueEnum)]
pub enum HookClient {
    Claude,
    Codex,
}

/// The agent ID for this process: an explicit `WORKBOARD_AGENT`, else the Codex thread.
pub fn identity() -> Option<String> {
    identity_from(
        std::env::var("WORKBOARD_AGENT").ok().as_deref(),
        std::env::var("CODEX_THREAD_ID").ok().as_deref(),
    )
}

pub fn identity_from(explicit: Option<&str>, codex_thread: Option<&str>) -> Option<String> {
    if let Some(agent) = explicit.map(str::trim).filter(|value| !value.is_empty()) {
        return Some(agent.to_string());
    }
    codex_thread.and_then(|thread| session_agent("codex", thread))
}

/// `claude:1a2b3c4d` from a session ID. Short enough to read, unique enough for one Mac.
pub fn session_agent(tool: &str, session: &str) -> Option<String> {
    let short: String = session
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(8)
        .collect();
    (!short.is_empty()).then(|| format!("{tool}:{}", short.to_ascii_lowercase()))
}

/// The shared git directory of the repository containing `path`, so that every worktree of a
/// repository maps to the same key. Reads `.git` files directly and runs no external program.
pub fn repository(path: &Path) -> Option<PathBuf> {
    for directory in path.ancestors() {
        let dot_git = directory.join(".git");
        let Ok(metadata) = fs::metadata(&dot_git) else {
            continue;
        };
        if metadata.is_dir() {
            return dot_git.canonicalize().ok();
        }
        let text = fs::read_to_string(&dot_git).ok()?;
        let target = text
            .lines()
            .find_map(|line| line.strip_prefix("gitdir:"))?
            .trim();
        let git_dir = directory.join(target);
        // A linked worktree's git directory names the shared directory in its `commondir` file.
        let common = fs::read_to_string(git_dir.join("commondir"))
            .ok()
            .map(|relative| git_dir.join(relative.trim()))
            .unwrap_or(git_dir);
        return common.canonicalize().ok();
    }
    None
}

/// A project matches when it shares the repository with `cwd`, or contains `cwd`.
pub fn project_matches(project_directory: &str, cwd: &Path, cwd_repository: Option<&Path>) -> bool {
    let directory = Path::new(project_directory);
    if project_directory.trim().is_empty() || !directory.is_absolute() {
        return false;
    }
    if let (Some(left), Some(right)) = (repository(directory), cwd_repository) {
        if left == right {
            return true;
        }
    }
    match (directory.canonicalize(), cwd.canonicalize()) {
        (Ok(project), Ok(current)) => current.starts_with(project),
        _ => false,
    }
}

fn line(task: &Value, detail: &str) -> String {
    let mut text = format!(
        "- {} (id {}, revision {}, {})",
        task["title"].as_str().unwrap_or("Untitled"),
        task["id"].as_str().unwrap_or("?"),
        task["revision"],
        task["status"].as_str().unwrap_or("?")
    );
    if !detail.is_empty() {
        text.push_str(" — ");
        text.push_str(detail);
    }
    text
}

fn section(out: &mut Vec<String>, title: &str, items: Vec<String>, limit: usize) {
    if items.is_empty() {
        return;
    }
    out.push(format!("{title}:"));
    let hidden = items.len().saturating_sub(limit);
    out.extend(items.into_iter().take(limit));
    if hidden > 0 {
        out.push(format!("- and {hidden} more"));
    }
}

/// A short plain-text summary for the start of an agent session.
pub fn context(
    client: &Client,
    cwd: &Path,
    agent: Option<&str>,
    start_service: bool,
    timeout: Duration,
) -> Result<String, String> {
    let call = |method: &str, params: Value| -> Result<Value, String> {
        let response = client.request(
            method,
            params,
            &uuid::Uuid::new_v4().to_string(),
            start_service,
            timeout,
        );
        if response["ok"] == true {
            Ok(response["result"].clone())
        } else {
            Err(response["error"]["message"]
                .as_str()
                .unwrap_or("The board request failed.")
                .to_string())
        }
    };
    let board = call("board.snapshot", json!({}))?;
    let empty = vec![];
    let tasks = board["tasks"].as_array().unwrap_or(&empty);
    let cwd_repository = repository(cwd);
    let projects: Vec<&Value> = board["projects"]
        .as_array()
        .unwrap_or(&empty)
        .iter()
        .filter(|p| {
            project_matches(
                p["directory"].as_str().unwrap_or(""),
                cwd,
                cwd_repository.as_deref(),
            )
        })
        .collect();
    let in_project = |task: &&Value| {
        projects
            .iter()
            .any(|project| project["id"] == task["project_id"])
    };
    let mut out = vec![match agent {
        Some(agent) => format!("Agent Workboard: you are `{agent}` on this board."),
        None => "Agent Workboard: no agent ID is set. Pass `--agent <id>` when you claim work."
            .to_string(),
    }];
    if projects.is_empty() {
        out.push(format!(
            "No board project matches {}. Work normally; capture board-worthy follow-ups with `workboard inbox capture`.",
            cwd.display()
        ));
    } else {
        let names: Vec<&str> = projects
            .iter()
            .map(|p| p["name"].as_str().unwrap_or("?"))
            .collect();
        out.push(format!("Project: {}.", names.join(", ")));
    }
    let mine: Vec<String> = tasks
        .iter()
        .filter(|t| agent.is_some() && t["assignee"].as_str() == agent && t["status"] != "done")
        .map(|t| line(t, t["next_action"].as_str().unwrap_or("")))
        .collect();
    section(&mut out, "Your tasks", mine, 5);
    let others: Vec<String> = tasks
        .iter()
        .filter(in_project)
        .filter(|t| t["status"] == "in_progress" && t["assignee"].as_str() != agent)
        .map(|t| line(t, t["assignee"].as_str().unwrap_or("unassigned")))
        .collect();
    section(&mut out, "In progress by others", others, 5);
    let review: Vec<String> = tasks
        .iter()
        .filter(in_project)
        .filter(|t| t["status"] == "review")
        .map(|t| line(t, "waiting for the user"))
        .collect();
    section(&mut out, "Waiting for review", review, 5);
    for project in &projects {
        let ready = call(
            "task.list",
            json!({"project_id":project["id"],"status":"todo","ready_only":true}),
        )?;
        let items: Vec<String> = ready["tasks"]
            .as_array()
            .unwrap_or(&empty)
            .iter()
            .filter(|t| t["assignee"].is_null())
            .map(|t| line(t, t["next_action"].as_str().unwrap_or("")))
            .collect();
        section(
            &mut out,
            &format!(
                "Ready to start in {}",
                project["name"].as_str().unwrap_or("?")
            ),
            items,
            5,
        );
    }
    if let Ok(inbox) = call("inbox.list", json!({"status":"open"})) {
        let open = inbox["items"].as_array().map(Vec::len).unwrap_or(0);
        if open > 0 {
            out.push(format!("Inbox: {open} open item(s) for the user to sort."));
        }
    }
    out.push(
        "Claim a task only when the user's request clearly matches it. Request review instead of completing. Run `workboard agent brief` for the full protocol."
            .to_string(),
    );
    Ok(out.join("\n"))
}

/// Writes `export WORKBOARD_AGENT=…` for later Bash commands in a Claude Code session.
fn export_identity(env_file: &Path, agent: &str) -> std::io::Result<()> {
    let quoted = agent.replace('\'', "'\\''");
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(env_file)?;
    writeln!(file, "export WORKBOARD_AGENT='{quoted}'")
}

/// Session-start hook. Prints `hookSpecificOutput.additionalContext` JSON, or nothing when the
/// board is unavailable. It never starts the service, never blocks the session, and exits 0.
pub fn hook(client: &Client, tool: HookClient) {
    let mut input = String::new();
    let _ = std::io::stdin()
        .take(1024 * 1024)
        .read_to_string(&mut input);
    let event: Value = serde_json::from_str(&input).unwrap_or(json!({}));
    let session = event["session_id"].as_str().unwrap_or("");
    let cwd = event["cwd"]
        .as_str()
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_default();
    let prefix = match tool {
        HookClient::Claude => "claude",
        HookClient::Codex => "codex",
    };
    // A launcher such as the Orca plugin may already have chosen the agent ID; keep it.
    let preset = std::env::var("WORKBOARD_AGENT")
        .ok()
        .filter(|value| !value.trim().is_empty());
    let agent = preset.clone().or_else(|| match tool {
        HookClient::Codex => identity_from(None, std::env::var("CODEX_THREAD_ID").ok().as_deref())
            .or_else(|| session_agent(prefix, session)),
        HookClient::Claude => session_agent(prefix, session),
    });
    if let (HookClient::Claude, None, Some(agent), Some(env_file)) =
        (tool, &preset, &agent, std::env::var_os("CLAUDE_ENV_FILE"))
    {
        let _ = export_identity(Path::new(&env_file), agent);
    }
    if let Ok(text) = context(
        client,
        &cwd,
        agent.as_deref(),
        false,
        Duration::from_secs(2),
    ) {
        println!(
            "{}",
            json!({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":text}})
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_prefers_the_explicit_agent_then_the_codex_thread() {
        assert_eq!(
            identity_from(Some(" orca:codex "), Some("0199-abcd")).as_deref(),
            Some("orca:codex")
        );
        assert_eq!(
            identity_from(Some(""), Some("0199ABCD-ef01-2345")).as_deref(),
            Some("codex:0199abcd")
        );
        assert_eq!(identity_from(None, None), None);
        assert_eq!(session_agent("claude", "---"), None);
    }

    #[test]
    fn worktrees_share_the_repository_key_of_their_main_checkout() {
        let root = tempfile::tempdir().unwrap();
        let main = root.path().join("projects/app");
        let common = main.join(".git");
        fs::create_dir_all(common.join("worktrees/feature")).unwrap();
        fs::write(common.join("worktrees/feature/commondir"), "../..\n").unwrap();
        let worktree = root.path().join("workspaces/app-feature");
        fs::create_dir_all(worktree.join("src")).unwrap();
        fs::write(
            worktree.join(".git"),
            format!("gitdir: {}\n", common.join("worktrees/feature").display()),
        )
        .unwrap();
        assert_eq!(repository(&main), common.canonicalize().ok());
        assert_eq!(
            repository(&worktree.join("src")),
            common.canonicalize().ok()
        );
        let cwd = worktree.join("src");
        assert!(project_matches(
            main.to_str().unwrap(),
            &cwd,
            repository(&cwd).as_deref()
        ));
        let other = root.path().join("elsewhere");
        fs::create_dir_all(&other).unwrap();
        assert!(!project_matches(
            other.to_str().unwrap(),
            &cwd,
            repository(&cwd).as_deref()
        ));
        assert!(!project_matches("relative/path", &cwd, None));
    }

    #[test]
    fn claude_identity_is_exported_as_a_quoted_shell_assignment() {
        let directory = tempfile::tempdir().unwrap();
        let env_file = directory.path().join("env");
        export_identity(&env_file, "claude:ab'cd").unwrap();
        assert_eq!(
            fs::read_to_string(env_file).unwrap(),
            "export WORKBOARD_AGENT='claude:ab'\\''cd'\n"
        );
    }
}
