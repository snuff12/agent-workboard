import SwiftUI
import AppKit

struct TaskDetailView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingAttachment = false
    @State private var showingAssignee = false
    @State private var showingTemplate = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Task details").font(.caption.weight(.semibold)).foregroundStyle(BoardInk.secondary(colorScheme))
                Spacer()
                if let task = store.detail?.task {
                    Menu {
                        Button("Edit…") { store.draft = TaskDraft(projectID: task.projectID, editingTask: task) }
                        Button("Add subtask") { store.newTask(parent: task) }
                        Button("Save as template…") { showingTemplate = true }
                        Button("Copy resume context") { Task { await store.resumeContext(task) } }
                        Button("Copy task ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(task.id, forType: .string); store.notice = "Task ID copied." }
                        Divider()
                        Button("Delete…", role: .destructive) { store.requestDelete(task) }.disabled(store.isMutating)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22).help("Task menu")
                }
                Button { store.selectedTaskID = nil; store.detail = nil } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)) }.buttonStyle(.plain).foregroundStyle(BoardInk.secondary(colorScheme)).help("Close details")
            }.padding(.horizontal, 23).padding(.vertical, 17)
            Divider()
            if let detail = store.detail, detail.task.id == store.selectedTaskID {
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
                        header(detail.task)
                        properties(detail.task)
                        if !detail.task.blockedReason.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 7) {
                                    Image(systemName: "exclamationmark.circle").renderingMode(.template).symbolRenderingMode(.monochrome).foregroundStyle(statusInk(.review))
                                    Text("Progress is blocked").foregroundStyle(statusInk(.review))
                                }.font(.caption.weight(.semibold))
                                Text(detail.task.blockedReason).font(.callout).textSelection(.enabled)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(statusInk(.review).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if !detail.task.nextAction.isEmpty {
                            VStack(alignment: .leading, spacing: 9) { Label("Next action", systemImage: "arrow.right.circle").font(.caption.weight(.semibold)).foregroundStyle(appearance.accent); Text(detail.task.nextAction).font(.system(size: 12 * appearance.theme.fontScale)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(appearance.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                        }
                        DetailSection(title: "Goal", symbol: "scope") { detailText(detail.task.goal, empty: "No goal yet. Add the task’s purpose in the editor.") }
                        DetailSection(title: "Completion criteria", symbol: "checkmark.seal") { detailText(detail.task.completionCriteria, empty: "Describe the outcome that completes this task.") }
                        TaskWorkflowSections(task: detail.task, decisions: detail.reviewDecisions).id(store.workflowGeneration)
                        if !detail.task.completionSummary.isEmpty { DetailSection(title: "Outcome", symbol: "checkmark.circle") { detailText(detail.task.completionSummary, empty: "") } }
                        children(detail)
                        artifacts(detail)
                        runs(detail)
                        history(detail)
                    }.padding(23)
                }
            } else if store.actionError != nil {
                ContentUnavailableView { Label("Could not read details", systemImage: "exclamationmark.triangle") } actions: { Button("Try again") { if let id = store.selectedTaskID { Task { await store.loadDetail(id) } } } }
            } else { Spacer(); ProgressView("Loading task…"); Spacer() }
        }.foregroundStyle(BoardInk.primary(colorScheme)).background(Color(nsColor: .controlBackgroundColor))
            .sheet(isPresented: $showingAttachment) { if let task = store.detail?.task { AttachmentView(task: task) } }
            .sheet(isPresented: $showingAssignee) { if let task = store.detail?.task { AssigneeView(task: task) } }
            .sheet(isPresented: $showingTemplate) { if let task = store.detail?.task { TemplateEditorView(definition: TaskTemplate.definition(from: task, tasks: store.tasks)) } }
    }
    private func header(_ task: BoardTask) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            if let parentID = task.parentID, let parent = store.tasks.first(where: { $0.id == parentID }) {
                Button { Task { await store.openTask(parentID) } } label: { Label(parent.title, systemImage: "arrow.up.left").font(.caption).lineLimit(1) }.buttonStyle(.plain).foregroundStyle(appearance.accent)
            } else { Label(store.projectName(for: task.projectID), systemImage: "folder").font(.caption).foregroundStyle(BoardInk.secondary(colorScheme)) }
            Text(task.title).font(.system(size: 23 * appearance.theme.fontScale, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                Menu {
                    ForEach(WorkStatus.allCases) { status in Button { Task { await store.move(task, to: status) } } label: { Label(status.title, systemImage: status.symbol) }.disabled(task.status == status || store.isMutating) }
                } label: { Label(task.status.title, systemImage: task.status.symbol).font(.caption.weight(.medium)).foregroundStyle(task.status.color).padding(.horizontal, 9).padding(.vertical, 5).background(task.status.color.opacity(0.08), in: Capsule()) }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("Edit") { store.draft = TaskDraft(projectID: task.projectID, editingTask: task) }.buttonStyle(BoardSecondaryButtonStyle())
            }
        }
    }
    private func properties(_ task: BoardTask) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 13) {
            GridRow { Label("Assignee", systemImage: "person").foregroundStyle(BoardInk.secondary(colorScheme)); Button(task.assignee ?? "Assign task") { showingAssignee = true }.buttonStyle(.plain).foregroundStyle(task.assignee == nil ? appearance.accent : BoardInk.primary(colorScheme)).lineLimit(1) }
            GridRow { Label("Priority", systemImage: "flag").foregroundStyle(BoardInk.secondary(colorScheme)); Text(task.priorityTitle).foregroundStyle(task.priority >= 3 ? .orange : BoardInk.primary(colorScheme)) }
            GridRow { Label("Last updated", systemImage: "clock").foregroundStyle(BoardInk.secondary(colorScheme)); Text(shortDate(task.updatedAt)).foregroundStyle(BoardInk.secondary(colorScheme)) }
            if task.ready { GridRow { Label("Readiness", systemImage: "play.circle").foregroundStyle(BoardInk.secondary(colorScheme)); Text("Ready").foregroundStyle(appearance.accent) } }
            if !task.blockedBy.isEmpty { GridRow { Label("Prerequisites", systemImage: "hourglass").foregroundStyle(BoardInk.secondary(colorScheme)); Text("Waiting for \(task.blockedBy.count) to complete").foregroundStyle(statusInk(.review)) } }
            if let due = task.dueDate { GridRow { Label("Due", systemImage: "flag.checkered").foregroundStyle(BoardInk.secondary(colorScheme)); Text(due, format: task.dueAt?.count == 10 ? .dateTime.month().day() : .dateTime.month().day().hour().minute()).foregroundStyle(task.isOverdue ? .red : BoardInk.primary(colorScheme)) } }
            if let start = task.startDate { GridRow { Label("Scheduled start", systemImage: "calendar").foregroundStyle(BoardInk.secondary(colorScheme)); Text(start, format: task.scheduledStart?.count == 10 ? .dateTime.month().day() : .dateTime.month().day().hour().minute()) } }
            if let end = task.endDate {
                GridRow {
                    Label(task.scheduledEnd?.count == 10 ? "Last day" : "Scheduled end", systemImage: "calendar.badge.checkmark").foregroundStyle(BoardInk.secondary(colorScheme))
                    if task.scheduledEnd?.count == 10 { Text(Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end, format: .dateTime.month().day()) }
                    else { Text(end, format: .dateTime.month().day().hour().minute()) }
                }
            }
            if task.dueAt != nil || task.scheduledStart != nil {
                GridRow { Label("Schedule time zone", systemImage: "globe").foregroundStyle(BoardInk.secondary(colorScheme)); Text(task.timeZone).foregroundStyle(BoardInk.secondary(colorScheme)) }
                if task.timeZone != TimeZone.current.identifier { GridRow { Text("Displayed time").foregroundStyle(BoardInk.secondary(colorScheme)); Text("Device time zone").foregroundStyle(BoardInk.secondary(colorScheme)) } }
            }
            if task.claimStale && !task.status.isClosed { GridRow { Label("Check assignee", systemImage: "exclamationmark.clock").foregroundStyle(.orange); Text("Check activity status").foregroundStyle(.orange) } }
        }.font(.system(size: 11 * appearance.theme.fontScale)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
    }
    private func detailText(_ value: String, empty: String) -> some View {
        Text(value.isEmpty ? empty : value).font(.system(size: 12 * appearance.theme.fontScale)).foregroundStyle(value.isEmpty ? BoardInk.tertiary(colorScheme) : BoardInk.primary(colorScheme)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
    }
    private func children(_ detail: TaskDetail) -> some View {
        let rows = store.children(of: detail.task)
        let counted = rows.filter { $0.status != .canceled }
        let done = counted.filter { $0.status == .done }.count
        return DetailSection(title: "Subtask", symbol: "checklist", count: counted.isEmpty ? nil : "\(done)/\(counted.count)", action: { store.newTask(parent: detail.task) }) {
            if rows.isEmpty { Text("Break a large task into small, actionable steps.").font(.caption).foregroundStyle(BoardInk.tertiary(colorScheme)) }
            else {
                VStack(spacing: 0) {
                    ForEach(rows) { child in
                        Button { Task { await store.openTask(child.id) } } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Image(systemName: child.status.symbol).renderingMode(.template).symbolRenderingMode(.monochrome).foregroundStyle(statusInk(child.status)).font(.system(size: 12))
                                VStack(alignment: .leading, spacing: 4) { Text(child.title).font(.system(size: 12 * appearance.theme.fontScale)).foregroundStyle(BoardInk.primary(colorScheme)).lineLimit(2); if let assignee = child.assignee { Text(assignee).font(.caption2).foregroundStyle(BoardInk.secondary(colorScheme)) } }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(BoardInk.tertiary(colorScheme))
                            }.padding(.vertical, 10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if child.id != rows.last?.id { Rectangle().fill(BoardInk.secondary(colorScheme).opacity(0.15)).frame(height: 1) }
                    }
                }
            }
        }
    }
    private func artifacts(_ detail: TaskDetail) -> some View {
        DetailSection(title: "Artifacts and links", symbol: "paperclip", count: detail.artifacts.isEmpty ? nil : "\(detail.artifacts.count)", action: { showingAttachment = true }) {
            if detail.artifacts.isEmpty { Text("Attach a file or URL so the next run can find it.").font(.caption).foregroundStyle(BoardInk.tertiary(colorScheme)) }
            else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(detail.artifacts) { artifact in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: artifact.kind == "url" ? "link" : "doc").font(.system(size: 13)).foregroundStyle(appearance.accent).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Button { if let url = artifact.url { NSWorkspace.shared.open(url) } } label: { Text(artifact.description.isEmpty ? (artifact.path as NSString).lastPathComponent : artifact.description).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading) }.buttonStyle(.plain).foregroundStyle(appearance.accent).disabled(artifact.url == nil)
                                Text(artifact.path).font(.system(size: 10)).foregroundStyle(BoardInk.tertiary(colorScheme)).lineLimit(2).textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }
    private func runs(_ detail: TaskDetail) -> some View {
        DetailSection(title: "Run history", symbol: "play.circle", count: detail.runs.isEmpty ? nil : "\(detail.runs.count)") {
            if detail.runs.isEmpty { Text("Starting a task creates a run record.").font(.caption).foregroundStyle(BoardInk.tertiary(colorScheme)) }
            else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(detail.runs) { run in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(run.agent.isEmpty ? "Run" : run.agent).font(.caption.weight(.medium)); Spacer(); Text(runStatus(run.status)).font(.caption2).foregroundStyle(BoardInk.secondary(colorScheme)) }
                            if !run.summary.isEmpty { Text(run.summary).font(.caption).foregroundStyle(BoardInk.secondary(colorScheme)).textSelection(.enabled) }
                            if !run.startedAt.isEmpty { Text(shortDate(run.startedAt)).font(.caption2).foregroundStyle(BoardInk.tertiary(colorScheme)) }
                        }
                    }
                }
            }
        }
    }
    private func history(_ detail: TaskDetail) -> some View {
        DetailSection(title: "Change history", symbol: "clock.arrow.circlepath") {
            if detail.events.isEmpty { Text("No change history yet.").font(.caption).foregroundStyle(BoardInk.tertiary(colorScheme)) }
            else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(detail.events.suffix(15).reversed().enumerated()), id: \.offset) { item in
                        let event = item.element
                        HStack(alignment: .top, spacing: 9) {
                            Circle().fill(Color.secondary.opacity(0.3)).frame(width: 5, height: 5).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 3) { Text(eventTitle(event)).font(.caption); Text(shortDate(event["created_at"].string ?? event["timestamp"].string ?? "")).font(.caption2).foregroundStyle(BoardInk.tertiary(colorScheme)) }
                        }
                    }
                }
            }
        }
    }
    private func shortDate(_ value: String) -> String {
        BoardDate.shortLocalTimestamp(value)
    }
    private func statusInk(_ status: WorkStatus) -> Color {
        switch status {
        case .backlog, .todo, .canceled: BoardInk.secondary(colorScheme)
        case .inProgress: Color(hex: colorScheme == .dark ? "76ACFF" : "316AC4")
        case .review: Color(hex: colorScheme == .dark ? "FFB454" : "AE6200")
        case .done: Color(hex: colorScheme == .dark ? "66D695" : "25834C")
        }
    }
    private func runStatus(_ status: String) -> String {
        switch status { case "running", "active": "Running"; case "completed", "done": "Done"; case "interrupted", "stopped": "Interrupted"; case "failed": "Failed"; default: status }
    }
    private func eventTitle(_ event: JSONValue) -> String {
        let type = event["event_type"].string ?? event["kind"].string ?? event["method"].string ?? event["action"].string ?? "Task updated"
        return ["task.created": "Task created", "task.updated": "Edit task", "task.claimed": "Assign task", "task.started": "Run started", "task.reviewed": "Request review", "task.completed": "Task completed", "artifact.attached": "Artifact attached"][type] ?? type
    }
}

struct DetailSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let symbol: String
    var count: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) { Image(systemName: symbol).font(.system(size: 11)); Text(title).font(.system(size: 11, weight: .semibold)); if let count { Text(count).font(.system(size: 10)).monospacedDigit().foregroundStyle(BoardInk.tertiary(colorScheme)) }; Spacer(); if let action { Button(action: action) { Image(systemName: "plus").font(.system(size: 11)) }.buttonStyle(.plain).help("Add \(title)").accessibilityLabel("Add \(title)") } }.foregroundStyle(BoardInk.secondary(colorScheme))
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
