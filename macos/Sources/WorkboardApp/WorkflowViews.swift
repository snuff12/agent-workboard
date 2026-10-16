import SwiftUI
import AppKit

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
                    HStack {
                        Button("Approve") { decision = ReviewSelection(task: task, value: "approve", context: context ?? store.workflowContext) }.disabled(!task.incompleteRequirements.isEmpty)
                        Button("Request changes") { decision = ReviewSelection(task: task, value: "request_changes", context: context ?? store.workflowContext) }
                        Menu { Button("Reject…") { decision = ReviewSelection(task: task, value: "reject", context: context ?? store.workflowContext) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
                    }.buttonStyle(BoardSecondaryButtonStyle()).disabled(store.isMutating)
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
