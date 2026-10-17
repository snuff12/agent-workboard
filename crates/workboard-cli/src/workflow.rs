//! Friendly commands for local planning. Validation and all writes remain in the service.
use clap::{Args, Subcommand, ValueEnum};
use serde_json::{json, Value};
use std::path::PathBuf;

type Request = Result<(String, Value), String>;

#[derive(Args, Default)]
pub struct Filters {
    #[arg(long)]
    project: Option<String>,
    #[arg(long)]
    status: Option<String>,
    #[arg(long)]
    assignee: Option<String>,
    #[arg(long, num_args = 0..=1, default_missing_value = "true", help = "Only list tasks whose prerequisites are complete")]
    ready: Option<bool>,
    #[arg(long, num_args = 0..=1, default_missing_value = "true", help = "Only list blocked tasks")]
    blocked: Option<bool>,
    #[arg(
        long,
        help = "Tasks not updated for at least the specified number of days"
    )]
    stale_days: Option<u32>,
    #[arg(long)]
    query: Option<String>,
}

impl Filters {
    fn params(self) -> Value {
        let mut p = json!({});
        for (key, value) in [
            ("project_id", self.project.map(Value::from)),
            ("status", self.status.map(Value::from)),
            ("assignee", self.assignee.map(Value::from)),
            ("stale_days", self.stale_days.map(Value::from)),
            ("query", self.query.map(Value::from)),
        ] {
            if let Some(value) = value {
                p[key] = value;
            }
        }
        if let Some(ready) = self.ready {
            p["ready_only"] = json!(ready);
        }
        if let Some(blocked) = self.blocked {
            p["blocked_only"] = json!(blocked);
        }
        p
    }
}

#[derive(Args)]
pub struct TaskList {
    #[command(flatten)]
    filters: Filters,
    #[arg(long)]
    parent: Option<String>,
    #[arg(
        long,
        help = "Saved view ID. Explicit filters override the saved filters"
    )]
    view: Option<String>,
}

impl TaskList {
    pub fn request(mut self, ready: bool) -> Request {
        if ready {
            self.filters.ready = Some(true);
        }
        let mut p = self.filters.params();
        if let Some(parent) = self.parent {
            p["parent_id"] = json!(parent);
        }
        if let Some(view) = self.view {
            p["view_id"] = json!(view);
        }
        Ok(("task.list".into(), p))
    }
}

#[derive(Subcommand)]
pub enum DependencyCommand {
    #[command(about = "Add a prerequisite")]
    Add {
        task_id: String,
        #[arg(long)]
        on: String,
    },
    #[command(about = "Remove a prerequisite")]
    Remove {
        task_id: String,
        #[arg(long)]
        on: String,
    },
}

impl DependencyCommand {
    pub fn request(self) -> Request {
        let (method, task_id, on) = match self {
            Self::Add { task_id, on } => ("task.dependency.add", task_id, on),
            Self::Remove { task_id, on } => ("task.dependency.remove", task_id, on),
        };
        Ok((method.into(), json!({"task_id":task_id,"depends_on_id":on})))
    }
}

#[derive(Subcommand)]
pub enum ChecklistCommand {
    Add {
        task_id: String,
        #[arg(long)]
        text: String,
        #[arg(long, help = "Add an optional checklist item")]
        optional: bool,
    },
    Update {
        task_id: String,
        item_id: String,
        #[arg(long)]
        text: Option<String>,
        #[arg(long, action = clap::ArgAction::Set)]
        required: Option<bool>,
        #[arg(long, action = clap::ArgAction::Set)]
        checked: Option<bool>,
        #[arg(long, conflicts_with = "clear_evidence")]
        evidence: Option<String>,
        #[arg(long)]
        clear_evidence: bool,
    },
    Check {
        task_id: String,
        item_id: String,
        #[arg(long)]
        evidence: Option<String>,
    },
    Uncheck {
        task_id: String,
        item_id: String,
    },
    Remove {
        task_id: String,
        item_id: String,
    },
}

impl ChecklistCommand {
    pub fn request(self) -> Request {
        let (method, p) = match self {
            Self::Add {
                task_id,
                text,
                optional,
            } => (
                "task.checklist.add",
                json!({"task_id":task_id,"text":text,"required":!optional}),
            ),
            Self::Update {
                task_id,
                item_id,
                text,
                required,
                checked,
                evidence,
                clear_evidence,
            } => {
                let mut p = json!({"task_id":task_id,"item_id":item_id});
                if let Some(v) = text {
                    p["text"] = json!(v);
                }
                if let Some(v) = required {
                    p["required"] = json!(v);
                }
                if let Some(v) = checked {
                    p["checked"] = json!(v);
                }
                if let Some(v) = evidence {
                    p["evidence"] = json!(v);
                }
                if clear_evidence {
                    p["evidence"] = Value::Null;
                }
                ("task.checklist.update", p)
            }
            Self::Check {
                task_id,
                item_id,
                evidence,
            } => {
                let mut p = json!({"task_id":task_id,"item_id":item_id,"checked":true});
                if let Some(v) = evidence {
                    p["evidence"] = json!(v);
                }
                ("task.checklist.update", p)
            }
            Self::Uncheck { task_id, item_id } => (
                "task.checklist.update",
                json!({"task_id":task_id,"item_id":item_id,"checked":false}),
            ),
            Self::Remove { task_id, item_id } => (
                "task.checklist.remove",
                json!({"task_id":task_id,"item_id":item_id}),
            ),
        };
        Ok((method.into(), p))
    }
}

#[derive(Clone, ValueEnum)]
pub enum Decision {
    Approve,
    RequestChanges,
    Reject,
}

#[derive(Args)]
pub struct ReviewDecision {
    task_id: String,
    #[arg(long, value_enum)]
    decision: Decision,
    #[arg(long)]
    summary: String,
    #[arg(long)]
    run: Option<String>,
    #[arg(long)]
    agent: Option<String>,
}

impl ReviewDecision {
    pub fn request(self) -> Request {
        let decision = match self.decision {
            Decision::Approve => "approve",
            Decision::RequestChanges => "request_changes",
            Decision::Reject => "reject",
        };
        let mut p = json!({"task_id":self.task_id,"decision":decision,"summary":self.summary});
        if let Some(v) = self.run {
            p["run_id"] = json!(v);
        }
        if let Some(v) = self.agent {
            p["agent_id"] = json!(v);
        }
        Ok(("task.review.decide".into(), p))
    }
}

#[derive(Args)]
pub struct SchedulePreview {
    #[arg(help = "Task being edited. Its existing schedule is excluded from conflicts")]
    task_id: Option<String>,
    #[arg(long, alias = "starts")]
    scheduled_start: String,
    #[arg(long, alias = "ends")]
    scheduled_end: String,
    #[arg(long)]
    time_zone: String,
}

impl SchedulePreview {
    pub fn request(self) -> Request {
        let mut p = json!({"scheduled_start":self.scheduled_start,"scheduled_end":self.scheduled_end,"time_zone":self.time_zone});
        if let Some(v) = self.task_id {
            p["task_id"] = json!(v);
        }
        Ok(("task.schedule.preview".into(), p))
    }
}

#[derive(Subcommand)]
pub enum TemplateCommand {
    List,
    Save {
        #[arg(long)]
        id: Option<String>,
        #[arg(long)]
        name: String,
        #[arg(
            long,
            required_unless_present = "from_task",
            conflicts_with = "from_task",
            help = "Template definition JSON file containing title, children, and other fields"
        )]
        file: Option<PathBuf>,
        #[arg(
            long,
            conflicts_with = "file",
            help = "Save this task and its subtasks as a template"
        )]
        from_task: Option<String>,
    },
    Delete {
        template_id: String,
    },
    Apply {
        template_id: String,
        #[arg(long)]
        project: String,
        #[arg(long, default_value = "inherit", value_parser = ["inherit", "automatic", "manual"], help = "Automation mode for every task created from this template")]
        automation: String,
        #[arg(long, help = "Process preset ID or auto for agent selection")]
        process_preset: Option<String>,
        #[arg(long)]
        preset_reason: Option<String>,
        #[arg(long)]
        parent: Option<String>,
        #[arg(long)]
        title: Option<String>,
        #[arg(
            long,
            help = "Status of every created task: backlog or todo. Defaults to todo"
        )]
        status: Option<String>,
    },
}

impl TemplateCommand {
    pub fn request(self) -> Request {
        let (method, p) = match self {
            Self::List => ("template.list", json!({})),
            Self::Save {
                id,
                name,
                file,
                from_task,
            } => {
                let mut p = json!({"name":name});
                if let Some(file) = file {
                    let bytes = std::fs::read(&file).map_err(|e| {
                        format!("Could not read the template file: {}: {e}", file.display())
                    })?;
                    let definition: Value = serde_json::from_slice(&bytes)
                        .map_err(|e| format!("Invalid template JSON: {e}"))?;
                    if !definition.is_object() {
                        return Err("The template definition must be a JSON object".into());
                    }
                    p["definition"] = definition;
                } else if let Some(task_id) = from_task {
                    p["task_id"] = json!(task_id);
                } else {
                    return Err("--file or --from-task is required".into());
                }
                if let Some(v) = id {
                    p["id"] = json!(v);
                }
                ("template.save", p)
            }
            Self::Delete { template_id } => ("template.delete", json!({"template_id":template_id})),
            Self::Apply {
                template_id,
                project,
                automation,
                process_preset,
                preset_reason,
                parent,
                title,
                status,
            } => {
                let mut p = json!({"template_id":template_id,"project_id":project,"automation_mode":automation});
                if let Some(v) = process_preset {
                    p["process_preset"] = json!(v);
                }
                if let Some(v) = preset_reason {
                    p["preset_reason"] = json!(v);
                }
                if let Some(v) = parent {
                    p["parent_id"] = json!(v);
                }
                if let Some(v) = title {
                    p["title"] = json!(v);
                }
                if let Some(v) = status {
                    p["status"] = json!(v);
                }
                ("template.apply", p)
            }
        };
        Ok((method.into(), p))
    }
}

#[derive(Subcommand)]
pub enum InboxCommand {
    List {
        #[arg(long)]
        status: Option<String>,
    },
    Capture {
        #[arg(long)]
        title: String,
        #[arg(long)]
        source: Option<String>,
        #[arg(long)]
        note: Option<String>,
    },
    Promote {
        item_id: String,
        #[arg(long)]
        project: String,
        #[arg(long)]
        parent: Option<String>,
        #[arg(long)]
        title: Option<String>,
        #[arg(
            long,
            help = "Status of the new task: backlog or todo. Defaults to todo"
        )]
        status: Option<String>,
    },
    Dismiss {
        item_id: String,
    },
}

impl InboxCommand {
    pub fn request(self) -> Request {
        let (method, p) = match self {
            Self::List { status } => {
                let mut p = json!({});
                if let Some(v) = status {
                    p["status"] = json!(v);
                }
                ("inbox.list", p)
            }
            Self::Capture {
                title,
                source,
                note,
            } => {
                let mut p = json!({"title":title});
                if let Some(v) = source {
                    p["source"] = json!(v);
                }
                if let Some(v) = note {
                    p["note"] = json!(v);
                }
                ("inbox.capture", p)
            }
            Self::Promote {
                item_id,
                project,
                parent,
                title,
                status,
            } => {
                let mut p = json!({"item_id":item_id,"project_id":project});
                if let Some(v) = parent {
                    p["parent_id"] = json!(v);
                }
                if let Some(v) = title {
                    p["title"] = json!(v);
                }
                if let Some(v) = status {
                    p["status"] = json!(v);
                }
                ("inbox.promote", p)
            }
            Self::Dismiss { item_id } => ("inbox.dismiss", json!({"item_id":item_id})),
        };
        Ok((method.into(), p))
    }
}

#[derive(Clone, ValueEnum)]
pub enum Layout {
    Board,
    List,
    Week,
}

#[derive(Subcommand)]
pub enum ViewCommand {
    List,
    Save {
        #[arg(long)]
        id: Option<String>,
        #[arg(long)]
        name: String,
        #[command(flatten)]
        filters: Filters,
        #[arg(long, value_enum, default_value = "board")]
        layout: Layout,
    },
    Delete {
        view_id: String,
    },
}

impl ViewCommand {
    pub fn request(self) -> Request {
        let (method, p) = match self {
            Self::List => ("view.list", json!({})),
            Self::Save {
                id,
                name,
                filters,
                layout,
            } => {
                let layout = match layout {
                    Layout::Board => "board",
                    Layout::List => "list",
                    Layout::Week => "week",
                };
                let mut p = json!({"name":name,"filters":filters.params(),"layout":layout});
                if let Some(v) = id {
                    p["id"] = json!(v);
                }
                ("view.save", p)
            }
            Self::Delete { view_id } => ("view.delete", json!({"view_id":view_id})),
        };
        Ok((method.into(), p))
    }
}
