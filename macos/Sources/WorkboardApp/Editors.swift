import SwiftUI
import AppKit

struct TaskEditorView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    @State var draft: TaskDraft
    @FocusState private var titleFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader(draft.editingTask != nil ? "Edit task" : draft.parentID != nil ? "Create subtask" : "Create task", subtitle: "A goal and completion criteria help the next run continue your work.")
            Form {
                if draft.editingTask == nil && draft.parentID == nil {
                    Picker("Project", selection: $draft.projectID) { ForEach(store.projects) { Text($0.name).tag($0.id) } }
                }
                if let editingTask = draft.editingTask {
                    Picker("Parent task", selection: $draft.parentID) {
                        Text("None (standalone task)").tag(Optional<String>.none)
                        ForEach(store.tasks.filter { $0.projectID == draft.projectID && $0.id != editingTask.id }) { Text($0.title).tag(Optional($0.id)) }
                    }
                } else if let parentID = draft.parentID, let parent = store.tasks.first(where: { $0.id == parentID }) { LabeledContent("Parent task", value: parent.title) }
                if draft.editingTask == nil && !store.templates.isEmpty {
                    Picker("Template", selection: $draft.templateID) {
                        Text("Blank task").tag(Optional<String>.none)
                        ForEach(store.templates) { Text($0.name).tag(Optional($0.id)) }
                    }.accessibilityIdentifier("task.template").onChange(of: draft.templateID) { _, id in
                        if let template = store.templates.first(where: { $0.id == id }) { draft.title = template.title; draft.templateRevision = template.revision }
                        else { draft.templateRevision = nil }
                    }
                }
                if draft.editingTask == nil {
                    Section {
                        Picker("Execution", selection: $draft.automationMode) {
                            ForEach(TaskAutomationMode.allCases) { Text($0.title).tag($0) }
                        }.accessibilityIdentifier("task.automation-mode")
                        if draft.automationMode != .manual {
                            ProcessPresetPicker(selection: $draft.processPreset, presets: store.processPresets, includeDefault: true)
                            if draft.processPreset == "auto" { Text("An agent will choose a process and record its reason before work starts.").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(automationDescription).font(.caption).foregroundStyle(Color.secondary)
                        if (draft.automationMode == .automatic || !draft.processPreset.isEmpty) && draft.automationMode != .manual && !hasSavedAutomation {
                            Text("Save project automation defaults before choosing automation.").font(.caption).foregroundStyle(.red)
                        }
                    } header: { Text("Automation") }
                }
                Section {
                    TextField("What needs to be done?", text: $draft.title).font(.title3).focused($titleFocused)
                    if draft.editingTask == nil { Picker("Status", selection: $draft.status) { ForEach(WorkStatus.allCases.filter(\.acceptsNewTasks)) { Label($0.title, systemImage: $0.symbol).tag($0) } }.accessibilityIdentifier("task.status") }
                    if draft.templateID == nil { Picker("Priority", selection: $draft.priority) { Text("Low").tag(0); Text("Normal").tag(1); Text("High").tag(3) } }
                } header: { Text("Task") }
                if let template = store.templates.first(where: { $0.id == draft.templateID }) {
                    Section {
                        if let goal = template.definition["goal"].string, !goal.isEmpty { Text(goal).font(.callout).textSelection(.enabled) }
                        if let criteria = template.definition["completion_criteria"].string, !criteria.isEmpty { LabeledContent("Completion criteria", value: criteria).font(.caption) }
                        ForEach(Array(template.definition["checklist"].array.enumerated()), id: \.offset) { entry in Label(entry.element["text"].string ?? "", systemImage: "square").font(.caption) }
                        TemplateOutline(node: template.definition)
                        Text("Creates \(template.childCount) subtasks and their checklists. You can edit each task afterward.").font(.caption).foregroundStyle(Color.secondary)
                    } header: { Text(template.name) }
                } else {
                Section { TextEditor(text: $draft.goal).frame(minHeight: 65).font(.body).scrollContentBackground(.hidden) } header: { Text("Goal") }
                Section { TextEditor(text: $draft.completionCriteria).frame(minHeight: 65).font(.body).scrollContentBackground(.hidden) } header: { Text("Completion criteria") }
                Section {
                    Toggle("Set due date", isOn: $draft.hasDueDate)
                    if draft.hasDueDate {
                        DatePicker("Due", selection: $draft.dueDate, displayedComponents: draft.dueIncludesTime ? [.date, .hourAndMinute] : [.date])
                        Toggle("Include due time", isOn: $draft.dueIncludesTime).font(.caption)
                    }
                    Toggle("Schedule a meeting or work session", isOn: $draft.hasSchedule)
                    if draft.hasSchedule {
                        Toggle("All day", isOn: $draft.scheduleAllDay).onChange(of: draft.scheduleAllDay) { _, allDay in
                            if allDay {
                                draft.scheduledStart = editingCalendar.startOfDay(for: draft.scheduledStart)
                                draft.scheduledEnd = editingCalendar.date(byAdding: .day, value: 1, to: editingCalendar.startOfDay(for: max(draft.scheduledStart, draft.scheduledEnd))) ?? draft.scheduledStart.addingTimeInterval(86_400)
                            }
                        }
                        DatePicker("Start", selection: $draft.scheduledStart, displayedComponents: draft.scheduleAllDay ? [.date] : [.date, .hourAndMinute])
                        if draft.scheduleAllDay {
                            DatePicker("Last day", selection: Binding(get: { editingCalendar.date(byAdding: .day, value: -1, to: draft.scheduledEnd) ?? draft.scheduledEnd }, set: { draft.scheduledEnd = editingCalendar.date(byAdding: .day, value: 1, to: $0) ?? $0 }), displayedComponents: [.date])
                        } else { DatePicker("End", selection: $draft.scheduledEnd, displayedComponents: [.date, .hourAndMinute]) }
                        if draft.scheduledEnd <= draft.scheduledStart { Text("End time must be after start time.").font(.caption).foregroundStyle(.red) }
                    }
                    if draft.hasDueDate || draft.hasSchedule {
                        Picker("Time zone", selection: Binding(get: { draft.timeZoneID }, set: { draft.changeTimeZone(to: $0) })) {
                            ForEach(timeZoneOptions, id: \.self) { zone in Text(zone == TimeZone.current.identifier ? "Device time zone · \(zone)" : zone).tag(zone) }
                        }
                        Text("Dates and times use the selected time zone. Calendar integration runs separately through a plugin.").font(.caption2).foregroundStyle(Color.secondary)
                    }
                } header: { Text("Schedule") }
                Section { TextField("The specific action to take next", text: $draft.nextAction, axis: .vertical).lineLimit(2...4) } header: { Text("Next action") }
                if draft.editingTask != nil { Section { TextField("Leave blank if none", text: $draft.blockedReason, axis: .vertical).lineLimit(1...3) } header: { Text("Blocking reason") } }
                }
                if let error = store.actionError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped).environment(\.timeZone, TimeZone(identifier: draft.timeZoneID) ?? .current)
            Divider()
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); if store.isMutating { ProgressView().controlSize(.small) }; Button(draft.editingTask == nil ? "Create task" : "Save changes") { Task { _ = await store.save(draft) } }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).keyboardShortcut(.defaultAction).disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMutating || (draft.editingTask == nil && (draft.automationMode == .automatic || !draft.processPreset.isEmpty) && draft.automationMode != .manual && !hasSavedAutomation)) }.padding(20)
        }.frame(width: 560, height: 730).background(Color(nsColor: .windowBackgroundColor)).tint(appearance.accent).onAppear { titleFocused = true; store.actionError = nil; if draft.workflowContext == nil { draft.workflowContext = store.workflowContext } }
    }
    private var hasSavedAutomation: Bool { store.automationDefaults[draft.projectID]?["configuration"] != nil && store.automationDefaults[draft.projectID]?["configuration"] != .null }
    private var automationDescription: String {
        switch draft.automationMode {
        case .manual: "Status changes will not start agents. You can configure automation later. Applies to every subtask created from a template."
        case .automatic: "Use the saved project workflow for this task and its template subtasks. Agents start only after a matching status change."
        case .inherit: store.automationDefaults[draft.projectID]?["enabled"].bool == true ? "This project uses automation for new tasks. Choose Manual work to skip it for this task and its template subtasks." : "This project creates manual tasks by default."
        }
    }
    private var editingCalendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: draft.timeZoneID) ?? .current; return calendar }
    private var timeZoneOptions: [String] {
        var values: [String] = []
        for zone in [draft.timeZoneID, draft.editingTask?.timeZone ?? TimeZone.current.identifier, TimeZone.current.identifier, "UTC", "Asia/Seoul", "Asia/Tokyo", "America/New_York", "America/Los_Angeles", "Europe/London", "Europe/Berlin", "Australia/Sydney"] where !values.contains(zone) { values.append(zone) }
        return values
    }
}

struct NewProjectView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var directory = ""
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader("Create project", subtitle: "Group tasks and subtasks by project.")
            Form {
                TextField("Project name", text: $name).focused($nameFocused)
                HStack { TextField("Working directory (optional)", text: $directory); Button("Choose…") { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; if panel.runModal() == .OK, let url = panel.url { directory = url.path } } }
                Text("Linking a directory does not change existing files.").font(.caption).foregroundStyle(Color.secondary)
                if let error = store.actionError { Text(error).font(.caption).foregroundStyle(.red) }
            }.formStyle(.grouped)
            Divider()
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); if store.isMutating { ProgressView().controlSize(.small) }; Button("Create project") { Task { _ = await store.createProject(name: name, directory: directory) } }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMutating) }.padding(20)
        }.frame(width: 520, height: 330).background(Color(nsColor: .windowBackgroundColor)).tint(appearance.accent).onAppear { nameFocused = true; store.actionError = nil }
    }
}

struct CompleteTaskView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    let task: BoardTask
    @State private var summary = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader("Verify the outcome", subtitle: task.title)
            Form {
                if !task.completionCriteria.isEmpty { Section { Text(task.completionCriteria).font(.callout).textSelection(.enabled) } header: { Text("Completion criteria") } }
                let unfinished = store.children(of: task).filter { !$0.status.isClosed }
                if !unfinished.isEmpty { Label("There are \(unfinished.count) unfinished subtasks.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                if !task.incompleteRequirements.isEmpty { Label("Check \(task.incompleteRequirements.count) required items first.", systemImage: "checklist").font(.caption).foregroundStyle(.orange) }
                Section { TextEditor(text: $summary).frame(minHeight: 100).scrollContentBackground(.hidden) } header: { Text("What outcome completed this task?") }
                Text("Ending a response does not complete a task. Check its completion criteria and artifacts before recording the outcome.").font(.caption).foregroundStyle(Color.secondary)
                if let error = store.actionError { Text(error).font(.caption).foregroundStyle(.red) }
            }.formStyle(.grouped)
            Divider()
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); if store.isMutating { ProgressView().controlSize(.small) }; Button("Mark done") { Task { _ = await store.complete(task, summary: summary) } }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).keyboardShortcut(.defaultAction).disabled(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMutating || !task.incompleteRequirements.isEmpty) }.padding(20)
        }.frame(width: 530, height: 470).background(Color(nsColor: .windowBackgroundColor)).tint(appearance.accent).onAppear { store.actionError = nil }
    }
}

struct AttachmentView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    let task: BoardTask
    @State private var path = ""
    @State private var description = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader("Attach a file or URL", subtitle: "Link artifacts and evidence at their original locations.")
            Form {
                HStack { TextField("File path or https://…", text: $path); Button("Choose file…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; if panel.runModal() == .OK, let url = panel.url { path = url.path } } }
                TextField("Description (optional)", text: $description)
                if let error = store.actionError { Text(error).font(.caption).foregroundStyle(.red) }
            }.formStyle(.grouped)
            Divider()
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Connection") { Task { if await store.attach(task, path: path, description: description) { dismiss() } } }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).keyboardShortcut(.defaultAction).disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMutating) }.padding(20)
        }.frame(width: 530, height: 285).background(Color(nsColor: .windowBackgroundColor)).onAppear { store.actionError = nil }
    }
}

struct AssigneeView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    let task: BoardTask
    @State private var agent = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader("Assign task", subtitle: "Enter a person or agent identifier.")
            Form {
                if let assignee = task.assignee { LabeledContent("Current assignee", value: assignee) }
                if task.assignee != nil { Button("Release current assignee") { Task { if await store.release(task) { dismiss() } } }.disabled(store.isMutating) }
                TextField("For example: user, codex-ui", text: $agent)
                Text("The service checks for conflicts when a task already has an assignee.").font(.caption).foregroundStyle(Color.secondary)
                if let error = store.actionError { Text(error).font(.caption).foregroundStyle(.red) }
            }.formStyle(.grouped)
            Divider()
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Assign task") { Task { if await store.claim(task, agent: agent) { dismiss() } } }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).keyboardShortcut(.defaultAction).disabled(agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMutating) }.padding(20)
        }.frame(width: 470, height: 310).background(Color(nsColor: .windowBackgroundColor)).onAppear { agent = task.assignee ?? "user"; store.actionError = nil }
    }
}

@MainActor private func sheetHeader(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 7) { Text(title).font(.title2.weight(.semibold)); Text(subtitle).font(.callout).foregroundStyle(Color.secondary).lineLimit(2) }.padding(24)
}
