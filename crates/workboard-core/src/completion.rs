//! Completion is a status transition, not the last edit to a task.
use super::*;

pub(super) fn migrate(conn: &Connection) -> Result<(), ApiError> {
    conn.execute_batch(r#"
BEGIN IMMEDIATE;
ALTER TABLE tasks ADD COLUMN completed_at TEXT;
-- Metadata-only updates must not re-enter the external-content search index trigger.
DROP TRIGGER task_search_update;
CREATE TRIGGER task_search_update AFTER UPDATE OF title,goal,completion_criteria,next_action ON tasks BEGIN
 INSERT INTO task_fts(task_fts,rowid,title,goal,completion_criteria,next_action) VALUES('delete',old.rowid,old.title,old.goal,old.completion_criteria,old.next_action);
 INSERT INTO task_fts(rowid,title,goal,completion_criteria,next_action) VALUES (new.rowid,new.title,new.goal,new.completion_criteria,new.next_action);
END;
-- Recover known completion transitions, excluding later edits to already completed cards.
WITH states AS (
 SELECT task_id,sequence,created_at,kind,coalesce(json_extract(data,'$.task.status'),json_extract(data,'$.status')) AS status,
        lag(coalesce(json_extract(data,'$.task.status'),json_extract(data,'$.status'))) OVER (PARTITION BY task_id ORDER BY sequence) AS previous
 FROM events WHERE task_id IS NOT NULL AND json_valid(data)
 AND (json_type(data,'$.task.status')='text' OR json_type(data,'$.status')='text')
), completions AS (
 SELECT task_id,created_at,sequence FROM states WHERE status='done'
 AND (previous<>'done' OR (previous IS NULL AND kind='task.complete'))
)
UPDATE tasks SET completed_at=(SELECT created_at FROM completions WHERE task_id=tasks.id ORDER BY sequence DESC LIMIT 1)
 WHERE status='done';
-- Missing historical evidence remains unknown. Do not invent a completion time from updated_at.
CREATE TRIGGER task_completion_transition AFTER UPDATE OF status ON tasks
WHEN NEW.status<>OLD.status
BEGIN
 UPDATE tasks SET completed_at=CASE WHEN NEW.status='done' THEN NEW.updated_at ELSE NULL END WHERE id=NEW.id;
END;
PRAGMA user_version=8;
COMMIT;
"#)?;
    Ok(())
}
