//! Persistent local task model and versioned request dispatcher.
//! Only the service opens this database; clients use the JSON request protocol.
use chrono::{SecondsFormat, Utc};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    time::Duration,
};
use uuid::Uuid;

pub const SCHEMA_VERSION: u32 = 1;
pub const DATABASE_VERSION: u32 = 6;

mod trash;
mod workflow;
pub use workflow::ChecklistItem;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Request {
    pub schema_version: u32,
    pub request_id: String,
    pub method: String,
    #[serde(default = "empty_object")]
    pub params: Value,
}
fn empty_object() -> Value {
    json!({})
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ApiError {
    pub code: String,
    pub message: String,
    pub retryable: bool,
}
impl ApiError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            retryable: false,
        }
    }
}
impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}
impl std::error::Error for ApiError {}
impl From<rusqlite::Error> for ApiError {
    fn from(e: rusqlite::Error) -> Self {
        Self::new("DATABASE_ERROR", e.to_string())
    }
}
impl From<std::io::Error> for ApiError {
    fn from(e: std::io::Error) -> Self {
        Self::new("IO_ERROR", e.to_string())
    }
}
impl From<serde_json::Error> for ApiError {
    fn from(e: serde_json::Error) -> Self {
        Self::new("INVALID_REQUEST", e.to_string())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Response {
    pub schema_version: u32,
    pub request_id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ApiError>,
}
impl Response {
    pub fn success(id: impl Into<String>, result: Value) -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            request_id: id.into(),
            ok: true,
            result: Some(result),
            error: None,
        }
    }
    pub fn failure(id: impl Into<String>, error: ApiError) -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            request_id: id.into(),
            ok: false,
            result: None,
            error: Some(error),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Project {
    pub id: String,
    pub name: String,
    pub directory: String,
    pub created_at: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Task {
    pub id: String,
    pub project_id: String,
    pub parent_id: Option<String>,
    pub title: String,
    pub goal: String,
    pub completion_criteria: String,
    pub status: String,
    pub priority: i64,
    pub assignee: Option<String>,
    pub next_action: String,
    pub revision: i64,
    pub created_at: String,
    pub updated_at: String,
    pub blocked_reason: String,
    pub completion_summary: String,
    pub claimed_at: Option<String>,
    pub claim_expires_at: Option<String>,
    pub claim_stale: bool,
    pub due_at: Option<String>,
    pub scheduled_start: Option<String>,
    pub scheduled_end: Option<String>,
    pub time_zone: String,
    #[serde(default)]
    pub dependency_ids: Vec<String>,
    #[serde(default)]
    pub blocked_by: Vec<String>,
    #[serde(default)]
    pub ready: bool,
    #[serde(default)]
    pub checklist: Vec<ChecklistItem>,
    /// Set while the task waits in the trash. Live reads never return trashed tasks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deleted_at: Option<String>,
    /// Groups a task with the subtasks deleted in the same request, so they restore together.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deletion_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deleted_by: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Artifact {
    pub id: String,
    pub task_id: String,
    pub run_id: Option<String>,
    pub path: String,
    pub kind: String,
    pub description: String,
    pub created_at: String,
    pub locator: Option<String>,
    pub provider: Option<String>,
    pub verified_at: Option<String>,
    pub metadata: Value,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Run {
    pub id: String,
    pub task_id: String,
    pub agent_id: String,
    pub status: String,
    pub started_at: String,
    pub ended_at: Option<String>,
    pub summary: String,
    pub next_action: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Event {
    pub sequence: i64,
    pub request_id: String,
    pub task_id: Option<String>,
    pub kind: String,
    pub actor: Option<String>,
    pub created_at: String,
    pub data: Value,
}

pub fn default_data_dir() -> PathBuf {
    if let Some(path) = std::env::var_os("WORKBOARD_DATA_DIR") {
        return path.into();
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    #[cfg(target_os = "macos")]
    {
        home.join("Library/Application Support/AgentWorkboard")
    }
    #[cfg(not(target_os = "macos"))]
    {
        home.join(".local/share/agent-workboard")
    }
}
pub fn default_socket_path() -> PathBuf {
    std::env::var_os("WORKBOARD_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|| default_data_dir().join("workboard.sock"))
}
fn same_path(a: &Path, b: &Path) -> bool {
    a == b || matches!((a.canonicalize(),b.canonicalize()),(Ok(a),Ok(b)) if a==b)
}
fn now() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}
fn id() -> String {
    Uuid::new_v4().to_string()
}
fn invalid(message: impl Into<String>) -> ApiError {
    ApiError::new("INVALID_PARAMS", message)
}
fn required<'a>(p: &'a Value, key: &str) -> Result<&'a str, ApiError> {
    let s = p
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{key} must be a string")))?;
    if s.trim().is_empty() {
        return Err(invalid(format!("{key} must not be empty")));
    }
    Ok(s)
}
fn string(p: &Value, key: &str) -> Result<String, ApiError> {
    match p.get(key) {
        None | Some(Value::Null) => Ok(String::new()),
        Some(Value::String(s)) => Ok(s.clone()),
        _ => Err(invalid(format!("{key} must be a string"))),
    }
}
fn optional(p: &Value, key: &str) -> Result<Option<String>, ApiError> {
    match p.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if !s.trim().is_empty() => Ok(Some(s.clone())),
        _ => Err(invalid(format!("{key} must be a string or null"))),
    }
}
fn flag(p: &Value, key: &str) -> Result<bool, ApiError> {
    match p.get(key) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(value)) => Ok(*value),
        _ => Err(invalid(format!("{key} must be true or false"))),
    }
}
fn integer(p: &Value, key: &str, fallback: i64) -> Result<i64, ApiError> {
    match p.get(key) {
        None => Ok(fallback),
        Some(v) => v
            .as_i64()
            .ok_or_else(|| invalid(format!("{key} must be an integer"))),
    }
}
/// Workflow states in board order, following Linear's default team workflow.
pub const TASK_STATUSES: [&str; 6] = [
    "backlog",
    "todo",
    "in_progress",
    "review",
    "done",
    "canceled",
];
fn status(s: &str) -> Result<(), ApiError> {
    if TASK_STATUSES.contains(&s) {
        Ok(())
    } else {
        Err(invalid(
            "Status must be backlog, todo, in_progress, review, done, or canceled",
        ))
    }
}
/// Done and Canceled close a task: it no longer blocks dependents or counts as open work.
fn is_closed(s: &str) -> bool {
    s == "done" || s == "canceled"
}

fn validate_widget_path(data_dir: &Path, path: &Path) -> Result<PathBuf, ApiError> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };
    for name in [
        "workboard.sqlite3",
        "workboard.sqlite3-wal",
        "workboard.sqlite3-shm",
        "service.lock",
        "workboard.sock",
        "workboard.sock.lock",
        "widget-config.json",
    ] {
        if same_path(&absolute, &data_dir.join(name)) {
            return Err(invalid(
                "Database and service files cannot be used as widget snapshot destinations",
            ));
        }
    }
    if let Ok(metadata) = fs::metadata(&absolute) {
        if !metadata.is_file() {
            return Err(invalid(
                "The widget snapshot destination must be a regular file path",
            ));
        }
    }
    if let Some(parent) = absolute.parent() {
        if parent.exists() && !parent.is_dir() {
            return Err(invalid(
                "The parent path of the widget snapshot is not a directory",
            ));
        }
    }
    Ok(absolute)
}

struct TemporaryDatabase(PathBuf);
impl Drop for TemporaryDatabase {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
        for suffix in ["-wal", "-shm"] {
            let _ = fs::remove_file(format!("{}{suffix}", self.0.display()));
        }
    }
}
fn date_value(value: &str) -> Result<(bool, i64), ApiError> {
    if value.len() == 10 {
        let date = chrono::NaiveDate::parse_from_str(value, "%Y-%m-%d")
            .map_err(|_| invalid("The date must be a valid YYYY-MM-DD value"))?;
        if date.format("%Y-%m-%d").to_string() != value {
            return Err(invalid("Dates must use YYYY-MM-DD format"));
        }
        return Ok((
            true,
            date.and_hms_opt(0, 0, 0)
                .unwrap()
                .and_utc()
                .timestamp_millis(),
        ));
    }
    let time = chrono::DateTime::parse_from_rfc3339(value)
        .map_err(|_| invalid("Timestamps must use RFC3339 format with a time zone offset"))?;
    Ok((false, time.timestamp_millis()))
}
fn validate_schedule(task: &Task) -> Result<(), ApiError> {
    if task.time_zone.parse::<chrono_tz::Tz>().is_err() {
        return Err(invalid(
            "time_zone must be an IANA time zone such as UTC or America/New_York",
        ));
    }
    if let Some(due) = &task.due_at {
        date_value(due)?;
    }
    match (&task.scheduled_start, &task.scheduled_end) {
        (None, None) => {}
        (Some(start), Some(end)) => {
            let (start_date, start) = date_value(start)?;
            let (end_date, end) = date_value(end)?;
            if start_date != end_date {
                return Err(invalid(
                    "Schedule start and end must use the same date or timestamp format",
                ));
            }
            if end <= start {
                return Err(invalid("Schedule end must be after its start"));
            }
            workflow::interval(
                task.scheduled_start.as_deref().unwrap(),
                task.scheduled_end.as_deref().unwrap(),
                &task.time_zone,
            )?;
        }
        _ => {
            return Err(invalid(
                "Set or clear scheduled_start and scheduled_end together",
            ))
        }
    }
    Ok(())
}

pub struct Board {
    conn: Connection,
    data_dir: PathBuf,
    widget_changed: std::cell::Cell<bool>,
}
impl Board {
    pub fn open(data_dir: impl AsRef<Path>) -> Result<Self, ApiError> {
        let data_dir = data_dir.as_ref().to_path_buf();
        fs::create_dir_all(&data_dir)?;
        private_permissions(&data_dir, 0o700)?;
        let path = data_dir.join("workboard.sqlite3");
        let conn = Connection::open(&path)?;
        conn.busy_timeout(Duration::from_secs(5))?;
        let version: u32 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if version > DATABASE_VERSION {
            return Err(ApiError::new(
                "INCOMPATIBLE_DATABASE",
                "This database was created by a newer version",
            ));
        }
        conn.execute_batch(
            "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;",
        )?;
        migrate(&conn)?;
        private_permissions(&path, 0o600)?;
        let board = Self {
            conn,
            data_dir,
            widget_changed: std::cell::Cell::new(false),
        };
        if let Err(e) = board.write_widget_snapshot() {
            eprintln!("widget snapshot: {e}");
        }
        Ok(board)
    }
    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }
    pub fn snapshot(&self) -> Result<Value, ApiError> {
        snapshot(&self.conn)
    }
    /// True once after a shared App Group snapshot was rewritten. Desktop widgets reload only when
    /// the containing app asks WidgetKit, so the service uses this to request that reload.
    pub fn take_widget_change(&self) -> bool {
        self.widget_changed.replace(false)
    }
    pub fn dispatch(&mut self, request: Request) -> Response {
        let result = self.dispatch_inner(&request);
        match result {
            Ok(v) => Response::success(request.request_id, v),
            Err(e) => Response::failure(request.request_id, e),
        }
    }
    fn dispatch_inner(&mut self, r: &Request) -> Result<Value, ApiError> {
        if r.schema_version != SCHEMA_VERSION {
            return Err(ApiError::new(
                "INCOMPATIBLE_VERSION",
                "The request protocol version is incompatible",
            ));
        }
        if r.request_id.trim().is_empty() || r.request_id.len() > 200 {
            return Err(ApiError::new(
                "INVALID_REQUEST",
                "request_id must contain 1 to 200 characters",
            ));
        }
        if !r.params.is_object() {
            return Err(invalid("params must be a JSON object"));
        }
        let fingerprint = serde_json::to_string(&json!({"method":r.method,"params":r.params}))?;
        if let Some((old, response)) = cached(&self.conn, &r.request_id)? {
            if old != fingerprint {
                return Err(ApiError::new(
                    "REQUEST_ID_CONFLICT",
                    "A request_id cannot be reused for a different request",
                ));
            }
            return Ok(serde_json::from_str(&response)?);
        }
        match r.method.as_str() {
            "backup.create" => {
                let path = PathBuf::from(required(&r.params, "path")?);
                let v = self.backup_request(&path, r, &fingerprint)?;
                remember(&self.conn, r, &fingerprint, &v)?;
                return Ok(v);
            }
            "backup.restore" => {
                let path = PathBuf::from(required(&r.params, "path")?);
                let value = self.restore(&path, r, &fingerprint)?;
                if let Err(e) = self.write_widget_snapshot() {
                    eprintln!("widget snapshot: {e}");
                }
                return Ok(value);
            }
            "export" => return self.export(&r.params),
            _ => {}
        }
        if !is_mutation(&r.method) {
            return read_method(&self.conn, &r.method, &r.params);
        }
        let tx = self.conn.transaction()?;
        let value = mutate(&tx, r, &self.data_dir)?;
        remember(&tx, r, &fingerprint, &value)?;
        tx.commit()?;
        // A failed derived snapshot never rolls back a committed task or reports a false mutation failure.
        if let Err(e) = self.write_widget_snapshot() {
            eprintln!("widget snapshot: {e}");
        }
        Ok(value)
    }
    pub fn write_widget_snapshot(&self) -> Result<(), ApiError> {
        let state = snapshot(&self.conn)?;
        let tasks = state["tasks"].as_array().cloned().unwrap_or_default();
        let select = |s: &str| {
            tasks
                .iter()
                .filter(|t| t["status"] == s)
                .take(12)
                .cloned()
                .collect::<Vec<_>>()
        };
        let value = json!({"schema_version":1,"generated_at":now(),"event_sequence":state["event_sequence"],"projects":state["projects"],"tasks":tasks,"current":select("in_progress"),"next":select("todo"),"review":select("review"),"templates":state["templates"],"views":state["views"],"inbox":state["inbox"]});
        let bytes = serde_json::to_vec(&value)?;
        let mut paths =
            std::collections::BTreeSet::from([self.data_dir.join("widget-snapshot.json")]);
        let mut first_error = None;
        if let Some(path) = std::env::var_os("WORKBOARD_WIDGET_SNAPSHOT") {
            match validate_widget_path(&self.data_dir, Path::new(&path)) {
                Ok(path) => {
                    paths.insert(path);
                }
                Err(error) => first_error = Some(error),
            }
        }
        let configured: Option<String> = self
            .conn
            .query_row(
                "SELECT value FROM settings WHERE key='widget_snapshot_path'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(configured) = configured {
            let path = serde_json::from_str::<PathBuf>(&configured)
                .map_err(ApiError::from)
                .and_then(|path| validate_widget_path(&self.data_dir, &path));
            match path {
                Ok(path) => {
                    paths.insert(path);
                }
                Err(error) => {
                    if first_error.is_none() {
                        first_error = Some(error);
                    }
                }
            }
        }
        for path in paths {
            #[cfg(target_os = "macos")]
            group_container::approve(&path);
            match atomic_write(&path, &bytes) {
                #[cfg(target_os = "macos")]
                Ok(()) if group_container::identifier(&path).is_some() => {
                    self.widget_changed.set(true)
                }
                Ok(()) => {}
                Err(error) => {
                    if first_error.is_none() {
                        first_error = Some(error);
                    }
                }
            }
        }
        if let Some(error) = first_error {
            return Err(error);
        }
        Ok(())
    }
    fn backup_request(
        &self,
        path: &Path,
        request: &Request,
        fingerprint: &str,
    ) -> Result<Value, ApiError> {
        // The completed backup carries its own receipt. A crash after publishing the file but before
        // updating the live retry ledger can therefore return the same result without overwriting it.
        if path.exists() {
            let receipt = (|| -> Result<(String, String, String), rusqlite::Error> {
                let saved =
                    Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
                saved.query_row(
                    "SELECT request_id,fingerprint,result FROM backup_receipt WHERE id=1",
                    [],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
            })();
            if let Ok((old_id, old_fingerprint, result)) = receipt {
                if old_id == request.request_id {
                    if old_fingerprint != fingerprint {
                        return Err(ApiError::new(
                            "REQUEST_ID_CONFLICT",
                            "A request_id cannot be reused for a different backup request",
                        ));
                    }
                    return Ok(serde_json::from_str(&result)?);
                }
            }
            return Err(ApiError::new(
                "ALREADY_EXISTS",
                "The backup destination already exists",
            ));
        }
        let temporary = path.with_extension(format!("backup-{}", id()));
        let result = (|| -> Result<Value, ApiError> {
            self.backup(&temporary)?;
            let value = json!({"path":path,"event_sequence":sequence(&self.conn)?});
            let saved = Connection::open(&temporary)?;
            saved.execute_batch("CREATE TABLE backup_receipt(id INTEGER PRIMARY KEY CHECK(id=1),request_id TEXT NOT NULL,fingerprint TEXT NOT NULL,result TEXT NOT NULL)")?;
            saved.execute(
                "INSERT INTO backup_receipt(id,request_id,fingerprint,result) VALUES(1,?1,?2,?3)",
                params![
                    request.request_id,
                    fingerprint,
                    serde_json::to_string(&value)?
                ],
            )?;
            drop(saved);
            fs::File::open(&temporary)?.sync_all()?;
            // Atomic no-replace publication: an existing destination is never overwritten.
            fs::hard_link(&temporary, path)?;
            if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
                fs::File::open(parent)?.sync_all()?;
            }
            Ok(value)
        })();
        let _ = fs::remove_file(&temporary);
        result
    }
    fn backup(&self, path: &Path) -> Result<(), ApiError> {
        if path.exists() {
            return Err(ApiError::new(
                "ALREADY_EXISTS",
                "The backup destination already exists",
            ));
        }
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            fs::create_dir_all(parent)?;
        }
        // SQLite's online backup API includes committed WAL pages in one consistent database.
        self.conn.backup("main", path, None)?;
        private_permissions(path, 0o600)?;
        Ok(())
    }
    fn restore(
        &mut self,
        path: &Path,
        request: &Request,
        fingerprint: &str,
    ) -> Result<Value, ApiError> {
        if same_path(path, &self.data_dir.join("workboard.sqlite3")) {
            return Err(invalid(
                "The active task database cannot be used as a restore source",
            ));
        }
        let mut source =
            Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        let version: u32 = source.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if !(1..=DATABASE_VERSION).contains(&version) {
            return Err(ApiError::new(
                "INCOMPATIBLE_BACKUP",
                "The backup database version is incompatible",
            ));
        }
        let integrity: String = source.query_row("PRAGMA integrity_check", [], |row| row.get(0))?;
        if integrity != "ok" {
            return Err(ApiError::new("INVALID_BACKUP", integrity));
        }
        // Older backups are migrated on a private copy; the user's backup remains unchanged.
        let scratch = if version < DATABASE_VERSION {
            let scratch = TemporaryDatabase(
                self.data_dir
                    .join(format!("restore-input-{}.sqlite3", id())),
            );
            source.backup("main", &scratch.0, None)?;
            private_permissions(&scratch.0, 0o600)?;
            source = Connection::open(&scratch.0)?;
            migrate(&source)?;
            Some(scratch)
        } else {
            None
        };
        let restore_path = scratch.as_ref().map(|s| s.0.as_path()).unwrap_or(path);
        // Verify the full model before touching the live database.
        snapshot(&source)?;
        source.prepare("SELECT id,task_id,run_id,path,kind,description,created_at,locator,provider,verified_at,metadata FROM artifacts")?;
        source.prepare(
            "SELECT id,task_id,agent_id,status,started_at,ended_at,summary,next_action FROM runs",
        )?;
        source.prepare("SELECT request_id,fingerprint,result FROM requests")?;
        source.prepare("SELECT task_id,revision FROM task_revisions")?;
        source.prepare("SELECT rowid FROM task_fts WHERE task_fts MATCH 'probe'")?;
        events(&source, 0)?;
        let violations: i64 =
            source.query_row("SELECT count(*) FROM pragma_foreign_key_check", [], |r| {
                r.get(0)
            })?;
        if violations > 0 {
            return Err(ApiError::new(
                "INVALID_BACKUP",
                "The backup contains invalid task references",
            ));
        }
        // Keep an automatic pre-restore backup so a mistaken user selection remains reversible.
        self.backup(
            &self
                .data_dir
                .join(format!("before-restore-{}.sqlite3", id())),
        )?;
        if cached(&source, &request.request_id)?.is_some() {
            return Err(ApiError::new(
                "REQUEST_ID_CONFLICT",
                "The backup contains this request ID. Use a new request ID to restore it",
            ));
        }
        let previous_sequence = sequence(&self.conn)?;
        self.conn.execute(
            "ATTACH DATABASE ?1 AS restoration",
            [restore_path.to_string_lossy().as_ref()],
        )?;
        let restored = (|| -> Result<Value, ApiError> {
            // Import only our known model into the current schema. Schema, FTS triggers and the live
            // request ledger remain controlled by this service. The restore and its retry result commit together.
            let tx = self.conn.transaction()?;
            tx.execute_batch("PRAGMA defer_foreign_keys=ON; DELETE FROM task_dependencies; DELETE FROM checklist_items; DELETE FROM review_decisions; DELETE FROM inbox; DELETE FROM templates; DELETE FROM saved_views; DELETE FROM artifacts; DELETE FROM runs; DELETE FROM tasks; DELETE FROM projects; DELETE FROM events;")?;
            for (table,columns) in [
                ("projects","id,name,directory,created_at"),
                ("tasks","id,project_id,parent_id,title,goal,completion_criteria,status,priority,assignee,next_action,revision,created_at,updated_at,blocked_reason,completion_summary,claimed_at,due_at,scheduled_start,scheduled_end,time_zone,deleted_at,deletion_id,deleted_by"),
                ("runs","id,task_id,agent_id,status,started_at,ended_at,summary,next_action"),
                ("artifacts","id,task_id,run_id,path,kind,description,created_at,locator,provider,verified_at,metadata"),
                ("task_dependencies","task_id,depends_on_id"),
                ("checklist_items","id,task_id,text,required,checked,evidence,created_at"),
                ("review_decisions","id,task_id,decision,summary,run_id,actor,created_at"),
                ("inbox","id,title,source,note,status,task_id,revision,created_at,updated_at"),
                ("templates","id,name,definition,builtin,revision,created_at,updated_at"),
                ("saved_views","id,name,filters,layout,revision,created_at,updated_at"),
                ("events","sequence,request_id,task_id,kind,actor,created_at,data"),
            ] {
                let order=if ["runs","checklist_items","review_decisions"].contains(&table) {" ORDER BY rowid"}else{""};
                tx.execute_batch(&format!("INSERT INTO main.{table}({columns}) SELECT {columns} FROM restoration.{table}{order}"))?;
            }
            let conflicts:i64=tx.query_row("SELECT count(*) FROM main.requests live JOIN restoration.requests saved USING(request_id) WHERE live.fingerprint<>saved.fingerprint",[],|row|row.get(0))?;
            if conflicts > 0 {
                return Err(ApiError::new(
                    "REQUEST_ID_CONFLICT",
                    "Request IDs conflict between the backup and the current database",
                ));
            }
            tx.execute_batch("INSERT OR IGNORE INTO main.requests(request_id,fingerprint,result) SELECT request_id,fingerprint,result FROM restoration.requests")?;
            // Never rewind aggregate versions, even when a task disappeared in an earlier restore.
            // Keep live tombstones and import the backup's tombstones before assigning fresh versions.
            tx.execute_batch("INSERT INTO main.task_revisions(task_id,revision) SELECT task_id,revision FROM restoration.task_revisions WHERE true ON CONFLICT(task_id) DO UPDATE SET revision=max(task_revisions.revision,excluded.revision)")?;
            let restored_tasks = {
                let mut statement = tx.prepare("SELECT id,revision FROM tasks")?;
                let rows = statement.query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                })?;
                rows.collect::<Result<Vec<_>, _>>()?
            };
            for (task_id, old_revision) in restored_tasks {
                let revision = allocate_revision(&tx, &task_id, old_revision)?;
                tx.execute(
                    "UPDATE tasks SET revision=?2 WHERE id=?1",
                    params![task_id, revision],
                )?;
            }
            workflow::restore_revisions(&tx)?;
            let updated = tx.execute(
                "UPDATE sqlite_sequence SET seq=max(seq,?1) WHERE name='events'",
                [previous_sequence],
            )?;
            if updated == 0 {
                tx.execute(
                    "INSERT INTO sqlite_sequence(name,seq) VALUES ('events',?1)",
                    [previous_sequence],
                )?;
            }
            let seq = record(&tx, request, None, "backup.restored", json!({"path":path}))?;
            let value = json!({"restored":true,"path":path,"event_sequence":seq});
            remember(&tx, request, fingerprint, &value)?;
            tx.commit()?;
            Ok(value)
        })();
        if let Err(error) = self.conn.execute_batch("DETACH DATABASE restoration") {
            eprintln!("restore detach: {error}");
        }
        restored
    }
    fn export(&self, p: &Value) -> Result<Value, ApiError> {
        let state = snapshot(&self.conn)?;
        let artifacts = all_artifacts(&self.conn, None)?;
        let runs = all_runs(&self.conn, None)?;
        let events = events(&self.conn, 0)?;
        let document = json!({"schema_version":1,"exported_at":now(),"projects":state["projects"],"tasks":state["tasks"],"trash":state["trash"],"artifacts":artifacts,"runs":runs,"events":events,"templates":state["templates"],"views":state["views"],"inbox":state["inbox"],"review_decisions":workflow::review_decisions(&self.conn,None)?,"event_sequence":state["event_sequence"]});
        let format = optional(p, "format")?.unwrap_or_else(|| "json".into());
        let content = match format.as_str() {
            "json" => serde_json::to_string_pretty(&document)?,
            "markdown" => markdown(&document),
            _ => return Err(invalid("format must be json or markdown")),
        };
        if let Some(path) = optional(p, "path")? {
            let protected = [
                "workboard.sqlite3",
                "workboard.sqlite3-wal",
                "workboard.sqlite3-shm",
                "service.lock",
            ];
            if protected
                .iter()
                .any(|name| same_path(Path::new(&path), &self.data_dir.join(name)))
            {
                return Err(invalid(
                    "Task database and service files cannot be used as export destinations",
                ));
            }
            atomic_write(Path::new(&path), content.as_bytes())?;
            Ok(json!({"path":path,"format":format,"event_sequence":state["event_sequence"]}))
        } else {
            Ok(json!({"format":format,"content":content,"data":document}))
        }
    }
}

fn migrate(conn: &Connection) -> Result<(), ApiError> {
    let version: u32 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version > DATABASE_VERSION {
        return Err(ApiError::new(
            "INCOMPATIBLE_DATABASE",
            "This database was created by a newer version",
        ));
    }
    if version == DATABASE_VERSION {
        return Ok(());
    }
    if version == 0 {
        conn.execute_batch(r#"
BEGIN IMMEDIATE;
CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, directory TEXT NOT NULL, created_at TEXT NOT NULL);
CREATE TABLE tasks (
 id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), parent_id TEXT REFERENCES tasks(id),
 title TEXT NOT NULL, goal TEXT NOT NULL DEFAULT '', completion_criteria TEXT NOT NULL DEFAULT '',
 status TEXT NOT NULL DEFAULT 'todo' CHECK(status IN ('todo','in_progress','review','done')),
 priority INTEGER NOT NULL DEFAULT 0, assignee TEXT, next_action TEXT NOT NULL DEFAULT '', revision INTEGER NOT NULL DEFAULT 1,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, blocked_reason TEXT NOT NULL DEFAULT '', completion_summary TEXT NOT NULL DEFAULT '', claimed_at TEXT,
 CHECK(parent_id IS NULL OR parent_id <> id)
);
CREATE INDEX tasks_project ON tasks(project_id);
CREATE INDEX tasks_parent ON tasks(parent_id);
CREATE TABLE runs (id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id), agent_id TEXT NOT NULL, status TEXT NOT NULL,
 started_at TEXT NOT NULL, ended_at TEXT, summary TEXT NOT NULL DEFAULT '', next_action TEXT NOT NULL DEFAULT '');
CREATE INDEX runs_task ON runs(task_id);
CREATE TABLE artifacts (id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id), run_id TEXT REFERENCES runs(id), path TEXT NOT NULL,
 kind TEXT NOT NULL, description TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, locator TEXT, provider TEXT, verified_at TEXT, metadata TEXT NOT NULL DEFAULT '{}');
CREATE INDEX artifacts_task ON artifacts(task_id);
CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT NOT NULL, task_id TEXT,
 kind TEXT NOT NULL, actor TEXT, created_at TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE requests (request_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL);
CREATE VIRTUAL TABLE task_fts USING fts5(title,goal,completion_criteria,next_action,content='tasks',content_rowid='rowid');
CREATE TRIGGER task_search_insert AFTER INSERT ON tasks BEGIN
 INSERT INTO task_fts(rowid,title,goal,completion_criteria,next_action) VALUES (new.rowid,new.title,new.goal,new.completion_criteria,new.next_action);
END;
CREATE TRIGGER task_search_delete AFTER DELETE ON tasks BEGIN
 INSERT INTO task_fts(task_fts,rowid,title,goal,completion_criteria,next_action) VALUES('delete',old.rowid,old.title,old.goal,old.completion_criteria,old.next_action);
END;
CREATE TRIGGER task_search_update AFTER UPDATE ON tasks BEGIN
 INSERT INTO task_fts(task_fts,rowid,title,goal,completion_criteria,next_action) VALUES('delete',old.rowid,old.title,old.goal,old.completion_criteria,old.next_action);
 INSERT INTO task_fts(rowid,title,goal,completion_criteria,next_action) VALUES (new.rowid,new.title,new.goal,new.completion_criteria,new.next_action);
END;
PRAGMA user_version=1;
COMMIT;
"#)?;
    }
    if version < 2 {
        conn.execute_batch("BEGIN IMMEDIATE; ALTER TABLE tasks ADD COLUMN due_at TEXT; ALTER TABLE tasks ADD COLUMN scheduled_start TEXT; ALTER TABLE tasks ADD COLUMN scheduled_end TEXT; ALTER TABLE tasks ADD COLUMN time_zone TEXT NOT NULL DEFAULT 'UTC'; PRAGMA user_version=2; COMMIT;")?;
    }
    if version < 3 {
        conn.execute_batch("BEGIN IMMEDIATE; CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT NOT NULL); PRAGMA user_version=3; COMMIT;")?;
    }
    if version < 4 {
        conn.execute_batch(r#"
BEGIN IMMEDIATE;
CREATE TABLE task_revisions(task_id TEXT PRIMARY KEY,revision INTEGER NOT NULL CHECK(revision>0));
INSERT INTO task_revisions(task_id,revision) SELECT id,revision FROM tasks;
-- Version 3 kept retry receipts for tasks removed by a restore. Recover their high-water marks too.
INSERT INTO task_revisions(task_id,revision)
 SELECT json_extract(result,'$.task.id'),max(json_extract(result,'$.task.revision')) FROM requests
 WHERE json_valid(result) AND json_type(result,'$.task.id')='text' AND json_type(result,'$.task.revision')='integer'
 AND json_extract(result,'$.task.revision')>0 GROUP BY json_extract(result,'$.task.id')
 ON CONFLICT(task_id) DO UPDATE SET revision=max(task_revisions.revision,excluded.revision);
PRAGMA user_version=4;
COMMIT;
"#)?;
    }
    if version < 5 {
        workflow::migrate(conn)?;
    }
    if version < 6 {
        add_workflow_states_and_trash(conn)?;
    }
    Ok(())
}

/// Version 6 adds Backlog, Canceled, and the trash. SQLite cannot change a CHECK constraint in
/// place, so the tasks table is rebuilt. Rows keep their rowids, which the external-content search
/// index uses.
fn add_workflow_states_and_trash(conn: &Connection) -> Result<(), ApiError> {
    let foreign_keys: bool = conn.query_row("PRAGMA foreign_keys", [], |r| r.get(0))?;
    // Replacing a referenced table requires foreign keys off; the check below runs before commit.
    conn.execute_batch("PRAGMA foreign_keys=OFF")?;
    let rebuilt = (|| -> Result<(), ApiError> {
        conn.execute_batch(r#"
BEGIN IMMEDIATE;
CREATE TABLE tasks_v6 (
 id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), parent_id TEXT REFERENCES tasks(id),
 title TEXT NOT NULL, goal TEXT NOT NULL DEFAULT '', completion_criteria TEXT NOT NULL DEFAULT '',
 status TEXT NOT NULL DEFAULT 'todo' CHECK(status IN ('backlog','todo','in_progress','review','done','canceled')),
 priority INTEGER NOT NULL DEFAULT 0, assignee TEXT, next_action TEXT NOT NULL DEFAULT '', revision INTEGER NOT NULL DEFAULT 1,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, blocked_reason TEXT NOT NULL DEFAULT '', completion_summary TEXT NOT NULL DEFAULT '', claimed_at TEXT,
 due_at TEXT, scheduled_start TEXT, scheduled_end TEXT, time_zone TEXT NOT NULL DEFAULT 'UTC',
 deleted_at TEXT, deletion_id TEXT, deleted_by TEXT,
 CHECK(parent_id IS NULL OR parent_id <> id), CHECK((deleted_at IS NULL) = (deletion_id IS NULL))
);
INSERT INTO tasks_v6(rowid,id,project_id,parent_id,title,goal,completion_criteria,status,priority,assignee,next_action,revision,created_at,updated_at,blocked_reason,completion_summary,claimed_at,due_at,scheduled_start,scheduled_end,time_zone)
 SELECT rowid,id,project_id,parent_id,title,goal,completion_criteria,status,priority,assignee,next_action,revision,created_at,updated_at,blocked_reason,completion_summary,claimed_at,due_at,scheduled_start,scheduled_end,time_zone FROM tasks;
DROP TABLE tasks;
ALTER TABLE tasks_v6 RENAME TO tasks;
CREATE INDEX tasks_project ON tasks(project_id);
CREATE INDEX tasks_parent ON tasks(parent_id);
CREATE INDEX tasks_deletion ON tasks(deletion_id);
CREATE TRIGGER task_search_insert AFTER INSERT ON tasks BEGIN
 INSERT INTO task_fts(rowid,title,goal,completion_criteria,next_action) VALUES (new.rowid,new.title,new.goal,new.completion_criteria,new.next_action);
END;
CREATE TRIGGER task_search_delete AFTER DELETE ON tasks BEGIN
 INSERT INTO task_fts(task_fts,rowid,title,goal,completion_criteria,next_action) VALUES('delete',old.rowid,old.title,old.goal,old.completion_criteria,old.next_action);
END;
CREATE TRIGGER task_search_update AFTER UPDATE ON tasks BEGIN
 INSERT INTO task_fts(task_fts,rowid,title,goal,completion_criteria,next_action) VALUES('delete',old.rowid,old.title,old.goal,old.completion_criteria,old.next_action);
 INSERT INTO task_fts(rowid,title,goal,completion_criteria,next_action) VALUES (new.rowid,new.title,new.goal,new.completion_criteria,new.next_action);
END;
INSERT INTO task_fts(task_fts) VALUES('rebuild');
PRAGMA user_version=6;
"#)?;
        let violations: i64 =
            conn.query_row("SELECT count(*) FROM pragma_foreign_key_check", [], |r| {
                r.get(0)
            })?;
        if violations > 0 {
            return Err(ApiError::new(
                "DATABASE_CORRUPT",
                "The task table could not be upgraded because it contains invalid references",
            ));
        }
        conn.execute_batch("COMMIT")?;
        Ok(())
    })();
    if rebuilt.is_err() && !conn.is_autocommit() {
        let _ = conn.execute_batch("ROLLBACK");
    }
    conn.execute_batch(if foreign_keys {
        "PRAGMA foreign_keys=ON"
    } else {
        "PRAGMA foreign_keys=OFF"
    })?;
    rebuilt
}

fn allocate_revision(c: &Connection, task_id: &str, current: i64) -> Result<i64, ApiError> {
    let saved: Option<i64> = c
        .query_row(
            "SELECT revision FROM task_revisions WHERE task_id=?1",
            [task_id],
            |row| row.get(0),
        )
        .optional()?;
    let next = saved
        .unwrap_or(0)
        .max(current)
        .checked_add(1)
        .ok_or_else(|| {
            ApiError::new(
                "REVISION_EXHAUSTED",
                "The task revision limit has been reached",
            )
        })?;
    c.execute("INSERT INTO task_revisions(task_id,revision) VALUES (?1,?2) ON CONFLICT(task_id) DO UPDATE SET revision=excluded.revision",params![task_id,next])?;
    Ok(next)
}
fn is_latest_run(c: &Connection, task_id: &str, run_id: &str) -> Result<bool, ApiError> {
    // rowid is insertion order. UUID text order is unrelated to which run started last.
    let latest: Option<String> = c
        .query_row(
            "SELECT id FROM runs WHERE task_id=?1 ORDER BY rowid DESC LIMIT 1",
            [task_id],
            |row| row.get(0),
        )
        .optional()?;
    Ok(latest.as_deref() == Some(run_id))
}

fn cached(c: &Connection, id: &str) -> Result<Option<(String, String)>, ApiError> {
    Ok(c.query_row(
        "SELECT fingerprint,result FROM requests WHERE request_id=?1",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()?)
}
fn remember(c: &Connection, r: &Request, fingerprint: &str, value: &Value) -> Result<(), ApiError> {
    c.execute(
        "INSERT INTO requests(request_id,fingerprint,result) VALUES (?1,?2,?3)",
        params![r.request_id, fingerprint, serde_json::to_string(value)?],
    )?;
    Ok(())
}
fn sequence(c: &Connection) -> Result<i64, ApiError> {
    Ok(
        c.query_row("SELECT coalesce(max(sequence),0) FROM events", [], |r| {
            r.get(0)
        })?,
    )
}
fn record(
    c: &Connection,
    r: &Request,
    task: Option<&str>,
    kind: &str,
    data: Value,
) -> Result<i64, ApiError> {
    let actor = optional(&r.params, "agent_id")?.or(optional(&r.params, "actor")?);
    c.execute("INSERT INTO events(request_id,task_id,kind,actor,created_at,data) VALUES (?1,?2,?3,?4,?5,?6)",params![r.request_id,task,kind,actor,now(),serde_json::to_string(&data)?])?;
    Ok(c.last_insert_rowid())
}
const TASK_SELECT: &str = "SELECT id,project_id,parent_id,title,goal,completion_criteria,status,priority,assignee,next_action,revision,created_at,updated_at,blocked_reason,completion_summary,claimed_at,due_at,scheduled_start,scheduled_end,time_zone,deleted_at,deletion_id,deleted_by FROM tasks";
fn task_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Task> {
    let claimed_at: Option<String> = r.get(15)?;
    let expires = claimed_at
        .as_ref()
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|t| t + chrono::Duration::hours(1));
    let claim_stale = expires.as_ref().map(|t| *t < Utc::now()).unwrap_or(false);
    let claim_expires_at = expires.map(|t| t.to_rfc3339_opts(SecondsFormat::Millis, true));
    Ok(Task {
        id: r.get(0)?,
        project_id: r.get(1)?,
        parent_id: r.get(2)?,
        title: r.get(3)?,
        goal: r.get(4)?,
        completion_criteria: r.get(5)?,
        status: r.get(6)?,
        priority: r.get(7)?,
        assignee: r.get(8)?,
        next_action: r.get(9)?,
        revision: r.get(10)?,
        created_at: r.get(11)?,
        updated_at: r.get(12)?,
        blocked_reason: r.get(13)?,
        completion_summary: r.get(14)?,
        claimed_at,
        claim_expires_at,
        claim_stale,
        due_at: r.get(16)?,
        scheduled_start: r.get(17)?,
        scheduled_end: r.get(18)?,
        time_zone: r.get(19)?,
        dependency_ids: vec![],
        blocked_by: vec![],
        ready: false,
        checklist: vec![],
        deleted_at: r.get(20)?,
        deletion_id: r.get(21)?,
        deleted_by: r.get(22)?,
    })
}
/// A live task. A task in the trash reads as missing until it is restored.
fn get_task(c: &Connection, id: &str) -> Result<Task, ApiError> {
    let task = task_record(c, id)?;
    if task.deleted_at.is_some() {
        return Err(ApiError::new(
            "NOT_FOUND",
            "The task is in the trash. Restore it before using it",
        ));
    }
    workflow::enrich_task(c, task)
}
/// A live or trashed task.
fn get_any_task(c: &Connection, id: &str) -> Result<Task, ApiError> {
    workflow::enrich_task(c, task_record(c, id)?)
}
fn task_record(c: &Connection, id: &str) -> Result<Task, ApiError> {
    c.query_row(&format!("{TASK_SELECT} WHERE id=?1"), [id], task_row)
        .optional()?
        .ok_or_else(|| ApiError::new("NOT_FOUND", "Task not found"))
}
fn projects(c: &Connection) -> Result<Vec<Project>, ApiError> {
    let mut st =
        c.prepare("SELECT id,name,directory,created_at FROM projects ORDER BY created_at,id")?;
    let rows = st.query_map([], |r| {
        Ok(Project {
            id: r.get(0)?,
            name: r.get(1)?,
            directory: r.get(2)?,
            created_at: r.get(3)?,
        })
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}
fn list_tasks(c: &Connection, p: &Value) -> Result<Vec<Task>, ApiError> {
    let resolved = workflow::resolve_filters(c, p)?;
    let p = &resolved;
    let mut sql = format!("{TASK_SELECT} WHERE deleted_at IS NULL");
    let mut args: Vec<String> = vec![];
    for (key, col) in [("project_id", "project_id"), ("status", "status")] {
        if let Some(value) = optional(p, key)? {
            sql.push_str(&format!(" AND {col}=?"));
            args.push(value);
        }
    }
    if let Some(value) = p.get("parent_id") {
        if value.is_null() {
            sql.push_str(" AND parent_id IS NULL");
        } else {
            sql.push_str(" AND parent_id=?");
            args.push(required(p, "parent_id")?.into());
        }
    }
    if let Some(query) = optional(p, "query")? {
        let q = query
            .split_whitespace()
            .map(|s| format!("\"{}\"*", s.replace('"', "\"\"")))
            .collect::<Vec<_>>()
            .join(" AND ");
        if !q.is_empty() {
            sql.push_str(" AND rowid IN (SELECT rowid FROM task_fts WHERE task_fts MATCH ?)");
            args.push(q);
        }
    }
    sql.push_str(" ORDER BY priority DESC,created_at,id");
    let mut st = c.prepare(&sql)?;
    let result = st
        .query_map(rusqlite::params_from_iter(args), task_row)?
        .collect::<Result<Vec<_>, _>>()?;
    let tasks = result
        .into_iter()
        .map(|task| workflow::enrich_task(c, task))
        .collect::<Result<Vec<_>, _>>()?;
    workflow::filter_tasks(tasks, p)
}
fn all_artifacts(c: &Connection, task: Option<&str>) -> Result<Vec<Artifact>, ApiError> {
    let sql="SELECT id,task_id,run_id,path,kind,description,created_at,locator,provider,verified_at,metadata FROM artifacts WHERE (?1 IS NULL OR task_id=?1) ORDER BY created_at,id";
    let mut st = c.prepare(sql)?;
    let out = st
        .query_map([task], |r| {
            Ok(Artifact {
                id: r.get(0)?,
                task_id: r.get(1)?,
                run_id: r.get(2)?,
                path: r.get(3)?,
                kind: r.get(4)?,
                description: r.get(5)?,
                created_at: r.get(6)?,
                locator: r.get(7)?,
                provider: r.get(8)?,
                verified_at: r.get(9)?,
                metadata: serde_json::from_str(&r.get::<_, String>(10)?)
                    .unwrap_or_else(|_| json!({})),
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(out)
}
fn all_runs(c: &Connection, task: Option<&str>) -> Result<Vec<Run>, ApiError> {
    let mut st=c.prepare("SELECT id,task_id,agent_id,status,started_at,ended_at,summary,next_action FROM runs WHERE (?1 IS NULL OR task_id=?1) ORDER BY started_at,rowid")?;
    let out = st
        .query_map([task], |r| {
            Ok(Run {
                id: r.get(0)?,
                task_id: r.get(1)?,
                agent_id: r.get(2)?,
                status: r.get(3)?,
                started_at: r.get(4)?,
                ended_at: r.get(5)?,
                summary: r.get(6)?,
                next_action: r.get(7)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(out)
}
fn events(c: &Connection, after: i64) -> Result<Vec<Event>, ApiError> {
    let mut st=c.prepare("SELECT sequence,request_id,task_id,kind,actor,created_at,data FROM events WHERE sequence>?1 ORDER BY sequence")?;
    let out = st
        .query_map([after], |r| {
            let data: String = r.get(6)?;
            Ok(Event {
                sequence: r.get(0)?,
                request_id: r.get(1)?,
                task_id: r.get(2)?,
                kind: r.get(3)?,
                actor: r.get(4)?,
                created_at: r.get(5)?,
                data: serde_json::from_str(&data).unwrap_or(Value::Null),
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(out)
}
fn snapshot(c: &Connection) -> Result<Value, ApiError> {
    Ok(
        json!({"projects":projects(c)?,"tasks":list_tasks(c,&json!({}))?,"trash":trash::items(c)?,"templates":workflow::templates(c)?,"views":workflow::views(c)?,"inbox":workflow::inbox(c,&json!({}))?,"event_sequence":sequence(c)?}),
    )
}
fn task_detail(c: &Connection, id: &str) -> Result<Value, ApiError> {
    let task = get_task(c, id)?;
    let children = list_tasks(c, &json!({"parent_id":id}))?;
    let completed = children.iter().filter(|x| x.status == "done").count();
    let canceled = children.iter().filter(|x| x.status == "canceled").count();
    Ok(
        json!({"task":task,"children":children,"child_count":children.len(),"completed_child_count":completed,"canceled_child_count":canceled,"artifacts":all_artifacts(c,Some(id))?,"runs":all_runs(c,Some(id))?,"review_decisions":workflow::review_decisions(c,Some(id))?}),
    )
}
fn read_method(c: &Connection, method: &str, p: &Value) -> Result<Value, ApiError> {
    match method {
        "template.list" => Ok(json!({"templates":workflow::templates(c)?})),
        "trash.list" => Ok(json!({"items":trash::items(c)?})),
        "view.list" => Ok(json!({"views":workflow::views(c)?})),
        "inbox.list" => Ok(json!({"items":workflow::inbox(c,p)?})),
        "task.schedule.preview" => workflow::schedule_preview(c, p),
        "project.list" => Ok(json!({"projects":projects(c)?})),
        "task.list" => Ok(json!({"tasks":list_tasks(c,p)?})),
        "task.get" | "task.resume_context" => {
            let id = required(p, "task_id")?;
            let mut detail = task_detail(c, id)?;
            if method == "task.resume_context" {
                detail["events"] = json!(events(c, 0)?
                    .into_iter()
                    .filter(|e| e.task_id.as_deref() == Some(id))
                    .collect::<Vec<_>>());
            }
            Ok(detail)
        }
        "board.snapshot" => snapshot(c),
        "events.list" => {
            Ok(json!({"events":events(c,integer(p,"after",0)?)?,"event_sequence":sequence(c)?}))
        }
        "doctor" => {
            let result: String = c.query_row("PRAGMA quick_check", [], |r| r.get(0))?;
            let mode: String = c.query_row("PRAGMA journal_mode", [], |r| r.get(0))?;
            if result != "ok" {
                return Err(ApiError::new("DATABASE_CORRUPT", result));
            }
            Ok(
                json!({"healthy":true,"database":"ok","journal_mode":mode,"schema_version":SCHEMA_VERSION,"plugins_required":false,"database_version":DATABASE_VERSION,"event_sequence":sequence(c)?}),
            )
        }
        _ => Err(ApiError::new(
            "METHOD_NOT_FOUND",
            format!("Unsupported request: {method}"),
        )),
    }
}
fn is_mutation(method: &str) -> bool {
    matches!(
        method,
        "template.save"
            | "template.delete"
            | "template.apply"
            | "inbox.capture"
            | "inbox.promote"
            | "inbox.dismiss"
            | "view.save"
            | "view.delete"
            | "task.dependency.add"
            | "task.dependency.remove"
            | "task.checklist.add"
            | "task.checklist.update"
            | "task.checklist.remove"
            | "task.review.decide"
            | "widget.configure"
            | "project.create"
            | "project.delete"
            | "task.create"
            | "task.update"
            | "task.claim"
            | "task.release"
            | "task.start"
            | "task.review"
            | "task.complete"
            | "task.attach"
            | "task.pause"
            | "task.heartbeat"
            | "task.delete"
            | "trash.restore"
            | "trash.purge"
            | "trash.empty"
            | "run.update"
            | "run.finish"
    )
}
fn check_revision(task: &Task, p: &Value, required_revision: bool) -> Result<(), ApiError> {
    if let Some(v) = p.get("expected_revision") {
        if v.as_i64() != Some(task.revision) {
            return Err(ApiError::new(
                "REVISION_CONFLICT",
                format!("The task has changed. Current revision: {}", task.revision),
            ));
        }
    } else if required_revision {
        return Err(invalid("expected_revision is required"));
    }
    Ok(())
}
fn validate_parent(
    c: &Connection,
    task_id: &str,
    project: &str,
    parent: &Option<String>,
) -> Result<(), ApiError> {
    if let Some(parent) = parent {
        let p = get_task(c, parent)?;
        if p.project_id != project {
            return Err(invalid(
                "Subtasks must belong to the same project as their parent",
            ));
        }
        let cycle:i64=c.query_row("WITH RECURSIVE ancestors(id,parent_id) AS (SELECT id,parent_id FROM tasks WHERE id=?1 UNION ALL SELECT t.id,t.parent_id FROM tasks t JOIN ancestors a ON t.id=a.parent_id) SELECT count(*) FROM ancestors WHERE id=?2",params![parent,task_id],|r|r.get(0))?;
        if cycle > 0 {
            return Err(ApiError::new(
                "HIERARCHY_CYCLE",
                "A task cannot use itself or a descendant as its parent",
            ));
        }
    }
    Ok(())
}
/// The task and every descendant, root first. Parent links never form a cycle. Descendants of a
/// trashed task are always trashed too, because live tasks cannot be created or moved under it.
fn subtree(c: &Connection, root: &str, include_trashed: bool) -> Result<Vec<Task>, ApiError> {
    let live = if include_trashed {
        ""
    } else {
        " AND deleted_at IS NULL"
    };
    let mut st = c.prepare(&format!("WITH RECURSIVE tree(id) AS (SELECT ?1 UNION ALL SELECT t.id FROM tasks t JOIN tree ON t.parent_id=tree.id) {TASK_SELECT} WHERE id IN (SELECT id FROM tree){live}"))?;
    let mut tasks = st
        .query_map([root], task_row)?
        .collect::<Result<Vec<_>, _>>()?;
    tasks.sort_by_key(|t| t.id != root);
    Ok(tasks)
}
/// A caller that names an agent may only remove work that the agent holds or that nobody holds.
fn check_owners(tasks: &[Task], actor: &Option<String>) -> Result<(), ApiError> {
    let Some(actor) = actor else {
        return Ok(());
    };
    match tasks
        .iter()
        .find(|t| t.assignee.as_ref().is_some_and(|owner| owner != actor))
    {
        Some(held) => Err(ApiError::new(
            "CLAIM_CONFLICT",
            format!(
                "Includes a task assigned to {}: {}",
                held.assignee.as_deref().unwrap_or_default(),
                held.title
            ),
        )),
        None => Ok(()),
    }
}
/// Permanently removes tasks with their runs and artifacts and returns every removed row for the
/// event, so history still shows what was attached. Each task keeps a revision tombstone above its
/// last revision so a later restore or retry never reuses an older version.
fn delete_tasks(c: &Connection, tasks: &[Task]) -> Result<Value, ApiError> {
    let tasks = tasks
        .iter()
        .map(|task| get_any_task(c, &task.id))
        .collect::<Result<Vec<_>, _>>()?;
    let ids: Vec<&str> = tasks.iter().map(|t| t.id.as_str()).collect();
    let (mut runs, mut artifacts) = (Vec::new(), Vec::new());
    for task in &tasks {
        runs.extend(all_runs(c, Some(&task.id))?);
        artifacts.extend(all_artifacts(c, Some(&task.id))?);
        allocate_revision(c, &task.id, task.revision)?;
    }
    let list = serde_json::to_string(&ids)?;
    let workflow = workflow::detach_deleted_tasks(c, &tasks)?;
    // Each statement removes parents and children together; SQLite checks foreign keys per statement.
    for table in ["artifacts", "runs"] {
        c.execute(
            &format!("DELETE FROM {table} WHERE task_id IN (SELECT value FROM json_each(?1))"),
            [&list],
        )?;
    }
    c.execute(
        "DELETE FROM tasks WHERE id IN (SELECT value FROM json_each(?1))",
        [&list],
    )?;
    Ok(json!({"tasks":tasks,"runs":runs,"artifacts":artifacts,"workflow":workflow}))
}
fn save_task(c: &Connection, t: &Task) -> Result<(), ApiError> {
    c.execute("UPDATE tasks SET parent_id=?2,title=?3,goal=?4,completion_criteria=?5,status=?6,priority=?7,assignee=?8,next_action=?9,revision=?10,updated_at=?11,blocked_reason=?12,completion_summary=?13,claimed_at=?14,due_at=?15,scheduled_start=?16,scheduled_end=?17,time_zone=?18 WHERE id=?1",params![t.id,t.parent_id,t.title,t.goal,t.completion_criteria,t.status,t.priority,t.assignee,t.next_action,t.revision,t.updated_at,t.blocked_reason,t.completion_summary,t.claimed_at,t.due_at,t.scheduled_start,t.scheduled_end,t.time_zone])?;
    Ok(())
}
fn result_task(c: &Connection, t: &Task, seq: i64) -> Result<Value, ApiError> {
    let mut v = task_detail(c, &t.id)?;
    v["task_id"] = json!(t.id);
    v["revision"] = json!(t.revision);
    v["event_sequence"] = json!(seq);
    Ok(v)
}
fn mutate(c: &Transaction<'_>, r: &Request, data_dir: &Path) -> Result<Value, ApiError> {
    let p = &r.params;
    if let Some(result) = workflow::mutate(c, r)? {
        return Ok(result);
    }
    if r.method == "widget.configure" {
        if r.params.get("snapshot_path").is_none() {
            return Err(invalid("Specify a snapshot_path or null"));
        }
        let path = optional(&r.params, "snapshot_path")?
            .map(|value| validate_widget_path(data_dir, Path::new(&value)))
            .transpose()?;
        if let Some(path) = &path {
            c.execute("INSERT INTO settings(key,value) VALUES ('widget_snapshot_path',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[serde_json::to_string(path)?])?;
        } else {
            c.execute("DELETE FROM settings WHERE key='widget_snapshot_path'", [])?;
        }
        let seq = record(
            c,
            r,
            None,
            "widget.configured",
            json!({"snapshot_path":path}),
        )?;
        return Ok(json!({"snapshot_path":path,"event_sequence":seq}));
    }
    if r.method == "project.create" {
        let project = Project {
            id: id(),
            name: required(p, "name")?.trim().into(),
            directory: string(p, "directory")?,
            created_at: now(),
        };
        c.execute(
            "INSERT INTO projects(id,name,directory,created_at) VALUES (?1,?2,?3,?4)",
            params![
                project.id,
                project.name,
                project.directory,
                project.created_at
            ],
        )?;
        let seq = record(c, r, None, "project.created", json!(project))?;
        return Ok(json!({"project":project,"project_id":project.id,"event_sequence":seq}));
    }
    if r.method == "project.delete" {
        let project_id = required(p, "project_id")?;
        let with_tasks = flag(p, "with_tasks")?;
        if p.get("expected_revision").is_some() {
            return Err(invalid(
                "Projects do not have revisions. Omit expected_revision",
            ));
        }
        let project = projects(c)?
            .into_iter()
            .find(|project| project.id == project_id)
            .ok_or_else(|| ApiError::new("NOT_FOUND", "Project not found"))?;
        let tasks = list_tasks(c, &json!({"project_id":project_id}))?;
        let trashed = trash::project_tasks(c, project_id)?;
        let has_tasks = !tasks.is_empty() || !trashed.is_empty();
        if has_tasks && !with_tasks {
            return Err(ApiError::new(
                "HAS_TASKS",
                if trashed.is_empty() {
                    format!(
                        "The project contains {} tasks. Specify with_tasks to delete them",
                        tasks.len()
                    )
                } else {
                    format!(
                        "The project contains {} tasks and {} in the trash. Specify with_tasks to delete them permanently",
                        tasks.len(),
                        trashed.len()
                    )
                },
            ));
        }
        check_owners(&tasks, &optional(p, "agent_id")?)?;
        // Deleting a project is permanent, including tasks already in the trash.
        let tasks: Vec<Task> = tasks.into_iter().chain(trashed).collect();
        let deleted: Vec<String> = tasks.iter().map(|t| t.id.clone()).collect();
        let removed = delete_tasks(c, &tasks)?;
        c.execute("DELETE FROM projects WHERE id=?1", [project_id])?;
        let seq = record(
            c,
            r,
            None,
            "project.deleted",
            json!({"project":project,"removed":removed}),
        )?;
        return Ok(
            json!({"project_id":project_id,"deleted_task_ids":deleted,"event_sequence":seq}),
        );
    }
    if r.method == "task.create" {
        let project_id = required(p, "project_id")?.to_string();
        let exists: bool = c.query_row(
            "SELECT EXISTS(SELECT 1 FROM projects WHERE id=?1)",
            [&project_id],
            |r| r.get(0),
        )?;
        if !exists {
            return Err(ApiError::new("NOT_FOUND", "Project not found"));
        }
        let timestamp = now();
        let mut t = Task {
            id: id(),
            project_id,
            parent_id: optional(p, "parent_id")?,
            title: required(p, "title")?.trim().into(),
            goal: string(p, "goal")?,
            completion_criteria: string(p, "completion_criteria")?,
            status: optional(p, "status")?.unwrap_or_else(|| "todo".into()),
            priority: integer(p, "priority", 0)?,
            assignee: None,
            next_action: string(p, "next_action")?,
            revision: 1,
            created_at: timestamp.clone(),
            updated_at: timestamp,
            blocked_reason: String::new(),
            completion_summary: String::new(),
            claimed_at: None,
            claim_expires_at: None,
            claim_stale: false,
            due_at: optional(p, "due_at")?,
            scheduled_start: optional(p, "scheduled_start")?,
            scheduled_end: optional(p, "scheduled_end")?,
            time_zone: optional(p, "time_zone")?.unwrap_or_else(|| "UTC".into()),
            dependency_ids: vec![],
            blocked_by: vec![],
            ready: true,
            checklist: vec![],
            deleted_at: None,
            deletion_id: None,
            deleted_by: None,
        };
        if !["backlog", "todo"].contains(&t.status.as_str()) {
            return Err(invalid("New tasks start in backlog or todo"));
        }
        validate_schedule(&t)?;
        validate_parent(c, &t.id, &t.project_id, &t.parent_id)?;
        t.revision = allocate_revision(c, &t.id, 0)?;
        c.execute("INSERT INTO tasks(id,project_id,parent_id,title,goal,completion_criteria,status,priority,assignee,next_action,revision,created_at,updated_at,blocked_reason,completion_summary,claimed_at,due_at,scheduled_start,scheduled_end,time_zone) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20)",params![t.id,t.project_id,t.parent_id,t.title,t.goal,t.completion_criteria,t.status,t.priority,t.assignee,t.next_action,t.revision,t.created_at,t.updated_at,t.blocked_reason,t.completion_summary,t.claimed_at,t.due_at,t.scheduled_start,t.scheduled_end,t.time_zone])?;
        let seq = record(c, r, Some(&t.id), "task.created", json!(t))?;
        return result_task(c, &t, seq);
    }
    if let Some(result) = trash::mutate(c, r)? {
        return Ok(result);
    }
    let task_id = required(p, "task_id")?;
    let mut t = get_task(c, task_id)?;
    check_revision(
        &t,
        p,
        r.method == "task.update" || r.method.starts_with("task.checklist."),
    )?;
    let actor = optional(p, "agent_id")?;
    if let (Some(owner), Some(actor)) = (&t.assignee, &actor) {
        if owner != actor {
            return Err(ApiError::new(
                "CLAIM_CONFLICT",
                format!("This task is assigned to {owner}"),
            ));
        }
    }
    if r.method == "task.delete" {
        let with_subtasks = flag(p, "with_subtasks")?;
        let tasks = subtree(c, task_id, false)?;
        if tasks.len() > 1 && !with_subtasks {
            return Err(ApiError::new(
                "HAS_SUBTASKS",
                format!(
                    "The task has {} subtasks. Specify with_subtasks to delete them",
                    tasks.len() - 1
                ),
            ));
        }
        check_owners(&tasks, &actor)?;
        let deleted: Vec<String> = tasks.iter().map(|t| t.id.clone()).collect();
        let trashed = trash::move_to_trash(c, &tasks, actor.as_deref())?;
        let seq = record(
            c,
            r,
            Some(task_id),
            "task.deleted",
            json!({"task":t,"trashed":trashed}),
        )?;
        return Ok(
            json!({"task_id":task_id,"deleted_task_ids":deleted,"in_trash":true,"deletion_id":trashed["deletion_id"],"event_sequence":seq}),
        );
    }
    let mut extra = json!({});
    match r.method.as_str() {
        "task.dependency.add" | "task.dependency.remove" => {
            workflow::change_dependency(c, r, &t)?;
        }
        "task.checklist.add" | "task.checklist.update" | "task.checklist.remove" => {
            workflow::change_checklist(c, r, &t)?;
        }
        "task.update" => {
            if p.get("due_at").is_some() {
                t.due_at = optional(p, "due_at")?;
            }
            if p.get("scheduled_start").is_some() {
                t.scheduled_start = optional(p, "scheduled_start")?;
            }
            if p.get("scheduled_end").is_some() {
                t.scheduled_end = optional(p, "scheduled_end")?;
            }
            if p.get("time_zone").is_some() {
                t.time_zone = required(p, "time_zone")?.into();
            }
            validate_schedule(&t)?;
            if p.get("title").is_some() {
                t.title = required(p, "title")?.trim().into();
            }
            for (key, target) in [
                ("goal", &mut t.goal),
                ("completion_criteria", &mut t.completion_criteria),
                ("next_action", &mut t.next_action),
                ("blocked_reason", &mut t.blocked_reason),
                ("completion_summary", &mut t.completion_summary),
            ] {
                if p.get(key).is_some() {
                    *target = string(p, key)?;
                }
            }
            if p.get("priority").is_some() {
                t.priority = integer(p, "priority", 0)?;
            }
            if p.get("parent_id").is_some() {
                t.parent_id = optional(p, "parent_id")?;
                validate_parent(c, &t.id, &t.project_id, &t.parent_id)?;
            }
            if p.get("assignee").is_some() {
                let new_owner = optional(p, "assignee")?;
                if t.assignee.is_some() && new_owner.is_some() && t.assignee != new_owner {
                    return Err(ApiError::new(
                        "CLAIM_CONFLICT",
                        "Release the current assignee before assigning another",
                    ));
                }
                t.assignee = new_owner;
                t.claimed_at = t.assignee.as_ref().map(|_| now());
            }
            if p.get("status").is_some() {
                let s = required(p, "status")?;
                status(s)?;
                if s == "done" && t.completion_summary.trim().is_empty() {
                    return Err(invalid(
                        "Record the outcome in completion_summary before completing the task",
                    ));
                }
                t.status = s.into();
                if s != "in_progress" {
                    c.execute("UPDATE runs SET status=?2,ended_at=?3,summary=CASE WHEN ?2='completed' THEN ?4 ELSE summary END,next_action=CASE WHEN ?2='completed' THEN ?5 ELSE next_action END WHERE task_id=?1 AND (status='running' OR (?2='completed' AND status='review' AND rowid=(SELECT max(rowid) FROM runs WHERE task_id=?1)))",params![task_id,if s=="done" {"completed"} else {"interrupted"},now(),t.completion_summary,t.next_action])?;
                }
            }
        }
        "task.claim" => {
            let agent = required(p, "agent_id")?;
            if t.status == "done" {
                return Err(ApiError::new(
                    "INVALID_STATE",
                    "A completed task cannot be claimed",
                ));
            }
            if t.status == "canceled" {
                return Err(ApiError::new(
                    "INVALID_STATE",
                    "A canceled task cannot be claimed. Reopen it first",
                ));
            }
            if t.assignee.is_some() && t.assignee.as_deref() != Some(agent) {
                return Err(ApiError::new(
                    "CLAIM_CONFLICT",
                    "Another agent already holds this task",
                ));
            }
            t.assignee = Some(agent.into());
            t.claimed_at = Some(now());
        }
        "task.heartbeat" => {
            let agent = required(p, "agent_id")?;
            if t.assignee.as_deref() != Some(agent) {
                return Err(ApiError::new(
                    "CLAIM_CONFLICT",
                    "Only the current assignee can update the activity timestamp",
                ));
            }
            t.claimed_at = Some(now());
        }
        "task.release" => {
            if actor.is_none() {
                return Err(invalid("agent_id is required to release a claim"));
            }
            t.assignee = None;
            t.claimed_at = None;
            c.execute("UPDATE runs SET status='interrupted',ended_at=?2 WHERE task_id=?1 AND status='running'",params![task_id,now()])?;
        }
        "task.start" => {
            if is_closed(&t.status) {
                return Err(ApiError::new(
                    "INVALID_STATE",
                    if t.status == "done" {
                        "Reopen the completed task first"
                    } else {
                        "Reopen the canceled task first"
                    },
                ));
            }
            let agent = actor
                .clone()
                .or_else(|| t.assignee.clone())
                .unwrap_or_else(|| "user".into());
            if t.assignee.is_none() {
                t.assignee = Some(agent.clone());
                t.claimed_at = Some(now());
            }
            let run_id = optional(p, "run_id")?.unwrap_or_else(id);
            let exists: bool = c.query_row(
                "SELECT EXISTS(SELECT 1 FROM runs WHERE id=?1)",
                [&run_id],
                |r| r.get(0),
            )?;
            if exists {
                return Err(ApiError::new(
                    "RUN_CONFLICT",
                    "This run_id has already been used. Resume with a new run_id",
                ));
            }
            c.execute("UPDATE runs SET status='interrupted',ended_at=?2 WHERE task_id=?1 AND status='running'",params![task_id,now()])?;
            c.execute("INSERT INTO runs(id,task_id,agent_id,status,started_at,summary,next_action) VALUES (?1,?2,?3,'running',?4,?5,?6)",params![run_id,task_id,agent,now(),string(p,"summary")?,t.next_action])?;
            t.status = "in_progress".into();
            extra["run_id"] = json!(run_id);
        }
        "task.review" | "task.complete" | "task.pause" | "task.review.decide" => {
            let decision = if r.method == "task.review.decide" {
                if t.status != "review" {
                    return Err(ApiError::new(
                        "INVALID_STATE",
                        "Only tasks in review can receive a review decision",
                    ));
                }
                let decision = required(p, "decision")?;
                if !["approve", "request_changes", "reject"].contains(&decision) {
                    return Err(invalid(
                        "decision must be approve, request_changes, or reject",
                    ));
                }
                required(p, "summary")?;
                Some(decision)
            } else {
                None
            };
            let completing = r.method == "task.complete" || decision == Some("approve");
            let summary = string(p, "summary")?;
            if completing && summary.trim().is_empty() {
                return Err(invalid(
                    "Record the verified outcome in summary before completing the task",
                ));
            }
            let run_status = if completing {
                "completed"
            } else if r.method == "task.review" {
                "review"
            } else {
                "interrupted"
            };
            let target_run = optional(p, "run_id")?.or(
                if decision.is_some() || (completing && t.status == "review") {
                    workflow::latest_review_run(c, task_id)?
                } else {
                    None
                },
            );
            if let Some(run_id) = &target_run {
                let state: Option<String> = c
                    .query_row(
                        "SELECT status FROM runs WHERE id=?1 AND task_id=?2",
                        params![run_id, task_id],
                        |row| row.get(0),
                    )
                    .optional()?;
                let active = state.as_deref() == Some("running")
                    || ((completing || decision.is_some())
                        && t.status == "review"
                        && state.as_deref() == Some("review"));
                if !active || !is_latest_run(c, task_id, run_id)? {
                    return Err(ApiError::new(
                        "RUN_CONFLICT",
                        "Only the current run can update the task status",
                    ));
                }
            }
            if p.get("next_action").is_some() {
                t.next_action = string(p, "next_action")?;
            }
            if p.get("blocked_reason").is_some() {
                t.blocked_reason = string(p, "blocked_reason")?;
            }
            if decision == Some("request_changes") {
                t.next_action = summary.clone();
                t.blocked_reason.clear();
            }
            if decision == Some("reject") {
                t.blocked_reason = summary.clone();
            }
            // The explicit review run has already been checked as the latest run.
            // Approval completes that run as well as its task.
            c.execute("UPDATE runs SET status=?2,ended_at=?3,summary=?4,next_action=?5 WHERE task_id=?1 AND (status='running' OR (?6 IS NOT NULL AND status='review' AND (?2='completed' OR ?7=1))) AND (?6 IS NULL OR id=?6)",params![task_id,run_status,now(),summary,t.next_action,target_run,decision.is_some()])?;
            t.status = if completing {
                "done"
            } else if r.method == "task.review" {
                "review"
            } else {
                "todo"
            }
            .into();
            if let Some(decision) = decision {
                workflow::record_review(c, r, task_id, decision, &summary, target_run.as_deref())?;
                extra["decision"] = json!(decision);
            }
            if completing {
                t.completion_summary = summary.clone();
            }
            extra["summary"] = json!(summary);
        }
        "task.attach" => {
            let run_id = optional(p, "run_id")?;
            if let Some(run_id) = &run_id {
                let valid: bool = c.query_row(
                    "SELECT EXISTS(SELECT 1 FROM runs WHERE id=?1 AND task_id=?2)",
                    params![run_id, task_id],
                    |r| r.get(0),
                )?;
                if !valid {
                    return Err(ApiError::new(
                        "RUN_CONFLICT",
                        "The run is not linked to this task",
                    ));
                }
            }
            let a = Artifact {
                id: id(),
                task_id: t.id.clone(),
                run_id,
                path: required(p, "path")?.into(),
                kind: optional(p, "kind")?.unwrap_or_else(|| "file".into()),
                description: string(p, "description")?,
                created_at: now(),
                locator: optional(p, "locator")?,
                provider: optional(p, "provider")?,
                verified_at: optional(p, "verified_at")?,
                metadata: p.get("metadata").cloned().unwrap_or_else(|| json!({})),
            };
            if !a.metadata.is_object() {
                return Err(invalid("metadata must be a JSON object"));
            }
            c.execute("INSERT INTO artifacts(id,task_id,run_id,path,kind,description,created_at,locator,provider,verified_at,metadata) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",params![a.id,a.task_id,a.run_id,a.path,a.kind,a.description,a.created_at,a.locator,a.provider,a.verified_at,serde_json::to_string(&a.metadata)?])?;
            extra["artifact"] = json!(a);
        }
        "run.update" | "run.finish" => {
            let run_id = required(p, "run_id")?;
            let run = all_runs(c, Some(task_id))?
                .into_iter()
                .find(|run| run.id == run_id)
                .ok_or_else(|| ApiError::new("NOT_FOUND", "Run not found"))?;
            let run_status = optional(p, "status")?.unwrap_or_else(|| {
                if r.method == "run.finish" && run.status == "running" {
                    "interrupted".into()
                } else {
                    run.status.clone()
                }
            });
            if !["running", "interrupted", "review", "completed", "failed"]
                .contains(&run_status.as_str())
            {
                return Err(invalid("Invalid run status"));
            }
            let latest = is_latest_run(c, task_id, run_id)?;
            if run_status == "running" && (!latest || run.status != "running") {
                return Err(ApiError::new(
                    "RUN_CONFLICT",
                    "Resume a finished run by creating a new run",
                ));
            }
            let summary = if p.get("summary").is_some() {
                string(p, "summary")?
            } else {
                run.summary
            };
            let next = if p.get("next_action").is_some() {
                string(p, "next_action")?
            } else {
                run.next_action
            };
            c.execute(
                "UPDATE runs SET status=?2,ended_at=?3,summary=?4,next_action=?5 WHERE id=?1",
                params![
                    run_id,
                    run_status,
                    if run_status == "running" {
                        None
                    } else if run.status == "running" {
                        Some(now())
                    } else {
                        run.ended_at.clone().or_else(|| Some(now()))
                    },
                    summary,
                    next
                ],
            )?;
            if latest && run.status == "running" && p.get("next_action").is_some() {
                t.next_action = next;
            }
            // Corrections to ended runs stay in that run, including the latest one.
            // Finishing a run deliberately does not complete its task.
            extra["run_id"] = json!(run_id);
        }
        _ => {
            return Err(ApiError::new(
                "METHOD_NOT_FOUND",
                "Unsupported mutation request",
            ))
        }
    }
    if r.method == "task.start"
        || r.method == "task.complete"
        || (r.method == "task.review.decide" && p["decision"] == "approve")
        || (r.method == "task.update"
            && p.get("status").is_some()
            && ["in_progress", "done"].contains(&t.status.as_str()))
    {
        workflow::validate_transition(c, &t)?;
    }
    if actor.is_some() && actor == t.assignee {
        t.claimed_at = Some(now());
    }
    t.revision = allocate_revision(c, &t.id, t.revision)?;
    t.updated_at = now();
    save_task(c, &t)?;
    let t = get_task(c, task_id)?;
    let seq = record(
        c,
        r,
        Some(task_id),
        &r.method,
        json!({"task":t,"detail":extra}),
    )?;
    let mut result = result_task(c, &t, seq)?;
    for (key, value) in extra.as_object().unwrap() {
        result[key] = value.clone();
    }
    Ok(result)
}

pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), ApiError> {
    use std::io::Write;
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::create_dir_all(parent)?;
    }
    let temp = path.with_extension(format!("tmp-{}", id()));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        private_permissions(&temp, 0o600)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temp, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}
/// macOS refuses a LaunchAgent that writes into an App Group container by path alone: App Data
/// protection denies it and a background service cannot show the consent prompt. Looking the
/// container up through Foundation lets the container manager approve this signed code for the
/// group, after which plain file writes are allowed.
#[cfg(target_os = "macos")]
mod group_container {
    use std::collections::HashSet;
    use std::ffi::{c_char, c_void, CString};
    use std::path::{Component, Path};
    use std::sync::Mutex;

    type Id = *mut c_void;
    #[link(name = "Foundation", kind = "framework")]
    extern "C" {}
    #[link(name = "objc")]
    extern "C" {
        fn objc_getClass(name: *const c_char) -> Id;
        fn sel_registerName(name: *const c_char) -> Id;
        fn objc_msgSend();
        fn objc_autoreleasePoolPush() -> *mut c_void;
        fn objc_autoreleasePoolPop(pool: *mut c_void);
    }
    static APPROVED: Mutex<Option<HashSet<String>>> = Mutex::new(None);

    /// `~/Library/Group Containers/<group>/…` → `<group>`.
    pub(crate) fn identifier(path: &Path) -> Option<String> {
        let mut components = path.components();
        while let Some(component) = components.next() {
            if component == Component::Normal("Group Containers".as_ref()) {
                return match components.next() {
                    Some(Component::Normal(group)) => group.to_str().map(str::to_owned),
                    _ => None,
                };
            }
        }
        None
    }

    pub(crate) fn approve(path: &Path) {
        let Some(group) = identifier(path) else {
            return;
        };
        // The container manager owns only this user's containers; other paths are plain files.
        let Some(home) = std::env::var_os("HOME") else {
            return;
        };
        if !path.starts_with(Path::new(&home).join("Library/Group Containers")) {
            return;
        }
        let mut approved = APPROVED.lock().unwrap_or_else(|e| e.into_inner());
        let approved = approved.get_or_insert_with(HashSet::new);
        if !approved.contains(&group) && lookup(&group) {
            approved.insert(group);
        }
    }

    /// `[[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:]`
    fn lookup(group: &str) -> bool {
        let Ok(group) = CString::new(group) else {
            return false;
        };
        unsafe {
            let send: unsafe extern "C" fn() = objc_msgSend;
            let send_none: unsafe extern "C" fn(Id, Id) -> Id = std::mem::transmute(send);
            let send_text: unsafe extern "C" fn(Id, Id, *const c_char) -> Id =
                std::mem::transmute(send);
            let send_object: unsafe extern "C" fn(Id, Id, Id) -> Id = std::mem::transmute(send);
            let pool = objc_autoreleasePoolPush();
            let manager = send_none(
                objc_getClass(c"NSFileManager".as_ptr()),
                sel_registerName(c"defaultManager".as_ptr()),
            );
            let name = send_text(
                objc_getClass(c"NSString".as_ptr()),
                sel_registerName(c"stringWithUTF8String:".as_ptr()),
                group.as_ptr(),
            );
            let url = send_object(
                manager,
                sel_registerName(c"containerURLForSecurityApplicationGroupIdentifier:".as_ptr()),
                name,
            );
            objc_autoreleasePoolPop(pool);
            !url.is_null()
        }
    }
}

pub fn private_permissions(path: &Path, mode: u32) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
    }
    Ok(())
}
fn markdown(doc: &Value) -> String {
    let mut out = format!(
        "# Agent Workboard\n\nExported at: {}\n\n",
        doc["exported_at"].as_str().unwrap_or("")
    );
    for p in doc["projects"].as_array().unwrap() {
        out.push_str(&format!(
            "## {}\n\nDirectory: {}\n\n",
            p["name"].as_str().unwrap_or(""),
            p["directory"].as_str().unwrap_or("")
        ));
        for t in doc["tasks"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|t| t["project_id"] == p["id"])
        {
            let text = |key: &str| t[key].as_str().unwrap_or("");
            out.push_str(&format!("### {}\n\n- ID: {}\n- Parent task: {}\n- Status: {}\n- Assignee: {}\n- Goal: {}\n- Completion criteria: {}\n- Next action: {}\n- Outcome: {}\n\n",text("title"),text("id"),text("parent_id"),text("status"),text("assignee"),text("goal"),text("completion_criteria"),text("next_action"),text("completion_summary")));
            out.push_str(&format!(
                "- Due: {}\n- Schedule start: {}\n- Schedule end: {}\n- Time zone: {}\n\n",
                text("due_at"),
                text("scheduled_start"),
                text("scheduled_end"),
                text("time_zone")
            ));
            for a in doc["artifacts"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|a| a["task_id"] == t["id"])
            {
                out.push_str(&format!(
                    "- Artifact: {} — {}\n  - ID: {}\n  - Kind: {}\n  - Run: {}\n  - Location: {}\n  - Verified at: {}\n",
                    a["path"].as_str().unwrap_or(""),a["description"].as_str().unwrap_or(""),
                    a["id"].as_str().unwrap_or(""),a["kind"].as_str().unwrap_or(""),a["run_id"].as_str().unwrap_or(""),
                    a["locator"].as_str().or_else(||a["metadata"]["locator"].as_str()).unwrap_or(""),
                    a["verified_at"].as_str().or_else(||a["metadata"]["verified_at"].as_str()).unwrap_or(""),
                ));
                if a["metadata"]
                    .as_object()
                    .is_some_and(|fields| !fields.is_empty())
                {
                    out.push_str(&format!(
                        "\nLink metadata:\n\n```json\n{}\n```\n\n",
                        serde_json::to_string_pretty(&a["metadata"]).unwrap()
                    ));
                }
            }
            for run in doc["runs"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|run| run["task_id"] == t["id"])
            {
                out.push_str(&format!("\n#### Run {}\n\n- Agent: {}\n- Status: {}\n- Started: {}\n- Ended: {}\n- Resume summary: {}\n- Next action: {}\n",run["id"].as_str().unwrap_or(""),run["agent_id"].as_str().unwrap_or(""),run["status"].as_str().unwrap_or(""),run["started_at"].as_str().unwrap_or(""),run["ended_at"].as_str().unwrap_or(""),run["summary"].as_str().unwrap_or(""),run["next_action"].as_str().unwrap_or("")));
            }
            out.push('\n');
        }
    }
    if let Some(items) = doc["trash"].as_array().filter(|items| !items.is_empty()) {
        out.push_str("## Trash\n\n");
        for item in items {
            let task = &item["task"];
            out.push_str(&format!(
                "- {} (ID {}) · deleted {} by {} · {} subtasks\n",
                task["title"].as_str().unwrap_or(""),
                task["id"].as_str().unwrap_or(""),
                item["deleted_at"].as_str().unwrap_or(""),
                item["deleted_by"].as_str().unwrap_or("user"),
                item["subtask_count"].as_u64().unwrap_or(0)
            ));
        }
        out.push('\n');
    }
    workflow::markdown(doc, &mut out);
    out
}

#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_workflow;
