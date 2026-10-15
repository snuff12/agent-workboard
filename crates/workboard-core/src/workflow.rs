//! Durable planning features. All writes run inside the dispatcher's transaction.
use super::*;
use chrono::{DateTime, NaiveDate, TimeZone};
use std::collections::BTreeSet;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChecklistItem {
    pub id: String,
    pub text: String,
    pub required: bool,
    pub checked: bool,
    pub evidence: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TemplateCheck {
    pub text: String,
    #[serde(default = "yes")]
    pub required: bool,
}
fn yes() -> bool {
    true
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TemplateNode {
    pub title: String,
    #[serde(default)]
    pub goal: String,
    #[serde(default)]
    pub completion_criteria: String,
    #[serde(default)]
    pub priority: i64,
    #[serde(default)]
    pub checklist: Vec<TemplateCheck>,
    #[serde(default)]
    pub children: Vec<TemplateNode>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Template {
    pub id: String,
    pub name: String,
    pub definition: TemplateNode,
    pub builtin: bool,
    pub revision: i64,
    pub created_at: String,
    pub updated_at: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SavedView {
    pub id: String,
    pub name: String,
    pub filters: Value,
    pub layout: String,
    pub revision: i64,
    pub created_at: String,
    pub updated_at: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InboxItem {
    pub id: String,
    pub title: String,
    pub source: Option<String>,
    pub note: String,
    pub status: String,
    pub task_id: Option<String>,
    pub revision: i64,
    pub created_at: String,
    pub updated_at: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ReviewDecision {
    pub id: String,
    pub task_id: String,
    pub decision: String,
    pub summary: String,
    pub run_id: Option<String>,
    pub actor: Option<String>,
    pub created_at: String,
}

pub(super) fn migrate(c: &Connection) -> Result<(), ApiError> {
    c.execute_batch(r#"
BEGIN IMMEDIATE;
CREATE TABLE task_dependencies(task_id TEXT NOT NULL REFERENCES tasks(id),depends_on_id TEXT NOT NULL REFERENCES tasks(id),PRIMARY KEY(task_id,depends_on_id),CHECK(task_id<>depends_on_id));
CREATE INDEX dependencies_source ON task_dependencies(depends_on_id);
CREATE TABLE checklist_items(id TEXT PRIMARY KEY,task_id TEXT NOT NULL REFERENCES tasks(id),text TEXT NOT NULL,required INTEGER NOT NULL CHECK(required IN (0,1)),checked INTEGER NOT NULL CHECK(checked IN (0,1)),evidence TEXT,created_at TEXT NOT NULL);
CREATE INDEX checklist_task ON checklist_items(task_id);
CREATE TABLE review_decisions(id TEXT PRIMARY KEY,task_id TEXT NOT NULL REFERENCES tasks(id),decision TEXT NOT NULL CHECK(decision IN ('approve','request_changes','reject')),summary TEXT NOT NULL,run_id TEXT REFERENCES runs(id),actor TEXT,created_at TEXT NOT NULL);
CREATE INDEX decisions_task ON review_decisions(task_id);
CREATE TABLE inbox(id TEXT PRIMARY KEY,title TEXT NOT NULL,source TEXT,note TEXT NOT NULL,status TEXT NOT NULL CHECK(status IN ('pending','processed','dismissed')),task_id TEXT REFERENCES tasks(id),revision INTEGER NOT NULL CHECK(revision>0),created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
CREATE TABLE templates(id TEXT PRIMARY KEY,name TEXT NOT NULL,definition TEXT NOT NULL,builtin INTEGER NOT NULL,revision INTEGER NOT NULL CHECK(revision>0),created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
CREATE TABLE saved_views(id TEXT PRIMARY KEY,name TEXT NOT NULL,filters TEXT NOT NULL,layout TEXT NOT NULL CHECK(layout IN ('board','list','week')),revision INTEGER NOT NULL CHECK(revision>0),created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
CREATE TABLE workflow_revisions(kind TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL CHECK(revision>0),PRIMARY KEY(kind,id));
"#)?;
    let seeds = [
        (
            "builtin-bugfix",
            "Bug fix",
            json!({"title":"Bug fix","checklist":[{"text":"Reproduction and regression checks","required":true}],"children":[{"title":"Identify reproduction steps"},{"title":"Fix the cause"},{"title":"Regression checks"}]}),
        ),
        (
            "builtin-feature",
            "Feature development",
            json!({"title":"Feature development","checklist":[{"text":"Verify completion criteria","required":true}],"children":[{"title":"Confirm requirements"},{"title":"Implementation"},{"title":"Verify and document"}]}),
        ),
        (
            "builtin-research",
            "Document research",
            json!({"title":"Document research","checklist":[{"text":"Verify sources and evidence","required":true}],"children":[{"title":"Define questions and research scope"},{"title":"Read the source"},{"title":"Document conclusions and evidence"}]}),
        ),
    ];
    for (key, name, definition) in seeds {
        c.execute("INSERT INTO templates(id,name,definition,builtin,revision,created_at,updated_at) VALUES(?1,?2,?3,1,1,?4,?4)",params![key,name,serde_json::to_string(&definition)?,now()])?;
        c.execute(
            "INSERT INTO workflow_revisions(kind,id,revision) VALUES('template',?1,1)",
            [key],
        )?;
    }
    c.execute_batch("PRAGMA user_version=5; COMMIT;")?;
    Ok(())
}

pub(super) fn enrich_task(c: &Connection, mut task: Task) -> Result<Task, ApiError> {
    let mut st = c.prepare("SELECT d.depends_on_id,t.status FROM task_dependencies d JOIN tasks t ON t.id=d.depends_on_id WHERE d.task_id=?1 ORDER BY d.depends_on_id")?;
    let pairs = st
        .query_map([&task.id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    task.dependency_ids = pairs.iter().map(|p| p.0.clone()).collect();
    task.blocked_by = pairs
        .into_iter()
        .filter(|p| p.1 != "done")
        .map(|p| p.0)
        .collect();
    task.ready = task.status == "todo"
        && task.blocked_by.is_empty()
        && task.blocked_reason.trim().is_empty();
    let mut st=c.prepare("SELECT id,text,required,checked,evidence FROM checklist_items WHERE task_id=?1 ORDER BY rowid")?;
    task.checklist = st
        .query_map([&task.id], |row| {
            Ok(ChecklistItem {
                id: row.get(0)?,
                text: row.get(1)?,
                required: row.get(2)?,
                checked: row.get(3)?,
                evidence: row.get(4)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(task)
}
fn evidence(p: &Value) -> Result<Option<String>, ApiError> {
    let value = string(p, "evidence")?;
    Ok((!value.trim().is_empty()).then_some(value))
}
fn boolean(p: &Value, key: &str, default: bool) -> Result<bool, ApiError> {
    match p.get(key) {
        None => Ok(default),
        Some(v) => v
            .as_bool()
            .ok_or_else(|| invalid(format!("{key} must be true or false"))),
    }
}
pub(super) fn validate_transition(c: &Connection, t: &Task) -> Result<(), ApiError> {
    if !t.blocked_reason.trim().is_empty() {
        return Err(ApiError::new(
            "TASK_BLOCKED",
            "Resolve the blocking reason before starting or completing the task",
        ));
    }
    let enriched = enrich_task(c, t.clone())?;
    if !enriched.blocked_by.is_empty() {
        return Err(ApiError::new(
            "DEPENDENCY_BLOCKED",
            "Complete the prerequisites first",
        ));
    }
    if t.status == "done"
        && enriched
            .checklist
            .iter()
            .any(|item| item.required && !item.checked)
    {
        return Err(ApiError::new(
            "CHECKLIST_INCOMPLETE",
            "Check all required checklist items before completing the task",
        ));
    }
    Ok(())
}
pub(super) fn change_dependency(c: &Connection, r: &Request, t: &Task) -> Result<(), ApiError> {
    let other = required(&r.params, "depends_on_id")?;
    get_task(c, other)?;
    if r.method == "task.dependency.add" {
        let cycle:bool=c.query_row("WITH RECURSIVE upstream(id) AS (SELECT ?1 UNION SELECT d.depends_on_id FROM task_dependencies d JOIN upstream u ON d.task_id=u.id) SELECT EXISTS(SELECT 1 FROM upstream WHERE id=?2)",params![other,t.id],|row|row.get(0))?;
        if cycle {
            return Err(ApiError::new(
                "DEPENDENCY_CYCLE",
                "Dependencies must not reference the same task or create a cycle",
            ));
        }
        c.execute(
            "INSERT OR IGNORE INTO task_dependencies(task_id,depends_on_id) VALUES(?1,?2)",
            params![t.id, other],
        )?;
        if t.status == "done" {
            validate_transition(c, t)?;
        }
    } else {
        c.execute(
            "DELETE FROM task_dependencies WHERE task_id=?1 AND depends_on_id=?2",
            params![t.id, other],
        )?;
    }
    Ok(())
}
pub(super) fn change_checklist(c: &Connection, r: &Request, t: &Task) -> Result<(), ApiError> {
    let p = &r.params;
    if r.method == "task.checklist.add" {
        c.execute("INSERT INTO checklist_items(id,task_id,text,required,checked,evidence,created_at) VALUES(?1,?2,?3,?4,0,?5,?6)",params![id(),t.id,required(p,"text")?.trim(),boolean(p,"required",true)?,evidence(p)?,now()])?;
    } else {
        let item = required(p, "item_id")?;
        let mut check:ChecklistItem=c.query_row("SELECT id,text,required,checked,evidence FROM checklist_items WHERE id=?1 AND task_id=?2",params![item,t.id],|row|Ok(ChecklistItem{id:row.get(0)?,text:row.get(1)?,required:row.get(2)?,checked:row.get(3)?,evidence:row.get(4)?})).optional()?.ok_or_else(||ApiError::new("NOT_FOUND","Checklist item not found"))?;
        if r.method == "task.checklist.remove" {
            c.execute("DELETE FROM checklist_items WHERE id=?1", [item])?;
        } else {
            if p.get("text").is_some() {
                check.text = required(p, "text")?.trim().into();
            }
            if p.get("required").is_some() {
                check.required = boolean(p, "required", true)?;
            }
            if p.get("checked").is_some() {
                check.checked = boolean(p, "checked", false)?;
            }
            if p.get("evidence").is_some() {
                check.evidence = evidence(p)?;
            }
            c.execute(
                "UPDATE checklist_items SET text=?2,required=?3,checked=?4,evidence=?5 WHERE id=?1",
                params![
                    item,
                    check.text,
                    check.required,
                    check.checked,
                    check.evidence
                ],
            )?;
        }
    }
    if t.status == "done" {
        validate_transition(c, t)?;
    }
    Ok(())
}
pub(super) fn latest_review_run(c: &Connection, task_id: &str) -> Result<Option<String>, ApiError> {
    Ok(c.query_row("SELECT id FROM runs WHERE rowid=(SELECT max(rowid) FROM runs WHERE task_id=?1) AND status IN ('running','review')",[task_id],|row|row.get(0)).optional()?)
}
pub(super) fn record_review(
    c: &Connection,
    r: &Request,
    task: &str,
    decision: &str,
    summary: &str,
    run: Option<&str>,
) -> Result<(), ApiError> {
    c.execute("INSERT INTO review_decisions(id,task_id,decision,summary,run_id,actor,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7)",params![id(),task,decision,summary,run,optional(&r.params,"agent_id")?.or(optional(&r.params,"actor")?),now()])?;
    Ok(())
}
pub(super) fn review_decisions(
    c: &Connection,
    task: Option<&str>,
) -> Result<Vec<ReviewDecision>, ApiError> {
    let mut st=c.prepare("SELECT id,task_id,decision,summary,run_id,actor,created_at FROM review_decisions WHERE (?1 IS NULL OR task_id=?1) ORDER BY rowid")?;
    let out = st
        .query_map([task], |row| {
            Ok(ReviewDecision {
                id: row.get(0)?,
                task_id: row.get(1)?,
                decision: row.get(2)?,
                summary: row.get(3)?,
                run_id: row.get(4)?,
                actor: row.get(5)?,
                created_at: row.get(6)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(out)
}

pub(super) fn templates(c: &Connection) -> Result<Vec<Template>, ApiError> {
    let mut st=c.prepare("SELECT id,name,definition,builtin,revision,created_at,updated_at FROM templates ORDER BY created_at,id")?;
    let raw = st
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, bool>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    raw.into_iter()
        .map(
            |(id, name, def, builtin, revision, created_at, updated_at)| {
                Ok(Template {
                    id,
                    name,
                    definition: serde_json::from_str(&def)?,
                    builtin,
                    revision,
                    created_at,
                    updated_at,
                })
            },
        )
        .collect()
}
pub(super) fn views(c: &Connection) -> Result<Vec<SavedView>, ApiError> {
    let mut st=c.prepare("SELECT id,name,filters,layout,revision,created_at,updated_at FROM saved_views ORDER BY created_at,id")?;
    let raw = st
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    raw.into_iter()
        .map(
            |(id, name, filters, layout, revision, created_at, updated_at)| {
                Ok(SavedView {
                    id,
                    name,
                    filters: serde_json::from_str(&filters)?,
                    layout,
                    revision,
                    created_at,
                    updated_at,
                })
            },
        )
        .collect()
}
pub(super) fn inbox(c: &Connection, p: &Value) -> Result<Vec<InboxItem>, ApiError> {
    let status = optional(p, "status")?;
    if status
        .as_deref()
        .is_some_and(|s| !["pending", "processed", "dismissed"].contains(&s))
    {
        return Err(invalid(
            "Inbox status must be pending, processed, or dismissed",
        ));
    }
    let mut st=c.prepare("SELECT id,title,source,note,status,task_id,revision,created_at,updated_at FROM inbox WHERE (?1 IS NULL OR status=?1) ORDER BY created_at,id")?;
    let out = st
        .query_map([status], |row| {
            Ok(InboxItem {
                id: row.get(0)?,
                title: row.get(1)?,
                source: row.get(2)?,
                note: row.get(3)?,
                status: row.get(4)?,
                task_id: row.get(5)?,
                revision: row.get(6)?,
                created_at: row.get(7)?,
                updated_at: row.get(8)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(out)
}
fn check_version(current: i64, p: &Value) -> Result<(), ApiError> {
    if p.get("expected_revision")
        .is_some_and(|v| v.as_i64() != Some(current))
    {
        return Err(ApiError::new(
            "REVISION_CONFLICT",
            format!("The data has changed. Current revision: {current}"),
        ));
    }
    Ok(())
}
fn next_version(c: &Connection, kind: &str, key: &str, current: i64) -> Result<i64, ApiError> {
    let old: Option<i64> = c
        .query_row(
            "SELECT revision FROM workflow_revisions WHERE kind=?1 AND id=?2",
            params![kind, key],
            |row| row.get(0),
        )
        .optional()?;
    let revision = old
        .unwrap_or(0)
        .max(current)
        .checked_add(1)
        .ok_or_else(|| {
            ApiError::new("REVISION_EXHAUSTED", "The revision limit has been reached")
        })?;
    c.execute("INSERT INTO workflow_revisions(kind,id,revision) VALUES(?1,?2,?3) ON CONFLICT(kind,id) DO UPDATE SET revision=excluded.revision",params![kind,key,revision])?;
    Ok(revision)
}

/// Detach workflow references in the same transaction as task deletion. Keep the previous
/// links in its event, and invalidate editors whose dependency list or inbox link changed.
pub(super) fn detach_deleted_tasks(c: &Connection, tasks: &[Task]) -> Result<Value, ApiError> {
    let ids: BTreeSet<&str> = tasks.iter().map(|t| t.id.as_str()).collect();
    let list = serde_json::to_string(&ids)?;
    let mut statement = c.prepare("SELECT task_id,depends_on_id FROM task_dependencies WHERE task_id IN (SELECT value FROM json_each(?1)) OR depends_on_id IN (SELECT value FROM json_each(?1)) ORDER BY task_id,depends_on_id")?;
    let edges = statement
        .query_map([&list], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let survivors: BTreeSet<&str> = edges
        .iter()
        .filter(|(task, _)| !ids.contains(task.as_str()))
        .map(|(task, _)| task.as_str())
        .collect();
    let decisions: Vec<_> = review_decisions(c, None)?
        .into_iter()
        .filter(|d| ids.contains(d.task_id.as_str()))
        .collect();
    let linked_inbox: Vec<_> = inbox(c, &json!({}))?
        .into_iter()
        .filter(|item| {
            item.task_id
                .as_deref()
                .is_some_and(|task| ids.contains(task))
        })
        .collect();
    for item in &linked_inbox {
        let revision = next_version(c, "inbox", &item.id, item.revision)?;
        c.execute(
            "UPDATE inbox SET task_id=NULL,revision=?2,updated_at=?3 WHERE id=?1",
            params![item.id, revision, now()],
        )?;
    }
    c.execute("DELETE FROM task_dependencies WHERE task_id IN (SELECT value FROM json_each(?1)) OR depends_on_id IN (SELECT value FROM json_each(?1))", [&list])?;
    for table in ["checklist_items", "review_decisions"] {
        c.execute(
            &format!("DELETE FROM {table} WHERE task_id IN (SELECT value FROM json_each(?1))"),
            [&list],
        )?;
    }
    for key in &survivors {
        let mut task = get_task(c, key)?;
        task.revision = allocate_revision(c, key, task.revision)?;
        task.updated_at = now();
        save_task(c, &task)?;
    }
    let dependencies: Vec<_> = edges
        .iter()
        .map(|(task, dependency)| json!({"task_id":task,"depends_on_id":dependency}))
        .collect();
    Ok(
        json!({"dependencies":dependencies,"review_decisions":decisions,"inbox_links":linked_inbox,"updated_task_ids":survivors}),
    )
}

fn validate_definition(
    node: &TemplateNode,
    depth: usize,
    count: &mut usize,
) -> Result<(), ApiError> {
    *count += 1;
    if depth > 16 || *count > 256 {
        return Err(invalid("Templates must not exceed 16 levels or 256 tasks"));
    }
    if node.title.trim().is_empty() {
        return Err(invalid("Each template task requires a title"));
    }
    if node.checklist.len() > 256 || node.checklist.iter().any(|i| i.text.trim().is_empty()) {
        return Err(invalid(
            "A checklist must not exceed 256 items, each with nonempty text",
        ));
    }
    for child in &node.children {
        validate_definition(child, depth + 1, count)?;
    }
    Ok(())
}
fn definition_from_task(
    c: &Connection,
    task_id: &str,
    depth: usize,
    count: &mut usize,
) -> Result<TemplateNode, ApiError> {
    *count += 1;
    if depth > 16 || *count > 256 {
        return Err(invalid("Templates must not exceed 16 levels or 256 tasks"));
    }
    let task = get_task(c, task_id)?;
    let children = list_tasks(c, &json!({"parent_id":task_id}))?
        .iter()
        .map(|t| definition_from_task(c, &t.id, depth + 1, count))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(TemplateNode {
        title: task.title,
        goal: task.goal,
        completion_criteria: task.completion_criteria,
        priority: task.priority,
        checklist: task
            .checklist
            .into_iter()
            .map(|item| TemplateCheck {
                text: item.text,
                required: item.required,
            })
            .collect(),
        children,
    })
}
fn apply_node(
    c: &Transaction<'_>,
    r: &Request,
    project: &str,
    parent: Option<&str>,
    node: &TemplateNode,
    created: &mut Vec<Task>,
) -> Result<Task, ApiError> {
    let request = Request {
        schema_version: SCHEMA_VERSION,
        request_id: r.request_id.clone(),
        method: "task.create".into(),
        params: json!({"project_id":project,"parent_id":parent,"title":node.title,"goal":node.goal,"completion_criteria":node.completion_criteria,"priority":node.priority,"agent_id":optional(&r.params,"agent_id")?}),
    };
    let result = super::mutate(c, &request, Path::new("."))?;
    let task_id = result["task_id"]
        .as_str()
        .ok_or_else(|| invalid("Invalid task creation result"))?;
    for check in &node.checklist {
        c.execute("INSERT INTO checklist_items(id,task_id,text,required,checked,evidence,created_at) VALUES(?1,?2,?3,?4,0,NULL,?5)",params![id(),task_id,check.text.trim(),check.required,now()])?;
    }
    let task = get_task(c, task_id)?;
    created.push(task.clone());
    for child in &node.children {
        apply_node(c, r, project, Some(task_id), child, created)?;
    }
    Ok(task)
}

pub(super) fn mutate(c: &Transaction<'_>, r: &Request) -> Result<Option<Value>, ApiError> {
    let p = &r.params;
    let mut result = match r.method.as_str() {
        "template.save" => {
            let key = optional(p, "id")?.unwrap_or_else(id);
            let previous = templates(c)?.into_iter().find(|t| t.id == key);
            if let Some(t) = &previous {
                check_version(t.revision, p)?;
            } else if p.get("expected_revision").is_some() {
                return Err(ApiError::new("NOT_FOUND", "Template not found"));
            }
            let definition = match (p.get("definition"), optional(p, "task_id")?) {
                (Some(_), Some(_)) => {
                    return Err(invalid("Specify only one of definition and task_id"))
                }
                (Some(value), None) => serde_json::from_value::<TemplateNode>(value.clone())
                    .map_err(|e| invalid(e.to_string()))?,
                (None, Some(task)) => definition_from_task(c, &task, 1, &mut 0)?,
                _ => return Err(invalid("definition or task_id is required")),
            };
            validate_definition(&definition, 1, &mut 0)?;
            let revision = next_version(
                c,
                "template",
                &key,
                previous.as_ref().map_or(0, |t| t.revision),
            )?;
            let timestamp = now();
            c.execute("INSERT INTO templates(id,name,definition,builtin,revision,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(id) DO UPDATE SET name=excluded.name,definition=excluded.definition,revision=excluded.revision,updated_at=excluded.updated_at",params![key,required(p,"name")?.trim(),serde_json::to_string(&definition)?,previous.as_ref().is_some_and(|t|t.builtin),revision,previous.as_ref().map_or(timestamp.as_str(),|t|t.created_at.as_str()),timestamp])?;
            json!({"template":templates(c)?.into_iter().find(|t|t.id==key).unwrap()})
        }
        "template.delete" => {
            let key = required(p, "template_id")?;
            let template = templates(c)?
                .into_iter()
                .find(|t| t.id == key)
                .ok_or_else(|| ApiError::new("NOT_FOUND", "Template not found"))?;
            check_version(template.revision, p)?;
            next_version(c, "template", key, template.revision)?;
            c.execute("DELETE FROM templates WHERE id=?1", [key])?;
            json!({"template_id":key,"deleted":true})
        }
        "template.apply" => {
            let key = required(p, "template_id")?;
            let template = templates(c)?
                .into_iter()
                .find(|t| t.id == key)
                .ok_or_else(|| ApiError::new("NOT_FOUND", "Template not found"))?;
            check_version(template.revision, p)?;
            let mut definition = template.definition;
            if p.get("title").is_some() {
                definition.title = required(p, "title")?.into();
            }
            validate_definition(&definition, 1, &mut 0)?;
            let project = required(p, "project_id")?;
            let parent = optional(p, "parent_id")?;
            let mut tasks = vec![];
            let task = apply_node(c, r, project, parent.as_deref(), &definition, &mut tasks)?;
            json!({"task":task,"tasks":tasks})
        }
        "inbox.capture" => {
            let key = id();
            let timestamp = now();
            let revision = next_version(c, "inbox", &key, 0)?;
            c.execute("INSERT INTO inbox(id,title,source,note,status,task_id,revision,created_at,updated_at) VALUES(?1,?2,?3,?4,'pending',NULL,?5,?6,?6)",params![key,required(p,"title")?.trim(),optional(p,"source")?,string(p,"note")?,revision,timestamp])?;
            json!({"item":inbox(c,&json!({}))?.into_iter().find(|i|i.id==key).unwrap()})
        }
        "inbox.promote" | "inbox.dismiss" => {
            let key = required(p, "item_id")?;
            let item = inbox(c, &json!({}))?
                .into_iter()
                .find(|i| i.id == key)
                .ok_or_else(|| ApiError::new("NOT_FOUND", "Inbox item not found"))?;
            check_version(item.revision, p)?;
            if r.method == "inbox.promote" && item.status == "processed" {
                let task = get_task(
                    c,
                    item.task_id.as_deref().ok_or_else(|| {
                        ApiError::new(
                            "INVALID_STATE",
                            "The converted task was deleted and this item cannot be converted again",
                        )
                    })?,
                )?;
                json!({"item":item,"task":task})
            } else {
                if item.status != "pending" {
                    return Err(ApiError::new(
                        "INVALID_STATE",
                        "Only pending Inbox items can be converted or archived",
                    ));
                }
                let task = if r.method == "inbox.promote" {
                    let request = Request {
                        schema_version: SCHEMA_VERSION,
                        request_id: r.request_id.clone(),
                        method: "task.create".into(),
                        params: json!({"project_id":required(p,"project_id")?,"parent_id":optional(p,"parent_id")?,"title":optional(p,"title")?.unwrap_or(item.title.clone()),"goal":item.note}),
                    };
                    let task = super::mutate(c, &request, Path::new("."))?;
                    let task_id = task["task_id"].as_str().unwrap();
                    if let Some(source) = &item.source {
                        c.execute("INSERT INTO artifacts(id,task_id,path,kind,description,created_at,metadata) VALUES(?1,?2,?3,'source',?4,?5,?6)",params![id(),task_id,source,"Inbox capture source",now(),serde_json::to_string(&json!({"provider":"inbox","item_id":key}))?])?;
                    }
                    Some(get_task(c, task_id)?)
                } else {
                    None
                };
                let revision = next_version(c, "inbox", key, item.revision)?;
                c.execute(
                    "UPDATE inbox SET status=?2,task_id=?3,revision=?4,updated_at=?5 WHERE id=?1",
                    params![
                        key,
                        if task.is_some() {
                            "processed"
                        } else {
                            "dismissed"
                        },
                        task.as_ref().map(|t| &t.id),
                        revision,
                        now()
                    ],
                )?;
                let item = inbox(c, &json!({}))?
                    .into_iter()
                    .find(|i| i.id == key)
                    .unwrap();
                if let Some(task) = task {
                    json!({"item":item,"task":task})
                } else {
                    json!({"item":item})
                }
            }
        }
        "view.save" => {
            let key = optional(p, "id")?.unwrap_or_else(id);
            let previous = views(c)?.into_iter().find(|v| v.id == key);
            if let Some(v) = &previous {
                check_version(v.revision, p)?;
            } else if p.get("expected_revision").is_some() {
                return Err(ApiError::new("NOT_FOUND", "Saved view not found"));
            }
            let filters = p.get("filters").cloned().unwrap_or_else(|| json!({}));
            validate_filters(&filters, false)?;
            let layout = optional(p, "layout")?.unwrap_or_else(|| "board".into());
            if !["board", "list", "week"].contains(&layout.as_str()) {
                return Err(invalid("layout must be board, list, or week"));
            }
            let revision =
                next_version(c, "view", &key, previous.as_ref().map_or(0, |v| v.revision))?;
            let timestamp = now();
            c.execute("INSERT INTO saved_views(id,name,filters,layout,revision,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(id) DO UPDATE SET name=excluded.name,filters=excluded.filters,layout=excluded.layout,revision=excluded.revision,updated_at=excluded.updated_at",params![key,required(p,"name")?.trim(),serde_json::to_string(&filters)?,layout,revision,previous.as_ref().map_or(timestamp.as_str(),|v|v.created_at.as_str()),timestamp])?;
            json!({"view":views(c)?.into_iter().find(|v|v.id==key).unwrap()})
        }
        "view.delete" => {
            let key = required(p, "view_id")?;
            let view = views(c)?
                .into_iter()
                .find(|v| v.id == key)
                .ok_or_else(|| ApiError::new("NOT_FOUND", "Saved view not found"))?;
            check_version(view.revision, p)?;
            next_version(c, "view", key, view.revision)?;
            c.execute("DELETE FROM saved_views WHERE id=?1", [key])?;
            json!({"view_id":key,"deleted":true})
        }
        _ => return Ok(None),
    };
    let seq = record(c, r, None, &r.method, result.clone())?;
    result["event_sequence"] = json!(seq);
    Ok(Some(result))
}

fn validate_filters(p: &Value, direct: bool) -> Result<(), ApiError> {
    let object = p
        .as_object()
        .ok_or_else(|| invalid("filters must be a JSON object"))?;
    let allowed: BTreeSet<&str> = [
        "project_id",
        "status",
        "assignee",
        "ready_only",
        "stale_days",
        "blocked_only",
        "query",
    ]
    .into_iter()
    .collect();
    for (key, value) in object {
        if direct && ["parent_id", "view_id"].contains(&key.as_str()) {
            continue;
        }
        if !allowed.contains(key.as_str()) {
            return Err(invalid(format!("Unsupported filter: {key}")));
        }
        match key.as_str() {
            "ready_only" | "blocked_only" => {
                boolean(p, key, false)?;
            }
            "stale_days" => {
                let days = value
                    .as_i64()
                    .ok_or_else(|| invalid("stale_days must be an integer"))?;
                if !(0..=36500).contains(&days) {
                    return Err(invalid("stale_days must be between 0 and 36500"));
                }
            }
            "assignee" if value.is_null() => {}
            _ => {
                optional(p, key)?;
            }
        }
    }
    if let Some(s) = optional(p, "status")? {
        status(&s)?;
    }
    Ok(())
}
pub(super) fn resolve_filters(c: &Connection, p: &Value) -> Result<Value, ApiError> {
    validate_filters(p, true)?;
    let mut filters = if let Some(key) = optional(p, "view_id")? {
        views(c)?
            .into_iter()
            .find(|v| v.id == key)
            .ok_or_else(|| ApiError::new("NOT_FOUND", "Saved view not found"))?
            .filters
    } else {
        json!({})
    };
    for (key, value) in p.as_object().unwrap() {
        if key != "view_id" {
            filters[key] = value.clone();
        }
    }
    validate_filters(&filters, true)?;
    Ok(filters)
}
pub(super) fn filter_tasks(tasks: Vec<Task>, p: &Value) -> Result<Vec<Task>, ApiError> {
    let ready = boolean(p, "ready_only", false)?;
    let blocked = boolean(p, "blocked_only", false)?;
    let stale = if p.get("stale_days").is_some() {
        Some(Utc::now() - chrono::Duration::days(integer(p, "stale_days", 0)?))
    } else {
        None
    };
    Ok(tasks
        .into_iter()
        .filter(|task| {
            (!ready || task.ready)
                && (!blocked
                    || !task.blocked_by.is_empty()
                    || !task.blocked_reason.trim().is_empty())
                && (p.get("assignee").is_none()
                    || match p.get("assignee").unwrap() {
                        Value::Null => task.assignee.is_none(),
                        Value::String(owner) => task.assignee.as_ref() == Some(owner),
                        _ => false,
                    })
                && stale.is_none_or(|threshold| {
                    DateTime::parse_from_rfc3339(&task.updated_at)
                        .is_ok_and(|time| time < threshold)
                })
        })
        .collect())
}
fn local_day(date: &str, zone: chrono_tz::Tz) -> Result<DateTime<Utc>, ApiError> {
    let date = NaiveDate::parse_from_str(date, "%Y-%m-%d")
        .map_err(|_| invalid("A valid date is required"))?;
    // Some zones advance their clocks at midnight. The first valid instant in that civil day is
    // its boundary; a repeated midnight uses the earlier occurrence. Entirely skipped days fail.
    for second in 0..86400 {
        let naive = date
            .and_hms_opt(second / 3600, (second / 60) % 60, second % 60)
            .unwrap();
        if let Some(time) = zone.from_local_datetime(&naive).earliest() {
            return Ok(time.with_timezone(&Utc));
        }
    }
    Err(invalid(
        "This date does not exist in the selected time zone",
    ))
}
pub(super) fn interval(
    start: &str,
    end: &str,
    zone: &str,
) -> Result<(DateTime<Utc>, DateTime<Utc>), ApiError> {
    let zone = zone
        .parse::<chrono_tz::Tz>()
        .map_err(|_| invalid("A valid IANA time zone is required"))?;
    let (a, sa) = date_value(start)?;
    let (b, sb) = date_value(end)?;
    if a != b || sb <= sa {
        return Err(invalid(
            "Schedule start and end must use the same format, and end must be after start",
        ));
    }
    let (start, end) = if a {
        (local_day(start, zone)?, local_day(end, zone)?)
    } else {
        (
            DateTime::parse_from_rfc3339(start)
                .map_err(|_| invalid("An RFC3339 timestamp is required"))?
                .with_timezone(&Utc),
            DateTime::parse_from_rfc3339(end)
                .map_err(|_| invalid("An RFC3339 timestamp is required"))?
                .with_timezone(&Utc),
        )
    };
    if end <= start {
        return Err(invalid("Schedule end must be after its start"));
    }
    Ok((start, end))
}
pub(super) fn schedule_preview(c: &Connection, p: &Value) -> Result<Value, ApiError> {
    let excluded = optional(p, "task_id")?;
    if let Some(task) = &excluded {
        get_task(c, task)?;
    }
    let (start, end) = interval(
        required(p, "scheduled_start")?,
        required(p, "scheduled_end")?,
        required(p, "time_zone")?,
    )?;
    let mut conflicts = vec![];
    let mut invalid_tasks = vec![];
    for task in list_tasks(c, &json!({}))? {
        if task.status == "done" || excluded.as_deref() == Some(task.id.as_str()) {
            continue;
        }
        if let (Some(a), Some(b)) = (&task.scheduled_start, &task.scheduled_end) {
            // Version 4 accepted some civil dates that never occurred in the selected zone.
            // Preserve that historical data and isolate it from otherwise valid planning.
            let (a, b) = match interval(a, b, &task.time_zone) {
                Ok(range) => range,
                Err(error) => {
                    invalid_tasks
                        .push(json!({"task_id":task.id,"title":task.title,"reason":error.message}));
                    continue;
                }
            };
            if start < b && a < end {
                conflicts.push(json!({"id":task.id,"project_id":task.project_id,"title":task.title,"status":task.status,"scheduled_start":task.scheduled_start,"scheduled_end":task.scheduled_end,"time_zone":task.time_zone}));
            }
        }
    }
    Ok(
        json!({"has_conflicts":!conflicts.is_empty(),"conflicts":conflicts,"invalid_tasks":invalid_tasks}),
    )
}
pub(super) fn restore_revisions(c: &Connection) -> Result<(), ApiError> {
    c.execute_batch("INSERT INTO main.workflow_revisions(kind,id,revision) SELECT kind,id,revision FROM restoration.workflow_revisions WHERE true ON CONFLICT(kind,id) DO UPDATE SET revision=max(workflow_revisions.revision,excluded.revision)")?;
    for (kind, table) in [
        ("template", "templates"),
        ("view", "saved_views"),
        ("inbox", "inbox"),
    ] {
        let mut st = c.prepare(&format!("SELECT id,revision FROM {table}"))?;
        let rows = st
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        for (key, old) in rows {
            let revision = next_version(c, kind, &key, old)?;
            c.execute(
                &format!("UPDATE {table} SET revision=?2 WHERE id=?1"),
                params![key, revision],
            )?;
        }
    }
    Ok(())
}
pub(super) fn markdown(doc: &Value, out: &mut String) {
    // Keep complete planning metadata in the Markdown artifact too. The JSON blocks retain
    // identifiers, checklist evidence, definitions and filters without a lossy prose conversion.
    for (key, title) in [
        ("templates", "Task templates"),
        ("views", "Saved views"),
        ("inbox", "Inbox"),
        ("review_decisions", "Review decision history"),
    ] {
        out.push_str(&format!(
            "\n## {title}\n\n```json\n{}\n```\n",
            serde_json::to_string_pretty(&doc[key]).unwrap()
        ));
    }
    out.push_str("\n## Task dependencies and checklist items\n");
    for task in doc["tasks"].as_array().into_iter().flatten() {
        out.push_str(&format!("\n```json\n{}\n```\n",serde_json::to_string_pretty(&json!({"task_id":task["id"],"dependency_ids":task["dependency_ids"],"checklist":task["checklist"]})).unwrap()));
    }
}
