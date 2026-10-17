use super::*;
use tempfile::TempDir;

fn request(method: &str, params: Value) -> Request {
    Request {
        schema_version: 1,
        request_id: id(),
        method: method.into(),
        params,
    }
}
fn call(b: &mut Board, method: &str, params: Value) -> Value {
    let response = b.dispatch(request(method, params));
    assert!(response.ok, "{response:?}");
    response.result.unwrap()
}
fn control(b: &mut Board, task: &str, method: &str, mut params: Value) -> Value {
    let detail = call(b, "task.get", json!({"task_id":task}));
    params["task_id"] = json!(task);
    params["expected_revision"] = detail["task"]["revision"].clone();
    if !detail["automation"].is_null() {
        params["expected_automation_revision"] = detail["automation"]["revision"].clone();
    }
    call(b, method, params)
}
fn setup(max_reworks: i64) -> (TempDir, Board, String) {
    let dir = TempDir::new().unwrap();
    let mut b = Board::open(dir.path()).unwrap();
    let project = call(
        &mut b,
        "project.create",
        json!({"name":"Automation","directory":"/tmp/project"}),
    )["project_id"]
        .clone();
    let task=call(&mut b,"task.create",json!({"project_id":project,"title":"Implement a change","goal":"Deliver the change","completion_criteria":"Checks pass and release is prepared"}))["task_id"].as_str().unwrap().to_string();
    control(
        &mut b,
        &task,
        "automation.configure",
        json!({"configuration":{"plugin_id":"fixture","method":"automation.start","resource_key":"workspace","params":{},"max_reworks":max_reworks,"timeout_seconds":60}}),
    );
    call(
        &mut b,
        "automation.executor.changed",
        json!({"plugin_id":"fixture","generation":"one","enabled":true}),
    );
    (dir, b, task)
}
fn active(b: &mut Board) -> Value {
    let job = call(b, "automation.jobs", json!({}))["jobs"][0].clone();
    let context = json!({"task_id":job["task_id"],"attempt_id":job["attempt"]["id"],"token":job["attempt"]["token"],"executor_generation":"one"});
    call(b, "automation.launch", context.clone());
    context
}
fn report(b: &mut Board, context: &Value, outcome: &str, version: &str) -> Request {
    let mut params = context.clone();
    params["outcome"] = json!(outcome);
    params["summary"] = json!("Verified stage results");
    params["evidence"] = json!(["Checks passed; see the verification report"]);
    params["source_version"] = json!(version);
    let request = request("automation.report", params);
    let response = b.dispatch(request.clone());
    assert!(response.ok, "{response:?}");
    request
}
fn settle(b: &mut Board, mut context: Value, version: &str) {
    context["exit_code"] = json!(0);
    context["source_version"] = json!(version);
    call(b, "automation.settle", context);
}
fn finish(b: &mut Board, outcome: &str, version: &str) {
    let context = active(b);
    report(b, &context, outcome, version);
    settle(b, context, version);
}

fn preset_configuration(preset: &str) -> Value {
    json!({"configuration":{"plugin_id":"fixture","method":"automation.start","resource_key":"workspace","params":{},"max_reworks":3,"timeout_seconds":60,"process_preset":preset}})
}

#[test]
fn small_preset_runs_only_its_stages_and_rework_then_human_approval() {
    let (_dir, mut b, t) = setup(3);
    control(
        &mut b,
        &t,
        "automation.configure",
        preset_configuration("small"),
    );
    control(&mut b, &t, "automation.start", json!({}));
    finish(&mut b, "pass", "implementation");
    finish(&mut b, "changes_requested", "implementation");
    finish(&mut b, "pass", "corrected");
    finish(&mut b, "pass", "corrected");
    let detail = call(&mut b, "task.get", json!({"task_id":t}));
    assert_eq!(detail["automation"]["state"], "awaiting_approval");
    assert_eq!(detail["task"]["status"], "review");
    let stages: Vec<_> = detail["automation"]["attempts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a["stage"].clone())
        .collect();
    assert_eq!(
        stages,
        vec![
            json!("work"),
            json!("review"),
            json!("rework"),
            json!("review")
        ]
    );
    control(
        &mut b,
        &t,
        "task.review.decide",
        json!({"decision":"request_changes","summary":"Another correction"}),
    );
    assert_eq!(
        call(&mut b, "automation.get", json!({"task_id":t}))["automation"]["limit_reached"],
        true
    );
}

#[test]
fn large_preset_preserves_source_across_plan_verification_review_and_release() {
    let (_dir, mut b, t) = setup(3);
    control(
        &mut b,
        &t,
        "automation.configure",
        preset_configuration("large"),
    );
    control(&mut b, &t, "automation.start", json!({}));
    finish(&mut b, "pass", "before");
    finish(&mut b, "pass", "before");
    finish(&mut b, "pass", "after");
    let context = active(&mut b);
    let mut invalid_report = context.clone();
    invalid_report["outcome"] = json!("pass");
    invalid_report["summary"] = json!("Changed source");
    invalid_report["evidence"] = json!(["verification"]);
    invalid_report["source_version"] = json!("unexpected-change");
    assert_eq!(
        b.dispatch(request("automation.report", invalid_report))
            .error
            .unwrap()
            .code,
        "AUTOMATION_CONFLICT"
    );
    report(&mut b, &context, "pass", "after");
    settle(&mut b, context, "after");
    finish(&mut b, "changes_requested", "after");
    finish(&mut b, "pass", "fixed");
    finish(&mut b, "pass", "fixed");
    finish(&mut b, "pass", "fixed");
    finish(&mut b, "pass", "fixed");
    let a = call(&mut b, "automation.get", json!({"task_id":t}))["automation"].clone();
    assert_eq!(a["state"], "awaiting_approval");
    let stages: Vec<_> = a["attempts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a["stage"].as_str().unwrap())
        .collect();
    assert_eq!(
        stages,
        [
            "preflight",
            "plan",
            "work",
            "verify",
            "review",
            "rework",
            "verify",
            "review",
            "release"
        ]
    );
}

#[test]
fn agent_selects_only_an_authorized_frozen_preset_with_reason_and_exit() {
    let (_dir, mut b, t) = setup(3);
    let mut config = preset_configuration("auto");
    config["configuration"]["allowed_presets"] = json!(["small"]);
    control(&mut b, &t, "automation.configure", config);
    control(&mut b, &t, "automation.start", json!({}));
    let context = active(&mut b);
    let mut p = context.clone();
    p["outcome"] = json!("pass");
    p["summary"] = json!("Pick a process");
    p["evidence"] = json!(["A small scoped change"]);
    p["source_version"] = json!("source");
    assert!(!b.dispatch(request("automation.report", p.clone())).ok);
    p["preset_id"] = json!("large");
    p["selection_reason"] = json!("Cross-component change");
    assert!(!b.dispatch(request("automation.report", p.clone())).ok);
    p["preset_id"] = json!("small");
    p["selection_reason"] = json!("A single, well-defined change");
    call(&mut b, "automation.report", p);
    assert_eq!(
        call(&mut b, "automation.get", json!({"task_id":t}))["automation"]["stage"],
        "select"
    );
    settle(&mut b, context, "source");
    let a = call(&mut b, "automation.get", json!({"task_id":t}))["automation"].clone();
    assert_eq!(a["stage"], "work");
    assert_eq!(a["process"]["preset"]["id"], "small");
    assert_eq!(a["process"]["selected_by"], "agent");
    assert_eq!(
        a["process"]["selection_reason"],
        "A single, well-defined change"
    );
    assert_eq!(a["attempts"][1]["settings"]["step_number"], 1);
    finish(&mut b, "pass", "implementation");
    finish(&mut b, "pass", "implementation");
    assert_eq!(
        call(&mut b, "automation.get", json!({"task_id":t}))["automation"]["state"],
        "awaiting_approval"
    );
}

#[test]
fn preset_library_edits_and_deletion_keep_task_snapshot_and_monotonic_revisions() {
    let (_dir, mut b, t) = setup(3);
    let mut p = call(
        &mut b,
        "automation.presets.get",
        json!({"preset_id":"small"}),
    )["preset"]
        .clone();
    assert!(
        !b.dispatch(request(
            "automation.presets.save",
            json!({"preset":p,"expected_preset_revision":1})
        ))
        .ok
    );
    p["id"] = json!("docs-only");
    p["name"] = json!("Documentation");
    p["steps"][0]["skills"] = json!(["documentation-skill"]);
    p["steps"][0]["prompt"] = json!("Inspect the documentation marker");
    let saved = call(
        &mut b,
        "automation.presets.save",
        json!({"preset":p,"expected_preset_revision":0}),
    )["preset"]
        .clone();
    control(
        &mut b,
        &t,
        "automation.configure",
        preset_configuration("docs-only"),
    );
    p["steps"][0]["title"] = json!("Updated implementation");
    let edited = call(
        &mut b,
        "automation.presets.save",
        json!({"preset":p,"expected_preset_revision":saved["revision"]}),
    )["preset"]
        .clone();
    assert!(
        !b.dispatch(request(
            "automation.presets.save",
            json!({"preset":p,"expected_preset_revision":saved["revision"]})
        ))
        .ok
    );
    call(
        &mut b,
        "automation.presets.delete",
        json!({"preset_id":"docs-only","expected_preset_revision":edited["revision"]}),
    );
    control(&mut b, &t, "automation.start", json!({}));
    let a = call(&mut b, "automation.get", json!({"task_id":t}))["automation"].clone();
    assert_eq!(
        a["process"]["preset"]["steps"][0]["title"],
        "Implementation"
    );
    assert_eq!(
        a["attempts"][0]["settings"]["skills"],
        json!(["documentation-skill"])
    );
    let recreated = call(
        &mut b,
        "automation.presets.save",
        json!({"preset":p,"expected_preset_revision":0}),
    )["preset"]
        .clone();
    assert!(recreated["revision"].as_i64().unwrap() > edited["revision"].as_i64().unwrap());
    let snapshot = call(&mut b, "board.snapshot", json!({}));
    assert_eq!(snapshot["process_presets"].as_array().unwrap().len(), 4);
}

#[test]
fn agent_preset_apply_checks_assignment_revisions_and_active_process() {
    let (_dir, mut b, t) = setup(3);
    control(&mut b, &t, "task.claim", json!({"agent_id":"owner"}));
    let d = call(&mut b, "task.get", json!({"task_id":t}));
    let mut p = json!({"task_id":t,"expected_revision":d["task"]["revision"],"expected_automation_revision":d["automation"]["revision"],"preset_id":"small","reason":"A narrow fix","agent_id":"other"});
    assert_eq!(
        b.dispatch(request("automation.preset.apply", p.clone()))
            .error
            .unwrap()
            .code,
        "CLAIM_CONFLICT"
    );
    p["agent_id"] = json!("owner");
    p["expected_automation_revision"] = json!(0);
    assert!(!b.dispatch(request("automation.preset.apply", p.clone())).ok);
    p["expected_automation_revision"] = d["automation"]["revision"].clone();
    call(&mut b, "automation.preset.apply", p);
    control(&mut b, &t, "automation.start", json!({"agent_id":"owner"}));
    let d = call(&mut b, "task.get", json!({"task_id":t}));
    assert!(!b.dispatch(request("automation.preset.apply",json!({"task_id":t,"expected_revision":d["task"]["revision"],"expected_automation_revision":d["automation"]["revision"],"preset_id":"large","reason":"A larger fix","agent_id":"owner"}))).ok);
}

#[test]
fn development_loop_waits_for_exit_and_final_human_approval() {
    let (_dir, mut b, t) = setup(2);
    control(&mut b, &t, "automation.start", json!({}));
    let context = active(&mut b);
    let original = report(&mut b, &context, "pass", "source-a");
    assert_eq!(
        call(&mut b, "automation.get", json!({"task_id":t}))["automation"]["stage"],
        "preflight"
    );
    assert_eq!(
        b.dispatch(original.clone()).result,
        b.dispatch(original).result
    );
    let public = call(&mut b, "board.snapshot", json!({}));
    assert!(!public
        .to_string()
        .contains(context["token"].as_str().unwrap()));
    settle(&mut b, context, "source-a");
    finish(&mut b, "pass", "source-b");
    finish(&mut b, "changes_requested", "source-b");
    assert_eq!(
        call(&mut b, "task.get", json!({"task_id":t}))["automation"]["reworks"],
        1
    );
    finish(&mut b, "pass", "source-c");
    finish(&mut b, "pass", "source-c");
    finish(&mut b, "pass", "source-c");
    let detail = call(&mut b, "task.get", json!({"task_id":t}));
    assert_eq!(detail["task"]["status"], "review");
    assert_eq!(detail["automation"]["state"], "awaiting_approval");
    call(
        &mut b,
        "task.review.decide",
        json!({"task_id":t,"expected_revision":detail["task"]["revision"],"decision":"approve","summary":"Reviewed the release readiness report"}),
    );
    assert_eq!(
        call(&mut b, "task.get", json!({"task_id":t}))["automation"]["state"],
        "completed"
    );
}

#[test]
fn status_transition_arms_once_and_early_completion_is_rejected() {
    let (_dir, mut b, t) = setup(2);
    let started = call(
        &mut b,
        "task.start",
        json!({"task_id":t,"expected_revision":1}),
    );
    let detail = call(&mut b, "task.get", json!({"task_id":t}));
    assert_eq!(started["task"]["revision"], detail["task"]["revision"]);
    assert_eq!(
        detail["automation"]["attempts"].as_array().unwrap().len(),
        1
    );
    let response = b.dispatch(request(
        "task.complete",
        json!({"task_id":t,"summary":"Premature completion"}),
    ));
    assert_eq!(response.error.unwrap().code, "AUTOMATION_CONFLICT");
    assert_eq!(
        call(&mut b, "task.get", json!({"task_id":t}))["task"]["status"],
        "in_progress"
    );
}

#[test]
fn process_exit_alone_and_source_changes_do_not_pass_review() {
    let (_dir, mut b, t) = setup(2);
    control(&mut b, &t, "automation.start", json!({}));
    let context = active(&mut b);
    settle(&mut b, context, "source-a");
    assert_eq!(
        call(&mut b, "automation.get", json!({"task_id":t}))["automation"]["state"],
        "blocked"
    );
    control(&mut b, &t, "automation.resume", json!({}));
    finish(&mut b, "pass", "source-a");
    finish(&mut b, "pass", "source-b");
    let mut context = active(&mut b);
    context["outcome"] = json!("pass");
    context["summary"] = json!("Reviewed");
    context["evidence"] = json!(["Review report"]);
    context["source_version"] = json!("source-c");
    assert_eq!(
        b.dispatch(request("automation.report", context.clone()))
            .error
            .unwrap()
            .code,
        "AUTOMATION_CONFLICT"
    );
    report(&mut b, &context, "pass", "source-b");
    settle(&mut b, context, "source-c");
    assert_eq!(
        call(&mut b, "automation.get", json!({"task_id":t}))["automation"]["state"],
        "blocked"
    );
}

#[test]
fn pause_keeps_the_finished_result_without_launching_the_next_stage() {
    let (_dir, mut b, t) = setup(2);
    control(&mut b, &t, "automation.start", json!({}));
    let context = active(&mut b);
    control(&mut b, &t, "automation.pause", json!({}));
    report(&mut b, &context, "pass", "source-a");
    settle(&mut b, context.clone(), "source-a");
    settle(&mut b, context, "source-a");
    assert!(call(&mut b, "automation.jobs", json!({}))["jobs"]
        .as_array()
        .unwrap()
        .is_empty());
    control(&mut b, &t, "automation.resume", json!({}));
    assert_eq!(
        call(&mut b, "automation.get", json!({"task_id":t}))["automation"]["stage"],
        "work"
    );
}

#[test]
fn task_edits_disable_and_old_tokens_cannot_change_current_work() {
    let (_dir, mut b, t) = setup(2);
    control(&mut b, &t, "automation.start", json!({}));
    let mut context = active(&mut b);
    control(
        &mut b,
        &t,
        "task.update",
        json!({"task_id":t,"title":"Changed requirements"}),
    );
    context["outcome"] = json!("pass");
    context["summary"] = json!("Late result");
    context["evidence"] = json!(["Old evidence"]);
    context["source_version"] = json!("source-a");
    assert!(!b.dispatch(request("automation.report", context.clone())).ok);
    let detail = call(&mut b, "task.get", json!({"task_id":t}));
    assert!(
        !b.dispatch(request(
            "automation.resume",
            json!({"task_id":t,"expected_revision":detail["task"]["revision"]})
        ))
        .ok
    );
    settle(&mut b, context, "source-a");
    control(&mut b, &t, "automation.resume", json!({}));
    let mut context = active(&mut b);
    call(
        &mut b,
        "automation.executor.changed",
        json!({"plugin_id":"fixture","generation":"two","enabled":false}),
    );
    context["outcome"] = json!("pass");
    context["summary"] = json!("Late disabled result");
    context["evidence"] = json!(["Evidence"]);
    context["source_version"] = json!("source-a");
    assert!(!b.dispatch(request("automation.report", context)).ok);
    assert_eq!(
        call(&mut b, "automation.get", json!({"task_id":t}))["automation"]["state"],
        "blocked"
    );
}

#[test]
fn rework_limit_stops_the_automatic_loop() {
    let (_dir, mut b, t) = setup(0);
    control(&mut b, &t, "automation.start", json!({}));
    finish(&mut b, "pass", "source-a");
    finish(&mut b, "pass", "source-b");
    finish(&mut b, "changes_requested", "source-b");
    assert_eq!(
        call(&mut b, "automation.get", json!({"task_id":t}))["automation"]["state"],
        "blocked"
    );
    assert!(!b.has_automation_work());
    let detail = call(&mut b, "task.get", json!({"task_id":t}));
    assert!(
        !b.dispatch(request(
            "automation.resume",
            json!({"task_id":t,"expected_revision":detail["task"]["revision"]})
        ))
        .ok
    );
}

#[test]
fn service_restart_reconciles_a_plugin_disabled_while_the_service_was_stopped() {
    let (_dir, mut b, t) = setup(2);
    control(&mut b, &t, "automation.start", json!({}));
    let mut context = active(&mut b);
    b.reconcile_automation_executors(&json!({"fixture":{"generation":"two","enabled":false}}))
        .unwrap();
    context["outcome"] = json!("pass");
    context["summary"] = json!("Old result");
    context["source_version"] = json!("source-a");
    context["evidence"] = json!(["Old evidence"]);
    assert!(!b.dispatch(request("automation.report", context)).ok);
    assert_eq!(
        call(&mut b, "automation.get", json!({"task_id":t}))["automation"]["state"],
        "blocked"
    );
}

#[test]
fn checking_required_items_after_release_keeps_final_approval_available() {
    let (_dir, mut b, t) = setup(2);
    let item = control(
        &mut b,
        &t,
        "task.checklist.add",
        json!({"text":"Read the verification evidence","required":true}),
    )["task"]["checklist"][0]["id"]
        .clone();
    control(&mut b, &t, "automation.start", json!({}));
    for version in ["source-a", "source-b", "source-b", "source-b"] {
        finish(&mut b, "pass", version);
    }
    control(
        &mut b,
        &t,
        "task.checklist.update",
        json!({"item_id":item,"checked":true,"evidence":"Reviewed the attached stage evidence"}),
    );
    let detail = call(&mut b, "task.get", json!({"task_id":t}));
    assert_eq!(detail["automation"]["state"], "awaiting_approval");
    call(
        &mut b,
        "task.review.decide",
        json!({"task_id":t,"expected_revision":detail["task"]["revision"],"decision":"approve","summary":"Verified the completed checklist and release report"}),
    );
    assert_eq!(
        call(&mut b, "task.get", json!({"task_id":t}))["task"]["status"],
        "done"
    );
}

#[test]
fn restart_retains_jobs_and_restore_revokes_live_attempt_authority() {
    let (dir, mut b, t) = setup(2);
    control(&mut b, &t, "automation.start", json!({}));
    drop(b);
    let mut b = Board::open(dir.path()).unwrap();
    assert!(b.has_automation_work());
    let mut context = active(&mut b);
    let backup = dir.path().join("workflow.sqlite3");
    call(&mut b, "backup.create", json!({"path":backup}));
    assert!(
        !b.dispatch(request("backup.restore", json!({"path":backup})))
            .ok
    );
    control(&mut b, &t, "automation.disable", json!({}));
    control(
        &mut b,
        &t,
        "automation.resolve",
        json!({"confirm_stopped":true,"summary":"Verified the fixture process stopped"}),
    );
    call(&mut b, "backup.restore", json!({"path":backup}));
    context["outcome"] = json!("pass");
    context["summary"] = json!("Late result");
    context["evidence"] = json!(["Evidence"]);
    context["source_version"] = json!("source-a");
    assert!(!b.dispatch(request("automation.report", context)).ok);
    assert_eq!(
        call(&mut b, "automation.get", json!({"task_id":t}))["automation"]["state"],
        "blocked"
    );
    assert_eq!(
        call(&mut b, "export", json!({"format":"json"}))["data"]["automations"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn trash_retains_history_without_automatic_restart() {
    let (_dir, mut b, t) = setup(2);
    control(&mut b, &t, "automation.start", json!({}));
    let context = active(&mut b);
    call(&mut b, "task.delete", json!({"task_id":t}));
    assert!(!b.has_automation_work());
    settle(&mut b, context, "source-a");
    call(&mut b, "trash.restore", json!({"task_id":t}));
    let a = call(&mut b, "automation.get", json!({"task_id":t}));
    assert_eq!(a["automation"]["state"], "canceled");
    assert_eq!(a["automation"]["attempts"].as_array().unwrap().len(), 1);
}

#[test]
fn shared_workspace_waits_for_canceled_worker_exit_and_cannot_be_purged_early() {
    let (_dir, mut b, t) = setup(2);
    control(&mut b, &t, "automation.start", json!({}));
    let context = active(&mut b);
    call(&mut b, "automation.launched", context.clone());
    let detail = call(&mut b, "task.get", json!({"task_id":t}));
    let second=call(&mut b,"task.create",json!({"project_id":detail["task"]["project_id"],"title":"Second task","goal":"Change the same workspace","completion_criteria":"Changes verified"}))["task_id"].as_str().unwrap().to_string();
    control(
        &mut b,
        &second,
        "automation.configure",
        json!({"configuration":{"plugin_id":"fixture","method":"automation.start","resource_key":"workspace","params":{},"max_reworks":2,"timeout_seconds":60}}),
    );
    control(&mut b, &second, "automation.start", json!({}));
    assert!(
        !b.has_automation_work(),
        "Another task must not start while the resource has an unresolved agent"
    );
    control(&mut b, &t, "task.update", json!({"status":"canceled"}));
    call(&mut b, "task.delete", json!({"task_id":t}));
    assert!(!b.dispatch(request("trash.purge", json!({"task_id":t}))).ok);
    assert!(
        !b.has_automation_work(),
        "Trash must retain the active resource lease"
    );
    settle(&mut b, context, "source-a");
    assert!(b.has_automation_work());
    call(&mut b, "trash.purge", json!({"task_id":t}));
    let next = active(&mut b);
    assert_eq!(next["task_id"], second);
}

#[test]
fn expired_callback_cannot_advance_even_before_the_background_host_runs() {
    let (_dir, mut b, t) = setup(2);
    control(&mut b, &t, "automation.start", json!({}));
    let mut context = active(&mut b);
    let mut a = load(&b.conn, &t).unwrap().unwrap();
    a.attempts.last_mut().unwrap().deadline = "2000-01-01T00:00:00.000Z".into();
    store(&b.conn, &a).unwrap();
    context["outcome"] = json!("pass");
    context["summary"] = json!("Expired result");
    context["evidence"] = json!(["Evidence"]);
    context["source_version"] = json!("source-a");
    assert!(!b.dispatch(request("automation.report", context.clone())).ok);
    settle(&mut b, context, "source-a");
    let a = call(&mut b, "automation.get", json!({"task_id":t}));
    assert_eq!(a["automation"]["state"], "blocked");
    assert_eq!(a["automation"]["attempts"][0]["worker_exited"], true);
    assert!(!b.has_automation_work());
}

fn custom_configuration() -> Value {
    json!({"plugin_id":"fixture","method":"automation.start","resource_key":"workspace","params":{},"max_reworks":2,"timeout_seconds":60,
        "rules":[{"id":"check-todo","status":"todo","action":"stage","stage":"preflight","skills":["/tmp/example/SKILL.md"],"prompt":"Inspect the acceptance criteria","instructions":"Preserve source"},
        {"id":"review-column","status":"review","action":"stage","stage":"review","agent":"claude","prompt":"Review this card"}],
        "stage_settings":{"preflight":{"instructions":"Record the checked criteria"}}})
}

#[test]
fn project_defaults_apply_only_to_new_tasks_and_are_revision_checked() {
    let (_dir, mut b, old) = setup(2);
    let project = call(&mut b, "task.get", json!({"task_id":old}))["task"]["project_id"].clone();
    let defaults_request = request(
        "automation.defaults.set",
        json!({"project_id":project,"configuration":custom_configuration(),"enabled":true,"expected_defaults_revision":0}),
    );
    assert!(b.dispatch(defaults_request.clone()).ok);
    assert!(b.dispatch(defaults_request).ok);
    let stale=b.dispatch(request("automation.defaults.set",json!({"project_id":project,"configuration":custom_configuration(),"enabled":false,"expected_defaults_revision":0})));
    assert_eq!(stale.error.unwrap().code, "AUTOMATION_CONFLICT");
    let task=call(&mut b,"task.create",json!({"project_id":project,"title":"New card","goal":"Inspect","completion_criteria":"Evidence recorded"}))["task_id"].clone();
    let subtask = call(
        &mut b,
        "task.create",
        json!({"project_id":project,"parent_id":task,"title":"Child card"}),
    )["task_id"]
        .clone();
    for id in [task, subtask] {
        let workflow = call(&mut b, "automation.get", json!({"task_id":id}))["automation"].clone();
        assert_eq!(workflow["state"], "armed");
        assert_eq!(workflow["inherited_revision"], 1);
        assert_eq!(workflow["attempts"], json!([]));
    }
    assert!(
        call(&mut b, "automation.get", json!({"task_id":old}))["automation"]["inherited_revision"]
            .is_null()
    );
    assert_eq!(
        call(&mut b, "board.snapshot", json!({}))["automation_defaults"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn status_rules_run_on_edges_preserve_columns_and_freeze_instructions() {
    let (_dir, mut b, task) = setup(2);
    control(
        &mut b,
        &task,
        "automation.configure",
        json!({"configuration":custom_configuration()}),
    );
    control(&mut b, &task, "task.update", json!({"status":"backlog"}));
    control(&mut b, &task, "task.update", json!({"status":"todo"}));
    let workflow = call(&mut b, "automation.get", json!({"task_id":task}))["automation"].clone();
    assert_eq!(
        workflow["attempts"][0]["settings"]["skills"],
        json!(["/tmp/example/SKILL.md"])
    );
    assert_eq!(
        workflow["attempts"][0]["settings"]["instructions"],
        "Record the checked criteria"
    );
    assert_eq!(
        workflow["attempts"][0]["settings"]["prompt"],
        "Inspect the acceptance criteria"
    );
    finish(&mut b, "pass", "a");
    control(&mut b, &task, "task.update", json!({"status":"todo"}));
    let detail = call(&mut b, "task.get", json!({"task_id":task}));
    assert_eq!(detail["task"]["status"], "todo");
    assert_eq!(detail["automation"]["state"], "waiting");
    assert_eq!(
        detail["automation"]["attempts"].as_array().unwrap().len(),
        1
    );
    control(
        &mut b,
        &task,
        "task.review",
        json!({"summary":"Please review"}),
    );
    let workflow = call(&mut b, "automation.get", json!({"task_id":task}))["automation"].clone();
    assert_eq!(workflow["attempts"][1]["settings"]["agent"], "claude");
    finish(&mut b, "changes_requested", "a");
    assert_eq!(
        call(&mut b, "automation.get", json!({"task_id":task}))["automation"]["state"],
        "waiting"
    );
}

#[test]
fn manual_transition_waits_for_exit_and_discards_stale_results() {
    let (_dir, mut b, task) = setup(2);
    control(
        &mut b,
        &task,
        "automation.configure",
        json!({"configuration":custom_configuration()}),
    );
    control(&mut b, &task, "task.update", json!({"status":"backlog"}));
    control(&mut b, &task, "task.update", json!({"status":"todo"}));
    let context = active(&mut b);
    control(
        &mut b,
        &task,
        "task.review",
        json!({"summary":"Move to review"}),
    );
    assert!(call(&mut b, "automation.jobs", json!({}))["jobs"]
        .as_array()
        .unwrap()
        .is_empty());
    let late=b.dispatch(request("automation.report",json!({"task_id":task,"attempt_id":context["attempt_id"],"token":context["token"],"outcome":"pass","summary":"Late result","evidence":["old"],"source_version":"a"})));
    assert!(!late.ok);
    settle(&mut b, context, "a");
    let workflow = call(&mut b, "automation.get", json!({"task_id":task}))["automation"].clone();
    assert_eq!(workflow["state"], "running");
    assert_eq!(workflow["stage"], "review");
    assert_eq!(workflow["attempts"].as_array().unwrap().len(), 2);
    finish(&mut b, "pass", "b");
}

#[test]
fn invalid_rules_and_disabled_defaults_never_start_agents() {
    let (_dir, mut b, task) = setup(2);
    let mut config = custom_configuration();
    config["rules"][1]["status"] = json!("todo");
    let detail = call(&mut b, "task.get", json!({"task_id":task}));
    assert!(!b.dispatch(request("automation.configure",json!({"task_id":task,"configuration":config,"expected_revision":detail["task"]["revision"]}))).ok);
    call(
        &mut b,
        "automation.defaults.set",
        json!({"project_id":detail["task"]["project_id"],"configuration":custom_configuration(),"enabled":false,"expected_defaults_revision":0}),
    );
    let new = call(
        &mut b,
        "task.create",
        json!({"project_id":detail["task"]["project_id"],"title":"Ordinary card"}),
    )["task_id"]
        .clone();
    assert!(call(&mut b, "automation.get", json!({"task_id":new}))["automation"].is_null());
}

#[test]
fn project_defaults_survive_restore_with_fresh_revisions() {
    let (dir, mut b, task) = setup(2);
    let project = call(&mut b, "task.get", json!({"task_id":task}))["task"]["project_id"].clone();
    call(
        &mut b,
        "automation.defaults.set",
        json!({"project_id":project,"configuration":custom_configuration(),"enabled":true,"expected_defaults_revision":0}),
    );
    let backup = dir.path().join("defaults.sqlite3");
    call(&mut b, "backup.create", json!({"path":backup}));
    call(
        &mut b,
        "automation.defaults.set",
        json!({"project_id":project,"configuration":custom_configuration(),"enabled":false,"expected_defaults_revision":1}),
    );
    call(&mut b, "backup.restore", json!({"path":backup}));
    let restored = call(
        &mut b,
        "automation.defaults.get",
        json!({"project_id":project}),
    )["defaults"]
        .clone();
    assert_eq!(restored["enabled"], true);
    assert_eq!(restored["revision"], 3);
    let exported = dir.path().join("defaults.json");
    call(&mut b, "export", json!({"path":exported,"format":"json"}));
    let document: Value = serde_json::from_slice(&std::fs::read(exported).unwrap()).unwrap();
    assert_eq!(document["automation_defaults"][0]["revision"], 3);
}

#[test]
fn final_requested_changes_use_the_bounded_rework_path_instead_of_restarting_rules() {
    let (_dir, mut b, task) = setup(1);
    control(&mut b, &task, "automation.start", json!({}));
    for _ in 0..4 {
        finish(&mut b, "pass", "source");
    }
    control(
        &mut b,
        &task,
        "task.review.decide",
        json!({"decision":"request_changes","summary":"One final correction"}),
    );
    let workflow = call(&mut b, "automation.get", json!({"task_id":task}))["automation"].clone();
    assert_eq!(workflow["stage"], "rework");
    assert_eq!(workflow["reworks"], 1);
}

#[test]
fn restoring_without_defaults_cannot_reuse_an_old_editor_revision() {
    let (dir, mut b, task) = setup(2);
    let project = call(&mut b, "task.get", json!({"task_id":task}))["task"]["project_id"].clone();
    let backup = dir.path().join("before-defaults.sqlite3");
    call(&mut b, "backup.create", json!({"path":backup}));
    let previous=call(&mut b,"automation.defaults.set",json!({"project_id":project,"configuration":custom_configuration(),"enabled":true,"expected_defaults_revision":0}))["defaults"]["revision"].as_i64().unwrap();
    call(&mut b, "backup.restore", json!({"path":backup}));
    let new=call(&mut b,"automation.defaults.set",json!({"project_id":project,"configuration":custom_configuration(),"enabled":true,"expected_defaults_revision":0}))["defaults"]["revision"].as_i64().unwrap();
    assert!(new > previous);
    assert!(!b.dispatch(request("automation.defaults.set",json!({"project_id":project,"configuration":custom_configuration(),"enabled":false,"expected_defaults_revision":previous}))).ok);
}

#[test]
fn manual_creation_skips_enabled_defaults_and_status_changes_never_launch_agents() {
    let (_dir, mut b, old) = setup(2);
    let project = call(&mut b, "task.get", json!({"task_id":old}))["task"]["project_id"].clone();
    call(
        &mut b,
        "automation.defaults.set",
        json!({"project_id":project,"configuration":custom_configuration(),"enabled":true,"expected_defaults_revision":0}),
    );
    let task=call(&mut b,"task.create",json!({"project_id":project,"title":"Manual work","goal":"Handle by hand","completion_criteria":"User checks the result","automation_mode":"manual"}))["task_id"].clone();
    call(
        &mut b,
        "task.start",
        json!({"task_id":task,"agent_id":"user","expected_revision":1}),
    );
    assert!(call(&mut b, "automation.get", json!({"task_id":task}))["automation"].is_null());
    assert!(call(&mut b, "automation.jobs", json!({}))["jobs"]
        .as_array()
        .unwrap()
        .is_empty());
    let applied = call(
        &mut b,
        "template.apply",
        json!({"project_id":project,"template_id":"builtin-feature","automation_mode":"manual"}),
    );
    let root = applied["task"]["id"].clone();
    assert!(root.is_string());
    let tasks = call(&mut b, "task.list", json!({"project_id":project}))["tasks"]
        .as_array()
        .unwrap()
        .clone();
    let family: Vec<_> = tasks
        .iter()
        .filter(|t| t["id"] == root || t["parent_id"] == root)
        .collect();
    assert!(family.len() > 1);
    for task in family {
        assert!(
            call(&mut b, "automation.get", json!({"task_id":task["id"]}))["automation"].is_null()
        );
    }
}

#[test]
fn explicit_automatic_creation_uses_saved_disabled_defaults_and_missing_configuration_rolls_back() {
    let (_dir, mut b, old) = setup(2);
    let project = call(&mut b, "task.get", json!({"task_id":old}))["task"]["project_id"].clone();
    let before = call(&mut b, "task.list", json!({}))["tasks"]
        .as_array()
        .unwrap()
        .len();
    for mode in [json!("automatic"), json!("unknown"), json!(false)] {
        let response=b.dispatch(request("task.create",json!({"project_id":project,"title":"Must not be partially saved","automation_mode":mode})));
        assert!(!response.ok);
        assert_eq!(
            call(&mut b, "task.list", json!({}))["tasks"]
                .as_array()
                .unwrap()
                .len(),
            before
        );
    }
    call(
        &mut b,
        "automation.defaults.set",
        json!({"project_id":project,"configuration":custom_configuration(),"enabled":false,"expected_defaults_revision":0}),
    );
    let task = call(
        &mut b,
        "task.create",
        json!({"project_id":project,"title":"Explicit automation","automation_mode":"automatic"}),
    )["task_id"]
        .clone();
    let a = call(&mut b, "automation.get", json!({"task_id":task}))["automation"].clone();
    assert_eq!(a["state"], "armed");
    assert_eq!(a["attempts"], json!([]));
    let ordinary=call(&mut b,"task.create",json!({"project_id":project,"title":"Follow disabled defaults","automation_mode":"inherit"}))["task_id"].clone();
    assert!(call(&mut b, "automation.get", json!({"task_id":ordinary}))["automation"].is_null());
}

#[test]
fn restored_preset_library_rejects_stale_editors_and_preserves_task_process() {
    let (dir, mut b, t) = setup(3);
    let mut preset = call(
        &mut b,
        "automation.presets.get",
        json!({"preset_id":"small"}),
    )["preset"]
        .clone();
    preset["id"] = json!("restore-process");
    preset["name"] = json!("Original process");
    let original = call(
        &mut b,
        "automation.presets.save",
        json!({"preset":preset,"expected_preset_revision":0}),
    )["preset"]
        .clone();
    control(
        &mut b,
        &t,
        "automation.configure",
        preset_configuration("restore-process"),
    );
    let backup = dir.path().join("preset-backup.sqlite3");
    call(&mut b, "backup.create", json!({"path":backup}));
    preset["name"] = json!("Edited process");
    let edited = call(
        &mut b,
        "automation.presets.save",
        json!({"preset":preset,"expected_preset_revision":original["revision"]}),
    )["preset"]
        .clone();
    call(&mut b, "backup.restore", json!({"path":backup}));
    let restored = call(
        &mut b,
        "automation.presets.get",
        json!({"preset_id":"restore-process"}),
    )["preset"]
        .clone();
    assert_eq!(restored["name"], "Original process");
    assert!(restored["revision"].as_i64().unwrap() > edited["revision"].as_i64().unwrap());
    assert!(
        !b.dispatch(request(
            "automation.presets.save",
            json!({"preset":edited,"expected_preset_revision":edited["revision"]})
        ))
        .ok
    );
    let a = call(&mut b, "automation.get", json!({"task_id":t}))["automation"].clone();
    assert_eq!(a["process"]["preset"]["revision"], original["revision"]);
    assert_eq!(a["process"]["preset"]["name"], "Original process");
    let exported = call(&mut b, "export", json!({"format":"json"}));
    assert!(exported.to_string().contains("process_presets"));
}

#[test]
fn review_restore_refuses_to_discard_an_unresolved_worker() {
    let (dir, mut b, t) = setup(2);
    let backup = dir.path().join("before-worker.sqlite3");
    call(&mut b, "backup.create", json!({"path":backup}));
    control(&mut b, &t, "automation.start", json!({}));
    let context = active(&mut b);
    let response = b.dispatch(request("backup.restore", json!({"path":backup})));
    assert!(
        !response.ok,
        "Restore discarded a live worker's resource lease"
    );
    assert_eq!(response.error.unwrap().code, "AUTOMATION_CONFLICT");
    report(&mut b, &context, "pass", "source-a");
    settle(&mut b, context, "source-a");
}

#[test]
fn review_restored_workflow_revisions_never_rewind() {
    let (dir, mut b, t) = setup(2);
    let backup = dir.path().join("old-workflow.sqlite3");
    call(&mut b, "backup.create", json!({"path":backup}));
    let edited = control(&mut b, &t, "automation.disable", json!({}))["automation"]["revision"]
        .as_i64()
        .unwrap();
    call(&mut b, "backup.restore", json!({"path":backup}));
    let restored = call(&mut b, "automation.get", json!({"task_id":t}))["automation"]["revision"]
        .as_i64()
        .unwrap();
    assert!(
        restored > edited,
        "Restore reused a previous workflow revision"
    );
    call(&mut b, "backup.restore", json!({"path":backup}));
    assert!(
        call(&mut b, "automation.get", json!({"task_id":t}))["automation"]["revision"]
            .as_i64()
            .unwrap()
            > restored
    );
}

fn removable_process(b: &mut Board, t: &str) -> Value {
    let mut preset =
        call(b, "automation.presets.get", json!({"preset_id":"small"}))["preset"].clone();
    preset["id"] = json!("temporary-process");
    let saved = call(
        b,
        "automation.presets.save",
        json!({"preset":preset,"expected_preset_revision":0}),
    )["preset"]
        .clone();
    let mut config = preset_configuration("auto");
    config["configuration"]["allowed_presets"] = json!(["temporary-process"]);
    control(b, t, "automation.configure", config);
    saved
}

#[test]
fn review_deleted_candidate_cannot_block_ordinary_task_edits() {
    let (_dir, mut b, t) = setup(2);
    let preset = removable_process(&mut b, &t);
    control(&mut b, &t, "automation.start", json!({}));
    call(
        &mut b,
        "automation.presets.delete",
        json!({"preset_id":preset["id"],"expected_preset_revision":preset["revision"]}),
    );
    control(
        &mut b,
        &t,
        "task.update",
        json!({"goal":"Updated acceptance scope"}),
    );
    let detail = call(&mut b, "task.get", json!({"task_id":t}));
    assert_eq!(detail["task"]["goal"], "Updated acceptance scope");
    assert_eq!(detail["automation"]["state"], "blocked");
    assert!(!b.has_automation_work());
}

#[test]
fn review_failed_rule_start_does_not_leave_a_running_run() {
    let (_dir, mut b, t) = setup(2);
    let preset = removable_process(&mut b, &t);
    call(
        &mut b,
        "automation.presets.delete",
        json!({"preset_id":preset["id"],"expected_preset_revision":preset["revision"]}),
    );
    control(&mut b, &t, "task.update", json!({"status":"in_progress"}));
    let detail = call(&mut b, "task.get", json!({"task_id":t}));
    assert_eq!(detail["automation"]["state"], "armed");
    assert!(
        detail["runs"]
            .as_array()
            .unwrap()
            .iter()
            .all(|run| run["status"] != "running"),
        "A failed rule left a running task run"
    );
}

#[test]
fn review_controls_require_the_captured_workflow_revision() {
    let (_dir, mut b, t) = setup(2);
    let task = call(&mut b, "task.get", json!({"task_id":t}))["task"].clone();
    let params = json!({"task_id":t,"expected_revision":task["revision"]});
    assert_eq!(
        b.dispatch(request("automation.disable", params))
            .error
            .unwrap()
            .code,
        "AUTOMATION_CONFLICT"
    );
    assert_eq!(
        call(&mut b, "automation.get", json!({"task_id":t}))["automation"]["state"],
        "armed"
    );
}
