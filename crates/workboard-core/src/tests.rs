use super::*;
use tempfile::TempDir;
fn req(method: &str, params: Value) -> Request {
    Request {
        schema_version: 1,
        request_id: id(),
        method: method.into(),
        params,
    }
}
fn call(board: &mut Board, method: &str, params: Value) -> Value {
    let response = board.dispatch(req(method, params));
    assert!(response.ok, "{response:?}");
    response.result.unwrap()
}
fn setup() -> (TempDir, Board, String, String) {
    let dir = TempDir::new().unwrap();
    let mut board = Board::open(dir.path()).unwrap();
    let p = call(
        &mut board,
        "project.create",
        json!({"name":"Development","directory":"/tmp/project"}),
    )["project_id"]
        .as_str()
        .unwrap()
        .to_string();
    let t=call(&mut board,"task.create",json!({"project_id":p,"title":"Build the kanban board","goal":"Check tasks","completion_criteria":"Actual tasks are visible"}))["task_id"].as_str().unwrap().to_string();
    (dir, board, p, t)
}
#[test]
fn retries_survive_restart_and_conflicting_payload_is_rejected() {
    let (dir, mut b, p, _) = setup();
    let request = req(
        "task.create",
        json!({"project_id":p,"title":"Prevent duplicates"}),
    );
    let a = b.dispatch(request.clone());
    assert!(a.ok);
    drop(b);
    let mut b = Board::open(dir.path()).unwrap();
    let again = b.dispatch(request.clone());
    assert_eq!(a.result, again.result);
    let mut changed = request;
    changed.params["title"] = json!("Another request");
    assert_eq!(
        b.dispatch(changed).error.unwrap().code,
        "REQUEST_ID_CONFLICT"
    );
    assert_eq!(
        call(&mut b, "task.list", json!({}))["tasks"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        call(&mut b, "events.list", json!({}))["events"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
}
#[test]
fn stale_edits_and_claims_cannot_overwrite() {
    let (_dir, mut b, _, t) = setup();
    call(
        &mut b,
        "task.claim",
        json!({"task_id":t,"agent_id":"alpha","expected_revision":1}),
    );
    let conflict = b.dispatch(req("task.claim", json!({"task_id":t,"agent_id":"beta"})));
    assert_eq!(conflict.error.unwrap().code, "CLAIM_CONFLICT");
    let stale = b.dispatch(req(
        "task.update",
        json!({"task_id":t,"expected_revision":1,"title":"lost update"}),
    ));
    assert_eq!(stale.error.unwrap().code, "REVISION_CONFLICT");
    let blocked = b.dispatch(req("task.start", json!({"task_id":t,"agent_id":"beta"})));
    assert_eq!(blocked.error.unwrap().code, "CLAIM_CONFLICT");
    assert_eq!(
        call(&mut b, "task.get", json!({"task_id":t}))["task"]["title"],
        "Build the kanban board"
    );
}
#[test]
fn serialized_simultaneous_claims_have_one_winner() {
    let (_dir, b, _, t) = setup();
    let b = std::sync::Arc::new(std::sync::Mutex::new(b));
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(8));
    let jobs = (0..8)
        .map(|i| {
            let b = b.clone();
            let t = t.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                b.lock()
                    .unwrap()
                    .dispatch(req(
                        "task.claim",
                        json!({"task_id":t,"agent_id":format!("agent-{i}")}),
                    ))
                    .ok
            })
        })
        .collect::<Vec<_>>();
    assert_eq!(
        jobs.into_iter()
            .map(|j| j.join().unwrap())
            .filter(|won| *won)
            .count(),
        1
    );
}
#[test]
fn child_completion_does_not_complete_parent_and_cycles_are_rejected() {
    let (_dir, mut b, p, t) = setup();
    let child = call(
        &mut b,
        "task.create",
        json!({"project_id":p,"parent_id":t,"title":"CLI"}),
    )["task_id"]
        .as_str()
        .unwrap()
        .to_string();
    call(
        &mut b,
        "task.complete",
        json!({"task_id":child,"summary":"Verify CLI execution"}),
    );
    let parent = call(&mut b, "task.get", json!({"task_id":t}));
    assert_eq!(parent["task"]["status"], "todo");
    assert_eq!(parent["completed_child_count"], 1);
    assert_eq!(parent["child_count"], 1);
    let cycle = b.dispatch(req(
        "task.update",
        json!({"task_id":t,"parent_id":child,"expected_revision":1}),
    ));
    assert_eq!(cycle.error.unwrap().code, "HIERARCHY_CYCLE");
    let p2 = call(&mut b, "project.create", json!({"name":"Another project"}))["project_id"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(
        !b.dispatch(req(
            "task.create",
            json!({"project_id":p2,"parent_id":t,"title":"Invalid link"})
        ))
        .ok
    );
}
#[test]
fn interrupted_run_keeps_task_and_context_with_artifacts() {
    let (dir, mut b, _, t) = setup();
    let run = call(
        &mut b,
        "task.start",
        json!({"task_id":t,"agent_id":"alpha"}),
    )["run_id"]
        .as_str()
        .unwrap()
        .to_string();
    call(
        &mut b,
        "task.attach",
        json!({"task_id":t,"path":"https://example.com/design","kind":"url","run_id":run,"description":"Design evidence","metadata":{"provider":"agent-memory","collection":"docs","locator":"L12","scope":{"project":"workboard","domain":"design"}}}),
    );
    call(
        &mut b,
        "run.finish",
        json!({"task_id":t,"run_id":run,"status":"interrupted","summary":"Storage complete","next_action":"Implement the CLI"}),
    );
    drop(b);
    let mut b = Board::open(dir.path()).unwrap();
    let context = call(&mut b, "task.resume_context", json!({"task_id":t}));
    assert_eq!(context["task"]["status"], "in_progress");
    assert_eq!(context["task"]["next_action"], "Implement the CLI");
    assert_eq!(context["runs"][0]["status"], "interrupted");
    assert_eq!(context["artifacts"][0]["description"], "Design evidence");
    assert_eq!(
        context["artifacts"][0]["metadata"]["scope"]["project"],
        "workboard"
    );
    call(
        &mut b,
        "task.release",
        json!({"task_id":t,"agent_id":"alpha"}),
    );
    let resumed = call(&mut b, "task.start", json!({"task_id":t,"agent_id":"beta"}));
    assert_ne!(resumed["run_id"], run);
    assert_eq!(resumed["task"]["assignee"], "beta");
}
#[test]
fn completing_a_run_never_completes_a_task() {
    let (_dir, mut b, _, t) = setup();
    let run = call(&mut b, "task.start", json!({"task_id":t}))["run_id"].clone();
    call(
        &mut b,
        "run.finish",
        json!({"task_id":t,"run_id":run,"status":"completed","summary":"Response turn ended"}),
    );
    assert_eq!(
        call(&mut b, "task.get", json!({"task_id":t}))["task"]["status"],
        "in_progress"
    );
    assert!(!b.dispatch(req("task.complete", json!({"task_id":t}))).ok);
    call(
        &mut b,
        "task.complete",
        json!({"task_id":t,"summary":"Check completion criteria and artifacts"}),
    );
    assert_eq!(
        call(&mut b, "task.get", json!({"task_id":t}))["task"]["status"],
        "done"
    );
}
#[test]
fn search_updates_and_does_not_interpret_fts_operators() {
    let (_dir, mut b, _, t) = setup();
    assert_eq!(
        call(&mut b, "task.list", json!({"query":"Kanban"}))["tasks"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    call(
        &mut b,
        "task.update",
        json!({"task_id":t,"expected_revision":1,"title":"Implement the widget","next_action":"Verify the snapshot"}),
    );
    assert_eq!(
        call(&mut b, "task.list", json!({"query":"Kanban"}))["tasks"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert_eq!(
        call(&mut b, "task.list", json!({"query":"Snapshot"}))["tasks"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(b.dispatch(req("task.list", json!({"query":"\" OR *"}))).ok);
    // English project text must not reduce Unicode support in user task data.
    let revision = call(&mut b, "task.get", json!({"task_id":t}))["task"]["revision"].clone();
    call(
        &mut b,
        "task.update",
        json!({"task_id":t,"expected_revision":revision,"title":"Café résumé"}),
    );
    let found = call(&mut b, "task.list", json!({"query":"café"}));
    assert_eq!(found["tasks"][0]["title"], "Café résumé");
}
#[test]
fn online_backup_restores_wal_data_and_retries() {
    let (dir, mut b, p, t) = setup();
    let backup = dir.path().join("backup.sqlite3");
    call(
        &mut b,
        "task.attach",
        json!({"task_id":t,"path":"/tmp/output.md"}),
    );
    call(&mut b, "backup.create", json!({"path":backup}));
    call(
        &mut b,
        "task.create",
        json!({"project_id":p,"title":"New task after backup"}),
    );
    let previous_sequence = call(&mut b, "board.snapshot", json!({}))["event_sequence"]
        .as_i64()
        .unwrap();
    let restore = req("backup.restore", json!({"path":backup}));
    let first = b.dispatch(restore.clone());
    assert!(first.ok, "{first:?}");
    assert!(
        first.result.as_ref().unwrap()["event_sequence"]
            .as_i64()
            .unwrap()
            > previous_sequence
    );
    assert_eq!(b.dispatch(restore).result, first.result);
    assert_eq!(
        call(&mut b, "task.list", json!({}))["tasks"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        call(&mut b, "task.get", json!({"task_id":t}))["artifacts"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(fs::read_dir(dir.path()).unwrap().any(|e| e
        .unwrap()
        .file_name()
        .to_string_lossy()
        .starts_with("before-restore-")));
    let widget: Value =
        serde_json::from_slice(&fs::read(dir.path().join("widget-snapshot.json")).unwrap())
            .unwrap();
    assert_eq!(widget["tasks"].as_array().unwrap().len(), 1);
}
#[test]
fn invalid_backup_does_not_damage_current_database() {
    let (dir, mut b, _, t) = setup();
    let invalid = dir.path().join("bad.sqlite3");
    fs::write(&invalid, b"not a sqlite database").unwrap();
    assert!(
        !b.dispatch(req("backup.restore", json!({"path":invalid})))
            .ok
    );
    assert_eq!(
        call(&mut b, "task.get", json!({"task_id":t}))["task"]["title"],
        "Build the kanban board"
    );
    assert_eq!(call(&mut b, "doctor", json!({}))["healthy"], true);
}
#[test]
fn export_includes_hierarchy_results_and_runs_without_plugins() {
    let (_dir, mut b, p, t) = setup();
    call(
        &mut b,
        "task.create",
        json!({"project_id":p,"parent_id":t,"title":"Subtask"}),
    );
    call(&mut b, "task.start", json!({"task_id":t}));
    call(
        &mut b,
        "task.attach",
        json!({"task_id":t,"path":"/tmp/result.txt"}),
    );
    let export = call(&mut b, "export", json!({"format":"json"}));
    assert_eq!(export["data"]["tasks"].as_array().unwrap().len(), 2);
    assert_eq!(export["data"]["runs"].as_array().unwrap().len(), 1);
    assert_eq!(export["data"]["artifacts"].as_array().unwrap().len(), 1);
    let markdown = call(&mut b, "export", json!({"format":"markdown"}));
    assert!(markdown["content"].as_str().unwrap().contains("Subtask"));
    assert!(markdown["content"]
        .as_str()
        .unwrap()
        .contains("/tmp/result.txt"));
}
#[test]
fn schema_mismatch_is_rejected_before_mutation() {
    let (_dir, mut b, _, t) = setup();
    let mut r = req(
        "task.complete",
        json!({"task_id":t,"summary":"bad version"}),
    );
    r.schema_version = 2;
    assert_eq!(b.dispatch(r).error.unwrap().code, "INCOMPATIBLE_VERSION");
    assert_eq!(
        call(&mut b, "task.get", json!({"task_id":t}))["task"]["status"],
        "todo"
    );
}

#[test]
fn widget_failure_does_not_fail_committed_tasks() {
    let (dir, mut b, p, _) = setup();
    let widget = dir.path().join("widget-snapshot.json");
    fs::remove_file(&widget).unwrap();
    fs::create_dir(&widget).unwrap();
    call(
        &mut b,
        "task.create",
        json!({"project_id":p,"title":"Save despite widget write failure"}),
    );
    assert_eq!(
        call(&mut b, "task.list", json!({}))["tasks"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    drop(b);
    let mut b = Board::open(dir.path()).unwrap();
    assert_eq!(call(&mut b, "doctor", json!({}))["healthy"], true);
}
#[test]
fn stale_claim_is_retained_until_owner_releases_and_heartbeat_refreshes() {
    let (_dir, mut b, _, t) = setup();
    call(
        &mut b,
        "task.claim",
        json!({"task_id":t,"agent_id":"alpha"}),
    );
    b.conn
        .execute(
            "UPDATE tasks SET claimed_at='2000-01-01T00:00:00.000Z' WHERE id=?1",
            [&t],
        )
        .unwrap();
    let task = call(&mut b, "task.get", json!({"task_id":t}))["task"].clone();
    assert_eq!(task["claim_stale"], true);
    assert_eq!(task["assignee"], "alpha");
    assert_eq!(
        b.dispatch(req("task.claim", json!({"task_id":t,"agent_id":"beta"})))
            .error
            .unwrap()
            .code,
        "CLAIM_CONFLICT"
    );
    call(
        &mut b,
        "task.heartbeat",
        json!({"task_id":t,"agent_id":"alpha"}),
    );
    assert_eq!(
        call(&mut b, "task.get", json!({"task_id":t}))["task"]["claim_stale"],
        false
    );
}

#[test]
fn restore_request_conflict_rolls_back_all_tasks_and_search() {
    let (dir, mut live, _, t) = setup();
    let mut collision = req("project.create", json!({"name":"live ledger"}));
    collision.request_id = "shared-request-id".into();
    assert!(live.dispatch(collision.clone()).ok);
    let original = live.snapshot().unwrap();
    let foreign_dir = TempDir::new().unwrap();
    let mut foreign = Board::open(foreign_dir.path()).unwrap();
    collision.params = json!({"name":"different payload"});
    assert!(foreign.dispatch(collision).ok);
    let backup = dir.path().join("conflicting-backup.sqlite3");
    call(&mut foreign, "backup.create", json!({"path":backup}));
    let result = live.dispatch(req("backup.restore", json!({"path":backup})));
    assert_eq!(result.error.unwrap().code, "REQUEST_ID_CONFLICT");
    assert_eq!(live.snapshot().unwrap(), original);
    assert_eq!(
        call(&mut live, "task.list", json!({"query":"Kanban"}))["tasks"][0]["id"],
        t
    );
    assert!(call(&mut live, "doctor", json!({}))["healthy"]
        .as_bool()
        .unwrap());
}
#[test]
fn restore_rejects_future_schema_before_changing_tasks() {
    let (dir, mut b, _, _) = setup();
    let original = b.snapshot().unwrap();
    let path = dir.path().join("future.sqlite3");
    let future = Connection::open(&path).unwrap();
    future
        .execute_batch(&format!("PRAGMA user_version={}", DATABASE_VERSION + 1))
        .unwrap();
    drop(future);
    assert_eq!(
        b.dispatch(req("backup.restore", json!({"path":path})))
            .error
            .unwrap()
            .code,
        "INCOMPATIBLE_BACKUP"
    );
    assert_eq!(b.snapshot().unwrap(), original);
}

#[test]
fn backup_receipt_recovers_retry_after_publish_before_ledger_commit() {
    let (dir, mut b, p, _) = setup();
    let path = dir.path().join("receipt.sqlite3");
    let request = req("backup.create", json!({"path":path}));
    let response = b.dispatch(request.clone());
    assert!(response.ok);
    // Simulate process loss after the complete file was published but before the retry ledger committed.
    b.conn
        .execute(
            "DELETE FROM requests WHERE request_id=?1",
            [&request.request_id],
        )
        .unwrap();
    call(
        &mut b,
        "task.create",
        json!({"project_id":p,"title":"Follow-up task"}),
    );
    assert_eq!(b.dispatch(request).result, response.result);
    let saved =
        Connection::open_with_flags(&path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    assert_eq!(list_tasks(&saved, &json!({})).unwrap().len(), 1);
}

#[test]
fn deadlines_and_calendar_ranges_roundtrip_and_export_without_plugins() {
    let (_dir, mut b, p, _) = setup();
    let t = call(
        &mut b,
        "task.create",
        json!({"project_id":p,"title":"Prepare for the meeting","due_at":"2026-10-20","scheduled_start":"2026-10-19T10:00:00+09:00","scheduled_end":"2026-10-19T01:30:00Z","time_zone":"Asia/Seoul"}),
    );
    assert_eq!(t["task"]["due_at"], "2026-10-20");
    assert_eq!(t["task"]["time_zone"], "Asia/Seoul");
    let t = call(
        &mut b,
        "task.update",
        json!({"task_id":t["task_id"],"expected_revision":1,"scheduled_start":"2026-10-19","scheduled_end":"2026-10-20"}),
    );
    assert_eq!(t["task"]["scheduled_start"], "2026-10-19");
    assert!(
        call(&mut b, "export", json!({"format":"markdown"}))["content"]
            .as_str()
            .unwrap()
            .contains("Due: 2026-10-20")
    );
    let cleared = call(
        &mut b,
        "task.update",
        json!({"task_id":t["task_id"],"expected_revision":2,"due_at":null,"scheduled_start":null,"scheduled_end":null}),
    );
    assert_eq!(cleared["task"]["due_at"], Value::Null);
    assert_eq!(cleared["task"]["scheduled_end"], Value::Null);
}
#[test]
fn invalid_calendar_dates_ranges_and_timezones_do_not_create_tasks() {
    let (_dir, mut b, p, _) = setup();
    for extra in [
        json!({"due_at":"2026-02-30"}),
        json!({"due_at":"2026-10-20T09:00:00"}),
        json!({"time_zone":"Mars/Unknown"}),
        json!({"scheduled_start":"2026-10-20"}),
        json!({"scheduled_start":"2026-10-20","scheduled_end":"2026-10-19"}),
        json!({"scheduled_start":"2026-10-20","scheduled_end":"2026-10-20"}),
        json!({"scheduled_start":"2026-10-20","scheduled_end":"2026-10-21T09:00:00Z"}),
        json!({"scheduled_start":"2026-10-20T10:00:00+09:00","scheduled_end":"2026-10-20T00:30:00Z"}),
    ] {
        let mut params = json!({"project_id":p,"title":"Invalid schedule"});
        params
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        assert_eq!(
            b.dispatch(req("task.create", params)).error.unwrap().code,
            "INVALID_PARAMS"
        );
    }
    assert_eq!(
        call(&mut b, "task.list", json!({}))["tasks"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}
fn downgrade_to_v1(path: &Path) {
    let connection = Connection::open(path).unwrap();
    connection.execute_batch("DROP TABLE task_dependencies; DROP TABLE checklist_items; DROP TABLE review_decisions; DROP TABLE inbox; DROP TABLE templates; DROP TABLE saved_views; DROP TABLE workflow_revisions; ALTER TABLE tasks DROP COLUMN time_zone; ALTER TABLE tasks DROP COLUMN scheduled_end; ALTER TABLE tasks DROP COLUMN scheduled_start; ALTER TABLE tasks DROP COLUMN due_at; DROP TABLE IF EXISTS settings; DROP TABLE IF EXISTS task_revisions; PRAGMA user_version=1;").unwrap();
}
#[test]
fn schema_v1_migration_preserves_existing_tasks_and_adds_calendar_defaults() {
    let (dir, b, _, t) = setup();
    drop(b);
    let path = dir.path().join("workboard.sqlite3");
    downgrade_to_v1(&path);
    let mut b = Board::open(dir.path()).unwrap();
    let task = call(&mut b, "task.get", json!({"task_id":t}))["task"].clone();
    assert_eq!(task["title"], "Build the kanban board");
    assert_eq!(task["time_zone"], "UTC");
    assert_eq!(task["due_at"], Value::Null);
    assert_eq!(
        call(&mut b, "doctor", json!({}))["database_version"],
        DATABASE_VERSION
    );
    call(
        &mut b,
        "task.update",
        json!({"task_id":t,"expected_revision":1,"due_at":"2026-11-01"}),
    );
}
#[test]
fn v1_backup_is_restored_via_private_migration_without_modifying_source() {
    let (dir, mut b, p, t) = setup();
    let path = dir.path().join("old-backup.sqlite3");
    call(&mut b, "backup.create", json!({"path":path}));
    downgrade_to_v1(&path);
    let before = fs::read(&path).unwrap();
    call(
        &mut b,
        "task.create",
        json!({"project_id":p,"title":"Removed by restore"}),
    );
    call(&mut b, "backup.restore", json!({"path":path}));
    assert_eq!(fs::read(&path).unwrap(), before);
    let task = call(&mut b, "task.get", json!({"task_id":t}))["task"].clone();
    assert_eq!(task["time_zone"], "UTC");
    assert_eq!(
        call(&mut b, "task.list", json!({}))["tasks"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(!fs::read_dir(dir.path()).unwrap().any(|entry| entry
        .unwrap()
        .file_name()
        .to_string_lossy()
        .starts_with("restore-input-")));
}

#[test]
fn markdown_export_preserves_resume_summaries_and_verified_evidence_metadata() {
    let (_dir, mut b, _, t) = setup();
    let run = call(
        &mut b,
        "task.start",
        json!({"task_id":t,"agent_id":"codex"}),
    )["run_id"]
        .clone();
    call(
        &mut b,
        "task.attach",
        json!({"task_id":t,"path":"/project/source.md","run_id":run,"metadata":{"provider":"agent-memory","locator":"L42","verified_at":"2026-10-15T09:00:00Z","source_sha256":"verified-source-hash","scope":{"project":"agent-workboard"}}}),
    );
    call(
        &mut b,
        "run.finish",
        json!({"task_id":t,"run_id":run,"summary":"Storage verification complete","next_action":"Verify UI integration"}),
    );
    let exported = call(&mut b, "export", json!({"format":"markdown"}));
    let content = exported["content"].as_str().unwrap();
    for required in [
        "Storage verification complete",
        "Verify UI integration",
        "L42",
        "2026-10-15T09:00:00Z",
        "verified-source-hash",
        "agent-workboard",
    ] {
        assert!(content.contains(required), "missing {required}");
    }
}

#[test]
fn widget_configuration_survives_restart_updates_and_can_be_unset() {
    let (dir, mut b, p, _) = setup();
    let shared = dir.path().join("app-group/widget.json");
    let request = req("widget.configure", json!({"snapshot_path":shared}));
    let configured = b.dispatch(request.clone());
    assert!(configured.ok);
    assert_eq!(b.dispatch(request.clone()).result, configured.result);
    let mut changed = request;
    changed.params = json!({"snapshot_path":dir.path().join("other.json")});
    assert_eq!(
        b.dispatch(changed).error.unwrap().code,
        "REQUEST_ID_CONFLICT"
    );
    let t = call(
        &mut b,
        "task.create",
        json!({"project_id":p,"title":"Shared widget"}),
    )["task_id"]
        .clone();
    let initial: Value = serde_json::from_slice(&fs::read(&shared).unwrap()).unwrap();
    assert_eq!(initial["tasks"].as_array().unwrap().len(), 2);
    drop(b);
    let mut b = Board::open(dir.path()).unwrap();
    call(
        &mut b,
        "task.update",
        json!({"task_id":t,"expected_revision":1,"title":"Update after restart"}),
    );
    let current: Value = serde_json::from_slice(&fs::read(&shared).unwrap()).unwrap();
    assert!(current["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .any(|task| task["title"] == "Update after restart"));
    let saved = fs::read(&shared).unwrap();
    call(&mut b, "widget.configure", json!({"snapshot_path":null}));
    call(
        &mut b,
        "task.create",
        json!({"project_id":p,"title":"Task after disconnect"}),
    );
    assert_eq!(fs::read(&shared).unwrap(), saved);
    assert_eq!(
        serde_json::from_slice::<Value>(
            &fs::read(dir.path().join("widget-snapshot.json")).unwrap()
        )
        .unwrap()["tasks"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
}
#[test]
fn widget_configuration_rejects_database_and_non_file_targets() {
    let (dir, mut b, _, _) = setup();
    for target in [
        dir.path().to_path_buf(),
        dir.path().join("workboard.sqlite3"),
        dir.path().join("service.lock"),
        dir.path().join("workboard.sock"),
    ] {
        assert_eq!(
            b.dispatch(req("widget.configure", json!({"snapshot_path":target})))
                .error
                .unwrap()
                .code,
            "INVALID_PARAMS"
        );
    }
    assert_eq!(
        b.dispatch(req("widget.configure", json!({})))
            .error
            .unwrap()
            .code,
        "INVALID_PARAMS"
    );
    assert_eq!(call(&mut b, "doctor", json!({}))["healthy"], true);
}
#[test]
fn broken_shared_widget_target_does_not_block_default_snapshot_or_task_mutations() {
    let (dir, mut b, p, _) = setup();
    let shared = dir.path().join("widget-shared.json");
    call(&mut b, "widget.configure", json!({"snapshot_path":shared}));
    fs::remove_file(&shared).unwrap();
    fs::create_dir(&shared).unwrap();
    call(
        &mut b,
        "task.create",
        json!({"project_id":p,"title":"Preserve despite shared path failure"}),
    );
    assert_eq!(
        serde_json::from_slice::<Value>(
            &fs::read(dir.path().join("widget-snapshot.json")).unwrap()
        )
        .unwrap()["tasks"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
}
#[test]
fn schema_v2_migration_preserves_schedules_and_adds_widget_settings() {
    let (dir, mut b, _, t) = setup();
    call(
        &mut b,
        "task.update",
        json!({"task_id":t,"expected_revision":1,"due_at":"2026-12-01"}),
    );
    drop(b);
    let raw = Connection::open(dir.path().join("workboard.sqlite3")).unwrap();
    raw.execute_batch("DROP TABLE task_dependencies; DROP TABLE checklist_items; DROP TABLE review_decisions; DROP TABLE inbox; DROP TABLE templates; DROP TABLE saved_views; DROP TABLE workflow_revisions; DROP TABLE settings; DROP TABLE task_revisions; PRAGMA user_version=2")
        .unwrap();
    drop(raw);
    let mut b = Board::open(dir.path()).unwrap();
    assert_eq!(
        call(&mut b, "task.get", json!({"task_id":t}))["task"]["due_at"],
        "2026-12-01"
    );
    call(
        &mut b,
        "widget.configure",
        json!({"snapshot_path":dir.path().join("shared.json")}),
    );
    assert!(dir.path().join("shared.json").exists());
}
#[test]
fn restore_preserves_this_devices_shared_widget_configuration() {
    let (dir, mut b, p, _) = setup();
    let backup = dir.path().join("board-backup.sqlite3");
    call(&mut b, "backup.create", json!({"path":backup}));
    let shared = dir.path().join("current-app-group/snapshot.json");
    call(&mut b, "widget.configure", json!({"snapshot_path":shared}));
    call(
        &mut b,
        "task.create",
        json!({"project_id":p,"title":"Temporary task before restore"}),
    );
    call(&mut b, "backup.restore", json!({"path":backup}));
    let restored: Value = serde_json::from_slice(&fs::read(&shared).unwrap()).unwrap();
    assert_eq!(restored["tasks"].as_array().unwrap().len(), 1);
    drop(b);
    let mut b = Board::open(dir.path()).unwrap();
    call(
        &mut b,
        "task.create",
        json!({"project_id":p,"title":"Update shared snapshot after restore"}),
    );
    let updated: Value = serde_json::from_slice(&fs::read(&shared).unwrap()).unwrap();
    assert_eq!(updated["tasks"].as_array().unwrap().len(), 2);
}

#[test]
fn restore_never_reuses_a_revision_seen_before_restore() {
    let (dir, mut b, _, t) = setup();
    let backup = dir.path().join("revision-one.sqlite3");
    call(&mut b, "backup.create", json!({"path":backup}));
    let stale = call(
        &mut b,
        "task.update",
        json!({"task_id":t,"expected_revision":1,"title":"Old edit A"}),
    )["task"]
        .clone();
    call(&mut b, "backup.restore", json!({"path":backup}));
    let restored = call(&mut b, "task.get", json!({"task_id":t}))["task"].clone();
    call(
        &mut b,
        "task.update",
        json!({"task_id":t,"expected_revision":restored["revision"],"title":"Current edit B"}),
    );
    let attempted = b.dispatch(req(
        "task.update",
        json!({"task_id":t,"expected_revision":stale["revision"],"title":"Overwrite by stale request"}),
    ));
    assert_eq!(
        attempted
            .error
            .expect("stale edit was accepted after restore")
            .code,
        "REVISION_CONFLICT"
    );
    assert_eq!(
        call(&mut b, "task.get", json!({"task_id":t}))["task"]["title"],
        "Current edit B"
    );
    assert!(restored["revision"].as_i64().unwrap() > stale["revision"].as_i64().unwrap());
}
#[test]
fn restored_task_reappearance_retains_revision_watermark_across_restart() {
    let (dir, mut b, p, _) = setup();
    let absent = dir.path().join("before-new-task.sqlite3");
    call(&mut b, "backup.create", json!({"path":absent}));
    let created = call(
        &mut b,
        "task.create",
        json!({"project_id":p,"title":"Task created later"}),
    )["task"]
        .clone();
    let present = dir.path().join("with-new-task.sqlite3");
    call(&mut b, "backup.create", json!({"path":present}));
    let advanced = call(
        &mut b,
        "task.update",
        json!({"task_id":created["id"],"expected_revision":1,"title":"Latest edit of the new task"}),
    )["task"]
        .clone();
    call(&mut b, "backup.restore", json!({"path":absent}));
    drop(b);
    let mut b = Board::open(dir.path()).unwrap();
    call(&mut b, "backup.restore", json!({"path":present}));
    let returned = call(&mut b, "task.get", json!({"task_id":created["id"]}))["task"].clone();
    assert!(
        returned["revision"].as_i64().unwrap() > advanced["revision"].as_i64().unwrap(),
        "reappearing task reused an old revision"
    );
    assert_eq!(b.dispatch(req("task.update",json!({"task_id":created["id"],"expected_revision":advanced["revision"],"title":"stale"}))).error.unwrap().code,"REVISION_CONFLICT");
}
#[test]
fn late_old_run_cannot_complete_review_or_pause_a_new_run() {
    let (_dir, mut b, _, t) = setup();
    call(
        &mut b,
        "task.start",
        json!({"task_id":t,"agent_id":"alpha","run_id":"zz-old"}),
    );
    call(
        &mut b,
        "task.pause",
        json!({"task_id":t,"agent_id":"alpha","run_id":"zz-old","summary":"Old run interrupted"}),
    );
    call(
        &mut b,
        "task.start",
        json!({"task_id":t,"agent_id":"alpha","run_id":"aa-new"}),
    );
    b.conn
        .execute(
            "UPDATE runs SET started_at='2026-10-15T10:00:00.000Z' WHERE task_id=?1",
            [&t],
        )
        .unwrap();
    let before = call(&mut b, "task.get", json!({"task_id":t}));
    for method in ["task.complete", "task.review", "task.pause"] {
        let result=b.dispatch(req(method,json!({"task_id":t,"agent_id":"alpha","run_id":"zz-old","summary":"Late result from old run","next_action":"Old next action"})));
        assert_eq!(
            result.error.expect("old run mutated the current task").code,
            "RUN_CONFLICT"
        );
        assert_eq!(call(&mut b, "task.get", json!({"task_id":t})), before);
    }
    let finished = call(
        &mut b,
        "task.complete",
        json!({"task_id":t,"agent_id":"alpha","run_id":"aa-new","summary":"Current run verified"}),
    );
    assert_eq!(finished["task"]["status"], "done");
}
#[test]
fn historical_run_edits_preserve_current_task_next_action_and_new_run() {
    let (_dir, mut b, _, t) = setup();
    call(
        &mut b,
        "task.start",
        json!({"task_id":t,"agent_id":"alpha","run_id":"zz-old"}),
    );
    call(
        &mut b,
        "run.finish",
        json!({"task_id":t,"run_id":"zz-old","agent_id":"alpha","next_action":"Old action","status":"completed"}),
    );
    call(
        &mut b,
        "task.start",
        json!({"task_id":t,"agent_id":"alpha","run_id":"aa-new"}),
    );
    let task = call(&mut b, "task.get", json!({"task_id":t}))["task"].clone();
    call(
        &mut b,
        "task.update",
        json!({"task_id":t,"expected_revision":task["revision"],"next_action":"Current action"}),
    );
    b.conn
        .execute(
            "UPDATE runs SET started_at='2026-10-15T10:00:00.000Z' WHERE task_id=?1",
            [&t],
        )
        .unwrap();
    let ended_at = call(&mut b, "task.get", json!({"task_id":t}))["runs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|run| run["id"] == "zz-old")
        .unwrap()["ended_at"]
        .clone();
    for method in ["run.update", "run.finish"] {
        let result = call(
            &mut b,
            method,
            json!({"task_id":t,"run_id":"zz-old","agent_id":"alpha","summary":"Correct historical record","next_action":"Correct only the historical run"}),
        );
        assert_eq!(result["task"]["next_action"], "Current action");
        let runs = result["runs"].as_array().unwrap();
        assert_eq!(
            runs.iter().find(|run| run["id"] == "zz-old").unwrap()["ended_at"],
            ended_at
        );
        assert_eq!(
            runs.iter().find(|run| run["id"] == "zz-old").unwrap()["status"],
            "completed"
        );
        assert_eq!(
            runs.iter().find(|run| run["id"] == "aa-new").unwrap()["status"],
            "running"
        );
        assert_eq!(
            runs.iter().find(|run| run["id"] == "zz-old").unwrap()["next_action"],
            "Correct only the historical run"
        );
    }
    assert_eq!(
        b.dispatch(req(
            "run.update",
            json!({"task_id":t,"run_id":"zz-old","status":"running"})
        ))
        .error
        .unwrap()
        .code,
        "RUN_CONFLICT"
    );
    let finished = call(
        &mut b,
        "run.finish",
        json!({"task_id":t,"run_id":"aa-new","summary":"Edit only the current run summary"}),
    );
    assert_eq!(finished["task"]["next_action"], "Current action");
}

#[test]
fn restoring_foreign_backup_imports_watermarks_for_tasks_absent_from_that_backup() {
    let (source_dir, mut source, p, _) = setup();
    let absent = source_dir.path().join("absent.sqlite3");
    call(&mut source, "backup.create", json!({"path":absent}));
    let task = call(
        &mut source,
        "task.create",
        json!({"project_id":p,"title":"Task temporarily removed by restore"}),
    )["task"]
        .clone();
    let present = source_dir.path().join("present.sqlite3");
    call(&mut source, "backup.create", json!({"path":present}));
    let advanced = call(
        &mut source,
        "task.update",
        json!({"task_id":task["id"],"expected_revision":1,"title":"Latest state"}),
    )["task"]
        .clone();
    call(&mut source, "backup.restore", json!({"path":absent}));
    let absent_with_ledger = source_dir.path().join("absent-with-ledger.sqlite3");
    call(
        &mut source,
        "backup.create",
        json!({"path":absent_with_ledger}),
    );
    let target_dir = TempDir::new().unwrap();
    let mut target = Board::open(target_dir.path()).unwrap();
    call(
        &mut target,
        "backup.restore",
        json!({"path":absent_with_ledger}),
    );
    assert_eq!(
        target
            .dispatch(req("task.get", json!({"task_id":task["id"]})))
            .error
            .unwrap()
            .code,
        "NOT_FOUND"
    );
    call(&mut target, "backup.restore", json!({"path":present}));
    let restored = call(&mut target, "task.get", json!({"task_id":task["id"]}))["task"].clone();
    assert!(restored["revision"].as_i64().unwrap() > advanced["revision"].as_i64().unwrap());
}
#[test]
fn schema_v3_migration_recovers_absent_task_watermark_from_retry_receipts() {
    let (dir, mut b, _, t) = setup();
    let old = dir.path().join("old-task.sqlite3");
    call(&mut b, "backup.create", json!({"path":old}));
    let advanced = call(
        &mut b,
        "task.update",
        json!({"task_id":t,"expected_revision":1,"title":"Previously allocated revision"}),
    )["task"]
        .clone();
    drop(b);
    let raw = Connection::open(dir.path().join("workboard.sqlite3")).unwrap();
    raw.execute("DELETE FROM tasks WHERE id=?1", [&t]).unwrap();
    raw.execute_batch("DROP TABLE task_dependencies; DROP TABLE checklist_items; DROP TABLE review_decisions; DROP TABLE inbox; DROP TABLE templates; DROP TABLE saved_views; DROP TABLE workflow_revisions; DROP TABLE task_revisions; PRAGMA user_version=3")
        .unwrap();
    drop(raw);
    let mut b = Board::open(dir.path()).unwrap();
    call(&mut b, "backup.restore", json!({"path":old}));
    let restored = call(&mut b, "task.get", json!({"task_id":t}))["task"].clone();
    assert!(restored["revision"].as_i64().unwrap() > advanced["revision"].as_i64().unwrap());
}
#[test]
fn latest_run_order_survives_restore_when_start_timestamps_are_equal() {
    let (dir, mut b, _, t) = setup();
    call(
        &mut b,
        "task.start",
        json!({"task_id":t,"agent_id":"alpha","run_id":"zz-old"}),
    );
    call(
        &mut b,
        "task.start",
        json!({"task_id":t,"agent_id":"alpha","run_id":"aa-new"}),
    );
    b.conn
        .execute(
            "UPDATE runs SET started_at='2026-10-15T10:00:00.000Z' WHERE task_id=?1",
            [&t],
        )
        .unwrap();
    let backup = dir.path().join("equal-times.sqlite3");
    call(&mut b, "backup.create", json!({"path":backup}));
    call(&mut b, "backup.restore", json!({"path":backup}));
    assert_eq!(
        b.dispatch(req(
            "task.complete",
            json!({"task_id":t,"run_id":"zz-old","summary":"Old outcome"})
        ))
        .error
        .unwrap()
        .code,
        "RUN_CONFLICT"
    );
    let result = call(
        &mut b,
        "task.complete",
        json!({"task_id":t,"run_id":"aa-new","summary":"Current outcome"}),
    );
    assert_eq!(result["task"]["status"], "done");
}
#[test]
fn latest_review_run_can_be_explicitly_approved_without_restarting_it() {
    let (_dir, mut b, _, t) = setup();
    call(
        &mut b,
        "task.start",
        json!({"task_id":t,"agent_id":"alpha","run_id":"review-run"}),
    );
    call(
        &mut b,
        "task.review",
        json!({"task_id":t,"run_id":"review-run","summary":"Request review"}),
    );
    b.conn
        .execute(
            "UPDATE runs SET ended_at='2026-10-15T10:00:00.000Z' WHERE id='review-run'",
            [],
        )
        .unwrap();
    let approved = call(
        &mut b,
        "task.complete",
        json!({"task_id":t,"run_id":"review-run","summary":"Approve after review","next_action":"Verify final outcome"}),
    );
    assert_eq!(approved["task"]["status"], "done");
    assert_eq!(
        approved["task"]["completion_summary"],
        "Approve after review"
    );
    let run = approved["runs"].as_array().unwrap().first().unwrap();
    assert_eq!(run["status"], "completed");
    assert_eq!(run["summary"], "Approve after review");
    assert_eq!(run["next_action"], "Verify final outcome");
    assert_ne!(run["ended_at"], "2026-10-15T10:00:00.000Z");
    assert!(run["ended_at"].is_string());
}

#[test]
fn latest_terminal_run_corrections_do_not_replace_task_next_action() {
    let (_dir, mut b, _, t) = setup();
    call(
        &mut b,
        "task.start",
        json!({"task_id":t,"agent_id":"alpha","run_id":"latest-run"}),
    );
    let finished = call(
        &mut b,
        "run.finish",
        json!({"task_id":t,"run_id":"latest-run","status":"completed","next_action":"Action at run end"}),
    );
    assert_eq!(finished["task"]["next_action"], "Action at run end");
    let ended_at = finished["runs"][0]["ended_at"].clone();
    call(
        &mut b,
        "task.update",
        json!({"task_id":t,"expected_revision":finished["task"]["revision"],"next_action":"Current task action"}),
    );
    for method in ["run.update", "run.finish"] {
        let corrected = call(
            &mut b,
            method,
            json!({"task_id":t,"run_id":"latest-run","summary":"Correct finished run record","next_action":"Correct only the finished run"}),
        );
        assert_eq!(corrected["task"]["next_action"], "Current task action");
        assert_eq!(
            corrected["runs"][0]["summary"],
            "Correct finished run record"
        );
        assert_eq!(
            corrected["runs"][0]["next_action"],
            "Correct only the finished run"
        );
        assert_eq!(corrected["runs"][0]["status"], "completed");
        assert_eq!(corrected["runs"][0]["ended_at"], ended_at);
    }
}

#[cfg(target_os = "macos")]
#[test]
fn group_container_identifier_comes_only_from_a_group_container_path() {
    use crate::group_container::identifier;
    assert_eq!(
        identifier(Path::new(
            "/Users/u/Library/Group Containers/TEAMID1234.local.agentworkboard.shared/widget-snapshot.json"
        ))
        .as_deref(),
        Some("TEAMID1234.local.agentworkboard.shared")
    );
    assert_eq!(
        identifier(Path::new(
            "/Users/u/Library/Application Support/AgentWorkboard/widget-snapshot.json"
        )),
        None
    );
    assert_eq!(
        identifier(Path::new("/Users/u/Library/Group Containers")),
        None
    );
}

#[cfg(target_os = "macos")]
#[test]
fn only_shared_group_snapshot_writes_request_a_widget_reload() {
    let (dir, mut b, p, _) = setup();
    assert!(
        !b.take_widget_change(),
        "the private data snapshot does not reload widgets"
    );
    let shared = dir
        .path()
        .join("Library/Group Containers/TEAMID1234.local.test/widget-snapshot.json");
    call(&mut b, "widget.configure", json!({"snapshot_path":shared}));
    assert!(b.take_widget_change());
    assert!(!b.take_widget_change(), "each write requests one reload");
    call(
        &mut b,
        "task.create",
        json!({"project_id":p,"title":"Refresh widget"}),
    );
    assert!(b.take_widget_change());
    call(&mut b, "widget.configure", json!({"snapshot_path":null}));
    assert!(!b.take_widget_change());
    call(
        &mut b,
        "task.create",
        json!({"project_id":p,"title":"After disconnect"}),
    );
    assert!(!b.take_widget_change());
}

#[test]
fn deleting_a_task_removes_its_runs_and_artifacts_but_keeps_history_and_revision() {
    let (dir, mut b, p, t) = setup();
    let started = call(&mut b, "task.start", json!({"task_id":t,"agent_id":"a"}));
    call(
        &mut b,
        "task.attach",
        json!({"task_id":t,"agent_id":"a","path":"https://example.com/result","kind":"url"}),
    );
    let before = started["revision"].as_i64().unwrap() + 1;
    let other = b.dispatch(req("task.delete", json!({"task_id":t,"agent_id":"b"})));
    assert_eq!(other.error.unwrap().code, "CLAIM_CONFLICT");
    let stale = b.dispatch(req(
        "task.delete",
        json!({"task_id":t,"expected_revision":1}),
    ));
    assert_eq!(stale.error.unwrap().code, "REVISION_CONFLICT");
    let request = req("task.delete", json!({"task_id":t,"agent_id":"a"}));
    let deleted = b.dispatch(request.clone());
    assert!(deleted.ok, "{deleted:?}");
    assert_eq!(
        deleted.result.as_ref().unwrap()["deleted_task_ids"],
        json!([t])
    );
    assert_eq!(
        b.dispatch(request).result,
        deleted.result,
        "retry returns the same result"
    );
    assert_eq!(
        b.dispatch(req("task.get", json!({"task_id":t})))
            .error
            .unwrap()
            .code,
        "NOT_FOUND"
    );
    for table in ["runs", "artifacts"] {
        let count: i64 = b
            .conn
            .query_row(
                &format!("SELECT count(*) FROM {table} WHERE task_id=?1"),
                [&t],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 0, "{table}");
    }
    let tombstone: i64 = b
        .conn
        .query_row(
            "SELECT revision FROM task_revisions WHERE task_id=?1",
            [&t],
            |r| r.get(0),
        )
        .unwrap();
    assert!(tombstone > before, "{tombstone} > {before}");
    assert!(
        call(&mut b, "task.list", json!({"query":"Kanban"}))["tasks"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let events = call(&mut b, "events.list", json!({}))["events"].clone();
    let deletion = events
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["kind"] == "task.deleted" && e["task_id"] == t)
        .expect("deletion event");
    // History keeps what was attached even though the rows are gone.
    assert_eq!(
        deletion["data"]["removed"]["artifacts"][0]["path"],
        "https://example.com/result"
    );
    assert_eq!(deletion["data"]["removed"]["runs"][0]["agent_id"], "a");
    assert_eq!(
        deletion["data"]["removed"]["tasks"][0]["title"],
        "Build the kanban board"
    );
    let widget: Value =
        serde_json::from_slice(&fs::read(dir.path().join("widget-snapshot.json")).unwrap())
            .unwrap();
    assert!(widget["tasks"].as_array().unwrap().is_empty());
    assert!(call(&mut b, "project.list", json!({}))["projects"]
        .as_array()
        .unwrap()
        .iter()
        .any(|project| project["id"] == p));
}

#[test]
fn deleting_a_parent_requires_explicit_subtask_removal_and_respects_their_owners() {
    let (_dir, mut b, p, t) = setup();
    let child = call(
        &mut b,
        "task.create",
        json!({"project_id":p,"parent_id":t,"title":"Child"}),
    )["task_id"]
        .as_str()
        .unwrap()
        .to_string();
    let grandchild = call(
        &mut b,
        "task.create",
        json!({"project_id":p,"parent_id":child,"title":"Grandchild"}),
    )["task_id"]
        .as_str()
        .unwrap()
        .to_string();
    let refused = b.dispatch(req("task.delete", json!({"task_id":t})));
    assert_eq!(refused.error.unwrap().code, "HAS_SUBTASKS");
    call(
        &mut b,
        "task.claim",
        json!({"task_id":grandchild,"agent_id":"b"}),
    );
    let held = b.dispatch(req(
        "task.delete",
        json!({"task_id":t,"with_subtasks":true,"agent_id":"a"}),
    ));
    assert_eq!(held.error.unwrap().code, "CLAIM_CONFLICT");
    let deleted = call(
        &mut b,
        "task.delete",
        json!({"task_id":t,"with_subtasks":true}),
    );
    assert_eq!(deleted["deleted_task_ids"][0], t, "root first");
    assert_eq!(deleted["deleted_task_ids"].as_array().unwrap().len(), 3);
    assert!(call(&mut b, "task.list", json!({"project_id":p}))["tasks"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn deleting_a_project_requires_explicit_task_removal() {
    let (_dir, mut b, p, t) = setup();
    let refused = b.dispatch(req("project.delete", json!({"project_id":p})));
    assert_eq!(refused.error.unwrap().code, "HAS_TASKS");
    call(&mut b, "task.claim", json!({"task_id":t,"agent_id":"b"}));
    let held = b.dispatch(req(
        "project.delete",
        json!({"project_id":p,"with_tasks":true,"agent_id":"a"}),
    ));
    assert_eq!(held.error.unwrap().code, "CLAIM_CONFLICT");
    let versioned = b.dispatch(req(
        "project.delete",
        json!({"project_id":p,"with_tasks":true,"expected_revision":1}),
    ));
    assert_eq!(versioned.error.unwrap().code, "INVALID_PARAMS");
    let bad = b.dispatch(req(
        "project.delete",
        json!({"project_id":p,"with_tasks":"yes"}),
    ));
    assert_eq!(bad.error.unwrap().code, "INVALID_PARAMS");
    let deleted = call(
        &mut b,
        "project.delete",
        json!({"project_id":p,"with_tasks":true}),
    );
    assert_eq!(deleted["deleted_task_ids"], json!([t]));
    assert!(call(&mut b, "project.list", json!({}))["projects"]
        .as_array()
        .unwrap()
        .is_empty());
    let missing = b.dispatch(req("project.delete", json!({"project_id":p})));
    assert_eq!(missing.error.unwrap().code, "NOT_FOUND");
    let empty =
        call(&mut b, "project.create", json!({"name":"Empty project"}))["project_id"].clone();
    let malformed = b.dispatch(req(
        "project.delete",
        json!({"project_id":empty,"with_tasks":"yes"}),
    ));
    assert_eq!(
        malformed.error.unwrap().code,
        "INVALID_PARAMS",
        "options are checked even for an empty project"
    );
    call(&mut b, "project.delete", json!({"project_id":empty}));
}
