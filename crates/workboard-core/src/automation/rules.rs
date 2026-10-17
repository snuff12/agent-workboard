//! Status rules and project defaults use the same transactional service boundary.
use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(super) struct Rule {
    pub id: String,
    pub status: String,
    pub action: String,
    #[serde(default = "preflight")]
    pub stage: String,
    #[serde(default)]
    pub agent: String,
    #[serde(default)]
    pub skills: Vec<String>,
    #[serde(default)]
    pub prompt: String,
    #[serde(default)]
    pub instructions: String,
}
fn preflight() -> String {
    "preflight".into()
}
pub(super) fn default_rules() -> Vec<Rule> {
    vec![Rule {
        id: "start-development".into(),
        status: "in_progress".into(),
        action: "development".into(),
        stage: preflight(),
        agent: String::new(),
        skills: vec![],
        prompt: String::new(),
        instructions: String::new(),
    }]
}
pub(super) fn validate_configuration(config: &Configuration) -> Result<(), ApiError> {
    if config.plugin_id.trim().is_empty()
        || config.method.trim().is_empty()
        || config.resource_key.trim().is_empty()
        || !config.params.is_object()
        || !(0..=10).contains(&config.max_reworks)
        || !(30..=86400).contains(&config.timeout_seconds)
        || config.rules.len() > 6
        || config.allowed_presets.len() > 100
        || config
            .allowed_presets
            .iter()
            .any(|id| id.is_empty() || id.len() > 100)
        || config
            .process_preset
            .as_ref()
            .is_some_and(|id| id.is_empty() || id.len() > 100)
    {
        return Err(invalid("Use an executor, object parameters, up to six status rules, 0-10 reworks, and a timeout of 30-86400 seconds"));
    }
    let mut statuses = std::collections::HashSet::new();
    let mut ids = std::collections::HashSet::new();
    for rule in &config.rules {
        if rule.id.trim().is_empty()
            || rule.id.len() > 100
            || !ids.insert(&rule.id)
            || !statuses.insert(&rule.status)
            || ![
                "backlog",
                "todo",
                "in_progress",
                "review",
                "done",
                "canceled",
            ]
            .contains(&rule.status.as_str())
            || !["development", "stage"].contains(&rule.action.as_str())
            || (rule.action == "development" && rule.status != "in_progress")
            || ![
                "preflight",
                "plan",
                "work",
                "verify",
                "review",
                "rework",
                "release",
            ]
            .contains(&rule.stage.as_str())
        {
            return Err(invalid("Use unique rule IDs and statuses. Development starts only in In Progress; single stages can use any status"));
        }
        validate_settings(&json!(rule))?;
    }
    if !config.stage_settings.is_null() {
        let settings = config
            .stage_settings
            .as_object()
            .ok_or_else(|| invalid("stage_settings must be an object"))?;
        for (stage, value) in settings {
            if ![
                "preflight",
                "plan",
                "work",
                "verify",
                "review",
                "rework",
                "release",
            ]
            .contains(&stage.as_str())
            {
                return Err(invalid("Unknown stage settings"));
            }
            validate_settings(value)?;
        }
    }
    Ok(())
}
pub(super) fn validate_settings(value: &Value) -> Result<(), ApiError> {
    if !value.is_object() {
        return Err(invalid("Stage settings must be an object"));
    }
    for key in ["agent", "prompt", "instructions"] {
        if let Some(v) = value.get(key) {
            let text = v
                .as_str()
                .ok_or_else(|| invalid("Agent, prompt, and instructions must be text"))?;
            if text.len() > 12000 || text.contains('\0') {
                return Err(invalid(
                    "Stage text must contain at most 12000 bytes and no NUL characters",
                ));
            }
        }
    }
    if let Some(skills) = value.get("skills") {
        let skills: Vec<String> = serde_json::from_value(skills.clone())?;
        if skills.len() > 30
            || skills
                .iter()
                .any(|s| s.trim().is_empty() || s.len() > 2000 || s.contains('\0'))
        {
            return Err(invalid(
                "Supply at most thirty nonempty skill names or SKILL.md paths",
            ));
        }
    }
    Ok(())
}
pub(super) fn attempt_settings(a: &Automation) -> Value {
    let mut value = json!({"agent":"","skills":[],"prompt":"","instructions":""});
    if let Some(rule) = &a.active_rule {
        for key in ["agent", "skills", "prompt", "instructions"] {
            value[key] = json!(rule)[key].clone();
        }
        value["rule_id"] = json!(rule.id);
    }
    if let Some(settings) = a
        .configuration
        .stage_settings
        .get(&a.stage)
        .and_then(Value::as_object)
    {
        for (key, setting) in settings {
            value[key] = setting.clone();
        }
    }
    if let Some(settings) = presets::settings(a) {
        for (key, setting) in settings.as_object().unwrap() {
            if setting != &json!("") && setting != &json!([]) {
                value[key] = setting.clone();
            }
        }
    }
    value
}
fn key(project: &str) -> String {
    format!("automation.project:{project}")
}
pub(super) fn get_defaults(c: &Connection, project: &str) -> Result<Value, ApiError> {
    if !c.query_row(
        "SELECT EXISTS(SELECT 1 FROM projects WHERE id=?1)",
        [project],
        |row| row.get::<_, bool>(0),
    )? {
        return Err(ApiError::new("NOT_FOUND", "Project not found"));
    }
    let raw: Option<String> = c
        .query_row(
            "SELECT value FROM settings WHERE key=?1",
            [key(project)],
            |row| row.get(0),
        )
        .optional()?;
    Ok(json!({"defaults":raw.map(|v|serde_json::from_str::<Value>(&v)).transpose()?}))
}
pub(super) fn defaults(c: &Connection) -> Result<Vec<Value>, ApiError> {
    let mut result = vec![];
    for project in projects(c)? {
        if let Some(value) = get_defaults(c, &project.id)?["defaults"].as_object() {
            result.push(json!(value));
        }
    }
    Ok(result)
}
fn next_defaults_revision(c: &Connection, minimum: i64) -> Result<i64, ApiError> {
    let counter: Option<i64> = c
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM settings WHERE key='automation.defaults_revision'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let legacy:Option<i64>=c.query_row("SELECT max(json_extract(value,'$.revision')) FROM settings WHERE key LIKE 'automation.project:%'",[],|row|row.get(0))?;
    let revision = counter.unwrap_or(0).max(legacy.unwrap_or(0)).max(minimum) + 1;
    c.execute("INSERT INTO settings(key,value) VALUES ('automation.defaults_revision',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[revision.to_string()])?;
    Ok(revision)
}
pub(super) fn set_defaults(c: &Connection, r: &Request) -> Result<Value, ApiError> {
    let project = required(&r.params, "project_id")?;
    let previous = get_defaults(c, project)?["defaults"].clone();
    let revision = previous["revision"].as_i64().unwrap_or(0);
    if integer(&r.params, "expected_defaults_revision", 0)? != revision {
        return Err(conflict(
            "Project automation changed. Read the defaults again before editing",
        ));
    }
    let config: Configuration = serde_json::from_value(
        r.params
            .get("configuration")
            .cloned()
            .ok_or_else(|| invalid("configuration is required"))?,
    )?;
    validate_configuration(&config)?;
    presets::prepare(c, &config, "configuration", "")?;
    let value = json!({"project_id":project,"revision":next_defaults_revision(c,revision)?,"enabled":flag(&r.params,"enabled")?,"configuration":config});
    c.execute("INSERT INTO settings(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",params![key(project),value.to_string()])?;
    let sequence = record(c, r, None, "automation.defaults.updated", value.clone())?;
    Ok(json!({"defaults":value,"event_sequence":sequence}))
}
pub(super) fn statuses(
    c: &Connection,
) -> Result<std::collections::HashMap<String, String>, ApiError> {
    let mut statement = c.prepare("SELECT id,status FROM tasks")?;
    let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
    Ok(rows.collect::<Result<_, _>>()?)
}
pub(super) fn inherit_new(
    c: &Connection,
    r: &Request,
    before: &std::collections::HashMap<String, String>,
) -> Result<(), ApiError> {
    let mut mode = r
        .params
        .get("automation_mode")
        .map_or(Some("inherit"), Value::as_str)
        .filter(|mode| ["inherit", "automatic", "manual"].contains(mode))
        .ok_or_else(|| invalid("automation_mode must be inherit, automatic, or manual"))?;
    if r.params.get("process_preset").is_some() {
        if mode == "manual" {
            return Err(invalid("Manual work cannot select a process preset"));
        }
        required(&r.params, "process_preset")?;
        mode = "automatic";
    }
    if mode == "manual" {
        return Ok(());
    }
    for (task, _) in statuses(c)? {
        if before.contains_key(&task) || load(c, &task)?.is_some() {
            continue;
        }
        let project = get_task(c, &task)?.project_id;
        let defaults = get_defaults(c, &project)?["defaults"].clone();
        if mode == "automatic" && defaults["configuration"].is_null() {
            return Err(invalid("Save project automation defaults before creating an automatic task, or choose manual work"));
        }
        if defaults["configuration"].is_null() || (mode == "inherit" && defaults["enabled"] != true)
        {
            continue;
        }
        let mut configuration: Configuration =
            serde_json::from_value(defaults["configuration"].clone())?;
        if let Some(preset) = r.params.get("process_preset") {
            configuration.process_preset = Some(preset.as_str().unwrap().into());
        }
        let process = presets::prepare(
            c,
            &configuration,
            r.params["agent_id"].as_str().unwrap_or("user"),
            r.params["preset_reason"]
                .as_str()
                .unwrap_or("Task creation choice"),
        )?;
        let mut a = Automation {
            task_id: task,
            template: "status-rules-v1".into(),
            configuration,
            state: "armed".into(),
            stage: "preflight".into(),
            revision: 0,
            reworks: 0,
            limit_reached: false,
            run_id: None,
            approval_task_revision: None,
            message: "Project defaults applied. Waiting for a matching status change.".into(),
            attempts: vec![],
            single_stage: false,
            active_rule: None,
            pending_rule: None,
            inherited_revision: defaults["revision"].as_i64(),
            process,
        };
        save(c, r, &mut a)?;
    }
    Ok(())
}
pub(super) fn trigger(c: &Connection, a: &mut Automation, rule: Rule, reuse: bool) {
    let previous = a.clone();
    let result = (|| -> Result<(), ApiError> {
        c.execute_batch("SAVEPOINT automation_rule_start")?;
        let task = get_task(c, &a.task_id)?;
        if task.status != rule.status {
            return Err(conflict(
                "The task no longer matches the pending status rule",
            ));
        }
        if rule.action == "development" {
            let own_run = a.run_id.as_ref().is_some_and(|run| {
                c.query_row(
                    "SELECT EXISTS(SELECT 1 FROM runs WHERE id=?1 AND status='running')",
                    [run],
                    |row| row.get::<_, bool>(0),
                )
                .unwrap_or(false)
            });
            start(c, a, reuse || own_run)?;
            a.active_rule = Some(rule);
            a.attempts.last_mut().unwrap().settings = attempt_settings(a);
        } else {
            if task.goal.trim().is_empty() || task.completion_criteria.trim().is_empty() {
                return Err(invalid(
                    "Set a goal and completion criteria before running a status rule",
                ));
            }
            let existing:Option<String>=c.query_row("SELECT id FROM runs WHERE task_id=?1 AND status='running' ORDER BY rowid DESC LIMIT 1",[&task.id],|row|row.get(0)).optional()?;
            if existing.is_some() && !reuse && existing.as_ref() != a.run_id.as_ref() {
                return Err(conflict(
                    "Pause the current task run before starting a status rule",
                ));
            }
            let run = existing.unwrap_or_else(id);
            c.execute("INSERT OR IGNORE INTO runs(id,task_id,agent_id,status,started_at,summary,next_action) VALUES (?1,?2,?3,'running',?4,'','')",params![run,task.id,format!("automation:{}",task.id),now()])?;
            a.run_id = Some(run);
            a.single_stage = true;
            a.stage = rule.stage.clone();
            a.active_rule = Some(rule);
            a.reworks = 0;
            a.limit_reached = false;
            enqueue(c, a, String::new())?;
        }
        c.execute_batch("RELEASE automation_rule_start")?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = c.execute_batch("ROLLBACK TO automation_rule_start; RELEASE automation_rule_start");
        *a = previous;
        a.state = "armed".into();
        a.message = error.message;
    }
}

pub(super) fn restore_defaults(c: &Connection) -> Result<(), ApiError> {
    let saved = {
        let mut statement = c.prepare(
            "SELECT key,value FROM restoration.settings WHERE key LIKE 'automation.project:%'",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        rows.collect::<Result<Vec<_>, _>>()?
    };
    if saved.is_empty() {
        next_defaults_revision(c, 0)?;
    }
    let mut updated = vec![];
    for (key, raw) in saved {
        let mut value: Value = serde_json::from_str(&raw)?;
        value["revision"] = json!(next_defaults_revision(
            c,
            value["revision"].as_i64().unwrap_or(0)
        )?);
        updated.push((key, value));
    }
    c.execute(
        "DELETE FROM main.settings WHERE key LIKE 'automation.project:%'",
        [],
    )?;
    for (key, value) in updated {
        c.execute(
            "INSERT INTO main.settings(key,value) VALUES (?1,?2)",
            params![key, value.to_string()],
        )?;
    }
    Ok(())
}
