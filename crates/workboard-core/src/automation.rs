//! Durable development workflows. Executor code stays in separately installed plugins.
use super::*;
mod presets;
mod rules;

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Configuration {
    plugin_id: String,
    method: String,
    resource_key: String,
    params: Value,
    max_reworks: i64,
    timeout_seconds: i64,
    #[serde(default = "rules::default_rules")]
    rules: Vec<rules::Rule>,
    #[serde(default)]
    stage_settings: Value,
    #[serde(default)]
    process_preset: Option<String>,
    #[serde(default)]
    allowed_presets: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct StageResult {
    outcome: String,
    summary: String,
    evidence: Vec<String>,
    source_version: String,
    #[serde(default)]
    preset_id: Option<String>,
    #[serde(default)]
    selection_reason: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Attempt {
    id: String,
    stage: String,
    state: String,
    token: String,
    task_revision: i64,
    input_version: String,
    created_at: String,
    deadline: String,
    worker_exited: bool,
    executor_generation: String,
    receipt: Value,
    result: Option<StageResult>,
    #[serde(default)]
    settings: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Automation {
    task_id: String,
    template: String,
    configuration: Configuration,
    state: String,
    stage: String,
    revision: i64,
    reworks: i64,
    #[serde(default)]
    limit_reached: bool,
    run_id: Option<String>,
    approval_task_revision: Option<i64>,
    message: String,
    attempts: Vec<Attempt>,
    #[serde(default)]
    single_stage: bool,
    #[serde(default)]
    active_rule: Option<rules::Rule>,
    #[serde(default)]
    pending_rule: Option<rules::Rule>,
    #[serde(default)]
    inherited_revision: Option<i64>,
    #[serde(default)]
    process: Option<presets::Process>,
}

pub(super) fn migrate(c: &Connection) -> Result<(), ApiError> {
    c.execute_batch("BEGIN IMMEDIATE; CREATE TABLE automations(task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE, data TEXT NOT NULL); CREATE TABLE automation_executors(id TEXT PRIMARY KEY,generation TEXT NOT NULL,enabled INTEGER NOT NULL); PRAGMA user_version=7; COMMIT;")?;
    Ok(())
}

fn load(c: &Connection, task_id: &str) -> Result<Option<Automation>, ApiError> {
    let raw: Option<String> = c
        .query_row(
            "SELECT data FROM automations WHERE task_id=?1",
            [task_id],
            |row| row.get(0),
        )
        .optional()?;
    raw.map(|v| serde_json::from_str(&v).map_err(ApiError::from))
        .transpose()
}

fn all(c: &Connection) -> Result<Vec<Automation>, ApiError> {
    let mut statement = c.prepare("SELECT a.data FROM automations a JOIN tasks t ON t.id=a.task_id WHERE t.deleted_at IS NULL ORDER BY a.task_id")?;
    let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
    rows.map(|row| Ok(serde_json::from_str(&row?)?)).collect()
}

fn public(a: &Automation) -> Value {
    let mut value = json!(a);
    for attempt in value["attempts"].as_array_mut().unwrap() {
        attempt.as_object_mut().unwrap().remove("token");
    }
    value
}

fn resource_busy(c: &Connection, a: &Automation) -> Result<bool, ApiError> {
    let mut statement = c.prepare("SELECT data FROM automations WHERE task_id<>?1")?;
    let rows = statement.query_map([&a.task_id], |row| row.get::<_, String>(0))?;
    for row in rows {
        let other: Automation = serde_json::from_str(&row?)?;
        if other.configuration.plugin_id == a.configuration.plugin_id
            && other.configuration.resource_key == a.configuration.resource_key
            && other
                .attempts
                .iter()
                .any(|v| !v.worker_exited && v.state != "queued")
        {
            return Ok(true);
        }
    }
    Ok(false)
}

pub(super) fn get_public(c: &Connection, task_id: &str) -> Result<Value, ApiError> {
    Ok(load(c, task_id)?
        .as_ref()
        .map(public)
        .unwrap_or(Value::Null))
}

pub(super) fn list(c: &Connection) -> Result<Vec<Value>, ApiError> {
    Ok(all(c)?.iter().map(public).collect())
}

fn store(c: &Connection, a: &Automation) -> Result<(), ApiError> {
    c.execute("INSERT INTO automations(task_id,data) VALUES (?1,?2) ON CONFLICT(task_id) DO UPDATE SET data=excluded.data", params![a.task_id, serde_json::to_string(a)?])?;
    Ok(())
}

fn next_revision(c: &Connection, minimum: i64) -> Result<i64, ApiError> {
    let counter: Option<i64> = c
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM settings WHERE key='automation.revision'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let legacy: Option<i64> = c.query_row(
        "SELECT max(json_extract(data,'$.revision')) FROM automations",
        [],
        |row| row.get(0),
    )?;
    let revision = counter.unwrap_or(0).max(legacy.unwrap_or(0)).max(minimum) + 1;
    c.execute("INSERT INTO settings(key,value) VALUES ('automation.revision',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [revision.to_string()])?;
    Ok(revision)
}

pub(super) fn before_restore(c: &Connection) -> Result<(), ApiError> {
    let mut statement = c.prepare("SELECT data FROM automations")?;
    let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
    for row in rows {
        let a: Automation = serde_json::from_str(&row?)?;
        if a.attempts
            .iter()
            .any(|attempt| !attempt.worker_exited && attempt.state != "queued")
        {
            return Err(conflict("Confirm all automation agents have stopped before restoring a backup. Restoring cannot discard a live worker's resource lease"));
        }
    }
    next_revision(c, 0)?;
    Ok(())
}

fn save(c: &Connection, r: &Request, a: &mut Automation) -> Result<Value, ApiError> {
    a.revision = next_revision(c, a.revision)?;
    store(c, a)?;
    let sequence = record(c, r, Some(&a.task_id), &r.method, public(a))?;
    Ok(json!({"automation":public(a),"event_sequence":sequence}))
}

fn conflict(message: &str) -> ApiError {
    ApiError::new("AUTOMATION_CONFLICT", message)
}

fn current(a: &Automation) -> Result<&Attempt, ApiError> {
    a.attempts
        .last()
        .ok_or_else(|| conflict("This workflow has no stage attempt"))
}

fn executor_enabled(c: &Connection, a: &Automation, attempt: &Attempt) -> Result<(), ApiError> {
    let valid: bool = c.query_row("SELECT EXISTS(SELECT 1 FROM automation_executors WHERE id=?1 AND generation=?2 AND enabled=1)", params![a.configuration.plugin_id,attempt.executor_generation], |row| row.get(0))?;
    if !valid {
        return Err(ApiError::new(
            "PLUGIN_DISABLED",
            "The executor was disabled, removed, or reconfigured",
        ));
    }
    Ok(())
}

fn attempt_context(c: &Connection, p: &Value) -> Result<(Automation, usize), ApiError> {
    let task_id = required(p, "task_id")?;
    let a =
        load(c, task_id)?.ok_or_else(|| conflict("Configure automation for this task first"))?;
    let attempt_id = required(p, "attempt_id")?;
    let index = a
        .attempts
        .iter()
        .position(|v| v.id == attempt_id)
        .ok_or_else(|| conflict("Unknown stage attempt"))?;
    if required(p, "token")? != a.attempts[index].token {
        return Err(conflict("The stage token does not match"));
    }
    Ok((a, index))
}

fn validate_active(c: &Connection, a: &Automation, index: usize) -> Result<(), ApiError> {
    let task = get_task(c, &a.task_id)?;
    if index + 1 != a.attempts.len()
        || !["running", "paused"].contains(&a.state.as_str())
        || !["launching", "running", "reported"].contains(&a.attempts[index].state.as_str())
    {
        return Err(conflict(
            "This stage no longer has authority to update the workflow",
        ));
    }
    if a.attempts[index].task_revision != task.revision {
        return Err(conflict("The task changed after this stage started"));
    }
    if a.attempts[index].deadline < now() {
        return Err(conflict(
            "The stage deadline has passed. Inspect the agent before resuming",
        ));
    }
    executor_enabled(c, a, &a.attempts[index])
}

pub(super) fn read(c: &Connection, method: &str, p: &Value) -> Result<Option<Value>, ApiError> {
    if let Some(value) = presets::read(c, method, p)? {
        return Ok(Some(value));
    }
    Ok(Some(match method {
        "automation.get" => {
            let task_id = required(p, "task_id")?;
            get_task(c, task_id)?;
            json!({"automation":get_public(c,task_id)?})
        }
        "automation.list" => json!({"automations":list(c)?}),
        "automation.defaults.get" => rules::get_defaults(c, required(p, "project_id")?)?,
        "automation.jobs" => {
            let mut jobs = vec![];
            for a in all(c)? {
                if a.state != "running" {
                    continue;
                }
                if let Some(attempt) = a.attempts.last() {
                    if attempt.state == "queued" && resource_busy(c, &a)? {
                        continue;
                    }
                    if ["queued", "launching"].contains(&attempt.state.as_str())
                        || (!attempt.worker_exited && attempt.deadline <= now())
                    {
                        jobs.push(json!({"task_id":a.task_id,"attempt":attempt,"configuration":a.configuration}));
                    }
                }
            }
            json!({"jobs":jobs})
        }
        "automation.context" => {
            let (a, index) = attempt_context(c, p)?;
            validate_active(c, &a, index)?;
            json!({"automation":public(&a),"attempt":a.attempts[index],"task":get_task(c,&a.task_id)?})
        }
        _ => return Ok(None),
    }))
}

pub(super) fn is_mutation(method: &str) -> bool {
    matches!(
        method,
        "automation.configure"
            | "automation.defaults.set"
            | "automation.presets.save"
            | "automation.presets.delete"
            | "automation.preset.apply"
            | "automation.start"
            | "automation.pause"
            | "automation.resume"
            | "automation.disable"
            | "automation.launch"
            | "automation.launched"
            | "automation.report"
            | "automation.settle"
            | "automation.fail"
            | "automation.resolve"
            | "automation.executor.changed"
    )
}

fn project_task(
    c: &Connection,
    a: &Automation,
    status: &str,
    next_action: &str,
) -> Result<(), ApiError> {
    let mut task = get_task(c, &a.task_id)?;
    task.status = status.into();
    task.next_action = next_action.into();
    task.revision = allocate_revision(c, &task.id, task.revision)?;
    task.updated_at = now();
    save_task(c, &task)
}

fn enqueue(c: &Connection, a: &mut Automation, input_version: String) -> Result<(), ApiError> {
    if a.attempts
        .iter()
        .any(|attempt| !attempt.worker_exited && attempt.state != "queued")
    {
        return Err(conflict(
            "The previous agent has not confirmed exit. Inspect it before resolving the attempt",
        ));
    }
    let status = if a.stage == "review" {
        "review"
    } else {
        "in_progress"
    };
    if !a.single_stage {
        project_task(c, a, status, &format!("Automation: {}", a.stage))?;
    }
    if let Some(run_id) = &a.run_id {
        c.execute(
            "UPDATE runs SET status='running',ended_at=NULL WHERE id=?1",
            [run_id],
        )?;
    }
    a.attempts.push(Attempt {
        id: id(),
        stage: a.stage.clone(),
        state: "queued".into(),
        token: id(),
        task_revision: get_task(c, &a.task_id)?.revision,
        input_version,
        created_at: now(),
        deadline: String::new(),
        worker_exited: false,
        executor_generation: String::new(),
        receipt: json!({}),
        result: None,
        settings: rules::attempt_settings(a),
    });
    a.state = "running".into();
    a.message.clear();
    Ok(())
}

fn start(c: &Connection, a: &mut Automation, reuse_started_run: bool) -> Result<(), ApiError> {
    let task = get_task(c, &a.task_id)?;
    if !["todo", "in_progress"].contains(&task.status.as_str()) {
        return Err(conflict(
            "Move this task to Todo before starting automation",
        ));
    }
    if task.goal.trim().is_empty() || task.completion_criteria.trim().is_empty() {
        return Err(invalid(
            "Set a goal and completion criteria before starting automation",
        ));
    }
    workflow::validate_transition(
        c,
        &Task {
            status: "in_progress".into(),
            ..task.clone()
        },
    )?;
    if !task.blocked_reason.trim().is_empty() {
        return Err(conflict("Clear the task's blocking reason first"));
    }
    let existing: Option<String> = c
        .query_row(
            "SELECT id FROM runs WHERE task_id=?1 AND status='running' ORDER BY rowid DESC LIMIT 1",
            [&task.id],
            |row| row.get(0),
        )
        .optional()?;
    if existing.is_some() && !reuse_started_run {
        return Err(conflict(
            "Pause the current task run before starting automation",
        ));
    }
    let run_id = existing.clone().unwrap_or_else(id);
    if existing.is_none() {
        c.execute("INSERT INTO runs(id,task_id,agent_id,status,started_at,summary,next_action) VALUES (?1,?2,?3,'running',?4,'','')",params![run_id,task.id,format!("automation:{}",task.id),now()])?;
    }
    a.run_id = Some(run_id);
    a.single_stage = false;
    a.active_rule = a
        .configuration
        .rules
        .iter()
        .find(|rule| rule.action == "development")
        .cloned();
    presets::begin(c, a)?;
    a.reworks = 0;
    enqueue(c, a, String::new())
}

fn advance(c: &Connection, a: &mut Automation) -> Result<(), ApiError> {
    let result = current(a)?
        .result
        .clone()
        .ok_or_else(|| conflict("The agent exited without a structured result"))?;
    if result.outcome == "blocked" {
        a.state = "blocked".into();
        a.message = result.summary;
        return Ok(());
    }
    if a.single_stage {
        a.state = "waiting".into();
        a.message = format!(
            "{} finished: {}. Waiting for another status change.",
            a.stage, result.summary
        );
        if let Some(run_id) = &a.run_id {
            c.execute(
                "UPDATE runs SET status='paused',ended_at=?2,summary=?3,next_action=?4 WHERE id=?1",
                params![run_id, now(), result.summary, a.message],
            )?;
        }
        return Ok(());
    }
    if a.process.is_some() {
        return presets::advance(c, a, &result);
    }
    a.stage=match a.stage.as_str() {
        "preflight"=>"work",
        "work"|"rework"=>"review",
        "review" if result.outcome=="changes_requested"=>{
            if a.reworks>=a.configuration.max_reworks { a.limit_reached=true; a.state="blocked".into(); a.message="The rework limit was reached. Disable and configure a new workflow to change its limit.".into(); return Ok(()); }
            a.reworks+=1; "rework"
        },
        "review"=>"release",
        "release"=>{
            a.state="awaiting_approval".into(); a.message="Release preparation is complete. Final approval is required.".into();
            project_task(c,a,"review",&a.message)?;
            a.approval_task_revision=Some(get_task(c,&a.task_id)?.revision);
            if let Some(run_id)=&a.run_id { c.execute("UPDATE runs SET status='review',ended_at=?2,summary=?3,next_action=?4 WHERE id=?1",params![run_id,now(),result.summary,a.message])?; }
            return Ok(());
        },
        _=>return Err(conflict("Unknown development stage")),
    }.into();
    let input = if ["review", "release"].contains(&a.stage.as_str()) {
        result.source_version
    } else {
        String::new()
    };
    enqueue(c, a, input)
}

pub(super) fn mutate(c: &Transaction<'_>, r: &Request) -> Result<Option<Value>, ApiError> {
    if !is_mutation(&r.method) {
        return Ok(None);
    }
    let p = &r.params;
    if let Some(value) = presets::mutate(c, r)? {
        return Ok(Some(value));
    }
    if r.method == "automation.defaults.set" {
        return Ok(Some(rules::set_defaults(c, r)?));
    }
    if r.method == "automation.executor.changed" {
        let plugin_id = required(p, "plugin_id")?;
        let generation = required(p, "generation")?;
        let enabled = flag(p, "enabled")?;
        c.execute("INSERT INTO automation_executors(id,generation,enabled) VALUES (?1,?2,?3) ON CONFLICT(id) DO UPDATE SET generation=excluded.generation,enabled=excluded.enabled",params![plugin_id,generation,enabled])?;
        for mut a in all(c)? {
            if a.configuration.plugin_id == plugin_id
                && (["running", "paused"].contains(&a.state.as_str()) || a.pending_rule.is_some())
                && a.attempts.last().is_some_and(|v| {
                    !v.executor_generation.is_empty()
                        && (v.executor_generation != generation || !enabled)
                })
            {
                a.pending_rule = None;
                fence(
                    &mut a,
                    "The executor was disabled, removed, or reconfigured",
                );
                save(c, r, &mut a)?;
            }
        }
        return Ok(Some(json!({"plugin_id":plugin_id,"enabled":enabled})));
    }
    if matches!(
        r.method.as_str(),
        "automation.launch"
            | "automation.launched"
            | "automation.report"
            | "automation.settle"
            | "automation.fail"
    ) {
        let (mut a, index) = attempt_context(c, p)?;
        if r.method == "automation.settle" {
            if a.attempts[index].worker_exited && a.attempts[index].state == "settled" {
                return Ok(Some(
                    json!({"automation":public(&a),"event_sequence":sequence(c)?}),
                ));
            }
            // An exit receipt can retire a fenced attempt, but cannot grant it authority again.
            a.attempts[index].worker_exited = true;
            if a.pending_rule.is_some()
                && !a
                    .attempts
                    .iter()
                    .any(|v| !v.worker_exited && v.state != "queued")
            {
                let rule = a.pending_rule.take().unwrap();
                rules::trigger(c, &mut a, rule, false);
                return Ok(Some(save(c, r, &mut a)?));
            }
            if validate_active(c, &a, index).is_ok() {
                let exit_code = integer(p, "exit_code", -1)?;
                let source_version = string(p, "source_version")?;
                let valid = a.attempts[index]
                    .result
                    .as_ref()
                    .is_some_and(|result| result.source_version == source_version);
                if exit_code != 0 || !valid {
                    a.attempts[index].state = "failed".into();
                    a.state = "blocked".into();
                    a.message = if exit_code != 0 {
                        format!("The stage process exited with code {exit_code}. Inspect its output before resuming.")
                    } else {
                        "The agent exited without a result, or the source changed after its report."
                            .into()
                    };
                } else {
                    a.attempts[index].state = "settled".into();
                    if a.state != "paused" {
                        advance(c, &mut a)?;
                    }
                }
            } else if index + 1 == a.attempts.len()
                && ["running", "paused"].contains(&a.state.as_str())
            {
                fence(&mut a, "The stage exited after losing authority or exceeding its deadline. Inspect its results before resuming.");
            }
            return Ok(Some(save(c, r, &mut a)?));
        }
        if r.method == "automation.launched" {
            // A callback can finish before terminal creation returns. Attach only the old receipt.
            a.attempts[index].receipt = p.get("receipt").cloned().unwrap_or(json!({}));
            if a.attempts[index].state == "launching" {
                a.attempts[index].state = "running".into();
            }
            return Ok(Some(save(c, r, &mut a)?));
        }
        if r.method == "automation.launch" {
            if index + 1 != a.attempts.len()
                || a.state != "running"
                || !["queued", "launching"].contains(&a.attempts[index].state.as_str())
            {
                return Err(conflict("This stage is not queued for execution"));
            }
            if get_task(c, &a.task_id)?.revision != a.attempts[index].task_revision {
                return Err(conflict("The task changed before launch"));
            }
            a.attempts[index].executor_generation = required(p, "executor_generation")?.into();
            if resource_busy(c, &a)? {
                return Err(ApiError::new(
                    "AUTOMATION_RESOURCE_BUSY",
                    "Another unresolved agent owns this executor resource",
                ));
            }
            if a.attempts[index].state == "queued" {
                a.attempts[index].deadline = (Utc::now()
                    + chrono::Duration::seconds(a.configuration.timeout_seconds))
                .to_rfc3339_opts(SecondsFormat::Millis, true);
            }
            executor_enabled(c, &a, &a.attempts[index])?;
            a.attempts[index].state = "launching".into();
        } else if r.method == "automation.fail" {
            if index + 1 != a.attempts.len() || !["running", "paused"].contains(&a.state.as_str()) {
                return Err(conflict("This workflow is no longer active"));
            }
            a.state = "blocked".into();
            a.message = required(p, "summary")?.into();
            a.attempts[index].state = "uncertain".into();
            if flag(p, "never_started")? {
                a.attempts[index].worker_exited = true;
            }
        } else {
            validate_active(c, &a, index)?;
            if a.attempts[index].result.is_some() {
                return Err(conflict(
                    "This attempt already has a result. Retry the original request ID",
                ));
            }
            let outcome = required(p, "outcome")?;
            if !["pass", "changes_requested", "blocked"].contains(&outcome)
                || (outcome == "changes_requested" && a.stage != "review")
            {
                return Err(invalid(
                    "Use pass, blocked, or changes_requested for a review",
                ));
            }
            let evidence: Vec<String> =
                serde_json::from_value(p.get("evidence").cloned().unwrap_or(json!([])))?;
            if evidence.is_empty()
                || evidence.len() > 30
                || evidence
                    .iter()
                    .any(|v| v.trim().is_empty() || v.len() > 8000)
            {
                return Err(invalid("Supply between one and thirty nonempty evidence paths, URLs, or verification notes"));
            }
            let source_version = required(p, "source_version")?.to_string();
            if !a.attempts[index].input_version.is_empty()
                && source_version != a.attempts[index].input_version
            {
                return Err(conflict(
                    "The reviewed source differs from the previous stage's source version",
                ));
            }
            presets::validate_selection(&a, p)?;
            let result = StageResult {
                outcome: outcome.into(),
                summary: required(p, "summary")?.into(),
                evidence,
                source_version,
                preset_id: p
                    .get("preset_id")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                selection_reason: p
                    .get("selection_reason")
                    .and_then(Value::as_str)
                    .map(str::to_string),
            };
            for path in &result.evidence {
                if path.starts_with('/')
                    || path.starts_with("https://")
                    || path.starts_with("http://")
                    || path.starts_with("file://")
                {
                    c.execute("INSERT INTO artifacts(id,task_id,run_id,path,kind,description,created_at,metadata) VALUES (?1,?2,?3,?4,'verification',?5,?6,?7)",params![id(),a.task_id,a.run_id,path,format!("Automation {}: {}",a.stage,result.summary),now(),json!({"automation_attempt_id":a.attempts[index].id,"stage":a.stage,"source_version":result.source_version,"verification":"agent_reported"}).to_string()])?;
                }
            }
            a.attempts[index].result = Some(result);
            a.attempts[index].state = "reported".into();
        }
        return Ok(Some(save(c, r, &mut a)?));
    }
    let task_id = required(p, "task_id")?;
    let task = get_task(c, task_id)?;
    check_revision(&task, p, true)?;
    check_owners(std::slice::from_ref(&task), &optional(p, "agent_id")?)?;
    let previous = load(c, task_id)?;
    if let Some(a) = &previous {
        if p.get("expected_automation_revision")
            .and_then(Value::as_i64)
            != Some(a.revision)
        {
            return Err(conflict(
                "The workflow changed. Read its revision again before editing",
            ));
        }
    }
    if ["automation.configure", "automation.preset.apply"].contains(&r.method.as_str()) {
        if previous.as_ref().is_some_and(|a| {
            !["disabled", "armed", "waiting", "completed", "canceled"].contains(&a.state.as_str())
                || a.attempts
                    .iter()
                    .any(|v| !v.worker_exited && v.state != "queued")
        }) {
            return Err(conflict(
                "Disable this workflow and confirm agent exit before changing its configuration",
            ));
        }
        let mut configuration: Configuration = if r.method == "automation.preset.apply" {
            previous
                .as_ref()
                .map(|a| a.configuration.clone())
                .ok_or_else(|| {
                    invalid("Configure an executor for this task before selecting a preset")
                })?
        } else {
            serde_json::from_value(
                p.get("configuration")
                    .cloned()
                    .ok_or_else(|| invalid("configuration is required"))?,
            )?
        };
        if r.method == "automation.preset.apply" {
            if p.get("expected_automation_revision")
                .and_then(Value::as_i64)
                != previous.as_ref().map(|a| a.revision)
            {
                return Err(conflict(
                    "Read the workflow revision before selecting a process preset",
                ));
            }
            configuration.process_preset = Some(required(p, "preset_id")?.into());
            required(p, "reason")?;
        }
        let process = presets::prepare(
            c,
            &configuration,
            p["agent_id"].as_str().unwrap_or("user"),
            p["reason"].as_str().unwrap_or("Configured process preset"),
        )?;
        rules::validate_configuration(&configuration)?;
        let mut a = Automation {
            task_id: task_id.into(),
            template: "development-v1".into(),
            configuration,
            state: "armed".into(),
            stage: "preflight".into(),
            revision: previous.as_ref().map_or(0, |a| a.revision),
            reworks: 0,
            limit_reached: false,
            run_id: None,
            approval_task_revision: None,
            message: "Move the task from Todo to In Progress, or start automation.".into(),
            attempts: previous.map_or(vec![], |a| a.attempts),
            single_stage: false,
            active_rule: None,
            pending_rule: None,
            inherited_revision: None,
            process,
        };
        return Ok(Some(save(c, r, &mut a)?));
    }
    let mut a = previous.ok_or_else(|| conflict("Configure automation for this task first"))?;
    match r.method.as_str() {
        "automation.start" => {
            if a.state != "armed" {
                return Err(conflict("Only an armed workflow can start"));
            }
            start(c, &mut a, false)?;
        }
        "automation.pause" => {
            if a.state != "running" {
                return Err(conflict("Only a running workflow can pause"));
            }
            a.state = "paused".into();
            a.message = "Paused. An active agent may finish, but no next stage will start.".into();
        }
        "automation.disable" => {
            a.pending_rule = None;
            fence(&mut a,"Automation is disabled. Inspect any active agent in its executor before restarting.");
            a.state = "disabled".into();
        }
        "automation.resolve" => {
            if !flag(p, "confirm_stopped")? || required(p, "summary")?.trim().is_empty() {
                return Err(invalid("Confirm agent exit and record what you checked"));
            }
            if !["blocked", "paused", "disabled", "canceled"].contains(&a.state.as_str()) {
                return Err(conflict("Resolve only a stopped or blocked workflow"));
            }
            for attempt in &mut a.attempts {
                attempt.worker_exited = true;
            }
            a.message = required(p, "summary")?.into();
        }
        "automation.resume" => {
            if let Some(rule) = a.pending_rule.clone() {
                if a.attempts
                    .iter()
                    .any(|v| !v.worker_exited && v.state != "queued")
                {
                    return Err(conflict(
                        "Confirm the previous agent exited before starting the pending rule",
                    ));
                }
                a.pending_rule = None;
                rules::trigger(c, &mut a, rule, false);
                return Ok(Some(save(c, r, &mut a)?));
            }
            if a.limit_reached {
                return Err(conflict("The rework limit was reached. Disable and configure a new workflow to change its limit"));
            }
            if !["paused", "blocked"].contains(&a.state.as_str()) {
                return Err(conflict("Only a paused or blocked workflow can resume"));
            }
            if is_closed(&task.status) {
                return Err(conflict("Reopen the task before resuming"));
            }
            workflow::validate_transition(
                c,
                &Task {
                    status: "in_progress".into(),
                    ..task.clone()
                },
            )?;
            if !task.blocked_reason.trim().is_empty() {
                return Err(conflict("Clear the task's blocking reason first"));
            }
            let last = current(&a)?.clone();
            if a.state == "paused"
                && ["queued", "launching", "running", "reported"].contains(&last.state.as_str())
                && last.task_revision == task.revision
            {
                a.state = "running".into();
                a.message.clear();
            } else if !last.worker_exited {
                return Err(conflict("Agent exit is unconfirmed. Inspect the executor and resolve this attempt first"));
            } else if a.state == "paused" && last.state == "settled" {
                a.state = "running".into();
                advance(c, &mut a)?;
            } else {
                let input = if a.stage == last.stage {
                    last.input_version
                } else {
                    String::new()
                };
                if a.stage == "select" && last.state == "superseded" {
                    presets::begin(c, &mut a)?;
                }
                enqueue(c, &mut a, input)?;
            }
        }
        _ => return Err(invalid("Unsupported automation request")),
    }
    Ok(Some(save(c, r, &mut a)?))
}

fn non_material_change(r: &Request) -> bool {
    matches!(r.method.as_str(), "task.attach" | "task.heartbeat")
        || (r.method == "task.checklist.update"
            && r.params.get("text").is_none()
            && r.params.get("required").is_none())
}

fn fence(a: &mut Automation, message: &str) {
    a.state = "blocked".into();
    a.message = message.into();
    if let Some(attempt) = a.attempts.last_mut() {
        if attempt.state == "queued" {
            attempt.worker_exited = true;
        }
        attempt.state = "superseded".into();
    }
}

pub(super) fn before_mutation(c: &Connection, r: &Request) -> Result<(), ApiError> {
    if !matches!(
        r.method.as_str(),
        "project.delete" | "trash.purge" | "trash.empty"
    ) {
        return Ok(());
    }
    let mut statement = c.prepare(
        "SELECT a.data,t.project_id,t.deleted_at FROM automations a JOIN tasks t ON t.id=a.task_id",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,
        ))
    })?;
    for row in rows {
        let (data, project, deleted) = row?;
        let a: Automation = serde_json::from_str(&data)?;
        if !a
            .attempts
            .iter()
            .any(|v| !v.worker_exited && v.state != "queued")
        {
            continue;
        }
        let affected=match r.method.as_str() {
            "project.delete"=>r.params["project_id"]==project && flag(&r.params,"with_tasks")?,
            "trash.empty"=>deleted.is_some(),
            "trash.purge"=>c.query_row("WITH RECURSIVE descendants(id) AS (SELECT id FROM tasks WHERE id=?1 UNION SELECT t.id FROM tasks t JOIN descendants d ON t.parent_id=d.id) SELECT EXISTS(SELECT 1 FROM descendants WHERE id=?2)",params![required(&r.params,"task_id")?,a.task_id],|row|row.get(0))?,
            _=>false,
        };
        if affected {
            return Err(conflict("Confirm the active automation agent has stopped before permanently deleting its task. Restore a trashed task to inspect and resolve its workflow"));
        }
    }
    Ok(())
}

pub(super) fn after_mutation(
    c: &Connection,
    r: &Request,
    before: &std::collections::HashMap<String, String>,
) -> Result<(), ApiError> {
    if r.method.starts_with("automation.") {
        return Ok(());
    }
    rules::inherit_new(c, r, before)?;
    for mut a in all(c)? {
        let task = get_task(c, &a.task_id)?;
        if !a.single_stage
            && task.status == "done"
            && ["running", "paused", "blocked"].contains(&a.state.as_str())
        {
            return Err(conflict(
                "Finish the selected process before approving this automated task",
            ));
        }
        let changed = before
            .get(&a.task_id)
            .is_some_and(|status| status != &task.status);
        let rule = a
            .configuration
            .rules
            .iter()
            .find(|rule| rule.status == task.status)
            .cloned();
        if changed
            && a.state != "disabled"
            && !(a.state == "awaiting_approval"
                && r.method == "task.review.decide"
                && r.params["decision"] == "request_changes")
        {
            if let Some(rule) = rule {
                if ["running", "paused"].contains(&a.state.as_str()) {
                    fence(&mut a, "Status changed. Waiting for the previous agent to exit before starting its rule.");
                }
                if a.attempts
                    .iter()
                    .any(|v| !v.worker_exited && v.state != "queued")
                {
                    a.pending_rule = Some(rule);
                    a.state = "blocked".into();
                    a.message =
                        "Status rule queued. Waiting for the previous agent to confirm exit."
                            .into();
                } else {
                    rules::trigger(c, &mut a, rule, r.method == "task.start");
                }
                save(c, r, &mut a)?;
                continue;
            }
        }
        if task.status == "done" && a.state == "awaiting_approval" {
            a.state = "completed".into();
            a.message = "The user approved the completed workflow.".into();
            save(c, r, &mut a)?;
        } else if !a.single_stage
            && task.status == "canceled"
            && !["disabled", "canceled", "completed"].contains(&a.state.as_str())
        {
            fence(
                &mut a,
                "The task was canceled. Any late results are fenced.",
            );
            a.state = "canceled".into();
            save(c, r, &mut a)?;
        } else if a.state == "awaiting_approval"
            && r.method == "task.review.decide"
            && r.params["task_id"] == a.task_id
            && r.params["decision"] == "request_changes"
        {
            if a.process.is_some() {
                if !presets::request_rework(&mut a)? {
                    enqueue(c, &mut a, String::new())?;
                }
            } else if a.reworks >= a.configuration.max_reworks {
                a.limit_reached = true;
                fence(
                    &mut a,
                    "The rework limit was reached. Review the workflow before restarting.",
                );
            } else {
                a.reworks += 1;
                a.stage = "rework".into();
                enqueue(c, &mut a, String::new())?;
            }
            save(c, r, &mut a)?;
        } else if ["running", "paused"].contains(&a.state.as_str())
            && a.attempts
                .last()
                .is_some_and(|v| v.task_revision != task.revision)
        {
            if non_material_change(r) && r.params["task_id"] == a.task_id {
                a.attempts.last_mut().unwrap().task_revision = task.revision;
                store(c, &a)?;
            } else {
                fence(
                    &mut a,
                    "The task changed during automation. Inspect the active agent before resuming.",
                );
                a.pending_rule = None;
                if !a.single_stage {
                    presets::reset(&mut a);
                }
                save(c, r, &mut a)?;
            }
        } else if a.state == "awaiting_approval" && a.approval_task_revision != Some(task.revision)
        {
            if non_material_change(r) && r.params["task_id"] == a.task_id {
                a.approval_task_revision = Some(task.revision);
                store(c, &a)?;
            } else {
                fence(
                    &mut a,
                    "The task changed after the process finished. Review it again before approving.",
                );
                a.pending_rule = None;
                if !a.single_stage {
                    presets::reset(&mut a);
                }
                save(c, r, &mut a)?;
            }
        }
    }
    // Soft deletion preserves workflow history, but revokes execution authority.
    c.execute("UPDATE automations SET data=json_set(data,'$.state','canceled','$.message','The task is in the trash. Restart explicitly after restoring it.') WHERE task_id IN (SELECT id FROM tasks WHERE deleted_at IS NOT NULL) AND json_extract(data,'$.state') NOT IN ('canceled','disabled','completed')",[])?;
    Ok(())
}

impl Board {
    /// Reconcile generic plugin authority before the service accepts callbacks after restart.
    pub fn reconcile_automation_executors(&mut self, registry: &Value) -> Result<(), ApiError> {
        let known = {
            let mut statement = self
                .conn
                .prepare("SELECT id,generation,enabled FROM automation_executors")?;
            let rows = statement.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, bool>(2)?,
                ))
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        for (plugin_id, old_generation, old_enabled) in known {
            let entry = &registry[&plugin_id];
            let generation = entry["generation"].as_str().unwrap_or(&old_generation);
            let enabled =
                entry["enabled"].as_bool().unwrap_or(false) && entry["generation"].is_string();
            if generation != old_generation || enabled != old_enabled {
                let response=self.dispatch(Request{schema_version:SCHEMA_VERSION,request_id:id(),method:"automation.executor.changed".into(),params:json!({"plugin_id":plugin_id,"generation":generation,"enabled":enabled})});
                if let Some(error) = response.error {
                    return Err(error);
                }
            }
        }
        Ok(())
    }

    pub fn has_automation_work(&self) -> bool {
        read(&self.conn, "automation.jobs", &json!({}))
            .ok()
            .flatten()
            .is_some_and(|value| {
                value["jobs"]
                    .as_array()
                    .is_some_and(|jobs| !jobs.is_empty())
            })
    }
}

pub(super) fn after_restore(c: &Connection) -> Result<(), ApiError> {
    let restored = {
        let mut statement = c.prepare("SELECT data FROM automations")?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        rows.map(|row| Ok(serde_json::from_str::<Automation>(&row?)?))
            .collect::<Result<Vec<_>, ApiError>>()?
    };
    for mut a in restored {
        if !["disabled", "completed", "canceled"].contains(&a.state.as_str()) {
            fence(
                &mut a,
                "Restored from backup. Inspect previous agents before explicitly resuming.",
            );
        }
        for attempt in &mut a.attempts {
            attempt.token = id();
        }
        a.revision = next_revision(c, a.revision)?;
        store(c, &a)?;
    }
    Ok(())
}

#[cfg(test)]
#[path = "tests_automation.rs"]
mod tests;

pub(super) fn rules_statuses(
    c: &Connection,
) -> Result<std::collections::HashMap<String, String>, ApiError> {
    rules::statuses(c)
}
pub(super) fn project_defaults(c: &Connection) -> Result<Vec<Value>, ApiError> {
    rules::defaults(c)
}

pub(super) fn restore_defaults(c: &Connection) -> Result<(), ApiError> {
    rules::restore_defaults(c)?;
    presets::restore(c)
}

pub(super) fn process_presets(c: &Connection) -> Result<Value, ApiError> {
    Ok(json!(presets::list(c)?))
}
