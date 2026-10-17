import SwiftUI
import AppKit

struct TaskAutomationSection: View {
    @EnvironmentObject private var store: BoardStore
    let detail: TaskDetail
    @State private var configuring = false
    @State private var resolving = false
    @State private var disabling = false
    private var automation: TaskAutomation? { detail.automation }
    var body: some View {
        DetailSection(title: "Automation", symbol: "gearshape.2") {
            VStack(alignment: .leading, spacing: 10) {
                if let automation {
                    Text(automation.title).font(.callout.weight(.medium))
                    if let name = automation.presetName {
                        Text(name).font(.caption.weight(.medium))
                        if let reason = automation.raw["process"]["selection_reason"].string { Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        DisclosureGroup("Process stages") {
                            ForEach(Array(automation.raw["process"]["preset"]["steps"].array.enumerated()), id: \.offset) { row in
                                Text("\(row.offset + 1). \(row.element["title"].string ?? "Stage")").font(.caption)
                            }
                        }.font(.caption)
                    }
                    if let message = automation.raw["message"].string, !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    HStack {
                        if automation.state == "armed" { Button("Start") { action("start") }.disabled(detail.task.status.isClosed) }
                        if automation.state == "running" { Button("Pause after stage") { action("pause") } }
                        if ["paused", "blocked"].contains(automation.state) && automation.raw["limit_reached"].bool != true { Button("Resume") { action("resume") } }
                        if ["armed", "waiting", "disabled", "completed", "canceled"].contains(automation.state) { Button("Configure…") { configuring = true }.disabled(automation.needsExitConfirmation || store.orcaPlugin == nil) }
                        if !["disabled", "completed", "canceled"].contains(automation.state) { Button("Disable…") { disabling = true } }
                    }.controlSize(.small).disabled(store.isMutating)
                    if ["paused", "blocked", "disabled", "canceled"].contains(automation.state) && automation.needsExitConfirmation {
                        Button("Verify agent exit…") { resolving = true }.controlSize(.small)
                    }
                    if let revision = automation.raw["inherited_revision"].int { Text("Inherited project defaults, version \(revision)").font(.caption).foregroundStyle(.secondary) }
                    DisclosureGroup("Status rules (\(automation.raw["configuration"]["rules"].array.count))") {
                        ForEach(Array(automation.raw["configuration"]["rules"].array.enumerated()), id: \.offset) { row in
                            Text("\(WorkStatus(rawValue: row.element["status"].string ?? "")?.title ?? "Status") → \(row.element["action"].string == "development" ? "Development workflow" : TaskAutomation.stageTitle(row.element["stage"].string ?? ""))").font(.caption)
                        }
                    }
                    if !automation.attempts.isEmpty {
                        DisclosureGroup("Stage history (\(automation.attempts.count))") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(automation.attempts.enumerated()), id: \.offset) { row in
                                    let attempt = row.element
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(row.offset + 1). \(attempt["settings"]["step_title"].string ?? TaskAutomation.stageTitle(attempt["stage"].string ?? "")) · \(attempt["state"].string ?? "")").fontWeight(.medium)
                                        if !attempt["settings"]["skills"].array.isEmpty { Text("Skills: " + attempt["settings"]["skills"].array.compactMap(\.string).joined(separator: ", ")).textSelection(.enabled) }
                                        if let prompt = attempt["settings"]["prompt"].string, !prompt.isEmpty { Text("Prompt: " + prompt).textSelection(.enabled) }
                                        if let instructions = attempt["settings"]["instructions"].string, !instructions.isEmpty { Text("Instructions: " + instructions).textSelection(.enabled) }
                                        if let summary = attempt["result"]["summary"].string { Text(summary).textSelection(.enabled) }
                                        ForEach(Array(attempt["result"]["evidence"].array.enumerated()), id: \.offset) { evidence in Text(evidence.element.string ?? "").foregroundStyle(.secondary).textSelection(.enabled) }
                                        if let terminal = attempt["receipt"]["terminal"]["handle"].string { Text("Orca terminal: \(terminal)").foregroundStyle(.secondary).textSelection(.enabled) }
                                        if let version = attempt["result"]["source_version"].string { Text(version).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
                                    }
                                }
                            }.font(.caption).padding(.top, 8)
                        }.font(.caption)
                    }
                } else {
                    Text("Choose a process preset for this task. Final approval stays with you.").font(.caption).foregroundStyle(.secondary)
                    Button("Configure automation…") { configuring = true }.controlSize(.small).disabled(detail.task.status.isClosed)
                }
            }
        }
        .sheet(isPresented: $configuring) { AutomationConfigurationView(detail: detail) }
        .sheet(isPresented: $resolving) { AutomationExitConfirmationView(detail: detail) }
        .confirmationDialog("Disable this workflow?", isPresented: $disabling) {
            Button("Disable automation", role: .destructive) { action("disable") }
        } message: { Text("No further stage will start and late results will be refused. An active agent may continue; inspect it in Orca before restarting.") }
    }
    private func action(_ name: String) {
        let context = store.workflowContext
        var fields: [String: JSONValue] = [:]
        if let automation { fields["expected_automation_revision"] = .number(Double(automation.revision)) }
        Task { _ = await store.taskWorkflowMutation("automation.\(name)", task: detail.task, fields: fields, context: context) }
    }
}

struct AutomationStageDraft: Identifiable {
    var id: String
    var agent = ""
    var skills = ""
    var prompt = ""
    var instructions = ""
    init(id: String, value: JSONValue = .null) {
        self.id = id; agent = value["agent"].string ?? ""; skills = value["skills"].array.compactMap(\.string).joined(separator: "\n")
        prompt = value["prompt"].string ?? ""; instructions = value["instructions"].string ?? ""
    }
    var json: JSONValue { .object(["agent": .string(agent), "skills": .array(skills.split(separator: "\n").map { .string(String($0).trimmingCharacters(in: .whitespaces)) }.filter { $0.string?.isEmpty == false }), "prompt": .string(prompt), "instructions": .string(instructions)]) }
}
struct AutomationRuleDraft: Identifiable {
    var id: String
    var status: String
    var action: String
    var stage: String
    var settings: AutomationStageDraft
    init(_ value: JSONValue) {
        id = value["id"].string ?? UUID().uuidString; status = value["status"].string ?? "in_progress"
        action = value["action"].string ?? "development"; stage = value["stage"].string ?? "preflight"
        settings = AutomationStageDraft(id: id, value: value)
    }
    var json: JSONValue { var fields = settings.json.object; fields["id"] = .string(id); fields["status"] = .string(status); fields["action"] = .string(action); fields["stage"] = .string(stage); return .object(fields) }
}
struct AutomationStageFields: View {
    @Binding var draft: AutomationStageDraft
    var body: some View {
        Picker("Agent", selection: $draft.agent) { Text("Use workflow agent").tag(""); Text("Codex").tag("codex"); Text("Claude").tag("claude") }
        TextField("Required skills: one name or SKILL.md path per line", text: $draft.skills, axis: .vertical).lineLimit(2...5)
        TextField("Prompt", text: $draft.prompt, axis: .vertical).lineLimit(3...8)
        TextField("Instructions", text: $draft.instructions, axis: .vertical).lineLimit(3...8)
    }
}
struct AutomationConfigurationView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    var detail: TaskDetail? = nil
    var project: BoardProject? = nil
    @StateObject private var plugins = PluginStore()
    @State private var worktrees: [JSONValue] = []
    @State private var worktree = ""
    @State private var agent = "codex"
    @State private var reviewer = "codex"
    @State private var reworks = 2
    @State private var minutes = 30
    @State private var instructions = ""
    @State private var enabled = true
    @State private var processPreset = "standard"
    @State private var allowedPresets: [String] = []
    @State private var showingPresets = false
    @State private var defaultsRevision = 0
    @State private var rules: [AutomationRuleDraft] = []
    @State private var stages: [AutomationStageDraft] = []
    @State private var context: WorkflowEditContext?
    @State private var loaded = false
    private let stageIDs = ["preflight", "plan", "work", "verify", "review", "rework", "release"]
    private var duplicates: Bool { Set(rules.map(\.status)).count != rules.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(project == nil ? "Task automation" : "Project automation defaults").font(.title3.weight(.semibold))
            Text(project == nil ? "A matching status change starts its rule. Each stage uses a fresh agent session." : "Apply this configuration to new tasks and subtasks. Existing tasks keep their own configuration.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Form {
                    if project != nil { Toggle("Apply defaults to new tasks", isOn: $enabled) }
                    Section("Process") {
                        ProcessPresetPicker(selection: $processPreset, presets: store.processPresets, includeDefault: false)
                        if processPreset == "auto" {
                            Text("The agent chooses among these presets and records a reason. Leave all unchecked to allow every preset.").font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(store.processPresets.enumerated()), id: \.offset) { row in
                                let preset = row.element
                                if let id = preset["id"].string {
                                    Toggle(preset["name"].string ?? id, isOn: Binding(get: { allowedPresets.contains(id) }, set: { value in if value { allowedPresets.append(id) } else { allowedPresets.removeAll { $0 == id } } }))
                                }
                            }
                        }
                        Button("Manage process presets…") { showingPresets = true }
                    }
                    Picker("Worktree", selection: $worktree) {
                        Text("Choose a worktree").tag("")
                        if !worktree.isEmpty && !worktrees.contains(where: { $0["id"].string == worktree }) { Text(worktree).tag(worktree) }
                        ForEach(Array(worktrees.enumerated()), id: \.offset) { row in Text(row.element["title"].string ?? row.element["path"].string ?? "Worktree").tag(row.element["id"].string ?? "") }
                    }
                    Picker("Implementation agent", selection: $agent) { Text("Codex").tag("codex"); Text("Claude").tag("claude") }
                    Picker("Review agent", selection: $reviewer) { Text("Codex").tag("codex"); Text("Claude").tag("claude") }
                    Stepper("Maximum rework cycles: \(reworks)", value: $reworks, in: 0...10)
                    Stepper("Stage deadline: \(minutes) minutes", value: $minutes, in: 1...1440)
                    TextField("Workflow instructions", text: $instructions, axis: .vertical).lineLimit(2...5)
                    Section("Status rules") {
                        Text("One rule per status. A single stage preserves the card's column and waits for the next status change.").font(.caption).foregroundStyle(.secondary)
                        ForEach($rules) { $rule in
                            DisclosureGroup("\(WorkStatus(rawValue: rule.status)?.title ?? rule.status) → \(rule.action == "development" ? "Development workflow" : TaskAutomation.stageTitle(rule.stage))") {
                                Picker("When moved to", selection: $rule.status) { ForEach(WorkStatus.allCases) { Text($0.title).tag($0.rawValue) } }
                                Picker("Run", selection: $rule.action) { Text("Development workflow").tag("development"); Text("Single stage").tag("stage") }
                                if rule.action == "stage" { stagePicker(selection: $rule.stage) }
                                if rule.action == "development" && rule.status != "in_progress" { Text("Development workflows require In Progress.").foregroundStyle(.red).font(.caption) }
                                AutomationStageFields(draft: $rule.settings)
                                Button("Remove rule", role: .destructive) { rules.removeAll { $0.id == rule.id } }
                            }
                        }
                        Button("Add status rule") {
                            let status = WorkStatus.allCases.first { candidate in !rules.contains { $0.status == candidate.rawValue } }?.rawValue ?? "review"
                            rules.append(AutomationRuleDraft(.object(["status": .string(status), "action": .string("stage"), "stage": .string(status == "review" ? "review" : "preflight")])))
                        }.disabled(rules.count >= 6)
                        if duplicates { Text("Choose a different status for each rule.").font(.caption).foregroundStyle(.red) }
                    }
                    Section("Development stage overrides") {
                        Text("Optional settings override the rule for this stage. Leave empty to use the rule settings.").font(.caption).foregroundStyle(.secondary)
                        ForEach($stages) { $stage in DisclosureGroup(TaskAutomation.stageTitle(stage.id)) { AutomationStageFields(draft: $stage) } }
                    }
                }.formStyle(.grouped)
            }
            if let error = plugins.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); if !loaded { ProgressView().controlSize(.small) }; Button(project == nil ? "Arm automation" : "Save defaults") { Task { await save() } }.disabled(!loaded || worktree.isEmpty || duplicates || rules.contains { $0.action == "development" && $0.status != "in_progress" } || store.isMutating || store.orcaPlugin?.methods.contains("automation.start") != true).accessibilityIdentifier("automation-save") }
        }.padding(24).frame(width: 650, height: 720).task { await load() }.onChange(of: store.workflowGeneration) { _, _ in dismiss() }.sheet(isPresented: $showingPresets) { ProcessPresetLibraryView() }
    }
    private func stagePicker(selection: Binding<String>) -> some View { Picker("Stage", selection: selection) { ForEach(stageIDs, id: \.self) { Text(TaskAutomation.stageTitle($0)).tag($0) } } }
    private func load() async {
        context = store.workflowContext
        var config = detail?.automation?.raw["configuration"] ?? .null
        if let project, let result = await plugins.call("automation.defaults.get", params: ["project_id": .string(project.id)], configuration: appearance.connection) {
            config = result["defaults"]["configuration"]; defaultsRevision = result["defaults"]["revision"].int ?? 0; enabled = result["defaults"]["enabled"].bool ?? true
        }
        worktree = config["resource_key"].string ?? TaskArtifact.orcaWorktrees(detail?.artifacts ?? []).first?.locator ?? ""
        processPreset = config == .null ? "standard" : (config["process_preset"].string ?? "")
        allowedPresets = config["allowed_presets"].array.compactMap(\.string)
        let params = config["params"]; agent = params["agent"].string ?? "codex"; reviewer = params["reviewer"].string ?? agent
        reworks = config["max_reworks"].int ?? 2; minutes = (config["timeout_seconds"].int ?? 1800) / 60; instructions = params["instructions"].string ?? ""
        let defaultRule: JSONValue = .object(["id": .string("start-development"), "status": .string("in_progress"), "action": .string("development")])
        rules = (config["rules"] == .null ? [defaultRule] : config["rules"].array).map(AutomationRuleDraft.init)
        stages = stageIDs.map { AutomationStageDraft(id: $0, value: config["stage_settings"][$0]) }
        if let plugin = store.orcaPlugin, let result = await plugins.run(plugin, method: "worktrees.list", params: ["limit": .number(100)], configuration: appearance.connection) { worktrees = result["worktrees"].array }
        loaded = true
    }
    private func save() async {
        guard let context, store.isCurrentWorkflow(context) else { return }
        var overrides: [String: JSONValue] = [:]
        for stage in stages {
            var fields: [String: JSONValue] = [:]
            for (key, value) in stage.json.object where value != .string("") && value != .array([]) { fields[key] = value }
            if !fields.isEmpty { overrides[stage.id] = .object(fields) }
        }
        let config: JSONValue = .object(["plugin_id": .string("orca"), "method": .string("automation.start"), "resource_key": .string(worktree), "params": .object(["worktree_id": .string(worktree), "agent": .string(agent), "reviewer": .string(reviewer), "instructions": .string(instructions)]), "max_reworks": .number(Double(reworks)), "timeout_seconds": .number(Double(minutes * 60)), "rules": .array(rules.map(\.json)), "stage_settings": .object(overrides), "process_preset": processPreset.isEmpty ? .null : .string(processPreset), "allowed_presets": .array(allowedPresets.map(JSONValue.string))])
        if let project {
            if await store.workflowMutation("automation.defaults.set", params: ["project_id": .string(project.id), "configuration": config, "enabled": .bool(enabled), "expected_defaults_revision": .number(Double(defaultsRevision))], context: context) != nil { dismiss() }
        } else if let detail {
            var fields: [String: JSONValue] = ["configuration": config]
            if let automation = detail.automation { fields["expected_automation_revision"] = .number(Double(automation.revision)) }
            if await store.taskWorkflowMutation("automation.configure", task: detail.task, fields: fields, context: context) { dismiss() }
        }
    }
}

private struct AutomationExitConfirmationView: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    let detail: TaskDetail
    @State private var confirmed = false
    @State private var summary = ""
    @State private var context: WorkflowEditContext?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Verify agent exit").font(.title3.weight(.semibold))
            Text("Inspect the stage's Orca terminal and stop any remaining agent before confirming. This records your observation and allows an explicit retry; it does not stop a process.").font(.callout)
            Toggle("I verified that the previous agent has stopped", isOn: $confirmed)
            TextField("What did you check?", text: $summary, axis: .vertical).lineLimit(2...4)
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Record confirmation") { Task { await save() } }.disabled(!confirmed || summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMutating) }
        }.padding(24).frame(width: 480).onAppear { context = store.workflowContext }.onChange(of: store.workflowGeneration) { _, _ in dismiss() }
    }
    private func save() async {
        guard let context else { return }
        let fields: [String: JSONValue] = ["confirm_stopped": .bool(confirmed), "summary": .string(summary), "expected_automation_revision": .number(Double(detail.automation?.revision ?? 0))]
        if await store.taskWorkflowMutation("automation.resolve", task: detail.task, fields: fields, context: context) { dismiss() }
    }
}

extension BoardStore {
    @discardableResult func taskWorkflowMutation(_ method: String, task: BoardTask, fields: [String: JSONValue] = [:], context: WorkflowEditContext? = nil) async -> Bool {
        var params = fields
        params["task_id"] = .string(task.id); params["expected_revision"] = .number(Double(task.revision))
        return await workflowMutation(method, params: params, context: context) != nil
    }
}

struct TaskListView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    var body: some View {
        let rows = store.visibleTasks.filter { appearance.theme.showCompleted || !$0.status.isClosed }
        List(rows) { task in
            Button { Task { await store.openTask(task.id) } } label: {
                HStack(spacing: 12) {
                    Image(systemName: task.status.symbol).foregroundStyle(task.status.color).frame(width: 20)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.title).font(.callout.weight(.medium)).foregroundStyle(Color.primary)
                        HStack(spacing: 8) {
                            Text(store.projectName(for: task.projectID))
                            if task.parentID != nil { Label("Subtask", systemImage: "arrow.turn.down.right") }
                            if task.ready { Text("Ready").foregroundStyle(appearance.accent) }
                            if !task.blockedBy.isEmpty { Text("Waiting for \(task.blockedBy.count) prerequisites") }
                            if task.isStale(days: store.filters.staleDays ?? 14) && !task.status.isClosed { Label("No recent updates", systemImage: "clock") }
                        }.font(.caption2).foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    if let due = task.dueDate { Text(due, format: .dateTime.month().day()).font(.caption).foregroundStyle(task.isOverdue ? .red : .secondary) }
                    Text(task.assignee ?? "Unspecified").font(.caption).foregroundStyle(Color.secondary).frame(width: 90, alignment: .trailing)
                    Text(task.status.title).font(.caption).foregroundStyle(Color.secondary).frame(width: 70)
                }.padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain).contextMenu { Button("Delete…", role: .destructive) { store.requestDelete(task) }.disabled(store.isMutating) }.listRowBackground(store.selectedTaskID == task.id ? appearance.accent.opacity(0.08) : Color.clear)
        }.listStyle(.inset).overlay { if rows.isEmpty { ContentUnavailableView("No tasks match these filters", systemImage: "line.3.horizontal.decrease", description: Text("Change the filters or add a task.")) } }
    }
}

struct ViewFilterPanel: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    @State private var filters = TaskFilters()
    @State private var layout = "board"
    @State private var name = ""
    @State private var staleEnabled = false
    @State private var staleDays = 14
    @State private var deleting = false
    @State private var existing: SavedTaskView?
    @State private var context: WorkflowEditContext?
    private var currentFilters: TaskFilters { var value = filters; value.staleDays = staleEnabled ? staleDays : nil; return value }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkflowHeader(title: "Filters and saved views", subtitle: "Save frequently used filters and layouts together.")
            Form {
                Section {
                    Picker("Project", selection: $filters.projectID) { Text("All projects").tag(""); ForEach(store.projects) { Text($0.name).tag($0.id) } }
                    Picker("Status", selection: $filters.status) { Text("All statuses").tag(""); ForEach(WorkStatus.allCases) { Text($0.title).tag($0.rawValue) } }
                    Toggle("Unassigned only", isOn: $filters.unassignedOnly)
                    if !filters.unassignedOnly { TextField("Assignee name (exact match)", text: $filters.assignee) }
                    TextField("Search query", text: $filters.query)
                    Toggle("Ready tasks only", isOn: $filters.readyOnly)
                    Toggle("Blocked tasks only", isOn: $filters.blockedOnly)
                    Toggle("Stale tasks only", isOn: $staleEnabled)
                    if staleEnabled { Stepper("No changes for at least \(staleDays) days", value: $staleDays, in: 0...36500) }
                } header: { Text("Filters") }
                Section {
                    Picker("Display", selection: $layout) { Text("Kanban").tag("board"); Text("List").tag("list"); Text("Weekly planner").tag("week") }
                    TextField("Saved view name", text: $name)
                    if existing != nil { Button("Delete this saved view", role: .destructive) { deleting = true } }
                } header: { Text("Saved views") }
                if let error = store.actionError { Text(error).font(.caption).foregroundStyle(.red) }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply filters") { guard let context, store.isCurrentWorkflow(context) else { dismiss(); return }; store.selectedViewID = nil; store.filters = currentFilters; store.selectedLayout = layout; store.selectedProjectID = nil; store.searchText = ""; dismiss() }
                Button(existing == nil ? "Save view" : "Save changes") { Task { await save() } }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMutating)
            }.padding(20)
        }.frame(width: 530, height: 650).onAppear {
            guard context == nil else { return }
            context = store.workflowContext; existing = store.savedViews.first { $0.id == store.selectedViewID }
            filters = store.filters; layout = store.selectedLayout; staleEnabled = filters.staleDays != nil; staleDays = filters.staleDays ?? 14; name = existing?.name ?? ""; store.actionError = nil
        }.onChange(of: store.workflowGeneration) { _, _ in dismiss() }.confirmationDialog("Delete this saved view?", isPresented: $deleting) {
            Button("Delete view", role: .destructive) { Task { if let existing, let context, await store.workflowMutation("view.delete", params: ["view_id": .string(existing.id), "expected_revision": .number(Double(existing.revision))], context: context) != nil { store.clearFilters(); dismiss() } } }
        } message: { Text("Tasks are preserved.") }
    }
    private func save() async {
        guard let context else { return }
        var params: [String: JSONValue] = ["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "filters": currentFilters.json, "layout": .string(layout)]
        if let existing { params["id"] = .string(existing.id); params["expected_revision"] = .number(Double(existing.revision)) }
        if let result = await store.workflowMutation("view.save", params: params, context: context) {
            let id = result["view"]["id"].string ?? result["id"].string
            if let view = store.savedViews.first(where: { $0.id == id }) { store.selectView(view) }
            else { store.filters = currentFilters; store.selectedLayout = layout; store.selectedProjectID = nil }
            dismiss()
        }
    }
}

struct TaskWorkflowSections: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    let task: BoardTask
    let decisions: [ReviewDecision]
    @State private var showingDependencies = false
    @State private var checklistEditor: ChecklistEditSelection?
    @State private var decision: ReviewSelection?
    @State private var deletingItem: ChecklistEditSelection?
    @State private var context: WorkflowEditContext?
    var body: some View {
        DetailSection(title: "Prerequisites", symbol: "point.3.connected.trianglepath.dotted", count: task.dependencyIDs.isEmpty ? nil : "\(task.dependencyIDs.count)", action: { showingDependencies = true }) {
            if task.dependencyIDs.isEmpty { Text(task.ready ? "Ready to start without prerequisites." : "No linked prerequisites.").font(.caption).foregroundStyle(BoardInk.secondary(colorScheme)) }
            else {
                ForEach(task.dependencyIDs, id: \.self) { id in
                    let dependency = store.tasks.first { $0.id == id }
                    Button { Task { await store.openTask(id) } } label: {
                        HStack { Image(systemName: task.blockedBy.contains(id) ? "hourglass" : "checkmark.circle"); Text(dependency?.title ?? id).lineLimit(2); Spacer(); Text(task.blockedBy.contains(id) ? "Pending" : "Done").font(.caption2) }.font(.caption).foregroundStyle(task.blockedBy.contains(id) ? Color.orange : BoardInk.secondary(colorScheme))
                    }.buttonStyle(.plain)
                }
            }
        }
        DetailSection(title: "Checklist", symbol: "checklist", count: task.checklist.isEmpty ? nil : "\(task.checklist.filter(\.checked).count)/\(task.checklist.count)", action: { checklistEditor = ChecklistEditSelection(task: task, item: nil, context: context ?? store.workflowContext) }) {
            if task.checklist.isEmpty { Text("Add items to check before completing the task.").font(.caption).foregroundStyle(BoardInk.secondary(colorScheme)) }
            ForEach(task.checklist) { item in
                HStack(alignment: .top, spacing: 9) {
                    Button { Task { _ = await store.taskWorkflowMutation("task.checklist.update", task: task, fields: ["item_id": .string(item.id), "checked": .bool(!item.checked)], context: context) } } label: { Image(systemName: item.checked ? "checkmark.square.fill" : "square").foregroundStyle(item.checked ? appearance.accent : BoardInk.secondary(colorScheme)).font(.system(size: 15)) }.buttonStyle(.plain).disabled(store.isMutating).accessibilityLabel(item.checked ? "Uncheck \(item.text)" : "Check \(item.text)")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) { Text(item.text).font(.caption).strikethrough(item.checked).textSelection(.enabled); if item.required { Text("Required").font(.system(size: 9)).foregroundStyle(BoardInk.secondary(colorScheme)) } }
                        if let evidence = item.evidence, !evidence.isEmpty { Text(evidence).font(.caption2).foregroundStyle(BoardInk.secondary(colorScheme)).textSelection(.enabled) }
                    }
                    Spacer(minLength: 0)
                    Menu { Button("Edit…") { checklistEditor = ChecklistEditSelection(task: task, item: item, context: context ?? store.workflowContext) }; Button("Delete", role: .destructive) { deletingItem = ChecklistEditSelection(task: task, item: item, context: context ?? store.workflowContext) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 18)
                }.padding(.vertical, 3)
            }
            if !task.incompleteRequirements.isEmpty { Text("Check \(task.incompleteRequirements.count) required items to complete the task.").font(.caption2).foregroundStyle(BoardInk.secondary(colorScheme)) }
        }
        if task.status == .review || !decisions.isEmpty {
            DetailSection(title: "Review", symbol: "checkmark.bubble") {
                if task.status == .review {
                    if let automation = store.automations[task.id], automation.raw["single_stage"].bool != true, !["awaiting_approval", "disabled", "completed", "canceled"].contains(automation.state) {
                        Text("Final approval becomes available after automation finishes release preparation.").font(.caption).foregroundStyle(BoardInk.secondary(colorScheme))
                    } else {
                    HStack {
                        Button("Approve") { decision = ReviewSelection(task: task, value: "approve", context: context ?? store.workflowContext) }.disabled(!task.incompleteRequirements.isEmpty)
                        Button("Request changes") { decision = ReviewSelection(task: task, value: "request_changes", context: context ?? store.workflowContext) }
                        Menu { Button("Reject…") { decision = ReviewSelection(task: task, value: "reject", context: context ?? store.workflowContext) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
                    }.buttonStyle(BoardSecondaryButtonStyle()).disabled(store.isMutating)
                    }
                }
                ForEach(decisions.reversed()) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(item.title).font(.caption.weight(.medium)); Spacer(); Text(BoardDate.shortLocalTimestamp(item.createdAt)).font(.caption2).foregroundStyle(BoardInk.secondary(colorScheme)) }
                        Text(item.summary).font(.caption).foregroundStyle(BoardInk.secondary(colorScheme)).textSelection(.enabled)
                        if let actor = item.actor { Text(actor).font(.caption2).foregroundStyle(BoardInk.secondary(colorScheme)) }
                    }.padding(.top, 5)
                }
            }
        }
        Color.clear.frame(height: 0)
            .onAppear { if context == nil { context = store.workflowContext } }
            .onChange(of: store.workflowGeneration) { _, _ in showingDependencies = false; checklistEditor = nil; decision = nil; deletingItem = nil }
            .sheet(isPresented: $showingDependencies) { DependencyEditor(taskID: task.id) }
            .sheet(item: $checklistEditor) { selection in ChecklistEditor(task: selection.task, item: selection.item, context: selection.context) }
            .sheet(item: $decision) { selection in ReviewDecisionEditor(task: selection.task, decision: selection.value, context: selection.context) }
            .confirmationDialog("Delete this checklist item?", isPresented: Binding(get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } })) {
                Button("Delete", role: .destructive) { if let selection = deletingItem, let item = selection.item { Task { _ = await store.taskWorkflowMutation("task.checklist.remove", task: selection.task, fields: ["item_id": .string(item.id)], context: selection.context) } }; deletingItem = nil }
            }
    }
}

private struct ChecklistEditSelection: Identifiable { let id = UUID(); let task: BoardTask; let item: ChecklistItem?; let context: WorkflowEditContext }
private struct ReviewSelection: Identifiable { let id = UUID(); let task: BoardTask; let value: String; let context: WorkflowEditContext }

private struct DependencyEditor: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    let taskID: String
    @State private var query = ""
    @State private var context: WorkflowEditContext?
    private var task: BoardTask? { store.tasks.first { $0.id == taskID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkflowHeader(title: "Link a prerequisite", subtitle: "Choose a task that must finish before this one.")
            if let task {
                List {
                    Section("Connected") {
                        if task.dependencyIDs.isEmpty { Text("No linked tasks.").foregroundStyle(Color.secondary) }
                        ForEach(task.dependencyIDs, id: \.self) { id in HStack { Text(store.tasks.first { $0.id == id }?.title ?? id); Spacer(); Button("Remove") { Task { _ = await store.taskWorkflowMutation("task.dependency.remove", task: task, fields: ["depends_on_id": .string(id)], context: context) } } } }
                    }
                    Section("Add") {
                        TextField("Search tasks", text: $query)
                        ForEach(store.tasks.filter { $0.id != taskID && !task.dependencyIDs.contains($0.id) && (query.isEmpty || $0.title.localizedStandardContains(query)) }) { candidate in
                            HStack { Image(systemName: candidate.status.symbol).foregroundStyle(candidate.status.color); VStack(alignment: .leading, spacing: 4) { Text(candidate.title); if candidate.projectID != task.projectID { Text(store.projectName(for: candidate.projectID)).font(.caption2).foregroundStyle(Color.secondary) } }; Spacer(); Button("Connection") { Task { _ = await store.taskWorkflowMutation("task.dependency.add", task: task, fields: ["depends_on_id": .string(candidate.id)], context: context) } } }
                        }
                    }
                }.disabled(store.isMutating)
            }
            WorkflowError()
            HStack { Text("The service rejects dependency cycles.").font(.caption).foregroundStyle(Color.secondary); Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(20)
        }.frame(width: 580, height: 540).onAppear { if context == nil { context = store.workflowContext } }.onChange(of: store.workflowGeneration) { _, _ in dismiss() }
    }
}

private struct ChecklistEditor: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    let task: BoardTask
    let item: ChecklistItem?
    let context: WorkflowEditContext
    @State private var text = ""
    @State private var required = true
    @State private var evidence = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkflowHeader(title: item == nil ? "Add checklist item" : "Edit checklist item", subtitle: "Check all required items before completing the task.")
            Form { TextField("Item to check", text: $text, axis: .vertical); Toggle("Required for completion", isOn: $required); TextField("Verification evidence (optional)", text: $evidence, axis: .vertical) }.formStyle(.grouped)
            WorkflowError()
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Save") { Task {
                var fields: [String: JSONValue] = ["text": .string(text.trimmingCharacters(in: .whitespacesAndNewlines)), "required": .bool(required)]
                if let item { fields["item_id"] = .string(item.id) }; if !evidence.isEmpty || item != nil { fields["evidence"] = .string(evidence) }
                if await store.taskWorkflowMutation(item == nil ? "task.checklist.add" : "task.checklist.update", task: task, fields: fields, context: context) { dismiss() }
            } }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMutating) }.padding(20)
        }.frame(width: 500, height: 340).onAppear { text = item?.text ?? ""; required = item?.required ?? true; evidence = item?.evidence ?? ""; store.actionError = nil }.onChange(of: store.workflowGeneration) { _, _ in dismiss() }
    }
}

private struct ReviewDecisionEditor: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    let task: BoardTask
    let decision: String
    let context: WorkflowEditContext
    @State private var summary = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkflowHeader(title: "Review · \(ReviewDecision.title(for: decision))", subtitle: decision == "approve" ? "Check completion criteria and outcomes, and record why you approve." : "Record a reason the next run can understand.")
            Form { TextEditor(text: $summary).frame(minHeight: 110); Text(decision == "approve" ? "Approving completes the task." : decision == "reject" ? "Returns to To do and records the blocking reason." : "Returns to To do and records the requested changes as the next action.").font(.caption).foregroundStyle(Color.secondary) }.formStyle(.grouped)
            WorkflowError()
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Record \(ReviewDecision.title(for: decision))") { Task { if await store.taskWorkflowMutation("task.review.decide", task: task, fields: ["decision": .string(decision), "summary": .string(summary)], context: context) { dismiss() } } }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).disabled(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMutating) }.padding(20)
        }.frame(width: 510, height: 365).onAppear { store.actionError = nil }.onChange(of: store.workflowGeneration) { _, _ in dismiss() }
    }
}

struct TemplateLibraryView: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: TemplateEditSelection?
    @State private var deleting: TaskTemplate?
    @State private var context: WorkflowEditContext?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkflowHeader(title: "Task templates", subtitle: "Selecting a template in the new task window also creates its subtasks and checklists.")
            List(store.templates) { template in
                HStack(alignment: .top) {
                    Image(systemName: template.builtin ? "square.stack.3d.up" : "doc.on.doc").foregroundStyle(Color.secondary)
                    VStack(alignment: .leading, spacing: 5) { Text(template.name).font(.callout.weight(.medium)); Text("\(template.builtin ? "Built-in" : "Custom") · \(template.childCount) subtasks").font(.caption).foregroundStyle(Color.secondary) }
                    Spacer()
                    Menu { Button("Edit…") { editing = TemplateEditSelection(template: template, definition: template.definition, context: context) }; Button("Delete", role: .destructive) { deleting = template } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                }.padding(.vertical, 6)
            }
            WorkflowError()
            HStack {
                Button("New template") { editing = TemplateEditSelection(template: nil, definition: .object([:]), context: context) }
                if let task = store.selectedTask { Button("Save selected task") { editing = TemplateEditSelection(template: nil, definition: TaskTemplate.definition(from: task, tasks: store.tasks), context: context) } }
                Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
        }.frame(width: 570, height: 500)
            .onAppear { if context == nil { context = store.workflowContext } }
            .onChange(of: store.workflowGeneration) { _, _ in editing = nil; deleting = nil; dismiss() }
            .sheet(item: $editing) { selection in TemplateEditorView(template: selection.template, definition: selection.definition, sourceContext: selection.context) }
            .confirmationDialog("Delete this template?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete", role: .destructive) { if let template = deleting, let context { Task { _ = await store.workflowMutation("template.delete", params: ["template_id": .string(template.id), "expected_revision": .number(Double(template.revision))], context: context) } }; deleting = nil }
            } message: { Text("Previously created tasks are preserved.") }
    }
}

private struct TemplateEditSelection: Identifiable { let id = UUID(); let template: TaskTemplate?; let definition: JSONValue; let context: WorkflowEditContext? }

struct TemplateEditorView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    var template: TaskTemplate? = nil
    let definition: JSONValue
    var sourceContext: WorkflowEditContext? = nil
    @State private var context: WorkflowEditContext?
    @State private var name = ""
    @State private var title = ""
    @State private var goal = ""
    @State private var criteria = ""
    @State private var priority = 1
    @State private var checklist = ""
    @State private var children = ""
    private var existingChildren: [JSONValue] { definition["children"].array }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkflowHeader(title: template == nil ? "Save template" : "Edit template", subtitle: "Templates do not include status, assignees, or completion records.")
            Form {
                TextField("Template name", text: $name); TextField("Task title", text: $title)
                TextField("Goal", text: $goal, axis: .vertical); TextField("Completion criteria", text: $criteria, axis: .vertical)
                Picker("Priority", selection: $priority) { Text("Low").tag(0); Text("Normal").tag(1); Text("High").tag(3) }
                Section { TextEditor(text: $checklist).frame(minHeight: 70); Text("One required item per line. Unchanged text keeps the existing required flag.").font(.caption2).foregroundStyle(Color.secondary) } header: { Text("Checklist") }
                Section {
                    if existingChildren.isEmpty { TextEditor(text: $children).frame(minHeight: 80); Text("Enter one subtask title per line.").font(.caption2).foregroundStyle(Color.secondary) }
                    else { TemplateOutline(node: definition); Text("Preserves the original subtask structure and completion criteria.").font(.caption2).foregroundStyle(Color.secondary) }
                } header: { Text("Subtask") }
                WorkflowError()
            }.formStyle(.grouped)
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Save") { Task { await save() } }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMutating) }.padding(20)
        }.frame(width: 560, height: 650).onAppear {
            guard context == nil else { return }
            context = sourceContext ?? store.workflowContext
            name = template?.name ?? definition["title"].string ?? ""; title = definition["title"].string ?? ""; goal = definition["goal"].string ?? ""; criteria = definition["completion_criteria"].string ?? ""; priority = definition["priority"].int ?? 1; checklist = checklistText; store.actionError = nil
        }.onChange(of: store.workflowGeneration) { _, _ in dismiss() }
    }
    private var checklistText: String { definition["checklist"].array.compactMap { $0["text"].string }.joined(separator: "\n") }
    private func lines(_ text: String) -> [String] { text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private func save() async {
        guard let context else { return }
        var value = definition.object
        value["title"] = .string(title); value["goal"] = .string(goal); value["completion_criteria"] = .string(criteria); value["priority"] = .number(Double(priority))
        value["checklist"] = checklist == checklistText ? definition["checklist"] == .null ? .array([]) : definition["checklist"] : .array(lines(checklist).map { .object(["text": .string($0), "required": .bool(true)]) })
        if existingChildren.isEmpty { value["children"] = .array(lines(children).map { .object(["title": .string($0)]) }) }
        var params: [String: JSONValue] = ["name": .string(name), "definition": .object(value)]
        if let template { params["id"] = .string(template.id); params["expected_revision"] = .number(Double(template.revision)) }
        if await store.workflowMutation("template.save", params: params, context: context) != nil { dismiss() }
    }
}

struct TemplateOutline: View {
    let node: JSONValue
    private func rows(_ node: JSONValue, depth: Int = 0) -> [(String, Int)] {
        node["children"].array.flatMap { [(($0["title"].string ?? "Task"), depth)] + rows($0, depth: depth + 1) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) { ForEach(Array(rows(node).enumerated()), id: \.offset) { entry in Label(entry.element.0, systemImage: "arrow.turn.down.right").font(.caption).padding(.leading, CGFloat(min(entry.element.1, 6)) * 14) } }
    }
}

private struct WorkflowHeader: View {
    let title: String
    let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 7) { Text(title).font(.title2.weight(.semibold)); Text(subtitle).font(.callout).foregroundStyle(Color.secondary) }.padding(24) }
}
private struct WorkflowError: View {
    @EnvironmentObject private var store: BoardStore
    var body: some View { if let error = store.actionError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 20) } }
}
