//! Deleted tasks wait in the trash until the user restores them or deletes them permanently.
//! A trashed task keeps its runs, artifacts, checklist, reviews, dependencies, and Inbox links;
//! live reads skip it. All writes run inside the dispatcher's transaction.
use super::*;
use std::collections::BTreeSet;

/// One entry per deletion: the task the user deleted, with the subtasks deleted alongside it.
pub(super) fn items(c: &Connection) -> Result<Vec<Value>, ApiError> {
    let trashed = trashed_tasks(c, None)?;
    let ids: BTreeSet<&str> = trashed.iter().map(|t| t.id.as_str()).collect();
    let mut groups: Vec<(&str, Vec<&Task>)> = vec![];
    for task in &trashed {
        let key = task.deletion_id.as_deref().unwrap_or(&task.id);
        match groups.iter_mut().find(|(k, _)| *k == key) {
            Some((_, group)) => group.push(task),
            None => groups.push((key, vec![task])),
        }
    }
    groups
        .into_iter()
        .map(|(deletion, group)| {
            let members: BTreeSet<&str> = group.iter().map(|t| t.id.as_str()).collect();
            let root = group
                .iter()
                .find(|t| t.parent_id.as_deref().is_none_or(|p| !members.contains(p)))
                .unwrap_or(&group[0]);
            let parent = root
                .parent_id
                .as_deref()
                .filter(|p| ids.contains(p))
                .and_then(|p| trashed.iter().find(|t| t.id == p));
            let mut tasks: Vec<&Task> = vec![root];
            tasks.extend(group.iter().filter(|t| t.id != root.id));
            Ok(json!({
                "deletion_id": deletion,
                "deleted_at": root.deleted_at,
                "deleted_by": root.deleted_by,
                "task": root,
                "tasks": tasks,
                "subtask_count": group.len() - 1,
                "restorable": parent.is_none(),
                "parent_in_trash": parent.map(|p| json!({"id":p.id,"title":p.title})),
            }))
        })
        .collect()
}

pub(super) fn project_tasks(c: &Connection, project: &str) -> Result<Vec<Task>, ApiError> {
    trashed_tasks(c, Some(project))
}

fn trashed_tasks(c: &Connection, project: Option<&str>) -> Result<Vec<Task>, ApiError> {
    let mut st = c.prepare(&format!("{TASK_SELECT} WHERE deleted_at IS NOT NULL AND (?1 IS NULL OR project_id=?1) ORDER BY deleted_at DESC,rowid"))?;
    let tasks = st
        .query_map([project], task_row)?
        .collect::<Result<Vec<_>, _>>()?;
    tasks
        .into_iter()
        .map(|task| workflow::enrich_task(c, task))
        .collect()
}

/// Moves live tasks into one trash entry. Running runs end as interrupted, as they would on release.
pub(super) fn move_to_trash(
    c: &Connection,
    tasks: &[Task],
    actor: Option<&str>,
) -> Result<Value, ApiError> {
    let deletion = id();
    let at = now();
    let ids: Vec<String> = tasks.iter().map(|t| t.id.clone()).collect();
    for task in tasks {
        let revision = allocate_revision(c, &task.id, task.revision)?;
        c.execute(
            "UPDATE tasks SET deleted_at=?2,deletion_id=?3,deleted_by=?4,revision=?5,updated_at=?2 WHERE id=?1",
            params![task.id, at, deletion, actor, revision],
        )?;
        c.execute(
            "UPDATE runs SET status='interrupted',ended_at=?2 WHERE task_id=?1 AND status='running'",
            params![task.id, at],
        )?;
    }
    let updated = refresh_dependents(c, &ids)?;
    Ok(json!({"deletion_id":deletion,"task_ids":ids,"updated_task_ids":updated}))
}

/// Live tasks that depend on these tasks see their prerequisites change, so they get new revisions
/// and stale editors are rejected.
fn refresh_dependents(c: &Connection, ids: &[String]) -> Result<Vec<String>, ApiError> {
    let list = serde_json::to_string(ids)?;
    let mut st = c.prepare("SELECT DISTINCT d.task_id FROM task_dependencies d JOIN tasks t ON t.id=d.task_id WHERE d.depends_on_id IN (SELECT value FROM json_each(?1)) AND d.task_id NOT IN (SELECT value FROM json_each(?1)) AND t.deleted_at IS NULL ORDER BY d.task_id")?;
    let dependents = st
        .query_map([&list], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    for key in &dependents {
        let mut task = get_task(c, key)?;
        task.revision = allocate_revision(c, key, task.revision)?;
        task.updated_at = now();
        save_task(c, &task)?;
    }
    Ok(dependents)
}

/// The trashed task a restore or permanent deletion names. Subtasks deleted with their parent are
/// handled through that parent.
fn trashed_root(c: &Connection, p: &Value) -> Result<Task, ApiError> {
    let task = get_any_task(c, required(p, "task_id")?)?;
    let Some(deletion) = task.deletion_id.clone() else {
        return Err(ApiError::new(
            "INVALID_STATE",
            "The task is not in the trash",
        ));
    };
    let mut root = task.clone();
    while let Some(parent) = root.parent_id.clone() {
        let parent = get_any_task(c, &parent)?;
        if parent.deletion_id.as_deref() != Some(deletion.as_str()) {
            break;
        }
        root = parent;
    }
    if root.id != task.id {
        return Err(ApiError::new(
            "INVALID_STATE",
            format!(
                "This task was deleted with “{}”. Restore or delete that task instead",
                root.title
            ),
        ));
    }
    check_revision(&task, p, false)?;
    Ok(task)
}

pub(super) fn mutate(c: &Transaction<'_>, r: &Request) -> Result<Option<Value>, ApiError> {
    let p = &r.params;
    let mut result = match r.method.as_str() {
        "trash.restore" => {
            let task = trashed_root(c, p)?;
            if let Some(parent) = &task.parent_id {
                let parent = get_any_task(c, parent)?;
                if parent.deleted_at.is_some() {
                    return Err(ApiError::new(
                        "INVALID_STATE",
                        format!(
                            "Its parent task “{}” is in the trash. Restore the parent first",
                            parent.title
                        ),
                    ));
                }
            }
            let mut st =
                c.prepare("SELECT id,revision FROM tasks WHERE deletion_id=?1 ORDER BY rowid")?;
            let group = st
                .query_map([&task.deletion_id], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            let at = now();
            let mut ids = vec![task.id.clone()];
            ids.extend(
                group
                    .iter()
                    .map(|(key, _)| key.clone())
                    .filter(|key| *key != task.id),
            );
            for (key, old) in &group {
                let revision = allocate_revision(c, key, *old)?;
                c.execute(
                    "UPDATE tasks SET deleted_at=NULL,deletion_id=NULL,deleted_by=NULL,revision=?2,updated_at=?3 WHERE id=?1",
                    params![key, revision, at],
                )?;
            }
            let updated = refresh_dependents(c, &ids)?;
            let seq = record(
                c,
                r,
                Some(&task.id),
                "task.restored",
                json!({"deletion_id":task.deletion_id,"task_ids":ids,"updated_task_ids":updated}),
            )?;
            json!({"task_id":task.id,"restored_task_ids":ids,"task":get_task(c,&task.id)?,"event_sequence":seq})
        }
        "trash.purge" => {
            let task = trashed_root(c, p)?;
            // Subtasks deleted earlier on their own are trashed too and go with their parent.
            let tasks = subtree(c, &task.id, true)?;
            if tasks.iter().any(|t| t.deleted_at.is_none()) {
                return Err(ApiError::new(
                    "INVALID_STATE",
                    "A subtask of this task is not in the trash",
                ));
            }
            // Permanent deletion keeps the rule for live tasks: an agent removes only work it holds or nobody holds.
            check_owners(&tasks, &optional(p, "agent_id")?)?;
            let deleted: Vec<String> = tasks.iter().map(|t| t.id.clone()).collect();
            let removed = delete_tasks(c, &tasks)?;
            let seq = record(
                c,
                r,
                Some(&task.id),
                "task.purged",
                json!({"task":task,"removed":removed}),
            )?;
            json!({"task_id":task.id,"deleted_task_ids":deleted,"event_sequence":seq})
        }
        "trash.empty" => {
            let tasks = trashed_tasks(c, None)?;
            check_owners(&tasks, &optional(p, "agent_id")?)?;
            let deleted: Vec<String> = tasks.iter().map(|t| t.id.clone()).collect();
            if tasks.is_empty() {
                return Ok(Some(
                    json!({"deleted_task_ids":deleted,"event_sequence":sequence(c)?}),
                ));
            }
            let removed = delete_tasks(c, &tasks)?;
            let seq = record(c, r, None, "trash.emptied", json!({"removed":removed}))?;
            json!({"deleted_task_ids":deleted,"event_sequence":seq})
        }
        _ => return Ok(None),
    };
    result["trash_count"] = json!(trashed_tasks(c, None)?.len());
    Ok(Some(result))
}
