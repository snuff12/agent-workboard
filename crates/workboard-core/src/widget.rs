//! A small display projection and observable publication state, independent of task commits.
use super::*;
use std::time::Instant;

#[derive(Default)]
pub(super) struct Publication {
    attempted: Option<Instant>,
    checked_at: Option<String>,
    generated_at: Option<String>,
    sequence: Option<i64>,
    destinations: Vec<Value>,
    configured: bool,
    healthy: bool,
}

#[cfg(test)]
impl Publication {
    pub(super) fn expire_for_test(&mut self) {
        self.attempted = None;
    }
}

impl Board {
    pub fn write_widget_snapshot(&self) -> Result<(), ApiError> {
        let current = sequence(&self.conn)?;
        let checked = now();
        let generated = {
            let previous = self.widget_publication.borrow();
            if previous.sequence == Some(current) {
                previous
                    .generated_at
                    .clone()
                    .unwrap_or_else(|| checked.clone())
            } else {
                self.conn.query_row(
                    "SELECT coalesce(max(created_at),?1) FROM events",
                    [&checked],
                    |r| r.get(0),
                )?
            }
        };
        // No dependency/checklist queries, automation histories, Inbox, or full task descriptions.
        // These fields are the native widget's display contract.
        let mut statement = self.conn.prepare(
            "SELECT id,project_id,parent_id,title,status,priority,assignee,next_action,updated_at,completed_at,due_at,scheduled_start,scheduled_end,time_zone FROM tasks WHERE deleted_at IS NULL ORDER BY priority DESC,created_at,id"
        )?;
        let tasks = statement.query_map([], |r| {
            Ok(json!({
                "id":r.get::<_,String>(0)?,"project_id":r.get::<_,String>(1)?,"parent_id":r.get::<_,Option<String>>(2)?,
                "title":r.get::<_,String>(3)?,"status":r.get::<_,String>(4)?,"priority":r.get::<_,i64>(5)?,
                "assignee":r.get::<_,Option<String>>(6)?,"next_action":r.get::<_,String>(7)?,"updated_at":r.get::<_,String>(8)?,
                "completed_at":r.get::<_,Option<String>>(9)?,"due_at":r.get::<_,Option<String>>(10)?,
                "scheduled_start":r.get::<_,Option<String>>(11)?,"scheduled_end":r.get::<_,Option<String>>(12)?,"time_zone":r.get::<_,String>(13)?
            }))
        })?.collect::<Result<Vec<_>,_>>()?;
        let value = json!({"schema_version":1,"generated_at":generated,"checked_at":checked,
            "event_sequence":current,"tasks":tasks});
        let bytes = serde_json::to_vec(&value)?;
        let mut paths =
            std::collections::BTreeSet::from([self.data_dir.join("widget-snapshot.json")]);
        let configured: Option<String> = self
            .conn
            .query_row(
                "SELECT value FROM settings WHERE key='widget_snapshot_path'",
                [],
                |r| r.get(0),
            )
            .optional()?;
        let environment = std::env::var_os("WORKBOARD_WIDGET_SNAPSHOT").map(PathBuf::from);
        let has_shared = configured.is_some() || environment.is_some();
        let mut destinations = Vec::new();
        let mut first_error = None;
        let mut candidates = Vec::new();
        if let Some(path) = environment {
            candidates.push(Ok(path));
        }
        if let Some(path) = configured {
            candidates.push(serde_json::from_str::<PathBuf>(&path).map_err(ApiError::from));
        }
        for path in candidates {
            match path.and_then(|path| validate_widget_path(&self.data_dir, &path)) {
                Ok(path) => {
                    paths.insert(path);
                }
                Err(error) => {
                    destinations.push(json!({"state":"failed","error":error}));
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
                Ok(()) => {
                    destinations.push(json!({"path":path,"state":"current","event_sequence":current,"checked_at":checked}));
                    #[cfg(target_os = "macos")]
                    if group_container::identifier(&path).is_some() {
                        self.widget_changed.set(true);
                    }
                }
                Err(error) => {
                    let prior = fs::read(&path)
                        .ok()
                        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
                    destinations.push(json!({"path":path,"state":"failed","error":error,
                        "event_sequence":prior.as_ref().and_then(|v| v["event_sequence"].as_i64()),
                        "action":"Check destination access. For a macOS App Group, install a correctly signed app, widget, and service with the same authorized group."}));
                    if first_error.is_none() {
                        first_error = Some(error);
                    }
                }
            }
        }
        *self.widget_publication.borrow_mut() = Publication {
            attempted: Some(Instant::now()),
            checked_at: Some(checked),
            generated_at: Some(generated),
            sequence: Some(current),
            destinations,
            configured: has_shared,
            healthy: first_error.is_none(),
        };
        match first_error {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    /// Retry failed publication without another task edit; healthy idle boards publish a heartbeat.
    pub fn maintain_widget(&self) {
        let due = {
            let state = self.widget_publication.borrow();
            let interval = Duration::from_secs(if state.healthy { 300 } else { 30 });
            state.attempted.is_none_or(|at| at.elapsed() >= interval)
        };
        if due {
            if let Err(error) = self.write_widget_snapshot() {
                eprintln!("widget snapshot: {error}");
            }
        }
    }

    pub(super) fn widget_status(&self) -> Result<Value, ApiError> {
        let state = self.widget_publication.borrow();
        Ok(
            json!({"healthy":state.healthy,"configured":state.configured,
            "state":if !state.healthy { "unavailable" } else if state.configured { "current" } else { "not_configured" },
            "event_sequence":sequence(&self.conn)?,"last_attempt_at":state.checked_at,
            "data_updated_at":state.generated_at,"destinations":state.destinations}),
        )
    }
}
