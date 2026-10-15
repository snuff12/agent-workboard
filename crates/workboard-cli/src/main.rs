mod agent;
mod cancellation;
mod journal;
mod plugins;
mod workflow;

use clap::{Args, Parser, Subcommand};
use fs2::FileExt;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Parser)]
#[command(
    name = "workboard",
    version,
    about = "A local workboard for agents and people"
)]
struct Cli {
    #[arg(long, global = true)]
    json: bool,
    #[arg(long, global = true, env = "WORKBOARD_DATA_DIR")]
    data_dir: Option<PathBuf>,
    #[arg(long, global = true, env = "WORKBOARD_SOCKET")]
    socket: Option<PathBuf>,
    #[arg(long, global = true)]
    request_id: Option<String>,
    #[arg(long, global = true)]
    expected_revision: Option<i64>,
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    #[command(about = "Manage projects")]
    Project {
        #[command(subcommand)]
        command: ProjectCommand,
    },
    #[command(about = "Manage tasks and subtasks")]
    Task {
        #[command(subcommand)]
        command: TaskCommand,
    },
    #[command(about = "Execute a shared JSON request")]
    Rpc {
        method: String,
        #[arg(long, default_value = "{}")]
        params: String,
    },
    #[command(about = "Show the complete board")]
    Board,
    #[command(about = "Show change history")]
    Events {
        #[arg(long, default_value_t = 0)]
        after: i64,
        #[arg(long)]
        watch: bool,
    },
    #[command(about = "Check core health")]
    Doctor,
    #[command(about = "Run the service directly")]
    Serve,
    #[command(about = "Back up and restore")]
    Backup {
        #[command(subcommand)]
        command: BackupCommand,
    },
    #[command(about = "Export JSON or Markdown")]
    Export {
        #[arg(long)]
        path: Option<PathBuf>,
        #[arg(long, default_value = "json")]
        format: String,
    },
    #[command(about = "Manage separately installed plugins")]
    Plugin {
        #[command(subcommand)]
        command: PluginCommand,
    },
    #[command(about = "Task and subtask templates")]
    Template {
        #[command(subcommand)]
        command: workflow::TemplateCommand,
    },
    #[command(about = "Quick capture and task conversion")]
    Inbox {
        #[command(subcommand)]
        command: workflow::InboxCommand,
    },
    #[command(about = "Saved filters and view layouts")]
    View {
        #[command(subcommand)]
        command: workflow::ViewCommand,
    },
    #[command(about = "Agent session context, protocol, and session-start hooks")]
    Agent {
        #[command(subcommand)]
        command: agent::AgentCommand,
    },
}

#[derive(Subcommand)]
enum ProjectCommand {
    List,
    Add {
        #[arg(long)]
        name: String,
        #[arg(long, default_value = ".")]
        directory: String,
    },
    #[command(about = "Delete a project. Use --with-tasks to delete its tasks as well")]
    Delete {
        project_id: String,
        #[arg(long)]
        with_tasks: bool,
        #[arg(long)]
        agent: Option<String>,
    },
}

#[derive(Args)]
struct TaskInput {
    #[arg(long)]
    project: String,
    #[arg(long)]
    title: String,
    #[arg(long)]
    parent: Option<String>,
    #[arg(long, default_value = "")]
    goal: String,
    #[arg(long, default_value = "")]
    completion_criteria: String,
    #[arg(long, default_value_t = 0)]
    priority: i64,
    #[arg(long)]
    next_action: Option<String>,
    #[arg(long, alias = "due")]
    due_at: Option<String>,
    #[arg(long, alias = "starts")]
    scheduled_start: Option<String>,
    #[arg(long, alias = "ends")]
    scheduled_end: Option<String>,
    #[arg(long)]
    time_zone: Option<String>,
}

#[derive(Subcommand)]
enum TaskCommand {
    Add(TaskInput),
    List(workflow::TaskList),
    #[command(about = "List tasks ready to start after their prerequisites are complete")]
    Ready(workflow::TaskList),
    #[command(alias = "depends", about = "Manage task dependencies")]
    Dependency {
        #[command(subcommand)]
        command: workflow::DependencyCommand,
    },
    #[command(about = "Manage completion checklists")]
    Checklist {
        #[command(subcommand)]
        command: workflow::ChecklistCommand,
    },
    #[command(about = "Approve a review, request changes, or reject it")]
    Decide(workflow::ReviewDecision),
    #[command(about = "Preview schedule conflicts before saving")]
    SchedulePreview(workflow::SchedulePreview),
    Show {
        task_id: String,
    },
    Update {
        task_id: String,
        #[arg(long)]
        title: Option<String>,
        #[arg(long)]
        goal: Option<String>,
        #[arg(long)]
        completion_criteria: Option<String>,
        #[arg(long)]
        status: Option<String>,
        #[arg(long)]
        priority: Option<i64>,
        #[arg(long)]
        next_action: Option<String>,
        #[arg(long)]
        blocked_reason: Option<String>,
        #[arg(long)]
        completion_summary: Option<String>,
        #[arg(long)]
        parent: Option<String>,
        #[arg(long, alias = "due")]
        due_at: Option<String>,
        #[arg(long, alias = "starts")]
        scheduled_start: Option<String>,
        #[arg(long, alias = "ends")]
        scheduled_end: Option<String>,
        #[arg(long)]
        time_zone: Option<String>,
    },
    Claim {
        task_id: String,
        #[arg(long, help = "Defaults to WORKBOARD_AGENT or the Codex thread")]
        agent: Option<String>,
    },
    #[command(about = "Refresh the claim of a task you hold")]
    Heartbeat {
        task_id: String,
        #[arg(long)]
        agent: Option<String>,
    },
    #[command(about = "Release a task you hold and interrupt its running run")]
    Release {
        task_id: String,
        #[arg(long)]
        agent: Option<String>,
    },
    #[command(about = "Pause unfinished work with its state and next action")]
    Pause {
        task_id: String,
        #[arg(long)]
        summary: String,
        #[arg(long)]
        next_action: Option<String>,
        #[arg(long)]
        run: Option<String>,
        #[arg(long)]
        agent: Option<String>,
    },
    Start {
        task_id: String,
        #[arg(long)]
        agent: Option<String>,
        #[arg(long)]
        run: Option<String>,
    },
    Review {
        task_id: String,
        #[arg(long)]
        summary: String,
        #[arg(long)]
        agent: Option<String>,
        #[arg(long)]
        run: Option<String>,
    },
    Complete {
        task_id: String,
        #[arg(long)]
        summary: String,
        #[arg(long)]
        agent: Option<String>,
        #[arg(long)]
        run: Option<String>,
    },
    ResumeContext {
        task_id: String,
    },
    #[command(
        about = "Delete a task, its runs, and artifact links. Use --with-subtasks to include subtasks"
    )]
    Delete {
        task_id: String,
        #[arg(long)]
        with_subtasks: bool,
        #[arg(long)]
        agent: Option<String>,
    },
    Attach {
        task_id: String,
        #[arg(long)]
        source: String,
        #[arg(long, default_value = "file")]
        kind: String,
        #[arg(long, default_value = "")]
        description: String,
    },
}

#[derive(Subcommand)]
enum BackupCommand {
    Create { path: PathBuf },
    Restore { path: PathBuf },
}

#[derive(Subcommand, serde::Serialize)]
pub enum PluginCommand {
    List,
    /// Read saved settings without starting a plugin or the board service.
    Config {
        id: String,
    },
    Install {
        package: PathBuf,
    },
    Enable {
        id: String,
        #[arg(long)]
        executable: Option<String>,
        #[arg(long)]
        config: Option<String>,
    },
    Disable {
        id: String,
    },
    Remove {
        id: String,
    },
    Check {
        id: String,
    },
    Run {
        id: String,
        method: String,
        #[arg(long, default_value = "{}")]
        params: String,
        #[arg(long)]
        task: Option<String>,
        #[arg(long)]
        query: Option<String>,
        #[arg(long)]
        collection: Option<String>,
        #[arg(long)]
        source: Option<String>,
        #[arg(long)]
        locator: Option<String>,
    },
}

#[derive(Clone)]
pub struct Client {
    pub data_dir: PathBuf,
    pub socket: PathBuf,
}

pub fn failure(request_id: &str, code: &str, message: impl ToString) -> Value {
    json!({"schema_version":1,"request_id":request_id,"ok":false,"error":{"code":code,"message":message.to_string(),"retryable":false}})
}
pub fn success(request_id: &str, result: Value) -> Value {
    json!({"schema_version":1,"request_id":request_id,"ok":true,"result":result})
}

impl Client {
    fn existing_connection(&self) -> Result<Option<UnixStream>, String> {
        match UnixStream::connect(&self.socket) {
            Ok(stream) => {
                #[cfg(target_os = "macos")]
                unsafe {
                    let mut uid = 0;
                    let mut gid = 0;
                    if libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) != 0
                        || uid != libc::geteuid()
                    {
                        return Err("The service socket belongs to another user.".into());
                    }
                }
                #[cfg(target_os = "linux")]
                unsafe {
                    let mut creds: libc::ucred = std::mem::zeroed();
                    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
                    if libc::getsockopt(
                        stream.as_raw_fd(),
                        libc::SOL_SOCKET,
                        libc::SO_PEERCRED,
                        &mut creds as *mut _ as *mut _,
                        &mut len,
                    ) != 0
                        || creds.uid != libc::geteuid()
                    {
                        return Err("The service socket belongs to another user.".into());
                    }
                }
                Ok(Some(stream))
            }
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
                ) =>
            {
                Ok(None)
            }
            Err(e) => Err(e.to_string()),
        }
    }
    fn service_binary(&self) -> Result<PathBuf, String> {
        if let Some(path) = std::env::var_os("WORKBOARD_SERVICE_BIN") {
            return Ok(path.into());
        }
        let current = std::env::current_exe().map_err(|e| e.to_string())?;
        let candidate = current
            .parent()
            .unwrap_or(Path::new("."))
            .join("workboard-service");
        if candidate.exists() {
            Ok(candidate)
        } else {
            Err("Install the workboard-service executable next to the CLI.".into())
        }
    }
    fn connect(&self) -> Result<UnixStream, String> {
        if self.socket.as_os_str().len() > 103 {
            return Err(
                "The socket path is too long. Use --socket to specify a shorter path.".into(),
            );
        }
        if let Some(stream) = self.existing_connection()? {
            return Ok(stream);
        }
        if let Some(parent) = self.socket.parent() {
            if parent
                .to_string_lossy()
                .starts_with("/tmp/agent-workboard-")
            {
                if let Ok(info) = fs::symlink_metadata(parent) {
                    if info.file_type().is_symlink() || info.uid() != unsafe { libc::geteuid() } {
                        return Err("Could not verify ownership of the socket directory.".into());
                    }
                }
                fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
                    .map_err(|e| e.to_string())?;
            }
        }
        fs::create_dir_all(&self.data_dir).map_err(|e| e.to_string())?;
        fs::set_permissions(&self.data_dir, fs::Permissions::from_mode(0o700))
            .map_err(|e| e.to_string())?;
        let start_lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.data_dir.join("install.lock"))
            .map_err(|e| e.to_string())?;
        FileExt::lock_shared(&start_lock).map_err(|e| e.to_string())?;
        if let Some(stream) = self.existing_connection()? {
            return Ok(stream);
        }
        let log = OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.data_dir.join("service.log"))
            .map_err(|e| e.to_string())?;
        let error_log = log.try_clone().map_err(|e| e.to_string())?;
        let mut child = Command::new(self.service_binary()?)
            .args(["--data-dir"])
            .arg(&self.data_dir)
            .arg("--socket")
            .arg(&self.socket)
            .stdin(Stdio::null())
            .stdout(log)
            .stderr(error_log)
            .spawn()
            .map_err(|e| e.to_string())?;
        let start = Instant::now();
        loop {
            if let Some(stream) = self.existing_connection()? {
                return Ok(stream);
            }
            if start.elapsed() > Duration::from_secs(8) {
                return Err("The service connection timed out. Check service.log.".into());
            }
            // Reconnect after exit because another concurrently started CLI may have launched the service.
            let _ = child.try_wait();
            std::thread::sleep(Duration::from_millis(40));
        }
    }
    pub fn call(&self, method: &str, params: Value, request_id: &str) -> Value {
        self.request(method, params, request_id, true, Duration::from_secs(35))
    }
    /// `start_service: false` only uses a running service, as session hooks must stay fast.
    pub fn request(
        &self,
        method: &str,
        params: Value,
        request_id: &str,
        start_service: bool,
        read_timeout: Duration,
    ) -> Value {
        let params = match resolve_file_request_path(method, params) {
            Ok(params) => params,
            Err(message) => return failure(request_id, "INVALID_PARAMS", message),
        };
        let encoded = match request_frame(method, params, request_id) {
            Ok(encoded) => encoded,
            Err(response) => return response,
        };
        let result = (|| -> Result<Value, String> {
            let mut stream = if start_service {
                self.connect()?
            } else {
                self.existing_connection()?
                    .ok_or("The board service is not running.")?
            };
            stream
                .set_read_timeout(Some(read_timeout))
                .map_err(|e| e.to_string())?;
            stream
                .set_write_timeout(Some(Duration::from_secs(10)))
                .map_err(|e| e.to_string())?;
            stream.write_all(&encoded).map_err(|e| e.to_string())?;
            let mut response = String::new();
            // A trusted local service can return aggregate history larger than a request.
            // Truncating a committed mutation's response makes even an idempotent retry fail.
            BufReader::new(stream)
                .read_line(&mut response)
                .map_err(|e| e.to_string())?;
            if !response.ends_with('\n') {
                return Err(
                    "The connection closed before the service response was complete.".into(),
                );
            }
            let value: Value = serde_json::from_str(&response)
                .map_err(|e| format!("Invalid service response: {e}"))?;
            if value["request_id"] != request_id || value["schema_version"] != 1 {
                return Err("The service response protocol does not match.".into());
            }
            Ok(value)
        })();
        result.unwrap_or_else(|message| failure(request_id, "SERVICE_UNAVAILABLE", message))
    }
}

fn request_frame(method: &str, params: Value, request_id: &str) -> Result<Vec<u8>, Value> {
    let request =
        json!({"schema_version":1,"request_id":request_id,"method":method,"params":params});
    let mut encoded = serde_json::to_vec(&request)
        .map_err(|error| failure(request_id, "INVALID_PARAMS", error))?;
    encoded.push(b'\n');
    if encoded.len() > 1024 * 1024 {
        return Err(failure(
            request_id,
            "REQUEST_TOO_LARGE",
            "Requests must not exceed 1 MiB, including the newline.",
        ));
    }
    Ok(encoded)
}

fn resolve_file_request_path(method: &str, mut params: Value) -> Result<Value, String> {
    if matches!(method, "backup.create" | "backup.restore" | "export") {
        if let Some(path) = params["path"].as_str().filter(|value| !value.is_empty()) {
            let path = PathBuf::from(path);
            if path.is_relative() {
                let absolute = std::env::current_dir()
                    .map_err(|error| {
                        format!("Could not resolve the current working directory: {error}")
                    })?
                    .join(path);
                params["path"] = json!(absolute);
            }
        }
    }
    Ok(params)
}

fn params_object(pairs: Vec<(&str, Option<Value>)>) -> Value {
    Value::Object(
        pairs
            .into_iter()
            .filter_map(|(k, v)| v.map(|v| (k.into(), v)))
            .collect(),
    )
}
fn string(value: Option<String>) -> Option<Value> {
    value.map(Value::String)
}
fn output(value: &Value, json_output: bool) {
    if json_output {
        println!("{}", value);
        return;
    }
    if value["ok"] == false {
        eprintln!(
            "{}: {}",
            value["error"]["code"].as_str().unwrap_or("ERROR"),
            value["error"]["message"]
                .as_str()
                .unwrap_or("Request failed")
        );
    } else {
        println!(
            "{}",
            serde_json::to_string_pretty(&value["result"]).unwrap()
        );
    }
}

fn workflow_request(
    request: Result<(String, Value), String>,
    request_id: &str,
    json_output: bool,
) -> (String, Value) {
    request.unwrap_or_else(|message| {
        output(&failure(request_id, "INVALID_PARAMS", message), json_output);
        std::process::exit(2)
    })
}

fn main() {
    let cli = Cli::parse();
    let data_dir = cli.data_dir.unwrap_or_else(|| {
        PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
            .join("Library/Application Support/AgentWorkboard")
    });
    let data_dir = if data_dir.is_absolute() {
        data_dir
    } else {
        std::env::current_dir().unwrap_or_default().join(data_dir)
    };
    let socket = cli.socket.unwrap_or_else(|| {
        let direct = data_dir.join("workboard.sock");
        if direct.as_os_str().len() <= 100 {
            direct
        } else {
            let digest = format!(
                "{:x}",
                Sha256::digest(data_dir.as_os_str().as_encoded_bytes())
            );
            PathBuf::from(format!(
                "/tmp/agent-workboard-{}/{}.sock",
                unsafe { libc::geteuid() },
                &digest[..16]
            ))
        }
    });
    let client = Client { data_dir, socket };
    let request_id = cli
        .request_id
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    if matches!(cli.command, Commands::Serve) {
        let result = client.service_binary().and_then(|binary| {
            Command::new(binary)
                .arg("--data-dir")
                .arg(&client.data_dir)
                .arg("--socket")
                .arg(&client.socket)
                .status()
                .map_err(|e| e.to_string())
        });
        match result {
            Ok(status) => std::process::exit(status.code().unwrap_or(1)),
            Err(e) => {
                output(&failure(&request_id, "SERVICE_UNAVAILABLE", e), cli.json);
                std::process::exit(1)
            }
        }
    }
    if let Commands::Agent { ref command } = cli.command {
        match command {
            agent::AgentCommand::Brief => print!("{}", agent::PROTOCOL),
            agent::AgentCommand::Hook { client: tool } => agent::hook(&client, *tool),
            agent::AgentCommand::Context { cwd } => {
                let cwd = cwd
                    .clone()
                    .or_else(|| std::env::current_dir().ok())
                    .unwrap_or_default();
                let me = agent::identity();
                match agent::context(&client, &cwd, me.as_deref(), true, Duration::from_secs(35)) {
                    Ok(text) if cli.json => output(
                        &success(&request_id, json!({"agent":me,"context":text})),
                        true,
                    ),
                    Ok(text) => println!("{text}"),
                    Err(message) => {
                        output(
                            &failure(&request_id, "SERVICE_UNAVAILABLE", message),
                            cli.json,
                        );
                        std::process::exit(1)
                    }
                }
            }
        }
        std::process::exit(0);
    }
    if let Commands::Plugin { ref command } = cli.command {
        let response = plugins::execute(&client, command, &request_id);
        output(&response, cli.json);
        std::process::exit(if response["ok"] == true { 0 } else { 1 });
    }
    let is_rpc = matches!(cli.command, Commands::Rpc { .. });
    let (method, mut params) = match cli.command {
        Commands::Project { command } => match command {
            ProjectCommand::List => ("project.list".into(), json!({})),
            ProjectCommand::Add { name, directory } => (
                "project.create".into(),
                json!({"name":name,"directory":directory}),
            ),
            ProjectCommand::Delete {
                project_id,
                with_tasks,
                agent,
            } => (
                "project.delete".into(),
                params_object(vec![
                    ("project_id", Some(json!(project_id))),
                    ("with_tasks", Some(json!(with_tasks))),
                    ("agent_id", string(agent)),
                ]),
            ),
        },
        Commands::Task { command } => match command {
            TaskCommand::Add(input) => (
                "task.create".into(),
                params_object(vec![
                    ("project_id", Some(json!(input.project))),
                    ("parent_id", string(input.parent)),
                    ("title", Some(json!(input.title))),
                    ("goal", Some(json!(input.goal))),
                    (
                        "completion_criteria",
                        Some(json!(input.completion_criteria)),
                    ),
                    ("priority", Some(json!(input.priority))),
                    ("next_action", string(input.next_action)),
                    ("due_at", string(input.due_at)),
                    ("scheduled_start", string(input.scheduled_start)),
                    ("scheduled_end", string(input.scheduled_end)),
                    ("time_zone", string(input.time_zone)),
                ]),
            ),
            TaskCommand::List(input) => {
                workflow_request(input.request(false), &request_id, cli.json)
            }
            TaskCommand::Ready(input) => {
                workflow_request(input.request(true), &request_id, cli.json)
            }
            TaskCommand::Dependency { command } => {
                workflow_request(command.request(), &request_id, cli.json)
            }
            TaskCommand::Checklist { command } => {
                workflow_request(command.request(), &request_id, cli.json)
            }
            TaskCommand::Decide(input) => workflow_request(input.request(), &request_id, cli.json),
            TaskCommand::SchedulePreview(input) => {
                workflow_request(input.request(), &request_id, cli.json)
            }
            TaskCommand::Show { task_id } => ("task.get".into(), json!({"task_id":task_id})),
            TaskCommand::Update {
                task_id,
                title,
                goal,
                completion_criteria,
                status,
                priority,
                next_action,
                blocked_reason,
                completion_summary,
                parent,
                due_at,
                scheduled_start,
                scheduled_end,
                time_zone,
            } => (
                "task.update".into(),
                params_object(vec![
                    ("task_id", Some(json!(task_id))),
                    ("title", string(title)),
                    ("goal", string(goal)),
                    ("completion_criteria", string(completion_criteria)),
                    ("status", string(status)),
                    ("priority", priority.map(Value::from)),
                    ("next_action", string(next_action)),
                    ("blocked_reason", string(blocked_reason)),
                    ("completion_summary", string(completion_summary)),
                    ("parent_id", string(parent)),
                    ("due_at", string(due_at)),
                    ("scheduled_start", string(scheduled_start)),
                    ("scheduled_end", string(scheduled_end)),
                    ("time_zone", string(time_zone)),
                ]),
            ),
            TaskCommand::Claim { task_id, agent } => (
                "task.claim".into(),
                params_object(vec![
                    ("task_id", Some(json!(task_id))),
                    ("agent_id", string(agent)),
                ]),
            ),
            TaskCommand::Heartbeat { task_id, agent } => (
                "task.heartbeat".into(),
                params_object(vec![
                    ("task_id", Some(json!(task_id))),
                    ("agent_id", string(agent)),
                ]),
            ),
            TaskCommand::Release { task_id, agent } => (
                "task.release".into(),
                params_object(vec![
                    ("task_id", Some(json!(task_id))),
                    ("agent_id", string(agent)),
                ]),
            ),
            TaskCommand::Pause {
                task_id,
                summary,
                next_action,
                run,
                agent,
            } => (
                "task.pause".into(),
                params_object(vec![
                    ("task_id", Some(json!(task_id))),
                    ("summary", Some(json!(summary))),
                    ("next_action", string(next_action)),
                    ("run_id", string(run)),
                    ("agent_id", string(agent)),
                ]),
            ),
            TaskCommand::Start {
                task_id,
                agent,
                run,
            } => (
                "task.start".into(),
                params_object(vec![
                    ("task_id", Some(json!(task_id))),
                    ("agent_id", string(agent)),
                    ("run_id", string(run)),
                ]),
            ),
            TaskCommand::Review {
                task_id,
                summary,
                agent,
                run,
            } => (
                "task.review".into(),
                params_object(vec![
                    ("task_id", Some(json!(task_id))),
                    ("summary", Some(json!(summary))),
                    ("agent_id", string(agent)),
                    ("run_id", string(run)),
                ]),
            ),
            TaskCommand::Complete {
                task_id,
                summary,
                agent,
                run,
            } => (
                "task.complete".into(),
                params_object(vec![
                    ("task_id", Some(json!(task_id))),
                    ("summary", Some(json!(summary))),
                    ("agent_id", string(agent)),
                    ("run_id", string(run)),
                ]),
            ),
            TaskCommand::ResumeContext { task_id } => {
                ("task.resume_context".into(), json!({"task_id":task_id}))
            }
            TaskCommand::Delete {
                task_id,
                with_subtasks,
                agent,
            } => (
                "task.delete".into(),
                params_object(vec![
                    ("task_id", Some(json!(task_id))),
                    ("with_subtasks", Some(json!(with_subtasks))),
                    ("agent_id", string(agent)),
                ]),
            ),
            TaskCommand::Attach {
                task_id,
                source,
                kind,
                description,
            } => (
                "task.attach".into(),
                json!({"task_id":task_id,"path":source,"kind":kind,"description":description}),
            ),
        },
        Commands::Rpc { method, params } => match serde_json::from_str::<Value>(&params) {
            Ok(value) if value.is_object() => (method, value),
            _ => {
                output(
                    &failure(
                        &request_id,
                        "INVALID_PARAMS",
                        "--params must contain a JSON object.",
                    ),
                    cli.json,
                );
                std::process::exit(2)
            }
        },
        Commands::Board => ("board.snapshot".into(), json!({})),
        Commands::Doctor => ("doctor".into(), json!({})),
        Commands::Events { after, watch } => {
            if watch {
                let mut sequence = after;
                loop {
                    let response = client.call(
                        "events.list",
                        json!({"after":sequence}),
                        &uuid::Uuid::new_v4().to_string(),
                    );
                    if response["ok"] != true {
                        output(&response, cli.json);
                        std::process::exit(1)
                    }
                    let latest = response["result"]["event_sequence"]
                        .as_i64()
                        .unwrap_or(sequence);
                    if latest > sequence {
                        output(&response, cli.json);
                        sequence = latest;
                    }
                    std::thread::sleep(Duration::from_secs(1));
                }
            }
            ("events.list".into(), json!({"after":after}))
        }
        Commands::Backup { command } => match command {
            BackupCommand::Create { path } => ("backup.create".into(), json!({"path":path})),
            BackupCommand::Restore { path } => ("backup.restore".into(), json!({"path":path})),
        },
        Commands::Export { path, format } => {
            ("export".into(), json!({"path":path,"format":format}))
        }
        Commands::Template { command } => {
            workflow_request(command.request(), &request_id, cli.json)
        }
        Commands::Inbox { command } => workflow_request(command.request(), &request_id, cli.json),
        Commands::View { command } => workflow_request(command.request(), &request_id, cli.json),
        Commands::Plugin { .. } | Commands::Serve | Commands::Agent { .. } => unreachable!(),
    };
    // Agent sessions identify themselves without repeating --agent. Raw `rpc` stays explicit.
    if !is_rpc {
        if let Some(me) = agent::identity() {
            let fields = params.as_object_mut().unwrap();
            if agent::IDENTIFIED_METHODS.contains(&method.as_str()) {
                fields.entry("agent_id").or_insert(json!(me));
            } else if method == "inbox.capture" {
                fields.entry("source").or_insert(json!(me));
            }
        }
    }
    if let Some(revision) = cli.expected_revision {
        params
            .as_object_mut()
            .unwrap()
            .insert("expected_revision".into(), json!(revision));
    }
    let response = if method.starts_with("plugin.") {
        plugins::rpc(&client, &method, params, &request_id)
    } else {
        client.call(&method, params, &request_id)
    };
    output(&response, cli.json);
    std::process::exit(if response["ok"] == true { 0 } else { 1 });
}

#[cfg(test)]
mod protocol_tests {
    use super::*;

    #[test]
    fn request_limit_includes_the_newline_and_rejects_before_connecting() {
        let overhead = request_frame("probe", json!({"body":""}), "frame-limit")
            .unwrap()
            .len();
        let body = "x".repeat(1024 * 1024 - overhead);
        let boundary = request_frame("probe", json!({"body":body}), "frame-limit").unwrap();
        assert_eq!(boundary.len(), 1024 * 1024);
        assert_eq!(boundary.last(), Some(&b'\n'));
        assert_eq!(
            serde_json::from_slice::<Value>(&boundary).unwrap()["request_id"],
            "frame-limit"
        );
        let client = Client {
            data_dir: PathBuf::from("/nonexistent/workboard-frame-limit-data"),
            socket: PathBuf::from("/nonexistent/workboard-frame-limit.sock"),
        };
        let response = client.call(
            "probe",
            json!({"body":"x".repeat(1024 * 1024 - overhead + 1)}),
            "frame-limit",
        );
        assert_eq!(response["error"]["code"], "REQUEST_TOO_LARGE");
        assert_eq!(response["request_id"], "frame-limit");
    }
}
