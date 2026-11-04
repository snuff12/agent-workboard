//! Append-only observations of attached sources. Source access stays in optional plugins.
use super::*;

pub(super) fn migrate(c: &Connection) -> Result<(), ApiError> {
    c.execute_batch(
        "BEGIN IMMEDIATE;
CREATE TABLE evidence_verifications (
 id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id),
 artifact_id TEXT NOT NULL REFERENCES artifacts(id), request_id TEXT NOT NULL UNIQUE,
 checked_at TEXT NOT NULL, recorded_at TEXT NOT NULL, data TEXT NOT NULL);
CREATE INDEX evidence_verifications_artifact ON evidence_verifications(artifact_id,checked_at);
PRAGMA user_version=9;
COMMIT;",
    )?;
    Ok(())
}

pub(super) fn source(a: &Artifact) -> Value {
    json!({"path":a.path,"provider":a.provider.as_deref().map(Value::from).unwrap_or_else(||a.metadata["provider"].clone()),
        "locator":a.locator.as_deref().map(Value::from).unwrap_or_else(||a.metadata["locator"].clone()),
        "ref":a.metadata["ref"],"collection":a.metadata["collection"],
        "source_sha256":a.metadata["source_sha256"],"scope":a.metadata["scope"]})
}

pub(super) fn list(
    c: &Connection,
    task: Option<&str>,
    artifact: Option<&str>,
) -> Result<Vec<Value>, ApiError> {
    let mut st = c.prepare("SELECT data FROM evidence_verifications WHERE (?1 IS NULL OR task_id=?1) AND (?2 IS NULL OR artifact_id=?2) ORDER BY checked_at DESC,rowid DESC")?;
    let rows = st.query_map(params![task, artifact], |row| row.get::<_, String>(0))?;
    rows.map(|row| Ok(serde_json::from_str(&row?)?)).collect()
}

pub(super) fn record_check(c: &Connection, r: &Request, task: &Task) -> Result<Value, ApiError> {
    let p = &r.params;
    let artifact_id = required(p, "artifact_id")?;
    let a = all_artifacts(c, Some(&task.id))?
        .into_iter()
        .find(|a| a.id == artifact_id)
        .ok_or_else(|| {
            ApiError::new(
                "EVIDENCE_SOURCE_CONFLICT",
                "The artifact no longer belongs to this task",
            )
        })?;
    let original = source(&a);
    if p["source"] != original {
        return Err(ApiError::new(
            "EVIDENCE_SOURCE_CONFLICT",
            "The observation does not match the attached source generation",
        ));
    }
    let status = required(p, "status")?;
    if !["current", "changed", "unreadable", "integration_failure"].contains(&status) {
        return Err(invalid(
            "status must be current, changed, unreadable or integration_failure",
        ));
    }
    let checked_at = chrono::DateTime::parse_from_rfc3339(required(p, "checked_at")?)
        .map_err(|_| invalid("checked_at must be an RFC 3339 timestamp"))?
        .with_timezone(&Utc)
        .to_rfc3339_opts(SecondsFormat::Millis, true);
    let observed = p.get("observed").cloned().unwrap_or(Value::Null);
    if ["current", "changed"].contains(&status) {
        required(&observed, "path")?;
        required(&observed, "collection")?;
        required(&observed, "source_sha256")?;
        let matches = ["path", "collection", "source_sha256"]
            .iter()
            .all(|key| observed[key] == original[key]);
        if matches != (status == "current") {
            return Err(invalid(
                "The source verdict does not match the observed identity and hash",
            ));
        }
    } else if !observed.is_null() {
        return Err(invalid(
            "An incomplete source read must not include an observed identity",
        ));
    }
    let detail = string(p, "detail")?;
    let error_code = optional(p, "error_code")?;
    if detail.chars().count() > 2000 || error_code.as_ref().is_some_and(|s| s.len() > 100) {
        return Err(invalid("The diagnostic is too long"));
    }
    let actor = optional(p, "agent_id")?
        .or(optional(p, "actor")?)
        .unwrap_or_else(|| "user".into());
    let data = json!({"id":id(),"task_id":task.id,"artifact_id":a.id,"request_id":r.request_id,
        "payload_fingerprint":serde_json::to_string(&json!({"method":r.method,"params":p}))?,
        "actor":actor,"checked_at":checked_at,"recorded_at":now(),"source":original,
        "status":status,"observed":observed,"detail":detail,"error_code":error_code});
    c.execute("INSERT INTO evidence_verifications(id,task_id,artifact_id,request_id,checked_at,recorded_at,data) VALUES (?1,?2,?3,?4,?5,?6,?7)",
        params![data["id"].as_str(),task.id,a.id,r.request_id,checked_at,data["recorded_at"].as_str(),data.to_string()])?;
    Ok(data)
}
