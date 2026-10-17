//! Reusable process definitions and frozen, task-specific execution plans.
use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(super) struct Step {
    pub id: String,
    pub title: String,
    pub kind: String,
    #[serde(default)]
    pub agent: String,
    #[serde(default)]
    pub skills: Vec<String>,
    #[serde(default)]
    pub prompt: String,
    #[serde(default)]
    pub instructions: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(super) struct Preset {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub when_to_use: String,
    pub steps: Vec<Step>,
    #[serde(default = "rework_step")]
    pub rework: Step,
    #[serde(default = "default_reworks")]
    pub max_reworks: i64,
    #[serde(default)]
    pub revision: i64,
    #[serde(default)]
    pub builtin: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(super) struct Process {
    pub preset: Option<Preset>,
    pub candidates: Vec<Preset>,
    pub cursor: usize,
    pub rework_resume: Option<usize>,
    pub selected_by: String,
    pub selection_reason: String,
}
fn default_reworks() -> i64 {
    2
}
fn step(kind: &str, title: &str) -> Step {
    Step {
        id: kind.into(),
        title: title.into(),
        kind: kind.into(),
        agent: String::new(),
        skills: vec![],
        prompt: String::new(),
        instructions: String::new(),
    }
}
fn rework_step() -> Step {
    step("rework", "Address review findings")
}
fn builtins() -> Vec<Preset> {
    [
        ("small","Small task","Work and independent review.","Small, well-defined changes with limited impact and clear acceptance criteria.",vec![step("work","Implementation"),step("review","Review")],1),
        ("standard","Standard task","Preflight, implementation, review, and release preparation.","Ordinary features and bug fixes that need requirements checks and release evidence.",vec![step("preflight","Preflight"),step("work","Implementation"),step("review","Review"),step("release","Release preparation")],2),
        ("large","Large task","Inspect, plan, implement, verify, review, and prepare release.","Large or uncertain tasks, cross-component changes, migrations, and work that benefits from an explicit plan and separate verification.",vec![step("preflight","Preflight"),step("plan","Plan"),step("work","Implementation"),step("verify","Verification"),step("review","Review"),step("release","Release preparation")],3),
    ].into_iter().map(|(id,name,description,when_to_use,steps,max_reworks)|Preset{id:id.into(),name:name.into(),description:description.into(),when_to_use:when_to_use.into(),steps,rework:rework_step(),max_reworks,revision:1,builtin:true}).collect()
}
pub(super) fn list(c: &Connection) -> Result<Vec<Preset>, ApiError> {
    let mut presets = builtins();
    let mut statement =
        c.prepare("SELECT value FROM settings WHERE key LIKE 'automation.preset:%' ORDER BY key")?;
    let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
    for row in rows {
        presets.push(serde_json::from_str(&row?)?);
    }
    Ok(presets)
}
fn get(c: &Connection, id: &str) -> Result<Preset, ApiError> {
    list(c)?
        .into_iter()
        .find(|preset| preset.id == id)
        .ok_or_else(|| ApiError::new("NOT_FOUND", "Process preset not found"))
}
fn validate(p: &Preset) -> Result<(), ApiError> {
    if p.id.is_empty()
        || p.id.len() > 100
        || !p
            .id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        || p.id == "auto"
        || p.name.trim().is_empty()
        || p.name.len() > 300
        || p.description.len() > 12000
        || p.when_to_use.len() > 12000
        || p.steps.is_empty()
        || p.steps.len() > 20
        || !(0..=10).contains(&p.max_reworks)
    {
        return Err(invalid(
            "Use a preset ID, name, one to twenty stages, and zero to ten rework cycles",
        ));
    }
    let mut ids = std::collections::HashSet::new();
    for stage in p.steps.iter().chain(std::iter::once(&p.rework)) {
        if stage.id.is_empty()
            || stage.id.len() > 100
            || stage.title.trim().is_empty()
            || stage.title.len() > 300
            || ![
                "preflight",
                "plan",
                "work",
                "verify",
                "review",
                "rework",
                "release",
            ]
            .contains(&stage.kind.as_str())
        {
            return Err(invalid("Each stage needs an ID, title, and supported kind"));
        }
        rules::validate_settings(&json!(stage))?;
    }
    for stage in &p.steps {
        if !ids.insert(&stage.id) {
            return Err(invalid("Stage IDs must be unique within a preset"));
        }
    }
    if p.rework.kind != "rework" {
        return Err(invalid("The correction stage must use the rework kind"));
    }
    Ok(())
}
fn next_revision(c: &Connection, minimum: i64) -> Result<i64, ApiError> {
    let counter: Option<i64> = c
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM settings WHERE key='automation.presets_revision'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let legacy:Option<i64>=c.query_row("SELECT max(json_extract(value,'$.revision')) FROM settings WHERE key LIKE 'automation.preset:%'",[],|row|row.get(0))?;
    let revision = counter.unwrap_or(0).max(legacy.unwrap_or(0)).max(minimum) + 1;
    c.execute("INSERT INTO settings(key,value) VALUES ('automation.presets_revision',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[revision.to_string()])?;
    Ok(revision)
}
pub(super) fn read(c: &Connection, method: &str, p: &Value) -> Result<Option<Value>, ApiError> {
    Ok(match method {
        "automation.presets.list" => Some(json!({"presets":list(c)?})),
        "automation.presets.get" => Some(json!({"preset":get(c,required(p,"preset_id")?)?})),
        _ => None,
    })
}
pub(super) fn mutate(c: &Connection, r: &Request) -> Result<Option<Value>, ApiError> {
    if !["automation.presets.save", "automation.presets.delete"].contains(&r.method.as_str()) {
        return Ok(None);
    }
    let mut preset = if r.method == "automation.presets.save" {
        serde_json::from_value::<Preset>(
            r.params
                .get("preset")
                .cloned()
                .ok_or_else(|| invalid("preset is required"))?,
        )?
    } else {
        get(c, required(&r.params, "preset_id")?)?
    };
    if builtins().iter().any(|p| p.id == preset.id) {
        return Err(conflict(
            "Built-in presets are read-only. Duplicate one with a new ID to customize it",
        ));
    }
    let previous = list(c)?.into_iter().find(|p| p.id == preset.id);
    let revision = previous.as_ref().map_or(0, |p| p.revision);
    if integer(&r.params, "expected_preset_revision", 0)? != revision {
        return Err(conflict(
            "The process preset changed. Read it again before editing",
        ));
    }
    let result = if r.method == "automation.presets.save" {
        validate(&preset)?;
        preset.builtin = false;
        preset.revision = next_revision(c, revision)?;
        c.execute("INSERT INTO settings(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",params![format!("automation.preset:{}",preset.id),serde_json::to_string(&preset)?])?;
        json!({"preset":preset})
    } else {
        c.execute(
            "DELETE FROM settings WHERE key=?1",
            [format!("automation.preset:{}", preset.id)],
        )?;
        json!({"preset_id":preset.id,"deleted":true})
    };
    let sequence = record(c, r, None, &r.method, result.clone())?;
    let mut result = result;
    result["event_sequence"] = json!(sequence);
    Ok(Some(result))
}
pub(super) fn prepare(
    c: &Connection,
    config: &Configuration,
    actor: &str,
    reason: &str,
) -> Result<Option<Process>, ApiError> {
    let Some(selected) = &config.process_preset else {
        return Ok(None);
    };
    let candidates = if config.allowed_presets.is_empty() {
        list(c)?
    } else {
        config
            .allowed_presets
            .iter()
            .map(|id| get(c, id))
            .collect::<Result<_, _>>()?
    };
    let preset = if selected == "auto" {
        None
    } else {
        if !config.allowed_presets.is_empty() && !config.allowed_presets.contains(selected) {
            return Err(invalid(
                "This preset is outside the configured allowed presets",
            ));
        }
        Some(get(c, selected)?)
    };
    if candidates.is_empty() {
        return Err(invalid(
            "At least one process preset is required for agent selection",
        ));
    }
    Ok(Some(Process {
        preset,
        candidates,
        cursor: 0,
        rework_resume: None,
        selected_by: actor.into(),
        selection_reason: reason.into(),
    }))
}
pub(super) fn begin(c: &Connection, a: &mut Automation) -> Result<(), ApiError> {
    if a.configuration.process_preset.as_deref() == Some("auto") {
        a.process = prepare(
            c,
            &a.configuration,
            "agent",
            "Waiting for an agent to choose a process",
        )?;
    }
    reset(a);
    Ok(())
}
pub(super) fn reset(a: &mut Automation) {
    if let Some(process) = &mut a.process {
        if a.configuration.process_preset.as_deref() == Some("auto") {
            process.preset = None;
            process.selection_reason = "Waiting for an agent to choose a process".into();
        }
        process.cursor = 0;
        process.rework_resume = None;
        a.stage = process
            .preset
            .as_ref()
            .map_or("select", |p| p.steps[0].kind.as_str())
            .into();
    } else {
        a.stage = "preflight".into();
    }
}
pub(super) fn settings(a: &Automation) -> Option<Value> {
    if a.single_stage {
        return None;
    }
    let process = a.process.as_ref()?;
    if a.stage == "select" {
        return Some(json!({"step_id":"select","step_title":"Choose process preset"}));
    }
    let preset = process.preset.as_ref()?;
    let stage = if process.rework_resume.is_some() {
        &preset.rework
    } else {
        preset.steps.get(process.cursor)?
    };
    let mut value = json!(stage);
    value["step_id"] = json!(stage.id);
    value["step_title"] = json!(stage.title);
    value["preset_name"] = json!(preset.name);
    value["step_number"] = json!(process.rework_resume.unwrap_or(process.cursor + 1));
    value["step_count"] = json!(preset.steps.len());
    Some(value)
}
pub(super) fn validate_selection(a: &Automation, p: &Value) -> Result<(), ApiError> {
    if a.stage == "select" {
        if required(p, "outcome")? == "blocked" {
            return Ok(());
        }
        let selected = required(p, "preset_id")?;
        required(p, "selection_reason")?;
        if !a
            .process
            .as_ref()
            .is_some_and(|process| process.candidates.iter().any(|p| p.id == selected))
        {
            return Err(invalid(
                "Select one of this attempt's authorized process presets",
            ));
        }
    } else if p.get("preset_id").is_some_and(|value| !value.is_null()) {
        return Err(invalid(
            "Only a process-selection stage can choose a preset",
        ));
    }
    Ok(())
}
pub(super) fn request_rework(a: &mut Automation) -> Result<bool, ApiError> {
    let Some(process) = &mut a.process else {
        return Ok(false);
    };
    let preset = process
        .preset
        .as_ref()
        .ok_or_else(|| conflict("Select a process first"))?;
    if a.reworks >= a.configuration.max_reworks.min(preset.max_reworks) {
        a.limit_reached = true;
        a.state = "blocked".into();
        a.message="The selected process reached its rework limit. Inspect the findings before changing the workflow.".into();
        return Ok(true);
    }
    let preceding = preset.steps[..process.cursor]
        .iter()
        .rposition(|s| ["work", "rework"].contains(&s.kind.as_str()));
    let Some(index) = preceding else {
        a.state = "blocked".into();
        a.message="The selected process has no implementation stage before this review. Inspect the findings and choose a suitable process.".into();
        return Ok(true);
    };
    a.reworks += 1;
    process.rework_resume = Some(index + 1);
    a.stage = "rework".into();
    Ok(false)
}
pub(super) fn advance(
    c: &Connection,
    a: &mut Automation,
    result: &StageResult,
) -> Result<(), ApiError> {
    if a.stage == "select" {
        let process = a.process.as_mut().unwrap();
        let id = result
            .preset_id
            .as_deref()
            .ok_or_else(|| invalid("A selected preset is required"))?;
        process.preset = process.candidates.iter().find(|p| p.id == id).cloned();
        process.selected_by = "agent".into();
        process.selection_reason = result.selection_reason.clone().unwrap_or_default();
        process.cursor = 0;
        a.stage = process.preset.as_ref().unwrap().steps[0].kind.clone();
    } else if a.stage == "review" && result.outcome == "changes_requested" {
        if request_rework(a)? {
            return Ok(());
        }
    } else {
        let process = a.process.as_mut().unwrap();
        process.cursor = process.rework_resume.take().unwrap_or(process.cursor + 1);
        let preset = process.preset.as_ref().unwrap();
        if process.cursor >= preset.steps.len() {
            return finish_process(c, a, &result.summary);
        }
        a.stage = preset.steps[process.cursor].kind.clone();
    }
    let input = if ["work", "rework"].contains(&a.stage.as_str()) {
        String::new()
    } else {
        result.source_version.clone()
    };
    enqueue(c, a, input)
}
fn finish_process(c: &Connection, a: &mut Automation, summary: &str) -> Result<(), ApiError> {
    a.state = "awaiting_approval".into();
    a.message = "The selected process is complete. Final approval is required.".into();
    project_task(c, a, "review", &a.message)?;
    a.approval_task_revision = Some(get_task(c, &a.task_id)?.revision);
    if let Some(run) = &a.run_id {
        c.execute(
            "UPDATE runs SET status='review',ended_at=?2,summary=?3,next_action=?4 WHERE id=?1",
            params![run, now(), summary, a.message],
        )?;
    }
    Ok(())
}
pub(super) fn restore(c: &Connection) -> Result<(), ApiError> {
    let saved = {
        let mut st = c.prepare(
            "SELECT value FROM restoration.settings WHERE key LIKE 'automation.preset:%'",
        )?;
        let rows = st.query_map([], |row| row.get::<_, String>(0))?;
        rows.collect::<Result<Vec<_>, _>>()?
    };
    let mut presets = vec![];
    if saved.is_empty() {
        next_revision(c, 0)?;
    }
    for raw in saved {
        let mut p: Preset = serde_json::from_str(&raw)?;
        validate(&p)?;
        p.revision = next_revision(c, p.revision)?;
        presets.push(p);
    }
    c.execute(
        "DELETE FROM settings WHERE key LIKE 'automation.preset:%'",
        [],
    )?;
    for p in presets {
        c.execute(
            "INSERT INTO settings(key,value) VALUES (?1,?2)",
            params![
                format!("automation.preset:{}", p.id),
                serde_json::to_string(&p)?
            ],
        )?;
    }
    Ok(())
}
