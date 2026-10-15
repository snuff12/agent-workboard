//! Durable idempotency for optional plugin side effects.
//! A pending call is never repeated automatically: the process may have changed an external service.
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

#[derive(Debug, PartialEq)]
pub enum State {
    Fresh,
    Prepared(Value),
    Complete(Value),
}

pub struct Ticket {
    _lock: File,
    path: PathBuf,
    request_id: String,
    payload: Value,
}
#[derive(Serialize, Deserialize)]
struct Record {
    schema_version: u32,
    request_id: String,
    payload: Value,
    phase: String,
    #[serde(default)]
    value: Option<Value>,
}
fn io_error(error: impl std::fmt::Display) -> String {
    format!("PLUGIN_JOURNAL_ERROR: {error}")
}

/// Acquires a dedicated nonblocking lock and writes the pending marker before Fresh is returned.
pub fn begin(
    data_dir: &Path,
    request_id: &str,
    payload: &Value,
) -> Result<(Ticket, State), String> {
    if request_id.trim().is_empty() || request_id.len() > 200 {
        return Err("INVALID_REQUEST: request_id must contain 1 to 200 characters.".into());
    }
    let directory = data_dir.join("plugin-journal");
    fs::create_dir_all(&directory).map_err(io_error)?;
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).map_err(io_error)?;
    let digest = format!("{:x}", Sha256::digest(request_id.as_bytes()));
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(directory.join(format!("{digest}.lock")))
        .map_err(io_error)?;
    match lock.try_lock_exclusive() {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
            return Err(
                "PLUGIN_REQUEST_IN_PROGRESS: Another process is handling this request.".into(),
            )
        }
        Err(e) => return Err(io_error(e)),
    }
    let path = directory.join(format!("{digest}.json"));
    let ticket = Ticket {
        _lock: lock,
        path,
        request_id: request_id.into(),
        payload: payload.clone(),
    };
    let mut bytes = Vec::new();
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&ticket.path);
    let record = match file {
        Ok(mut file) => {
            // This private journal is written by Ticket::store without a size cap.
            // Read the complete record so every successfully stored response can
            // be replayed with its original meaning, including large core results.
            file.read_to_end(&mut bytes).map_err(io_error)?;
            Some(serde_json::from_slice::<Record>(&bytes).map_err(io_error)?)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(io_error(e)),
    };
    let state = if let Some(record) = record {
        if record.schema_version != 1 {
            return Err(io_error("Unsupported request journal version."));
        }
        if record.request_id != request_id || record.payload != *payload {
            return Err(
                "REQUEST_ID_CONFLICT: A request_id cannot be reused for a different request."
                    .into(),
            );
        }
        match (record.phase.as_str(),record.value) {
            ("prepared",Some(value))=>State::Prepared(value),
            ("complete",Some(value))=>State::Complete(value),
            ("pending",_)=>return Err("PLUGIN_RESULT_UNCERTAIN: The previous external execution has an uncertain result. Check the external service before using a new request.".into()),
            _=>return Err(io_error("Invalid request journal state.")),
        }
    } else {
        ticket.store("pending", None)?;
        State::Fresh
    };
    Ok((ticket, state))
}
impl Ticket {
    /// Persists the plugin's original response before any returned core mutation is applied.
    pub fn prepare(&self, value: &Value) -> Result<(), String> {
        self.store("prepared", Some(value.clone()))
    }
    /// Persists the full CLI response; a later retry returns this exact value.
    pub fn complete(&self, value: &Value) -> Result<(), String> {
        self.store("complete", Some(value.clone()))
    }
    fn store(&self, phase: &str, value: Option<Value>) -> Result<(), String> {
        let record = Record {
            schema_version: 1,
            request_id: self.request_id.clone(),
            payload: self.payload.clone(),
            phase: phase.into(),
            value,
        };
        let temporary = self
            .path
            .with_extension(format!("tmp-{}", uuid::Uuid::new_v4()));
        let result = (|| {
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(&temporary)
                .map_err(io_error)?;
            file.write_all(&serde_json::to_vec(&record).map_err(io_error)?)
                .map_err(io_error)?;
            file.sync_all().map_err(io_error)?;
            fs::rename(&temporary, &self.path).map_err(io_error)?;
            // Persist the rename so a successful external action cannot lose its completion marker on power loss.
            File::open(self.path.parent().unwrap())
                .map_err(io_error)?
                .sync_all()
                .map_err(io_error)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn dir() -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("workboard-journal-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        path
    }
    #[test]
    fn completed_retry_and_payload_conflict() {
        let dir = dir();
        let payload = json!({"method":"plugin.run","params":{"x":1}});
        let (ticket, state) = begin(&dir, "request/one", &payload).unwrap();
        assert_eq!(state, State::Fresh);
        let response = json!({"ok":true,"result":{"id":"original"}});
        ticket.complete(&response).unwrap();
        drop(ticket);
        let (ticket, state) = begin(&dir, "request/one", &payload).unwrap();
        assert_eq!(state, State::Complete(response));
        drop(ticket);
        assert!(begin(&dir, "request/one", &json!({"method":"other"}))
            .err()
            .unwrap()
            .starts_with("REQUEST_ID_CONFLICT:"));
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn completed_response_larger_than_64_mib_replays_without_loss() {
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let dir = dir();
        let _cleanup = Cleanup(dir.clone());
        let payload =
            json!({"id":"workspace","method":"events.pull","params":{"task_id":"large-task"}});
        let (ticket, state) = begin(&dir, "large-complete", &payload).unwrap();
        assert_eq!(state, State::Fresh);
        let previous_read_limit = 64 * 1024 * 1024;
        let response = json!({"ok":true,"result":{"applied":[{"task":{
            "id":"large-task","revision":7,"goal":"x".repeat(previous_read_limit + 1)
        }}]}});
        ticket.complete(&response).unwrap();
        assert!(fs::metadata(&ticket.path).unwrap().len() > previous_read_limit as u64);
        drop(ticket);

        let (_ticket, state) = begin(&dir, "large-complete", &payload).unwrap();
        let State::Complete(replayed) = state else {
            panic!("A successfully stored complete record must remain complete on retry");
        };
        assert!(
            replayed == response,
            "The full stored response must survive replay unchanged"
        );
    }
    #[test]
    fn pending_after_crash_never_repeats_external_action() {
        let dir = dir();
        let (ticket, _) = begin(&dir, "pending", &json!({})).unwrap();
        drop(ticket);
        assert!(begin(&dir, "pending", &json!({}))
            .err()
            .unwrap()
            .starts_with("PLUGIN_RESULT_UNCERTAIN:"));
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn prepared_result_remains_stable_for_core_retries() {
        let dir = dir();
        let payload = json!({"id":"amem","method":"attach"});
        let (ticket, _) = begin(&dir, "prepared", &payload).unwrap();
        let response = json!({"requests":[{"params":{"verified_at":"original-time"}}]});
        ticket.prepare(&response).unwrap();
        drop(ticket);
        let (ticket, state) = begin(&dir, "prepared", &payload).unwrap();
        assert_eq!(state, State::Prepared(response));
        ticket.complete(&json!({"ok":true})).unwrap();
        drop(ticket);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn concurrent_request_is_rejected_without_waiting() {
        let dir = dir();
        let (ticket, _) = begin(&dir, "one", &json!({})).unwrap();
        assert!(begin(&dir, "one", &json!({}))
            .err()
            .unwrap()
            .starts_with("PLUGIN_REQUEST_IN_PROGRESS:"));
        drop(ticket);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn unusual_ids_do_not_alias_and_permissions_are_private() {
        let dir = dir();
        let (first, _) = begin(&dir, "a/b", &json!({})).unwrap();
        let (second, _) = begin(&dir, "a_b", &json!({})).unwrap();
        assert_ne!(first.path, second.path);
        assert_eq!(
            fs::metadata(&first.path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(dir.join("plugin-journal"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        drop(first);
        drop(second);
        fs::remove_dir_all(dir).unwrap();
    }
}
