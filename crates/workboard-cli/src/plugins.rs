use crate::{failure, success, Client, PluginCommand};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Clone, Serialize, Deserialize)]
struct Manifest {
    id: String,
    name: String,
    version: String,
    protocol_version: u32,
    executable: String,
    methods: Vec<String>,
    #[serde(default)]
    allowed_requests: Vec<String>,
    #[serde(default)]
    read_only_methods: Vec<String>,
    #[serde(default)]
    task_context_methods: Vec<String>,
    #[serde(default)]
    setup_methods: Vec<String>,
    #[serde(default)]
    description: String,
    #[serde(default = "default_timeout")]
    timeout_seconds: u64,
}
/// Core requests a plugin may return. Deletion, board restore and service settings stay with the user
/// whatever a manifest lists, so disabling or removing a plugin always leaves the board intact.
const PLUGIN_REQUESTS: [&str; 19] = [
    "project.list",
    "project.create",
    "task.list",
    "task.get",
    "task.resume_context",
    "board.snapshot",
    "events.list",
    "task.create",
    "task.update",
    "task.claim",
    "task.release",
    "task.start",
    "task.review",
    "task.complete",
    "task.attach",
    "task.pause",
    "task.heartbeat",
    "run.update",
    "run.finish",
];
fn default_timeout() -> u64 {
    30
}
fn subrequest_id(request_id: &str, suffix: impl std::fmt::Display) -> String {
    format!(
        "plugin:{:x}:{suffix}",
        Sha256::digest(request_id.as_bytes())
    )
}

fn core_request_id(
    plugin_id: &str,
    request_id: &str,
    index: usize,
    request: &Value,
) -> Result<String> {
    let Some(key) = request.get("idempotency_key") else {
        return Ok(subrequest_id(request_id, index));
    };
    let key = key
        .as_str()
        .filter(|key| !key.trim().is_empty() && key.len() <= 200 && !key.contains('\0'))
        .ok_or("PLUGIN_INVALID_RESPONSE: idempotency_key must be a string of 1 to 200 bytes.")?;
    // Scope stable operations to the plugin so different top-level recovery
    // requests share one service receipt without colliding with other plugins.
    let identity = serde_json::to_vec(&json!([plugin_id, key])).map_err(|e| e.to_string())?;
    Ok(format!("plugin-operation:{:x}", Sha256::digest(identity)))
}
#[derive(Clone, Serialize, Deserialize)]
struct Installed {
    manifest: Manifest,
    enabled: bool,
    generation: String,
    #[serde(default)]
    config: Value,
}
type Registry = BTreeMap<String, Installed>;
type Result<T> = std::result::Result<T, String>;

struct ProcessGuard(std::process::Child);
impl Drop for ProcessGuard {
    fn drop(&mut self) {
        // Terminate only each plugin’s dedicated process group, including its external CLI children.
        unsafe {
            libc::kill(-(self.0.id() as i32), libc::SIGKILL);
        }
        let _ = self.0.wait();
    }
}

fn directory(client: &Client) -> PathBuf {
    client.data_dir.join("plugins")
}
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() < 80
        && id
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
}
fn relative_path(path: &str) -> bool {
    let p = Path::new(path);
    !p.is_absolute() && p.components().all(|c| matches!(c, Component::Normal(_)))
}
fn ensure(client: &Client) -> Result<PathBuf> {
    let dir = directory(client);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
    Ok(dir)
}
fn registry(client: &Client) -> Result<Registry> {
    let file = directory(client).join("registry.json");
    if !file.exists() {
        return Ok(Registry::new());
    }
    serde_json::from_slice(&fs::read(file).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}
fn locked<T>(client: &Client, action: impl FnOnce(&mut Registry, &Path) -> Result<T>) -> Result<T> {
    let dir = ensure(client)?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(dir.join("registry.lock"))
        .map_err(|e| e.to_string())?;
    lock.lock_exclusive().map_err(|e| e.to_string())?;
    let mut state = registry(client)?;
    let result = action(&mut state, &dir)?;
    let temporary = dir.join(format!("registry-{}.tmp", uuid::Uuid::new_v4()));
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|e| e.to_string())?;
    file.write_all(&serde_json::to_vec_pretty(&state).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    fs::rename(temporary, dir.join("registry.json")).map_err(|e| e.to_string())?;
    Ok(result)
}
fn copy_package(
    source: &Path,
    destination: &Path,
    total: &mut (u64, usize),
    depth: usize,
) -> Result<()> {
    if depth > 16 {
        return Err("The plugin directory exceeds the nesting limit.".into());
    }
    fs::create_dir_all(destination).map_err(|e| e.to_string())?;
    fs::set_permissions(destination, fs::Permissions::from_mode(0o700))
        .map_err(|e| e.to_string())?;
    for entry in fs::read_dir(source).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let info = fs::symlink_metadata(entry.path()).map_err(|e| e.to_string())?;
        if info.file_type().is_symlink() {
            return Err("Symbolic links are not supported in plugin packages.".into());
        }
        let target = destination.join(entry.file_name());
        total.1 += 1;
        if total.1 > 4096 {
            return Err("The plugin exceeds the file count limit.".into());
        }
        if info.is_dir() {
            copy_package(&entry.path(), &target, total, depth + 1)?;
        } else if info.is_file() {
            total.0 += info.len();
            if total.0 > 20 * 1024 * 1024 {
                return Err("Plugin packages must not exceed 20 MiB.".into());
            }
            fs::copy(entry.path(), &target).map_err(|e| e.to_string())?;
            let mode = if info.permissions().mode() & 0o111 != 0 {
                0o700
            } else {
                0o600
            };
            fs::set_permissions(target, fs::Permissions::from_mode(mode))
                .map_err(|e| e.to_string())?;
        } else {
            return Err("Only regular files and directories can be installed.".into());
        }
    }
    Ok(())
}
fn entry_info(entry: &Installed) -> Value {
    json!({"id":entry.manifest.id,"name":entry.manifest.name,"version":entry.manifest.version,"description":entry.manifest.description,"enabled":entry.enabled,"compatible":entry.manifest.protocol_version==1,"methods":entry.manifest.methods,"allowed_requests":entry.manifest.allowed_requests,"setup_methods":entry.manifest.setup_methods})
}

pub fn execute(client: &Client, command: &PluginCommand, request_id: &str) -> Value {
    if matches!(
        command,
        PluginCommand::Install { .. }
            | PluginCommand::Enable { .. }
            | PluginCommand::Disable { .. }
            | PluginCommand::Remove { .. }
    ) {
        let payload = serde_json::to_value(command).unwrap();
        let (ticket, state) = match crate::journal::begin(&client.data_dir, request_id, &payload) {
            Ok(value) => value,
            Err(e) => return plugin_error(request_id, e),
        };
        match state {
            crate::journal::State::Complete(response) => return response,
            crate::journal::State::Prepared(_) => {
                return failure(
                    request_id,
                    "PLUGIN_RESULT_UNCERTAIN",
                    "Check the result of the previous configuration change.",
                )
            }
            crate::journal::State::Fresh => {}
        }
        let response = execute_uncached(client, command, request_id);
        if let Err(e) = ticket.complete(&response) {
            return plugin_error(request_id, e);
        }
        return response;
    }
    execute_uncached(client, command, request_id)
}

// Preserve the provider's documented codes without treating arbitrary diagnostic text as a code.
// Namespace codes remain extensible, but must be one bounded uppercase identifier.
fn plugin_error_code(candidate: &str) -> &str {
    let identifier = !candidate.is_empty()
        && candidate.len() <= 80
        && candidate
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_');
    let namespace = ["PLUGIN_", "INTEGRATION_", "REQUEST_"]
        .iter()
        .any(|prefix| candidate.starts_with(prefix) && candidate.len() > prefix.len());
    if identifier
        && (namespace
            || matches!(
                candidate,
                "CONFLICT" | "AUTHORIZATION_REQUIRED" | "INVALID_REQUEST"
            ))
    {
        candidate
    } else {
        "PLUGIN_ERROR"
    }
}
fn plugin_error(request_id: &str, message: String) -> Value {
    let code = plugin_error_code(message.split(':').next().unwrap_or(""));
    failure(request_id, code, &message)
}

fn execute_uncached(client: &Client, command: &PluginCommand, request_id: &str) -> Value {
    let result = match command {
        PluginCommand::List => registry(client)
            .map(|state| json!({"plugins":state.values().map(entry_info).collect::<Vec<_>>()})),
        PluginCommand::Config { id } => registry(client).and_then(|state| {
            let entry = state
                .get(id)
                .ok_or("PLUGIN_NOT_INSTALLED: The plugin is not installed.")?;
            Ok(json!({"id":id,"config":entry.config}))
        }),
        PluginCommand::Setup {
            id,
            method,
            params,
            expected_generation,
        } => {
            let params = match serde_json::from_str(params) {
                Ok(params) => params,
                Err(error) => return failure(request_id, "INVALID_PARAMS", error.to_string()),
            };
            return setup(
                client,
                id,
                method,
                params,
                request_id,
                expected_generation.as_deref(),
            );
        }
        PluginCommand::Install { package, replace } => (|| {
            let manifest: Manifest = serde_json::from_slice(
                &fs::read(package.join("plugin.json")).map_err(|e| e.to_string())?,
            )
            .map_err(|e| e.to_string())?;
            if !valid_id(&manifest.id)
                || !relative_path(&manifest.executable)
                || manifest.version.trim().is_empty()
            {
                return Err("Invalid plugin ID or executable path.".into());
            }
            if manifest.protocol_version != 1 {
                return Err("PLUGIN_INCOMPATIBLE: Unsupported plugin protocol.".into());
            }
            if !package.join(&manifest.executable).is_file() {
                return Err("The plugin executable is missing.".into());
            }
            locked(client, |state, dir| {
                if state.contains_key(&manifest.id) && !replace {
                    return Err(
                        "The plugin is already installed. Use --replace to update it and preserve settings.".into(),
                    );
                }
                let canonical_source = package.canonicalize().map_err(|e| e.to_string())?;
                if dir
                    .canonicalize()
                    .map_err(|e| e.to_string())?
                    .starts_with(&canonical_source)
                {
                    return Err(
                        "A directory containing the plugin registry cannot be installed.".into(),
                    );
                }
                let staging = dir.join(format!(".install-{}", uuid::Uuid::new_v4()));
                if let Err(e) = copy_package(package, &staging, &mut (0, 0), 0) {
                    let _ = fs::remove_dir_all(staging);
                    return Err(e);
                }
                let target = dir.join(&manifest.id);
                let previous = dir.join(format!(".previous-{}", uuid::Uuid::new_v4()));
                if target.exists() {
                    fs::rename(&target, &previous).map_err(|e| e.to_string())?;
                }
                if let Err(error) = fs::rename(&staging, &target) {
                    if previous.exists() {
                        let _ = fs::rename(&previous, &target);
                    }
                    let _ = fs::remove_dir_all(&staging);
                    return Err(error.to_string());
                }
                let prior = state.get(&manifest.id);
                let installed = Installed {
                    manifest: manifest.clone(),
                    enabled: prior.is_some_and(|entry| entry.enabled),
                    generation: uuid::Uuid::new_v4().to_string(),
                    config: prior.map(|entry| entry.config.clone()).unwrap_or(json!({})),
                };
                let info = entry_info(&installed);
                state.insert(manifest.id.clone(), installed);
                if previous.exists() {
                    let _ = fs::remove_dir_all(previous);
                }
                Ok(info)
            })
        })(),
        PluginCommand::Enable {
            id,
            executable,
            config,
            expected_generation,
        } => locked(client, |state, _| {
            let entry = state
                .get_mut(id)
                .ok_or("PLUGIN_NOT_INSTALLED: Install the plugin first.")?;
            if expected_generation
                .as_ref()
                .is_some_and(|expected| expected != &entry.generation)
            {
                return Err("CONFLICT: Connection settings changed. Try connecting again.".into());
            }
            if entry.manifest.protocol_version != 1 {
                return Err("PLUGIN_INCOMPATIBLE: Protocol versions do not match.".into());
            }
            let mut settings = entry.config.as_object().cloned().unwrap_or_default();
            if let Some(raw) = config {
                let parsed: Value = serde_json::from_str(raw).map_err(|e| e.to_string())?;
                settings.extend(
                    parsed
                        .as_object()
                        .ok_or("Configuration must be a JSON object.")?
                        .clone(),
                );
            }
            if let Some(executable) = executable {
                settings.insert("executable".into(), json!(executable));
            }
            entry.config = Value::Object(settings);
            entry.enabled = true;
            entry.generation = uuid::Uuid::new_v4().to_string();
            Ok(entry_info(entry))
        }),
        PluginCommand::Disable { id } => locked(client, |state, _| {
            let entry = state
                .get_mut(id)
                .ok_or("PLUGIN_NOT_INSTALLED: The plugin is not installed.")?;
            entry.enabled = false;
            entry.generation = uuid::Uuid::new_v4().to_string();
            Ok(entry_info(entry))
        }),
        PluginCommand::Remove { id } => locked(client, |state, dir| {
            if !valid_id(id) {
                return Err("Invalid plugin ID.".into());
            }
            state
                .remove(id)
                .ok_or("PLUGIN_NOT_INSTALLED: The plugin is not installed.")?;
            let path = dir.join(id);
            if path.exists() {
                fs::remove_dir_all(path).map_err(|e| e.to_string())?;
            }
            Ok(json!({"removed":id,"task_data_preserved":true}))
        }),
        PluginCommand::Check { id } => return run(client, id, "check", json!({}), request_id),
        PluginCommand::Run {
            id,
            method,
            params,
            task,
            query,
            collection,
            source,
            locator,
        } => {
            let mut params: Value = match serde_json::from_str(params) {
                Ok(p) => p,
                Err(e) => return failure(request_id, "INVALID_PARAMS", e),
            };
            let Some(object) = params.as_object_mut() else {
                return failure(request_id, "INVALID_PARAMS", "A JSON object is required.");
            };
            for (key, value) in [
                ("task_id", task),
                ("query", query),
                ("collection", collection),
                ("source", source),
                ("locator", locator),
            ] {
                if let Some(value) = value {
                    object.insert(key.into(), json!(value));
                }
            }
            return run(client, id, method, params, request_id);
        }
    };
    match result {
        Ok(value) => success(request_id, value),
        Err(message) => plugin_error(request_id, message),
    }
}

fn invoke_plugin(
    client: &Client,
    entry: &Installed,
    method: &str,
    params: &Value,
    request_id: &str,
    setup: bool,
) -> Result<Value> {
    crate::cancellation::check()?;
    let dir = ensure(client)?;
    let id = &entry.manifest.id;
    let package = dir.join(id);
    let run_dir = dir.join(format!(".run-{}", uuid::Uuid::new_v4()));
    fs::create_dir(&run_dir).map_err(|e| e.to_string())?;
    fs::set_permissions(&run_dir, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
    let result = (|| -> Result<Value> {
        let stdout = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(run_dir.join("output"))
            .map_err(|e| e.to_string())?;
        let stderr = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(run_dir.join("error"))
            .map_err(|e| e.to_string())?;
        let request = json!({"protocol_version":1,"request_id":request_id,"method":method,"params":params,"config":entry.config});
        let input_path = run_dir.join("input");
        let mut input = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&input_path)
            .map_err(|e| e.to_string())?;
        input
            .write_all(&serde_json::to_vec(&request).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        drop(input);
        let mut process = locked(client, |state, _| {
            crate::cancellation::check()?;
            if !state
                .get(id)
                .is_some_and(|p| (setup || p.enabled) && p.generation == entry.generation)
            {
                return Err("PLUGIN_DISABLED: The plugin is disabled.".into());
            }
            let mut command = Command::new(package.join(&entry.manifest.executable));
            command.current_dir(&package).env_clear();
            for key in ["HOME", "PATH", "LANG", "LC_ALL", "TMPDIR", "USER"] {
                if let Some(value) = std::env::var_os(key) {
                    command.env(key, value);
                }
            }
            command.env(
                "WORKBOARD_PLUGIN_DATA_DIR",
                client.data_dir.join("plugin-data").join(id),
            );
            command
                .process_group(0)
                .stdin(Stdio::from(
                    File::open(&input_path).map_err(|e| e.to_string())?,
                ))
                .stdout(stdout)
                .stderr(stderr);
            Ok(ProcessGuard(
                command
                    .spawn()
                    .map_err(|e| format!("INTEGRATION_UNAVAILABLE: {e}"))?,
            ))
        })?;
        let child = &mut process.0;
        let started = Instant::now();
        loop {
            crate::cancellation::check()?;
            if !registry(client)?
                .get(id)
                .is_some_and(|p| (setup || p.enabled) && p.generation == entry.generation)
            {
                return Err(
                    "PLUGIN_DISABLED: The plugin was disabled or removed during execution.".into(),
                );
            }
            for name in ["output", "error"] {
                if fs::metadata(run_dir.join(name))
                    .map_err(|e| e.to_string())?
                    .len()
                    > 2 * 1024 * 1024
                {
                    return Err("PLUGIN_OUTPUT_TOO_LARGE: Output exceeds the size limit.".into());
                }
            }
            if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
                if !status.success() {
                    return Err("INTEGRATION_UNAVAILABLE: Plugin execution failed.".into());
                }
                break;
            }
            if started.elapsed() > Duration::from_secs(entry.manifest.timeout_seconds.clamp(1, 180))
            {
                return Err("PLUGIN_TIMEOUT: Execution timed out.".into());
            }
            std::thread::sleep(Duration::from_millis(30));
        }
        crate::cancellation::check()?;
        let output = fs::read(run_dir.join("output")).map_err(|e| e.to_string())?;
        if output.len() > 2 * 1024 * 1024 {
            return Err("PLUGIN_OUTPUT_TOO_LARGE: The response exceeds the size limit.".into());
        }
        let response: Value =
            serde_json::from_slice(&output).map_err(|e| format!("PLUGIN_INVALID_RESPONSE: {e}"))?;
        if response["ok"] != true {
            return Err(format!(
                "{}: {}",
                plugin_error_code(
                    response["error"]["code"]
                        .as_str()
                        .unwrap_or("INTEGRATION_UNAVAILABLE")
                ),
                response["error"]["message"]
                    .as_str()
                    .unwrap_or("Plugin request failed")
            ));
        }
        Ok(response)
    })();
    let _ = fs::remove_dir_all(run_dir);
    result
}

fn setup(
    client: &Client,
    id: &str,
    method: &str,
    params: Value,
    request_id: &str,
    expected_generation: Option<&str>,
) -> Value {
    if !params.is_object()
        || serde_json::to_vec(&params).map_or(true, |bytes| bytes.len() > 1024 * 1024)
    {
        return failure(
            request_id,
            "INVALID_PARAMS",
            "Setup input must be an object of at most 1 MiB.",
        );
    }
    let entry = match registry(client).and_then(|state| {
        state
            .get(id)
            .cloned()
            .ok_or("The plugin is not installed.".into())
    }) {
        Ok(entry) => entry,
        Err(error) => return failure(request_id, "PLUGIN_NOT_INSTALLED", error),
    };
    if entry.manifest.protocol_version != 1 {
        return failure(
            request_id,
            "PLUGIN_INCOMPATIBLE",
            "Protocol versions do not match.",
        );
    }
    if expected_generation.is_some_and(|expected| expected != entry.generation) {
        return failure(
            request_id,
            "CONFLICT",
            "Connection settings changed. Try connecting again.",
        );
    }
    if !entry
        .manifest
        .setup_methods
        .iter()
        .any(|name| name == method)
    {
        return failure(
            request_id,
            "PLUGIN_METHOD_NOT_FOUND",
            "This plugin does not provide that connection step.",
        );
    }
    let result = (|| -> Result<Value> {
        crate::cancellation::install()?;
        let response = invoke_plugin(client, &entry, method, &params, request_id, true)?;
        if let Some(requests) = response.get("requests") {
            if !requests.as_array().is_some_and(|items| items.is_empty()) {
                return Err(
                    "PLUGIN_PERMISSION_DENIED: Connection setup cannot change board data.".into(),
                );
            }
        }
        Ok(
            json!({"plugin_id":id,"generation":entry.generation,"config":entry.config,"result":response.get("result").cloned().unwrap_or(json!({}))}),
        )
    })();
    match result {
        Ok(value) => success(request_id, value),
        Err(error) => plugin_error(request_id, error),
    }
}

fn run(client: &Client, id: &str, method: &str, params: Value, request_id: &str) -> Value {
    if !params.is_object() {
        return failure(
            request_id,
            "INVALID_PARAMS",
            "Plugin input must be a JSON object.",
        );
    }
    if serde_json::to_vec(&params)
        .map(|p| p.len())
        .unwrap_or(usize::MAX)
        > 1024 * 1024
    {
        return failure(
            request_id,
            "INVALID_PARAMS",
            "Plugin input must not exceed 1 MiB.",
        );
    }
    let entry = match registry(client).and_then(|state| {
        state
            .get(id)
            .cloned()
            .ok_or("The plugin is not installed.".into())
    }) {
        Ok(entry) => entry,
        Err(e) => return failure(request_id, "PLUGIN_NOT_INSTALLED", e),
    };
    if !entry.enabled {
        return failure(request_id, "PLUGIN_DISABLED", "Enable the plugin first.");
    }
    if entry.manifest.protocol_version != 1 {
        return failure(
            request_id,
            "PLUGIN_INCOMPATIBLE",
            "Protocol versions do not match.",
        );
    }
    if !entry.manifest.methods.iter().any(|m| m == method) {
        return failure(
            request_id,
            "PLUGIN_METHOD_NOT_FOUND",
            "This feature is not provided by the plugin.",
        );
    }
    if let Err(error) = crate::cancellation::install().and_then(|()| crate::cancellation::check()) {
        return plugin_error(request_id, error);
    }
    let read_only =
        method == "check" || entry.manifest.read_only_methods.iter().any(|m| m == method);
    let mut ticket = None;
    let mut prepared = None;
    if !read_only {
        let payload = json!({"id":id,"method":method,"params":params});
        match crate::journal::begin(&client.data_dir, request_id, &payload) {
            Ok((item, state)) => {
                match state {
                    crate::journal::State::Complete(response) => return response,
                    crate::journal::State::Prepared(value) => prepared = Some(value),
                    crate::journal::State::Fresh => {}
                }
                ticket = Some(item);
            }
            Err(e) => return plugin_error(request_id, e),
        }
    }
    let result = (|| -> Result<Value> {
        crate::cancellation::check()?;
        let mut response = if let Some(prepared) = prepared {
            if prepared["generation"] != entry.generation {
                return Err(
                    "PLUGIN_DISABLED: Plugin configuration changed after the result was prepared."
                        .into(),
                );
            }
            prepared["response"].clone()
        } else {
            let mut execution_params = params.clone();
            if entry
                .manifest
                .task_context_methods
                .iter()
                .any(|m| m == method)
            {
                let task_id = params["task_id"]
                    .as_str()
                    .or_else(|| params["task"]["id"].as_str())
                    .ok_or("PLUGIN_INVALID_PARAMS: task_id is required.")?;
                let context = client.call(
                    "task.get",
                    json!({"task_id":task_id}),
                    &subrequest_id(request_id, "context"),
                );
                if context["ok"] != true {
                    return Err(format!(
                        "PLUGIN_CONTEXT_UNAVAILABLE: {}",
                        context["error"]["message"]
                            .as_str()
                            .unwrap_or("Could not read the task.")
                    ));
                }
                let current = context["result"]["task"].clone();
                if let Some(expected) = params["task"]["revision"]
                    .as_i64()
                    .or_else(|| params["expected_revision"].as_i64())
                {
                    if current["revision"] != expected {
                        return Err("PLUGIN_REVISION_CONFLICT: The task has changed. Read it again before applying changes.".into());
                    }
                }
                execution_params["task"] = current;
                execution_params["task_runs"] = context["result"]["runs"].clone();
                execution_params["agent_protocol"] = json!(crate::agent::PROTOCOL);
                execution_params["board_connection"] = json!({
                    "executable": std::env::current_exe().map_err(|e| e.to_string())?,
                    "data_dir": client.data_dir,
                    "socket": client.socket
                });
            }
            let response =
                invoke_plugin(client, &entry, method, &execution_params, request_id, false)?;
            crate::cancellation::check()?;
            if let Some(ticket) = &ticket {
                ticket.prepare(&json!({"generation":entry.generation,"response":response}))?;
            }
            response
        };
        let mut applied = Vec::new();
        if let Some(requests) = response.get("requests").and_then(Value::as_array) {
            if read_only && !requests.is_empty() {
                return Err(
                    "PLUGIN_PERMISSION_DENIED: Read operations cannot modify tasks.".into(),
                );
            }
            if requests.len() > 25 {
                return Err("PLUGIN_INVALID_RESPONSE: Too many mutation requests.".into());
            }
            let operations = requests
                .iter()
                .enumerate()
                .map(|(index, request)| {
                    let method = request["method"]
                        .as_str()
                        .ok_or("Invalid mutation request.")?;
                    Ok((method, core_request_id(id, request_id, index, request)?))
                })
                .collect::<Result<Vec<_>>>()?;
            // Check every request before applying any, so a refused one cannot follow committed ones.
            for (method, _) in &operations {
                if !PLUGIN_REQUESTS.contains(method) {
                    return Err("PLUGIN_PERMISSION_DENIED: Plugins cannot delete data or restore the board.".into());
                }
                if !entry.manifest.allowed_requests.iter().any(|m| m == method) {
                    return Err(
                        "PLUGIN_PERMISSION_DENIED: This task request is not allowed.".into(),
                    );
                }
            }
            for (request, (method, operation_id)) in requests.iter().zip(operations) {
                crate::cancellation::check()?;
                let result = locked(client, |state, _| {
                    crate::cancellation::check()?;
                    if !state
                        .get(id)
                        .is_some_and(|p| p.enabled && p.generation == entry.generation)
                    {
                        return Err("PLUGIN_DISABLED: The plugin is disabled.".into());
                    }
                    let params = resolve_results(
                        request.get("params").cloned().unwrap_or(json!({})),
                        &applied,
                    )?;
                    Ok(client.call(method, params, &operation_id))
                })?;
                if result["ok"] != true {
                    return Err(format!(
                        "{}: {}",
                        result["error"]["code"]
                            .as_str()
                            .unwrap_or("PLUGIN_REQUEST_FAILED"),
                        result["error"]["message"]
                            .as_str()
                            .unwrap_or("Task mutation failed")
                    ));
                }
                applied.push(result["result"].clone());
            }
        }
        response["applied"] = json!(applied);
        crate::cancellation::check()?;
        Ok(
            json!({"plugin_id":id,"result":response.get("result").cloned().unwrap_or(json!({})),"applied":applied}),
        )
    })();
    let response = match result {
        Ok(value) => success(request_id, value),
        Err(e) => plugin_error(request_id, e),
    };
    if response["ok"] == true {
        if let Some(ticket) = ticket {
            if let Err(e) = ticket.complete(&response) {
                return plugin_error(request_id, e);
            }
        }
    }
    response
}

fn resolve_results(value: Value, results: &[Value]) -> Result<Value> {
    match value {
        Value::Object(mut fields) => {
            if let Some(reference) = fields.remove("$result") {
                let pointer = reference
                    .as_str()
                    .ok_or("Mutation result references must be strings.")?;
                return Value::Array(results.to_vec())
                    .pointer(pointer)
                    .cloned()
                    .ok_or("Could not find the preceding mutation result.".into());
            }
            fields
                .into_iter()
                .map(|(k, v)| resolve_results(v, results).map(|v| (k, v)))
                .collect::<Result<serde_json::Map<_, _>>>()
                .map(Value::Object)
        }
        Value::Array(values) => values
            .into_iter()
            .map(|v| resolve_results(v, results))
            .collect::<Result<Vec<_>>>()
            .map(Value::Array),
        value => Ok(value),
    }
}

pub fn rpc(client: &Client, method: &str, params: Value, request_id: &str) -> Value {
    let id = params["id"].as_str().unwrap_or("").to_owned();
    let command = match method {
        "plugin.list" => PluginCommand::List,
        "plugin.config" => PluginCommand::Config { id },
        "plugin.setup" => {
            return setup(
                client,
                &id,
                params["method"].as_str().unwrap_or("discover"),
                params.get("params").cloned().unwrap_or(json!({})),
                request_id,
                params["expected_generation"].as_str(),
            )
        }
        "plugin.install" => PluginCommand::Install {
            package: PathBuf::from(params["path"].as_str().unwrap_or("")),
            replace: params["replace"].as_bool().unwrap_or(false),
        },
        "plugin.enable" => PluginCommand::Enable {
            id,
            executable: params["executable"].as_str().map(str::to_owned),
            config: params.get("config").map(Value::to_string),
            expected_generation: params["expected_generation"].as_str().map(str::to_owned),
        },
        "plugin.disable" => PluginCommand::Disable { id },
        "plugin.remove" => PluginCommand::Remove { id },
        "plugin.check" => PluginCommand::Check { id },
        "plugin.run" => {
            return run(
                client,
                &id,
                params["method"].as_str().unwrap_or(""),
                params.get("params").cloned().unwrap_or(json!({})),
                request_id,
            )
        }
        _ => return failure(request_id, "METHOD_NOT_FOUND", "Unknown plugin request."),
    };
    execute(client, &command, request_id)
}

#[cfg(test)]
mod error_code_tests {
    use super::*;
    #[test]
    fn preserves_documented_provider_codes_and_existing_namespaces() {
        for code in [
            "CONFLICT",
            "AUTHORIZATION_REQUIRED",
            "INVALID_REQUEST",
            "INTEGRATION_DISABLED",
            "INTEGRATION_UNAVAILABLE",
            "PLUGIN_DISABLED",
            "PLUGIN_RESULT_UNCERTAIN",
            "REQUEST_ID_CONFLICT",
        ] {
            assert_eq!(plugin_error_code(code), code);
            let message = format!("{code}: Original diagnostic: verification required");
            let response = plugin_error("request", message.clone());
            assert_eq!(response["error"]["code"], code);
            assert_eq!(response["error"]["message"], message);
        }
    }
    #[test]
    fn rejects_unknown_or_malformed_codes_without_interpreting_messages() {
        for code in [
            "ARBITRARY_ERROR",
            "CONFLICT: injected",
            "PLUGIN_\nINJECTED",
            "PLUGIN_",
            "conflict",
            "",
        ] {
            assert_eq!(plugin_error_code(code), "PLUGIN_ERROR");
        }
        assert_eq!(
            plugin_error_code(&format!("PLUGIN_{}", "A".repeat(80))),
            "PLUGIN_ERROR"
        );
        let message = "ARBITRARY_ERROR: $(touch never-executed)\nCONFLICT: diagnostic only";
        let response = plugin_error("request", message.into());
        assert_eq!(response["error"]["code"], "PLUGIN_ERROR");
        assert_eq!(response["error"]["message"], message);
    }
}
