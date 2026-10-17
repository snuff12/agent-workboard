//! Generic workflow controls and the optional executor host. No provider is built in.
use super::*;

#[derive(Subcommand)]
pub enum AutomationCommand {
    List,
    #[command(about = "Create, inspect, and select reusable process presets")]
    Preset {
        #[command(subcommand)]
        command: PresetCommand,
    },
    #[command(about = "Read project automation defaults")]
    Defaults {
        project_id: String,
    },
    #[command(
        about = "Save project defaults from a configuration JSON file; applies to new tasks"
    )]
    SetDefaults {
        project_id: String,
        #[arg(long)]
        configuration: PathBuf,
        #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
        enabled: bool,
        #[arg(long)]
        expected_defaults_revision: Option<i64>,
    },
    Show {
        task_id: String,
    },
    #[command(about = "Arm the development workflow for a task")]
    Configure {
        task_id: String,
        #[arg(long)]
        executor: String,
        #[arg(long, help = "Exclusive executor resource, such as a workspace ID")]
        resource_key: String,
        #[arg(long, default_value = "automation.start")]
        method: String,
        #[arg(long, default_value = "{}")]
        params: String,
        #[arg(long, default_value_t = 2)]
        max_reworks: i64,
        #[arg(long, default_value_t = 1800)]
        timeout_seconds: i64,
        #[arg(
            long,
            help = "JSON array of status rules; defaults to In Progress starting development"
        )]
        rules: Option<String>,
        #[arg(
            long,
            default_value = "{}",
            help = "JSON stage settings with agent, skills, prompt, and instructions"
        )]
        stage_settings: String,
        #[arg(long, help = "Process preset ID, or auto to let an agent choose")]
        process_preset: Option<String>,
        #[arg(long, value_delimiter = ',')]
        allowed_presets: Vec<String>,
    },
    Start {
        task_id: String,
    },
    #[command(about = "Pause after the current stage; do not start another agent")]
    Pause {
        task_id: String,
    },
    Resume {
        task_id: String,
    },
    #[command(about = "Disable the workflow and fence late results; active agents may continue")]
    Disable {
        task_id: String,
    },
    #[command(about = "Record manual confirmation that an uncertain agent has stopped")]
    Resolve {
        task_id: String,
        #[arg(long)]
        confirm_stopped: bool,
        #[arg(long)]
        summary: String,
    },
    #[command(about = "Report stage evidence; process exit is confirmed separately")]
    Report {
        #[arg(long)]
        preset_id: Option<String>,
        #[arg(long)]
        selection_reason: Option<String>,
        #[arg(
            long,
            env = "WORKBOARD_AUTOMATION_REPORT_FILE",
            help = "Write an executor handoff file instead of connecting to the service"
        )]
        report_file: Option<PathBuf>,
        #[arg(long, env = "WORKBOARD_AUTOMATION_TASK")]
        task: String,
        #[arg(long, env = "WORKBOARD_AUTOMATION_ATTEMPT")]
        attempt: String,
        #[arg(
            long,
            env = "WORKBOARD_AUTOMATION_TOKEN",
            hide_env_values = true,
            required_unless_present = "report_file"
        )]
        token: Option<String>,
        #[arg(long)]
        outcome: String,
        #[arg(long)]
        summary: String,
        #[arg(long, required = true)]
        evidence: Vec<String>,
        #[arg(long)]
        source_dir: PathBuf,
    },
    #[command(about = "Submit a stage handoff file (executor callback)")]
    SubmitReport {
        path: PathBuf,
        #[arg(long, env = "WORKBOARD_AUTOMATION_TASK")]
        task: String,
        #[arg(long, env = "WORKBOARD_AUTOMATION_ATTEMPT")]
        attempt: String,
        #[arg(long, env = "WORKBOARD_AUTOMATION_TOKEN", hide_env_values = true)]
        token: String,
    },
    #[command(about = "Confirm the stage process exit (executor callback)")]
    Settle {
        #[arg(long, env = "WORKBOARD_AUTOMATION_TASK")]
        task: String,
        #[arg(long, env = "WORKBOARD_AUTOMATION_ATTEMPT")]
        attempt: String,
        #[arg(long, env = "WORKBOARD_AUTOMATION_TOKEN", hide_env_values = true)]
        token: String,
        #[arg(long)]
        exit_code: i64,
        #[arg(long)]
        source_dir: PathBuf,
    },
    #[command(about = "Hash a Git checkout, including local and untracked changes")]
    Fingerprint {
        path: PathBuf,
    },
    #[command(about = "Process pending launches once (normally started by the service)")]
    Worker,
}

#[derive(Subcommand)]
pub enum PresetCommand {
    List,
    Show {
        preset_id: String,
    },
    Save {
        #[arg(long)]
        file: PathBuf,
        #[arg(long)]
        expected_preset_revision: Option<i64>,
    },
    Delete {
        preset_id: String,
        #[arg(long)]
        expected_preset_revision: Option<i64>,
    },
    #[command(
        about = "Select a preset for an inactive task and record the reason without launching"
    )]
    Apply {
        task_id: String,
        #[arg(long)]
        preset: String,
        #[arg(long)]
        reason: String,
    },
}
fn preset_request(
    client: &Client,
    command: &PresetCommand,
    request_id: &str,
) -> Result<Value, String> {
    let (method, params) = match command {
        PresetCommand::List => {
            return Ok(client.call("automation.presets.list", json!({}), request_id))
        }
        PresetCommand::Show { preset_id } => {
            return Ok(client.call(
                "automation.presets.get",
                json!({"preset_id":preset_id}),
                request_id,
            ))
        }
        PresetCommand::Save {
            file,
            expected_preset_revision,
        } => {
            let preset: Value = serde_json::from_slice(&fs::read(file).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
            (
                "automation.presets.save",
                json!({"preset":preset,"expected_preset_revision":expected_preset_revision}),
            )
        }
        PresetCommand::Delete {
            preset_id,
            expected_preset_revision,
        } => (
            "automation.presets.delete",
            json!({"preset_id":preset_id,"expected_preset_revision":expected_preset_revision}),
        ),
        PresetCommand::Apply { .. } => unreachable!(),
    };
    revisioned_call(client, method, params, request_id, None)
}

/// Resolve revisions once and persist the exact service request before sending it.
/// Retries recover those parameters instead of reading a newer task or library revision.
fn revisioned_call(
    client: &Client,
    method: &str,
    mut params: Value,
    request_id: &str,
    expected_revision: Option<i64>,
) -> Result<Value, String> {
    let payload = json!({"kind":"automation-control","method":method,"params":params,"expected_revision":expected_revision});
    let (ticket, state) = match journal::begin_core(&client.data_dir, request_id, &payload) {
        Ok(value) => value,
        Err(message) if message.starts_with("REQUEST_ID_CONFLICT:") => {
            return Ok(failure(request_id, "REQUEST_ID_CONFLICT", message))
        }
        Err(message) => return Err(message),
    };
    match state {
        journal::State::Complete(response) => return Ok(response),
        journal::State::Prepared(saved) => params = saved["params"].clone(),
        journal::State::Fresh => {
            match method {
                "automation.presets.save" | "automation.presets.delete" => {
                    let id = if method == "automation.presets.save" {
                        &params["preset"]["id"]
                    } else {
                        &params["preset_id"]
                    };
                    let current = client.call(
                        "automation.presets.get",
                        json!({"preset_id":id}),
                        &format!("{request_id}:preset"),
                    );
                    if current["ok"] != true
                        && !(method == "automation.presets.save"
                            && current["error"]["code"] == "NOT_FOUND")
                    {
                        return Ok(current);
                    }
                    if params["expected_preset_revision"].is_null() {
                        params["expected_preset_revision"] = json!(current["result"]["preset"]
                            ["revision"]
                            .as_i64()
                            .unwrap_or(0));
                    }
                }
                "automation.defaults.set" => {
                    let current = client.call(
                        "automation.defaults.get",
                        json!({"project_id":params["project_id"]}),
                        &format!("{request_id}:defaults"),
                    );
                    if current["ok"] != true {
                        return Ok(current);
                    }
                    if params["expected_defaults_revision"].is_null() {
                        params["expected_defaults_revision"] = json!(current["result"]["defaults"]
                            ["revision"]
                            .as_i64()
                            .unwrap_or(0));
                    }
                }
                _ => {
                    let current = client.call(
                        "task.get",
                        json!({"task_id":params["task_id"]}),
                        &format!("{request_id}:context"),
                    );
                    if current["ok"] != true {
                        return Ok(current);
                    }
                    params["expected_revision"] = expected_revision.map_or_else(
                        || current["result"]["task"]["revision"].clone(),
                        Value::from,
                    );
                    if !current["result"]["automation"].is_null() {
                        params["expected_automation_revision"] =
                            current["result"]["automation"]["revision"].clone();
                    }
                }
            }
            ticket.prepare(&json!({"params":params}))?;
        }
    }
    let response = client.call(method, params, request_id);
    if response["ok"] == true {
        ticket.complete(&response)?;
    }
    Ok(response)
}

fn git(path: &Path, arguments: &[&str]) -> Result<Vec<u8>, String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(arguments)
        .output()
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(
            "Could not inspect the Git checkout. Check its path and Git installation.".into(),
        );
    }
    Ok(output.stdout)
}

pub fn fingerprint(path: &Path) -> Result<String, String> {
    fingerprint_tree(path, 0)
}

fn fingerprint_tree(path: &Path, depth: usize) -> Result<String, String> {
    if depth > 16 {
        return Err("The checkout has too many nested submodules.".into());
    }
    let root = git(path, &["rev-parse", "--show-toplevel"])?;
    let root = PathBuf::from(
        String::from_utf8(root)
            .map_err(|e| e.to_string())?
            .trim_end(),
    );
    let mut hash = Sha256::new();
    for bytes in [
        git(&root, &["rev-parse", "--verify", "HEAD"])?,
        git(&root, &["diff", "--binary", "--no-ext-diff", "HEAD", "--"])?,
        git(
            &root,
            &["diff", "--cached", "--binary", "--no-ext-diff", "--"],
        )?,
        git(&root, &["submodule", "status", "--recursive"])?,
    ] {
        hash.update((bytes.len() as u64).to_le_bytes());
        hash.update(bytes);
    }
    // A dirty gitlink alone does not identify changes inside a submodule.
    let tracked = git(&root, &["ls-files", "--stage", "-z"])?;
    for entry in tracked
        .split(|byte| *byte == 0)
        .filter(|entry| entry.starts_with(b"160000 "))
    {
        use std::os::unix::ffi::OsStrExt;
        let name = entry
            .splitn(2, |byte| *byte == b'\t')
            .nth(1)
            .ok_or("Could not inspect a submodule path.")?;
        let child = root.join(std::ffi::OsStr::from_bytes(name));
        let child_root = git(&child, &["rev-parse", "--show-toplevel"])?;
        if Path::new(String::from_utf8_lossy(&child_root).trim_end()) != child {
            return Err("Initialize all submodules before reporting a stage.".into());
        }
        hash.update((name.len() as u64).to_le_bytes());
        hash.update(name);
        hash.update(fingerprint_tree(&child, depth + 1)?.as_bytes());
    }
    let untracked = git(&root, &["ls-files", "--others", "--exclude-standard", "-z"])?;
    for name in untracked.split(|byte| *byte == 0).filter(|v| !v.is_empty()) {
        use std::os::unix::ffi::OsStrExt;
        let file = root.join(std::ffi::OsStr::from_bytes(name));
        let metadata = fs::symlink_metadata(&file).map_err(|e| e.to_string())?;
        hash.update((name.len() as u64).to_le_bytes());
        hash.update(name);
        hash.update(metadata.permissions().mode().to_le_bytes());
        let bytes = if metadata.file_type().is_symlink() {
            fs::read_link(&file)
                .map_err(|e| e.to_string())?
                .as_os_str()
                .as_bytes()
                .to_vec()
        } else {
            fs::read(&file).map_err(|e| e.to_string())?
        };
        hash.update((bytes.len() as u64).to_le_bytes());
        hash.update(bytes);
    }
    Ok(format!("sha256:{:x}", hash.finalize()))
}

pub fn execute(
    client: &Client,
    command: &AutomationCommand,
    request_id: &str,
    expected_revision: Option<i64>,
) -> Value {
    let result = (|| -> Result<Value, String> {
        if let AutomationCommand::Fingerprint { path } = command {
            return Ok(success(
                request_id,
                json!({"source_version":fingerprint(path)?}),
            ));
        }
        if matches!(command, AutomationCommand::Worker) {
            return Ok(worker(client, request_id));
        }
        let (method, mut params) = match command {
            AutomationCommand::List => ("automation.list", json!({})),
            AutomationCommand::Preset { command } => match command {
                PresetCommand::Apply {
                    task_id,
                    preset,
                    reason,
                } => (
                    "automation.preset.apply",
                    json!({"task_id":task_id,"preset_id":preset,"reason":reason}),
                ),
                _ => return preset_request(client, command, request_id),
            },
            AutomationCommand::Defaults { project_id } => {
                ("automation.defaults.get", json!({"project_id":project_id}))
            }
            AutomationCommand::SetDefaults {
                project_id,
                configuration,
                enabled,
                expected_defaults_revision,
            } => {
                let config: Value =
                    serde_json::from_slice(&fs::read(configuration).map_err(|e| e.to_string())?)
                        .map_err(|e| e.to_string())?;
                (
                    "automation.defaults.set",
                    json!({"project_id":project_id,"configuration":config,"enabled":enabled,"expected_defaults_revision":expected_defaults_revision}),
                )
            }
            AutomationCommand::Show { task_id } => ("automation.get", json!({"task_id":task_id})),
            AutomationCommand::Configure {
                task_id,
                executor,
                resource_key,
                method,
                params,
                max_reworks,
                timeout_seconds,
                rules,
                stage_settings,
                process_preset,
                allowed_presets,
            } => {
                let parameters: Value = serde_json::from_str(params).map_err(|e| e.to_string())?;
                let mut configuration = json!({"plugin_id":executor,"method":method,"resource_key":resource_key,"params":parameters,"max_reworks":max_reworks,"timeout_seconds":timeout_seconds,"stage_settings":serde_json::from_str::<Value>(stage_settings).map_err(|e|e.to_string())?});
                configuration["process_preset"] = json!(process_preset);
                configuration["allowed_presets"] = json!(allowed_presets);
                if let Some(rules) = rules {
                    configuration["rules"] =
                        serde_json::from_str(rules).map_err(|e| e.to_string())?;
                }
                (
                    "automation.configure",
                    json!({"task_id":task_id,"configuration":configuration}),
                )
            }
            AutomationCommand::Start { task_id } => {
                ("automation.start", json!({"task_id":task_id}))
            }
            AutomationCommand::Pause { task_id } => {
                ("automation.pause", json!({"task_id":task_id}))
            }
            AutomationCommand::Resume { task_id } => {
                ("automation.resume", json!({"task_id":task_id}))
            }
            AutomationCommand::Disable { task_id } => {
                ("automation.disable", json!({"task_id":task_id}))
            }
            AutomationCommand::Resolve {
                task_id,
                confirm_stopped,
                summary,
            } => (
                "automation.resolve",
                json!({"task_id":task_id,"confirm_stopped":confirm_stopped,"summary":summary}),
            ),
            AutomationCommand::Report {
                task,
                attempt,
                token,
                outcome,
                summary,
                evidence,
                source_dir,
                preset_id,
                selection_reason,
                ..
            } => (
                "automation.report",
                json!({"task_id":task,"attempt_id":attempt,"token":token,"outcome":outcome,"summary":summary,"evidence":evidence,"source_version":fingerprint(source_dir)?,"preset_id":preset_id,"selection_reason":selection_reason}),
            ),
            AutomationCommand::SubmitReport {
                path,
                task,
                attempt,
                token,
            } => {
                let report: Value =
                    serde_json::from_slice(&fs::read(path).map_err(|e| e.to_string())?)
                        .map_err(|e| e.to_string())?;
                if report["task_id"] != *task || report["attempt_id"] != *attempt {
                    return Err("The handoff file belongs to another attempt".into());
                }
                (
                    "automation.report",
                    json!({"task_id":task,"attempt_id":attempt,"token":token,"outcome":report["outcome"],"summary":report["summary"],"evidence":report["evidence"],"source_version":report["source_version"],"preset_id":report["preset_id"],"selection_reason":report["selection_reason"]}),
                )
            }
            AutomationCommand::Settle {
                task,
                attempt,
                token,
                exit_code,
                source_dir,
            } => (
                "automation.settle",
                json!({"task_id":task,"attempt_id":attempt,"token":token,"exit_code":exit_code,"source_version":fingerprint(source_dir).unwrap_or_default()}),
            ),
            _ => unreachable!(),
        };
        if let AutomationCommand::Report {
            report_file: Some(path),
            ..
        } = command
        {
            use std::os::unix::fs::OpenOptionsExt;
            let mut report = params.clone();
            report.as_object_mut().unwrap().remove("token");
            let bytes = serde_json::to_vec(&report).map_err(|e| e.to_string())?;
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(path)
                .map_err(|e| e.to_string())?;
            std::io::Write::write_all(&mut file, &bytes).map_err(|e| e.to_string())?;
            file.sync_all().map_err(|e| e.to_string())?;
            return Ok(success(
                request_id,
                json!({"report_file":path,"submitted":false}),
            ));
        }
        if matches!(
            method,
            "automation.configure"
                | "automation.preset.apply"
                | "automation.start"
                | "automation.pause"
                | "automation.resume"
                | "automation.disable"
                | "automation.resolve"
        ) {
            if let Some(actor) = agent::identity() {
                params["agent_id"] = json!(actor);
            }
            return revisioned_call(client, method, params, request_id, expected_revision);
        }
        if method == "automation.defaults.set" {
            return revisioned_call(client, method, params, request_id, expected_revision);
        }
        Ok(client.call(method, params, request_id))
    })();
    result.unwrap_or_else(|message| failure(request_id, "AUTOMATION_ERROR", message))
}

fn worker(client: &Client, request_id: &str) -> Value {
    let result = (|| -> Result<Value, String> {
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(client.data_dir.join("automation-worker.lock"))
            .map_err(|e| e.to_string())?;
        if lock.try_lock_exclusive().is_err() {
            return Ok(json!({"busy":true}));
        }
        let response = client.request(
            "automation.jobs",
            json!({}),
            request_id,
            false,
            Duration::from_secs(10),
        );
        if response["ok"] != true {
            return Err(response["error"]["message"].to_string());
        }
        let jobs = response["result"]["jobs"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let mut processed = 0;
        for job in jobs.into_iter().take(1) {
            let attempt = &job["attempt"];
            let attempt_id = attempt["id"].as_str().ok_or("Missing attempt ID")?;
            let mut context = json!({"task_id":job["task_id"],"attempt_id":attempt["id"],"token":attempt["token"]});
            if attempt["deadline"].as_str().is_some_and(|v| {
                !v.is_empty()
                    && v <= chrono::Utc::now()
                        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
                        .as_str()
            }) {
                context["summary"]=json!("The stage deadline was reached. Inspect the agent before resuming; no duplicate was started.");
                context["never_started"] = json!(attempt["state"] == "queued");
                client.call(
                    "automation.fail",
                    context,
                    &format!("automation-timeout:{attempt_id}"),
                );
                continue;
            }
            let plugin_id = job["configuration"]["plugin_id"]
                .as_str()
                .ok_or("Missing executor")?;
            let generation = match plugins::automation_executor(client, plugin_id) {
                Ok(generation) => generation,
                Err(message) => {
                    context["summary"] = json!(message);
                    context["never_started"] = json!(attempt["state"] == "queued");
                    client.call(
                        "automation.fail",
                        context,
                        &format!("automation-unavailable:{attempt_id}"),
                    );
                    continue;
                }
            };
            context["executor_generation"] = json!(generation);
            let claim = client.call(
                "automation.launch",
                context.clone(),
                &format!("automation-launch:{attempt_id}"),
            );
            if claim["ok"] != true {
                continue;
            }
            let mut params = job["configuration"]["params"].clone();
            params["task_id"] = job["task_id"].clone();
            params["attempt_id"] = attempt["id"].clone();
            params["token"] = attempt["token"].clone();
            let response = plugins::run(
                client,
                plugin_id,
                job["configuration"]["method"]
                    .as_str()
                    .ok_or("Missing executor method")?,
                params,
                &format!("automation-execute:{attempt_id}"),
            );
            if response["ok"] == true {
                context["receipt"] = response["result"]["result"].clone();
                client.call(
                    "automation.launched",
                    context,
                    &format!("automation-receipt:{attempt_id}"),
                );
            } else {
                context["summary"] = json!(format!(
                    "Executor launch failed: {}. Inspect its launch record before resuming.",
                    response["error"]["message"]
                        .as_str()
                        .unwrap_or("Unknown error")
                ));
                context["never_started"] = json!(false);
                client.call(
                    "automation.fail",
                    context,
                    &format!("automation-error:{attempt_id}"),
                );
            }
            processed += 1;
        }
        Ok(json!({"processed":processed}))
    })();
    match result {
        Ok(value) => success(request_id, value),
        Err(message) => failure(request_id, "AUTOMATION_WORKER_ERROR", message),
    }
}
