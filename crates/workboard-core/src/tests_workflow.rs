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
fn call(b: &mut Board, method: &str, params: Value) -> Value {
    let response = b.dispatch(req(method, params));
    assert!(response.ok, "{response:?}");
    response.result.unwrap()
}
fn error(b: &mut Board, method: &str, params: Value, code: &str) {
    let response = b.dispatch(req(method, params));
    assert_eq!(response.error.expect("expected failure").code, code);
}
fn setup() -> (TempDir, Board, String, String) {
    let dir = TempDir::new().unwrap();
    let mut b = Board::open(dir.path()).unwrap();
    let p: String = call(&mut b, "project.create", json!({"name":"Planning"}))["project_id"]
        .as_str()
        .unwrap()
        .into();
    let t = task(&mut b, &p, "Task");
    (dir, b, p, t)
}
fn task(b: &mut Board, p: &str, title: &str) -> String {
    call(b, "task.create", json!({"project_id":p,"title":title}))["task_id"]
        .as_str()
        .unwrap()
        .into()
}
fn get(b: &mut Board, t: &str) -> Value {
    call(b, "task.get", json!({"task_id":t}))
}
fn revision(b: &mut Board, t: &str) -> Value {
    get(b, t)["task"]["revision"].clone()
}
fn update(b: &mut Board, t: &str, mut p: Value) -> Value {
    p["task_id"] = json!(t);
    p["expected_revision"] = revision(b, t);
    call(b, "task.update", p)
}
fn checklist(b: &mut Board, t: &str) -> Value {
    let rev = revision(b, t);
    call(
        b,
        "task.checklist.add",
        json!({"task_id":t,"text":"Check verification results","expected_revision":rev}),
    )["task"]["checklist"][0]
        .clone()
}

#[test]
fn task_delete_preserves_workflow_history_and_invalidates_affected_editors() {
    let (dir, mut b, p, t) = setup();
    let item = call(
        &mut b,
        "inbox.capture",
        json!({"title":"Captured task","source":"https://example.com/source","note":"Source note"}),
    )["item"]
        .clone();
    let promoted = call(
        &mut b,
        "inbox.promote",
        json!({"item_id":item["id"],"project_id":p}),
    );
    let root = promoted["task"]["id"].as_str().unwrap().to_string();
    let child = call(
        &mut b,
        "task.create",
        json!({"project_id":p,"parent_id":root,"title":"Child"}),
    )["task_id"]
        .as_str()
        .unwrap()
        .to_string();
    checklist(&mut b, &child);
    call(&mut b, "task.start", json!({"task_id":root}));
    call(
        &mut b,
        "task.review",
        json!({"task_id":root,"summary":"Request review"}),
    );
    let decision = call(
        &mut b,
        "task.review.decide",
        json!({"task_id":root,"decision":"request_changes","summary":"Changes required"}),
    );
    call(
        &mut b,
        "task.dependency.add",
        json!({"task_id":t,"depends_on_id":child}),
    );
    call(
        &mut b,
        "task.dependency.add",
        json!({"task_id":root,"depends_on_id":t}),
    );
    let previous_revision = revision(&mut b, &t);
    let backup = dir.path().join("before-delete.sqlite3");
    b.backup(&backup).unwrap();
    error(
        &mut b,
        "task.delete",
        json!({"task_id":root}),
        "HAS_SUBTASKS",
    );
    let delete = req("task.delete", json!({"task_id":root,"with_subtasks":true}));
    let result = b.dispatch(delete.clone());
    assert!(result.ok, "{result:?}");
    assert_eq!(
        b.dispatch(delete).result,
        result.result,
        "retry changed deletion"
    );
    assert_eq!(get(&mut b, &t)["task"]["dependency_ids"], json!([]));
    assert_eq!(get(&mut b, &t)["task"]["ready"], true);
    assert!(revision(&mut b, &t).as_i64().unwrap() > previous_revision.as_i64().unwrap());
    error(
        &mut b,
        "task.update",
        json!({"task_id":t,"title":"stale","expected_revision":previous_revision}),
        "REVISION_CONFLICT",
    );
    let archived = call(&mut b, "inbox.list", json!({}))["items"][0].clone();
    assert_eq!(archived["status"], "processed");
    assert_eq!(archived["task_id"], Value::Null);
    assert_eq!(archived["source"], item["source"]);
    assert_eq!(archived["note"], item["note"]);
    assert!(
        archived["revision"].as_i64().unwrap() > promoted["item"]["revision"].as_i64().unwrap()
    );
    error(
        &mut b,
        "inbox.promote",
        json!({"item_id":item["id"],"project_id":p}),
        "INVALID_STATE",
    );
    let events = call(&mut b, "events.list", json!({}))["events"].clone();
    let removed = &events
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["kind"] == "task.deleted")
        .unwrap()["data"]["removed"];
    assert_eq!(
        removed["workflow"]["dependencies"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        removed["workflow"]["review_decisions"][0]["summary"],
        "Changes required"
    );
    assert!(removed["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .any(|task| task["id"] == child && task["checklist"].as_array().unwrap().len() == 1));
    let violations: i64 = b
        .conn
        .query_row("SELECT count(*) FROM pragma_foreign_key_check", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(violations, 0);
    call(&mut b, "backup.restore", json!({"path":backup}));
    assert!(
        revision(&mut b, &root).as_i64().unwrap() > decision["task"]["revision"].as_i64().unwrap()
    );
    assert_eq!(
        get(&mut b, &child)["task"]["checklist"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        call(&mut b, "inbox.list", json!({}))["items"][0]["task_id"],
        root
    );
    assert_eq!(get(&mut b, &t)["task"]["dependency_ids"], json!([child]));
}

#[test]
fn project_delete_cleans_cross_project_workflow_links_atomically() {
    let (_dir, mut b, p, t) = setup();
    let other = call(&mut b, "project.create", json!({"name":"Keep"}))["project_id"]
        .as_str()
        .unwrap()
        .to_string();
    let survivor = task(&mut b, &other, "Follow-up task");
    checklist(&mut b, &t);
    call(
        &mut b,
        "task.dependency.add",
        json!({"task_id":survivor,"depends_on_id":t}),
    );
    let revision_before = revision(&mut b, &survivor);
    call(
        &mut b,
        "project.delete",
        json!({"project_id":p,"with_tasks":true}),
    );
    assert_eq!(get(&mut b, &survivor)["task"]["ready"], true);
    assert!(revision(&mut b, &survivor).as_i64().unwrap() > revision_before.as_i64().unwrap());
    let count: i64 = b
        .conn
        .query_row("SELECT count(*) FROM checklist_items", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 0);
    assert_eq!(
        call(&mut b, "project.list", json!({}))["projects"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn dependency_dag_readiness_and_all_start_done_paths_are_guarded() {
    let (_dir, mut b, p, t) = setup();
    let dep = task(&mut b, &p, "Prerequisite");
    let third = task(&mut b, &p, "Next");
    let added = call(
        &mut b,
        "task.dependency.add",
        json!({"task_id":t,"depends_on_id":dep}),
    );
    assert_eq!(added["task"]["dependency_ids"], json!([dep]));
    assert_eq!(added["task"]["blocked_by"], json!([dep]));
    assert_eq!(added["task"]["ready"], false);
    call(
        &mut b,
        "task.dependency.add",
        json!({"task_id":third,"depends_on_id":t}),
    );
    for (task_id, on) in [(&dep, &dep), (&dep, &third)] {
        error(
            &mut b,
            "task.dependency.add",
            json!({"task_id":task_id,"depends_on_id":on}),
            "DEPENDENCY_CYCLE",
        );
    }
    error(
        &mut b,
        "task.dependency.add",
        json!({"task_id":dep,"depends_on_id":"missing"}),
        "NOT_FOUND",
    );
    for method in ["task.start", "task.complete", "task.update"] {
        let rev = revision(&mut b, &t);
        error(
            &mut b,
            method,
            json!({"task_id":t,"summary":"Done","completion_summary":"Done","status":"done","expected_revision":rev}),
            "DEPENDENCY_BLOCKED",
        );
    }
    let rev = revision(&mut b, &t);
    error(
        &mut b,
        "task.update",
        json!({"task_id":t,"status":"in_progress","expected_revision":rev}),
        "DEPENDENCY_BLOCKED",
    );
    call(
        &mut b,
        "task.complete",
        json!({"task_id":dep,"summary":"Prerequisite complete"}),
    );
    assert_eq!(get(&mut b, &t)["task"]["ready"], true);
    let ready = call(&mut b, "task.list", json!({"ready_only":true}))["tasks"].clone();
    assert!(ready.as_array().unwrap().iter().any(|x| x["id"] == t));
    update(&mut b, &t, json!({"blocked_reason":"Check the key"}));
    for method in ["task.start", "task.complete"] {
        error(
            &mut b,
            method,
            json!({"task_id":t,"summary":"Done"}),
            "TASK_BLOCKED",
        );
    }
    update(&mut b, &t, json!({"blocked_reason":""}));
    call(&mut b, "task.start", json!({"task_id":t}));
    call(
        &mut b,
        "task.complete",
        json!({"task_id":t,"summary":"Verification complete"}),
    );
}
#[test]
fn dependencies_are_independent_of_parent_child_and_retries_do_not_duplicate_edges() {
    let (_dir, mut b, p, t) = setup();
    let child = call(
        &mut b,
        "task.create",
        json!({"project_id":p,"title":"Child","parent_id":t}),
    )["task_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let request = req(
        "task.dependency.add",
        json!({"task_id":t,"depends_on_id":child,"expected_revision":1}),
    );
    let first = b.dispatch(request.clone());
    assert!(first.ok);
    assert_eq!(first.result, b.dispatch(request).result);
    assert_eq!(get(&mut b, &t)["task"]["dependency_ids"], json!([child]));
    error(
        &mut b,
        "task.dependency.remove",
        json!({"task_id":t,"depends_on_id":child,"expected_revision":1}),
        "REVISION_CONFLICT",
    );
    call(
        &mut b,
        "task.dependency.remove",
        json!({"task_id":t,"depends_on_id":child}),
    );
    assert_eq!(get(&mut b, &t)["task"]["ready"], true);
}
#[test]
fn required_checklist_blocks_completion_and_review_approval_without_partial_writes() {
    let (_dir, mut b, _, t) = setup();
    error(
        &mut b,
        "task.checklist.add",
        json!({"task_id":t,"text":"Review"}),
        "INVALID_PARAMS",
    );
    let item = checklist(&mut b, &t);
    let before = get(&mut b, &t);
    for method in ["task.complete", "task.update"] {
        let rev = revision(&mut b, &t);
        error(
            &mut b,
            method,
            json!({"task_id":t,"summary":"Approve","status":"done","completion_summary":"Approve","expected_revision":rev}),
            "CHECKLIST_INCOMPLETE",
        );
        assert_eq!(get(&mut b, &t), before);
    }
    call(
        &mut b,
        "task.start",
        json!({"task_id":t,"run_id":"review-run"}),
    );
    call(
        &mut b,
        "task.review",
        json!({"task_id":t,"run_id":"review-run","summary":"Please review"}),
    );
    let before = get(&mut b, &t);
    error(
        &mut b,
        "task.review.decide",
        json!({"task_id":t,"decision":"approve","summary":"Approve"}),
        "CHECKLIST_INCOMPLETE",
    );
    assert_eq!(get(&mut b, &t), before);
    let rev = revision(&mut b, &t);
    call(
        &mut b,
        "task.checklist.update",
        json!({"task_id":t,"item_id":item["id"],"checked":true,"evidence":"Tests passed","expected_revision":rev}),
    );
    let request = req(
        "task.review.decide",
        json!({"task_id":t,"decision":"approve","summary":"Approve after verification","actor":"human"}),
    );
    let first = b.dispatch(request.clone());
    assert!(first.ok, "{first:?}");
    assert_eq!(first.result, b.dispatch(request).result);
    let detail = get(&mut b, &t);
    assert_eq!(detail["task"]["status"], "done");
    assert_eq!(detail["runs"][0]["status"], "completed");
    assert_eq!(detail["runs"][0]["summary"], "Approve after verification");
    assert_eq!(detail["review_decisions"].as_array().unwrap().len(), 1);
    assert_eq!(detail["review_decisions"][0]["actor"], "human");
    let rev = revision(&mut b, &t);
    error(
        &mut b,
        "task.checklist.update",
        json!({"task_id":t,"item_id":item["id"],"checked":false,"expected_revision":rev}),
        "CHECKLIST_INCOMPLETE",
    );
}
#[test]
fn review_changes_rejection_and_stale_run_decisions_keep_history() {
    let (_dir, mut b, _, t) = setup();
    error(
        &mut b,
        "task.review.decide",
        json!({"task_id":t,"decision":"approve","summary":"Approve"}),
        "INVALID_STATE",
    );
    for (decision, summary) in [
        ("request_changes", "Improve the tests"),
        ("reject", "Requirements not met"),
    ] {
        call(&mut b, "task.start", json!({"task_id":t}));
        call(
            &mut b,
            "task.review",
            json!({"task_id":t,"summary":"Request review"}),
        );
        let result = call(
            &mut b,
            "task.review.decide",
            json!({"task_id":t,"decision":decision,"summary":summary}),
        );
        assert_eq!(result["task"]["status"], "todo");
        if decision == "request_changes" {
            assert_eq!(result["task"]["next_action"], summary);
            assert_eq!(result["task"]["blocked_reason"], "");
        } else {
            assert_eq!(result["task"]["blocked_reason"], summary);
        }
    }
    assert_eq!(
        get(&mut b, &t)["review_decisions"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    update(&mut b, &t, json!({"blocked_reason":""}));
    call(
        &mut b,
        "task.start",
        json!({"task_id":t,"run_id":"new-run"}),
    );
    call(
        &mut b,
        "task.review",
        json!({"task_id":t,"summary":"Review again"}),
    );
    let old = get(&mut b, &t)["runs"][0]["id"].clone();
    let before = get(&mut b, &t);
    error(
        &mut b,
        "task.review.decide",
        json!({"task_id":t,"run_id":old,"decision":"approve","summary":"Old run outcome"}),
        "RUN_CONFLICT",
    );
    assert_eq!(get(&mut b, &t), before);
}
#[test]
fn templates_create_atomic_fresh_trees_and_builtin_deletions_persist() {
    let (dir, mut b, p, t) = setup();
    assert_eq!(
        call(&mut b, "template.list", json!({}))["templates"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
    let template=call(&mut b,"template.save",json!({"name":"Nested","definition":{"title":"Root","checklist":[{"text":"Required check"}],"children":[{"title":"Child","children":[{"title":"Grandchild"}]}]}}))["template"].clone();
    let seq = b.snapshot().unwrap()["event_sequence"].clone();
    error(
        &mut b,
        "template.apply",
        json!({"template_id":template["id"],"project_id":p,"parent_id":"missing"}),
        "NOT_FOUND",
    );
    assert_eq!(b.snapshot().unwrap()["event_sequence"], seq);
    let request = req(
        "template.apply",
        json!({"template_id":template["id"],"project_id":p,"parent_id":t,"title":"Actual name"}),
    );
    let first = b.dispatch(request.clone());
    assert!(first.ok);
    assert_eq!(first.result, b.dispatch(request).result);
    let result = first.result.unwrap();
    let tasks = result["tasks"].as_array().unwrap();
    assert_eq!(tasks.len(), 3);
    assert_eq!(tasks[0]["title"], "Actual name");
    assert_eq!(tasks[0]["parent_id"], t);
    assert_eq!(tasks[1]["parent_id"], tasks[0]["id"]);
    assert_eq!(tasks[2]["parent_id"], tasks[1]["id"]);
    assert_eq!(tasks[0]["checklist"][0]["checked"], false);
    let from_task = call(
        &mut b,
        "template.save",
        json!({"name":"Save existing task","task_id":tasks[0]["id"]}),
    );
    assert_eq!(
        from_task["template"]["definition"]["children"][0]["children"][0]["title"],
        "Grandchild"
    );
    let applied = call(
        &mut b,
        "template.apply",
        json!({"template_id":template["id"],"project_id":p}),
    );
    assert_ne!(applied["task"]["id"], tasks[0]["id"]);
    assert_ne!(
        applied["task"]["checklist"][0]["id"],
        tasks[0]["checklist"][0]["id"]
    );
    call(
        &mut b,
        "template.delete",
        json!({"template_id":"builtin-bugfix"}),
    );
    drop(b);
    let mut b = Board::open(dir.path()).unwrap();
    assert!(!call(&mut b, "template.list", json!({}))["templates"]
        .as_array()
        .unwrap()
        .iter()
        .any(|t| t["id"] == "builtin-bugfix"));
    let too_many = json!({"title":"root","children":(0..256).map(|i|json!({"title":i.to_string()})).collect::<Vec<_>>()});
    error(
        &mut b,
        "template.save",
        json!({"name":"Exceeded","definition":too_many}),
        "INVALID_PARAMS",
    );
    let mut deep = json!({"title":"leaf"});
    for _ in 0..16 {
        deep = json!({"title":"parent","children":[deep]});
    }
    error(
        &mut b,
        "template.save",
        json!({"name":"Depth exceeded","definition":deep}),
        "INVALID_PARAMS",
    );
}
#[test]
fn independent_inbox_promotes_once_and_preserves_source_without_reading_it() {
    let (dir, mut b, p, t) = setup();
    let request = req(
        "inbox.capture",
        json!({"title":"Capture","source":"/missing/never-read.txt","note":"Original note"}),
    );
    let first = b.dispatch(request.clone());
    assert!(first.ok);
    assert_eq!(first.result, b.dispatch(request).result);
    let item = first.result.unwrap()["item"].clone();
    assert_eq!(get(&mut b, &t)["task"]["title"], "Task");
    let before = b.snapshot().unwrap();
    error(
        &mut b,
        "inbox.promote",
        json!({"item_id":item["id"],"project_id":"missing"}),
        "NOT_FOUND",
    );
    assert_eq!(b.snapshot().unwrap(), before);
    let promoted = call(
        &mut b,
        "inbox.promote",
        json!({"item_id":item["id"],"project_id":p,"parent_id":t,"expected_revision":1}),
    );
    assert_eq!(promoted["item"]["status"], "processed");
    assert_eq!(promoted["task"]["goal"], "Original note");
    assert_eq!(promoted["task"]["parent_id"], t);
    let task_id = promoted["task"]["id"].clone();
    let detail = call(&mut b, "task.get", json!({"task_id":task_id}));
    assert_eq!(detail["artifacts"][0]["path"], "/missing/never-read.txt");
    drop(b);
    let mut b = Board::open(dir.path()).unwrap();
    let again = call(
        &mut b,
        "inbox.promote",
        json!({"item_id":item["id"],"project_id":p}),
    );
    assert_eq!(again["task"]["id"], task_id);
    assert_eq!(
        call(&mut b, "task.list", json!({}))["tasks"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    error(
        &mut b,
        "inbox.dismiss",
        json!({"item_id":item["id"]}),
        "INVALID_STATE",
    );
    let dismissed = call(&mut b, "inbox.capture", json!({"title":"Archive"}))["item"].clone();
    call(
        &mut b,
        "inbox.dismiss",
        json!({"item_id":dismissed["id"],"expected_revision":1}),
    );
    assert_eq!(
        call(&mut b, "inbox.list", json!({"status":"pending"}))["items"],
        json!([])
    );
}
#[test]
fn saved_views_validate_types_and_apply_ready_blocked_stale_and_owner_filters() {
    let (_dir, mut b, p, t) = setup();
    let ready = task(&mut b, &p, "Ready task");
    let blocked = task(&mut b, &p, "Pending");
    call(
        &mut b,
        "task.dependency.add",
        json!({"task_id":blocked,"depends_on_id":t}),
    );
    update(
        &mut b,
        &t,
        json!({"assignee":"alpha","blocked_reason":"Awaiting response"}),
    );
    b.conn
        .execute(
            "UPDATE tasks SET updated_at='2020-01-01T00:00:00Z' WHERE id=?1",
            [&t],
        )
        .unwrap();
    let view=call(&mut b,"view.save",json!({"name":"Stale blocked task","filters":{"project_id":p,"blocked_only":true,"stale_days":7,"assignee":"alpha"},"layout":"list"}))["view"].clone();
    assert_eq!(
        call(&mut b, "task.list", json!({"view_id":view["id"]}))["tasks"][0]["id"],
        t
    );
    assert_eq!(
        call(&mut b, "task.list", json!({"ready_only":true}))["tasks"][0]["id"],
        ready
    );
    assert_eq!(
        call(&mut b, "task.list", json!({"blocked_only":true}))["tasks"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    let tasks = call(
        &mut b,
        "task.list",
        json!({"view_id":view["id"],"assignee":null,"stale_days":0}),
    )["tasks"]
        .clone();
    assert_eq!(tasks.as_array().unwrap().len(), 1);
    assert_eq!(tasks[0]["id"], blocked);
    for filters in [
        json!({"unknown":1}),
        json!({"stale_days":-1}),
        json!({"ready_only":"yes"}),
        json!({"status":"invalid"}),
        json!({"assignee":3}),
    ] {
        error(
            &mut b,
            "view.save",
            json!({"name":"Invalid view","filters":filters}),
            "INVALID_PARAMS",
        );
    }
    error(
        &mut b,
        "view.delete",
        json!({"view_id":view["id"],"expected_revision":0}),
        "REVISION_CONFLICT",
    );
    call(
        &mut b,
        "view.delete",
        json!({"view_id":view["id"],"expected_revision":view["revision"]}),
    );
    error(
        &mut b,
        "task.list",
        json!({"view_id":view["id"]}),
        "NOT_FOUND",
    );
}
#[test]
fn schedule_conflicts_use_exclusive_end_absolute_timestamps_and_dst_day_boundaries() {
    let (_dir, mut b, p, t) = setup();
    update(
        &mut b,
        &t,
        json!({"scheduled_start":"2026-03-08","scheduled_end":"2026-03-09","time_zone":"America/New_York"}),
    );
    let mut preview = |start: &str, end: &str, zone: &str| {
        call(
            &mut b,
            "task.schedule.preview",
            json!({"scheduled_start":start,"scheduled_end":end,"time_zone":zone}),
        )
    };
    assert_eq!(
        preview("2026-03-08T04:00:00Z", "2026-03-08T05:00:00Z", "UTC")["has_conflicts"],
        false
    );
    assert_eq!(
        preview("2026-03-09T03:30:00Z", "2026-03-09T04:00:00Z", "UTC")["has_conflicts"],
        true
    );
    assert_eq!(
        preview("2026-03-09T04:00:00Z", "2026-03-09T05:00:00Z", "UTC")["has_conflicts"],
        false
    );
    assert_eq!(
        call(
            &mut b,
            "task.schedule.preview",
            json!({"task_id":t,"scheduled_start":"2026-03-08","scheduled_end":"2026-03-09","time_zone":"America/New_York"})
        )["has_conflicts"],
        false
    );
    let autumn = task(&mut b, &p, "Fall DST");
    update(
        &mut b,
        &autumn,
        json!({"scheduled_start":"2026-11-01","scheduled_end":"2026-11-02","time_zone":"America/New_York"}),
    );
    assert_eq!(
        call(
            &mut b,
            "task.schedule.preview",
            json!({"scheduled_start":"2026-11-02T04:30:00Z","scheduled_end":"2026-11-02T05:00:00Z","time_zone":"UTC"})
        )["conflicts"][0]["id"],
        autumn
    );
    call(
        &mut b,
        "task.complete",
        json!({"task_id":autumn,"summary":"Done"}),
    );
    assert_eq!(
        call(
            &mut b,
            "task.schedule.preview",
            json!({"scheduled_start":"2026-11-02T04:30:00Z","scheduled_end":"2026-11-02T05:00:00Z","time_zone":"UTC"})
        )["has_conflicts"],
        false
    );
    for params in [
        json!({"scheduled_start":"2026-03-09","scheduled_end":"2026-03-08","time_zone":"UTC"}),
        json!({"scheduled_start":"2026-03-08","scheduled_end":"2026-03-09T00:00:00Z","time_zone":"UTC"}),
        json!({"scheduled_start":"2011-12-30","scheduled_end":"2011-12-31","time_zone":"Pacific/Apia"}),
    ] {
        error(&mut b, "task.schedule.preview", params, "INVALID_PARAMS");
    }
    // Scheduling itself remains allowed even when preview finds a collision.
    let overlapping = task(&mut b, &p, "Scheduled task");
    update(
        &mut b,
        &overlapping,
        json!({"scheduled_start":"2026-03-08T10:00:00Z","scheduled_end":"2026-03-08T11:00:00Z","time_zone":"UTC"}),
    );
}
#[test]
fn workflow_backup_restore_export_and_revision_watermarks_preserve_all_entities() {
    let (dir, mut b, p, t) = setup();
    let dep = task(&mut b, &p, "Prerequisite");
    call(
        &mut b,
        "task.complete",
        json!({"task_id":dep,"summary":"Done"}),
    );
    call(
        &mut b,
        "task.dependency.add",
        json!({"task_id":t,"depends_on_id":dep}),
    );
    let item = checklist(&mut b, &t);
    let rev = revision(&mut b, &t);
    call(
        &mut b,
        "task.checklist.update",
        json!({"task_id":t,"item_id":item["id"],"checked":true,"evidence":"Evidence","expected_revision":rev}),
    );
    call(
        &mut b,
        "task.review",
        json!({"task_id":t,"summary":"Review"}),
    );
    call(
        &mut b,
        "task.review.decide",
        json!({"task_id":t,"decision":"approve","summary":"Approve"}),
    );
    let inbox = call(
        &mut b,
        "inbox.capture",
        json!({"title":"Capture","source":"https://example.test/source"}),
    )["item"]
        .clone();
    let view = call(
        &mut b,
        "view.save",
        json!({"name":"View","filters":{"ready_only":true}}),
    )["view"]
        .clone();
    let template = call(
        &mut b,
        "template.save",
        json!({"name":"Template","task_id":t}),
    )["template"]
        .clone();
    let path = dir.path().join("planning.sqlite3");
    call(&mut b, "backup.create", json!({"path":path}));
    call(&mut b, "inbox.dismiss", json!({"item_id":inbox["id"]}));
    call(&mut b, "view.delete", json!({"view_id":view["id"]}));
    call(
        &mut b,
        "template.delete",
        json!({"template_id":template["id"]}),
    );
    let previous_revision = revision(&mut b, &t);
    call(&mut b, "backup.restore", json!({"path":path}));
    let detail = get(&mut b, &t);
    assert!(detail["task"]["revision"].as_i64() > previous_revision.as_i64());
    assert_eq!(detail["task"]["dependency_ids"], json!([dep]));
    assert_eq!(detail["task"]["checklist"][0]["evidence"], "Evidence");
    assert_eq!(detail["review_decisions"][0]["decision"], "approve");
    error(
        &mut b,
        "inbox.dismiss",
        json!({"item_id":inbox["id"],"expected_revision":1}),
        "REVISION_CONFLICT",
    );
    error(
        &mut b,
        "view.delete",
        json!({"view_id":view["id"],"expected_revision":1}),
        "REVISION_CONFLICT",
    );
    error(
        &mut b,
        "template.delete",
        json!({"template_id":template["id"],"expected_revision":1}),
        "REVISION_CONFLICT",
    );
    let exported = call(&mut b, "export", json!({"format":"json"}))["data"].clone();
    assert_eq!(
        exported["inbox"][0]["source"],
        "https://example.test/source"
    );
    assert_eq!(exported["views"][0]["id"], view["id"]);
    assert!(exported["templates"]
        .as_array()
        .unwrap()
        .iter()
        .any(|v| v["id"] == template["id"]));
    assert_eq!(exported["review_decisions"][0]["summary"], "Approve");
    let md = call(&mut b, "export", json!({"format":"markdown"}))["content"]
        .as_str()
        .unwrap()
        .to_owned();
    for needle in [
        "dependency_ids",
        "Review decision history",
        "https://example.test/source",
        "Evidence",
        "ready_only",
    ] {
        assert!(md.contains(needle), "missing {needle}");
    }
    drop(b);
    let mut b = Board::open(dir.path()).unwrap();
    assert_eq!(
        call(&mut b, "inbox.list", json!({}))["items"][0]["status"],
        "pending"
    );
    assert_eq!(
        get(&mut b, &t)["review_decisions"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}
#[test]
fn version_four_migration_preserves_tasks_and_seeds_templates_once() {
    let (dir, b, _, t) = setup();
    b.conn.execute_batch("DROP TABLE task_dependencies; DROP TABLE checklist_items; DROP TABLE review_decisions; DROP TABLE inbox; DROP TABLE templates; DROP TABLE saved_views; DROP TABLE workflow_revisions; PRAGMA user_version=4;").unwrap();
    drop(b);
    let mut b = Board::open(dir.path()).unwrap();
    assert_eq!(get(&mut b, &t)["task"]["title"], "Task");
    assert_eq!(
        call(&mut b, "template.list", json!({}))["templates"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
    assert_eq!(
        b.conn
            .query_row("PRAGMA user_version", [], |row| row.get::<_, u32>(0))
            .unwrap(),
        5
    );
}

#[test]
fn checklist_evidence_add_clear_and_stale_edits_are_transactional() {
    let (_dir, mut b, _, t) = setup();
    let added = call(
        &mut b,
        "task.checklist.add",
        json!({"task_id":t,"text":"Verification","required":false,"evidence":"Start evidence","expected_revision":1}),
    );
    let item = added["task"]["checklist"][0]["id"].clone();
    assert_eq!(added["task"]["checklist"][0]["evidence"], "Start evidence");
    error(
        &mut b,
        "task.checklist.remove",
        json!({"task_id":t,"item_id":item,"expected_revision":1}),
        "REVISION_CONFLICT",
    );
    let rev = revision(&mut b, &t);
    let cleared = call(
        &mut b,
        "task.checklist.update",
        json!({"task_id":t,"item_id":item,"evidence":"","checked":true,"expected_revision":rev}),
    );
    assert_eq!(cleared["task"]["checklist"][0]["evidence"], Value::Null);
    let rev = revision(&mut b, &t);
    call(
        &mut b,
        "task.checklist.remove",
        json!({"task_id":t,"item_id":item,"expected_revision":rev}),
    );
    assert_eq!(get(&mut b, &t)["task"]["checklist"], json!([]));
}
#[test]
fn review_decision_supports_manual_review_without_reactivating_terminal_runs() {
    let (_dir, mut b, _, t) = setup();
    call(
        &mut b,
        "task.start",
        json!({"task_id":t,"run_id":"finished-before-review"}),
    );
    update(&mut b, &t, json!({"status":"review"}));
    let before = get(&mut b, &t)["runs"][0].clone();
    let approved = call(
        &mut b,
        "task.review.decide",
        json!({"task_id":t,"decision":"approve","summary":"Manual review approval"}),
    );
    assert_eq!(approved["task"]["status"], "done");
    assert_eq!(approved["runs"][0], before);
    assert_eq!(approved["review_decisions"][0]["run_id"], Value::Null);
}
#[test]
fn schedule_preview_is_read_only_and_nonexistent_local_days_are_rejected_on_save() {
    let (_dir, mut b, _, t) = setup();
    let before = b.snapshot().unwrap();
    call(
        &mut b,
        "task.schedule.preview",
        json!({"scheduled_start":"2026-03-08","scheduled_end":"2026-03-09","time_zone":"America/New_York"}),
    );
    assert_eq!(b.snapshot().unwrap(), before);
    let rev = revision(&mut b, &t);
    error(
        &mut b,
        "task.update",
        json!({"task_id":t,"expected_revision":rev,"scheduled_start":"2011-12-30","scheduled_end":"2011-12-31","time_zone":"Pacific/Apia"}),
        "INVALID_PARAMS",
    );
    assert_eq!(b.snapshot().unwrap(), before);
}
#[test]
fn workflow_ids_reappearing_after_restore_do_not_reuse_revisions() {
    let (dir, mut b, _, _) = setup();
    let absent = dir.path().join("absent.sqlite3");
    call(&mut b, "backup.create", json!({"path":absent}));
    let item = call(
        &mut b,
        "inbox.capture",
        json!({"title":"Inbox created later"}),
    )["item"]
        .clone();
    let view = call(
        &mut b,
        "view.save",
        json!({"id":"later-view","name":"First view"}),
    )["view"]
        .clone();
    let present = dir.path().join("present.sqlite3");
    call(&mut b, "backup.create", json!({"path":present}));
    call(&mut b, "inbox.dismiss", json!({"item_id":item["id"]}));
    call(
        &mut b,
        "view.save",
        json!({"id":view["id"],"name":"Next view","expected_revision":view["revision"]}),
    );
    call(&mut b, "backup.restore", json!({"path":absent}));
    drop(b);
    let mut b = Board::open(dir.path()).unwrap();
    call(&mut b, "backup.restore", json!({"path":present}));
    let returned = call(&mut b, "inbox.list", json!({}))["items"][0].clone();
    assert!(returned["revision"].as_i64().unwrap() > 2);
    let returned = call(&mut b, "view.list", json!({}))["views"][0].clone();
    assert!(returned["revision"].as_i64().unwrap() > 2);
    error(
        &mut b,
        "inbox.dismiss",
        json!({"item_id":item["id"],"expected_revision":2}),
        "REVISION_CONFLICT",
    );
    error(
        &mut b,
        "view.delete",
        json!({"view_id":view["id"],"expected_revision":2}),
        "REVISION_CONFLICT",
    );
}

#[test]
fn all_task_completion_entry_points_finish_only_the_latest_review_run() {
    for method in ["task.complete", "task.update"] {
        let (_dir, mut b, _, t) = setup();
        call(
            &mut b,
            "task.start",
            json!({"task_id":t,"run_id":"old-review"}),
        );
        call(
            &mut b,
            "task.review",
            json!({"task_id":t,"summary":"Previous review request"}),
        );
        let old = get(&mut b, &t)["runs"][0].clone();
        call(
            &mut b,
            "task.start",
            json!({"task_id":t,"run_id":"current-review"}),
        );
        call(
            &mut b,
            "task.review",
            json!({"task_id":t,"summary":"Current review request"}),
        );
        b.conn
            .execute(
                "UPDATE runs SET ended_at='2026-01-01T00:00:00.000Z' WHERE id='current-review'",
                [],
            )
            .unwrap();
        let result = if method == "task.complete" {
            call(
                &mut b,
                method,
                json!({"task_id":t,"summary":"Final approval","next_action":"Share results"}),
            )
        } else {
            update(
                &mut b,
                &t,
                json!({"status":"done","completion_summary":"Final approval","next_action":"Share results"}),
            )
        };
        assert_eq!(result["task"]["status"], "done");
        let runs = result["runs"].as_array().unwrap();
        assert_eq!(
            runs.iter().find(|run| run["id"] == "old-review").unwrap(),
            &old
        );
        let current = runs
            .iter()
            .find(|run| run["id"] == "current-review")
            .unwrap();
        assert_eq!(current["status"], "completed", "{method}");
        assert_eq!(current["summary"], "Final approval", "{method}");
        assert_eq!(current["next_action"], "Share results", "{method}");
        assert_ne!(current["ended_at"], "2026-01-01T00:00:00.000Z", "{method}");
    }
}

#[test]
fn legacy_skipped_civil_day_survives_v4_migration_and_restore_without_blocking_valid_preview() {
    let (dir, mut b, p, t) = setup();
    let normal = task(&mut b, &p, "Valid schedule");
    update(
        &mut b,
        &normal,
        json!({"scheduled_start":"2026-10-15T10:00:00+09:00","scheduled_end":"2026-10-15T11:00:00+09:00","time_zone":"Asia/Seoul"}),
    );
    // These exact values were valid under the version 4 date-only validator. Recreate that
    // schema and data without sending an invalid new write through the version 5 API.
    b.conn.execute("UPDATE tasks SET scheduled_start='2011-12-30',scheduled_end='2011-12-31',time_zone='Pacific/Apia' WHERE id=?1",[&t]).unwrap();
    b.conn.execute_batch("DROP TABLE task_dependencies; DROP TABLE checklist_items; DROP TABLE review_decisions; DROP TABLE inbox; DROP TABLE templates; DROP TABLE saved_views; DROP TABLE workflow_revisions; PRAGMA user_version=4;").unwrap();
    let backup = dir.path().join("legacy-v4.sqlite3");
    b.backup(&backup).unwrap();
    let original_backup = fs::read(&backup).unwrap();
    drop(b);
    let mut b = Board::open(dir.path()).unwrap();
    let proposal = json!({"scheduled_start":"2026-10-15T01:30:00Z","scheduled_end":"2026-10-15T02:30:00Z","time_zone":"UTC"});
    let assert_preview = |b: &mut Board| {
        let before = b.snapshot().unwrap();
        let preview = call(b, "task.schedule.preview", proposal.clone());
        assert_eq!(preview["has_conflicts"], true);
        assert_eq!(preview["conflicts"][0]["id"], normal);
        assert_eq!(preview["invalid_tasks"].as_array().unwrap().len(), 1);
        assert_eq!(preview["invalid_tasks"][0]["task_id"], t);
        assert_eq!(preview["invalid_tasks"][0]["title"], "Task");
        assert!(!preview["invalid_tasks"][0]["reason"]
            .as_str()
            .unwrap()
            .is_empty());
        assert_eq!(
            b.snapshot().unwrap(),
            before,
            "preview mutated historical data"
        );
        assert_eq!(get(b, &t)["task"]["scheduled_start"], "2011-12-30");
    };
    assert_preview(&mut b);
    update(
        &mut b,
        &t,
        json!({"scheduled_start":null,"scheduled_end":null}),
    );
    assert_eq!(
        call(&mut b, "task.schedule.preview", proposal.clone())["invalid_tasks"],
        json!([])
    );
    call(&mut b, "backup.restore", json!({"path":backup}));
    assert_preview(&mut b);
    assert_eq!(
        fs::read(&backup).unwrap(),
        original_backup,
        "old backup migration changed its source"
    );
}
