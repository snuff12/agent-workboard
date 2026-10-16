import SwiftUI
import AppKit
import WidgetKit
import UniformTypeIdentifiers
import Combine

@MainActor final class BoardStore: ObservableObject {
    static let todayScope = "@workboard-today"
    static let inboxScope = "@workboard-inbox"
    static let trashScope = "@workboard-trash"
    @Published var projects: [BoardProject] = []
    @Published var tasks: [BoardTask] = []
    @Published var templates: [TaskTemplate] = []
    @Published var savedViews: [SavedTaskView] = []
    @Published var inbox: [InboxItem] = []
    @Published var trash: [TrashItem] = []
    @Published var selectedLayout = "board"
    @Published var selectedViewID: String?
    @Published var filters = TaskFilters() { didSet {
        if filters != oldValue { queryResultIDs = nil; queryResultKey = nil; Task { await self.refreshQueryResults() } }
    } }
    @Published var selectedProjectID: String?
    @Published var selectedTaskID: String?
    @Published var detail: TaskDetail?
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var isMutating = false
    @Published var connectionError: String?
    @Published var widgetWarning: String?
    @Published var actionError: String?
    @Published var lastUpdated: Date?
    @Published var draft: TaskDraft?
    @Published var showingNewProject = false
    @Published var completionTask: BoardTask?
    /// The enabled Orca plugin, so cards can link worktrees without opening plugin settings.
    @Published var orcaPlugin: InstalledPlugin?
    @Published var worktreeLinkTask: BoardTask?
    @Published var deletionTask: BoardTask?
    @Published var purgeItem: TrashItem?
    @Published var confirmingEmptyTrash = false
    @Published var undoDeletion: UndoDeletion?
    @Published var notice: String?
    let appearance: AppearanceSettings
    private let client = WorkboardClient()
    private var reloading = false
    private var eventSequence: Int?
    private var pendingDeepLink: String?
    private var widgetConfigurationKey: String?
    private var connectionIdentity: ConnectionIdentity?
    private var connectionGeneration = UUID()
    private var connectionObservation: AnyCancellable?
    private var reloadRequested = false
    @Published private var queryResultIDs: Set<String>?
    private var queryResultKey: String?

    init(appearance: AppearanceSettings) {
        self.appearance = appearance
        connectionObservation = appearance.connectionChanges.sink { [weak self] in
            guard let self, self.invalidateConnectionIfNeeded() else { return }
            if self.reloading { self.reloadRequested = true }
            else { Task { await self.reload() } }
        }
    }
    var selectedTask: BoardTask? { tasks.first { $0.id == selectedTaskID } }
    var configuration: ConnectionConfiguration { appearance.connection }
    var workflowGeneration: UUID { connectionGeneration }
    var workflowContext: WorkflowEditContext { WorkflowEditContext(connection: configuration.identity(), generation: connectionGeneration) }
    func isCurrentWorkflow(_ context: WorkflowEditContext) -> Bool { isCurrentConnection(context.connection, generation: context.generation) }
    var pendingInbox: [InboxItem] { inbox.filter { $0.status == "pending" } }
    var currentProject: BoardProject? { projects.first { $0.id == selectedProjectID } }
    var isTodayView: Bool { selectedProjectID == Self.todayScope }
    var isInboxView: Bool { selectedProjectID == Self.inboxScope }
    var isTrashView: Bool { selectedProjectID == Self.trashScope }
    var trashedTaskCount: Int { trash.reduce(0) { $0 + $1.tasks.count } }
    /// Permanently deleting an item also removes subtasks that were moved to the trash earlier on their own.
    func purgeCount(_ item: TrashItem) -> Int {
        let trashed = trash.flatMap(\.tasks)
        func below(_ id: String) -> Int { trashed.filter { $0.parentID == id }.reduce(0) { $0 + 1 + below($1.id) } }
        return 1 + below(item.task.id)
    }
    var scopedTasks: [BoardTask] {
        var local = filters; local.query = ""
        return tasks.filter {
            (isTodayView ? $0.isScheduledToday : selectedProjectID == nil || $0.projectID == selectedProjectID)
            && local.matches($0) && (filters.query.isEmpty || queryResultIDs?.contains($0.id) == true)
        }
    }
    var visibleTasks: [BoardTask] {
        scopedTasks.filter { task in
            (isTodayView || selectedLayout != "board" || !filters.isEmpty || appearance.theme.showSubtasksOnBoard || task.parentID == nil || !searchText.isEmpty)
            && (searchText.isEmpty || [task.title, task.goal, task.completionCriteria, task.nextAction, task.assignee ?? ""].joined(separator: " ").localizedStandardContains(searchText))
        }.sorted { lhs, rhs in
            if isTodayView, let left = lhs.startDate, let right = rhs.startDate, left != right { return left < right }
            return lhs.priority != rhs.priority ? lhs.priority > rhs.priority : lhs.updatedAt > rhs.updatedAt
        }
    }
    var completionRatio: Double { let all = scopedTasks.filter { $0.status != .canceled }; return all.isEmpty ? 0 : Double(all.filter { $0.status == .done }.count) / Double(all.count) }
    func children(of task: BoardTask) -> [BoardTask] { tasks.filter { $0.parentID == task.id }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    func descendants(of task: BoardTask) -> [BoardTask] { children(of: task).flatMap { [$0] + descendants(of: $0) } }
    func projectName(for id: String) -> String { projects.first { $0.id == id }?.name ?? "Project" }
    func selectView(_ view: SavedTaskView) {
        selectedViewID = view.id; filters = view.filters; selectedLayout = view.layout; selectedProjectID = nil; searchText = ""
    }
    func clearFilters() { selectedViewID = nil; filters = TaskFilters(); searchText = "" }

    @discardableResult private func invalidateConnectionIfNeeded() -> Bool {
        let identity = appearance.connection.identity()
        guard identity != connectionIdentity else { return false }
        if connectionIdentity != nil { pendingDeepLink = nil }
        connectionIdentity = identity; connectionGeneration = UUID()
        eventSequence = nil; widgetConfigurationKey = nil; lastUpdated = nil
        projects = []; tasks = []; selectedProjectID = nil; selectedTaskID = nil; detail = nil; orcaPlugin = nil; worktreeLinkTask = nil
        templates = []; savedViews = []; inbox = []; trash = []; selectedViewID = nil; filters = TaskFilters(); selectedLayout = "board"
        queryResultIDs = nil; queryResultKey = nil
        draft = nil; completionTask = nil; deletionTask = nil; purgeItem = nil; confirmingEmptyTrash = false; undoDeletion = nil; showingNewProject = false
        actionError = nil; notice = nil; widgetWarning = nil; connectionError = nil; isLoading = true
        return true
    }
    private func isCurrentConnection(_ identity: ConnectionIdentity, generation: UUID) -> Bool {
        identity == appearance.connection.identity() && identity == connectionIdentity && generation == connectionGeneration
    }
    func reload(force: Bool = false) async {
        let changed = invalidateConnectionIfNeeded()
        guard !reloading else {
            if force || changed { reloadRequested = true }
            return
        }
        let configuration = appearance.connection
        let identity = configuration.identity()
        let generation = connectionGeneration
        reloading = true; if force || lastUpdated == nil { isLoading = true }
        defer {
            reloading = false
            if reloadRequested {
                reloadRequested = false; Task { await self.reload(force: true) }
            } else { isLoading = false }
        }
        do {
            let snapshot = try await client.call("board.snapshot", configuration: configuration)
            guard isCurrentConnection(identity, generation: generation) else { reloadRequested = true; return }
            let sequence = snapshot["event_sequence"].int
            if sequence != eventSequence || force || lastUpdated == nil {
                projects = snapshot["projects"].array.compactMap(BoardProject.init)
                tasks = snapshot["tasks"].array.compactMap(BoardTask.init)
                templates = snapshot["templates"].array.compactMap(TaskTemplate.init)
                let previousView = savedViews.first { $0.id == selectedViewID }
                savedViews = snapshot["views"].array.compactMap(SavedTaskView.init)
                if let refreshed = savedViews.first(where: { $0.id == selectedViewID }), let previousView {
                    if filters == previousView.filters { filters = refreshed.filters }
                    if selectedLayout == previousView.layout { selectedLayout = refreshed.layout }
                }
                inbox = snapshot["inbox"].array.compactMap(InboxItem.init)
                trash = snapshot["trash"].array.compactMap(TrashItem.init)
                if let selectedViewID, !savedViews.contains(where: { $0.id == selectedViewID }) { self.selectedViewID = nil }
                if let selectedProjectID, ![Self.todayScope, Self.inboxScope, Self.trashScope].contains(selectedProjectID), !projects.contains(where: { $0.id == selectedProjectID }) { self.selectedProjectID = nil }
                if let pendingDeepLink { self.pendingDeepLink = nil; await openTask(pendingDeepLink) }
                else if let selectedTaskID {
                    if let current = tasks.first(where: { $0.id == selectedTaskID }) {
                        if force || detail?.task.revision != current.revision { await loadDetail(selectedTaskID) }
                    } else { self.selectedTaskID = nil; detail = nil }
                }
                guard isCurrentConnection(identity, generation: generation) else { reloadRequested = true; return }
                if sequence != eventSequence && appearance.sharesWidgetSettings { WidgetCenter.shared.reloadAllTimelines() }
                eventSequence = sequence
            }
            connectionError = nil; lastUpdated = Date()
            await refreshQueryResults()
            guard isCurrentConnection(identity, generation: generation) else { reloadRequested = true; return }
            await configureWidgetIfNeeded(configuration: configuration, identity: identity, generation: generation)
            if !isCurrentConnection(identity, generation: generation) { reloadRequested = true }
        } catch {
            if !isCurrentConnection(identity, generation: generation) { reloadRequested = true; return }
            connectionError = error.localizedDescription
        }
    }
    private func refreshQueryResults() async {
        guard !filters.query.isEmpty, lastUpdated != nil else { return }
        let requestedFilters = filters, configuration = appearance.connection, identity = configuration.identity(), generation = connectionGeneration
        let key = "\(generation)\n\(eventSequence ?? -1)\n\(requestedFilters.json.pretty)"
        guard key != queryResultKey else { return }
        do {
            let response = try await client.call("task.list", params: requestedFilters.json.object, configuration: configuration)
            guard isCurrentConnection(identity, generation: generation), requestedFilters == filters else { return }
            queryResultIDs = Set(response["tasks"].array.compactMap { $0["id"].string }); queryResultKey = key
        } catch {
            if isCurrentConnection(identity, generation: generation), requestedFilters == filters { actionError = "Could not read saved view search results. \(error.localizedDescription)" }
        }
    }
    private func configureWidgetIfNeeded(configuration: ConnectionConfiguration, identity: ConnectionIdentity, generation: UUID) async {
        guard isCurrentConnection(identity, generation: generation), configuration.sharesWidgetSnapshot,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WorkboardAppGroup.identifier) else { return }
        let snapshotPath = container.appendingPathComponent("widget-snapshot.json").path
        let key = [identity.executable, identity.dataDirectory, identity.socket, snapshotPath].joined(separator: "\n")
        guard key != widgetConfigurationKey else { return }
        do {
            _ = try await client.call("widget.configure", params: ["snapshot_path": .string(snapshotPath)], configuration: configuration)
            guard isCurrentConnection(identity, generation: generation) else { return }
            widgetConfigurationKey = key
            widgetWarning = nil; WidgetCenter.shared.reloadAllTimelines()
        } catch { if isCurrentConnection(identity, generation: generation) { widgetWarning = "Could not configure the shared widget location. \(error.localizedDescription)" } }
    }
    func poll() async {
        while !Task.isCancelled {
            if NSApp.isActive { await reload() }
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
        }
    }
    func openTask(_ id: String) async {
        guard tasks.contains(where: { $0.id == id }) else { return }
        selectedTaskID = id; detail = nil; await loadDetail(id)
        await refreshPlugins()
    }
    func refreshPlugins() async {
        let configuration = appearance.connection
        let identity = configuration.identity()
        let generation = connectionGeneration
        guard let response = try? await client.call("plugin.list", configuration: configuration),
              isCurrentConnection(identity, generation: generation) else { return }
        orcaPlugin = response["plugins"].array.compactMap(InstalledPlugin.init).first { $0.id == "orca" && $0.enabled && $0.compatible }
    }
    func loadDetail(_ id: String) async {
        let configuration = appearance.connection
        let identity = configuration.identity()
        let generation = connectionGeneration
        do {
            let response = try await client.call("task.get", params: ["task_id": .string(id)], configuration: configuration)
            guard selectedTaskID == id, isCurrentConnection(identity, generation: generation) else { return }
            let eventResponse = try? await client.call("events.list", params: ["after": .number(0)], configuration: configuration)
            guard selectedTaskID == id, isCurrentConnection(identity, generation: generation) else { return }
            detail = TaskDetail(response, events: eventResponse?["events"].array.filter { $0["task_id"].string == id })
            if detail == nil { actionError = "Could not read task details." }
        } catch { if selectedTaskID == id && isCurrentConnection(identity, generation: generation) { actionError = error.localizedDescription } }
    }
    func handle(url: URL) {
        guard url.scheme == "workboard", url.host == "task", let id = url.pathComponents.dropFirst().first, !id.isEmpty else { return }
        if tasks.contains(where: { $0.id == id }) { Task { await openTask(id) } }
        else { pendingDeepLink = id; Task { await reload(force: true) } }
    }
    func newTask(parent: BoardTask? = nil, status: WorkStatus = .todo) {
        guard lastUpdated != nil else { return }
        let projectID = parent?.projectID ?? currentProject?.id ?? projects.first?.id
        guard let projectID else { showingNewProject = true; return }
        draft = TaskDraft(projectID: projectID, parentID: parent?.id)
        draft?.status = status.acceptsNewTasks ? status : .todo
        draft?.workflowContext = workflowContext
    }
    func save(_ draft: TaskDraft) async -> Bool {
        if let templateID = draft.templateID, draft.editingTask == nil {
            var params: [String: JSONValue] = ["template_id": .string(templateID), "project_id": .string(draft.projectID), "title": .string(draft.title.trimmingCharacters(in: .whitespacesAndNewlines))]
            if let parentID = draft.parentID { params["parent_id"] = .string(parentID) }
            if draft.status != .todo { params["status"] = .string(draft.status.rawValue) }
            if let revision = draft.templateRevision { params["expected_revision"] = .number(Double(revision)) }
            guard let result = await workflowMutation("template.apply", params: params, context: draft.workflowContext) else { return false }
            self.draft = nil
            if let id = result["task"]["id"].string ?? result["task_id"].string { await openTask(id) }
            return true
        }
        if draft.hasSchedule && draft.scheduledEnd <= draft.scheduledStart { actionError = "Scheduled end must be after start."; return false }
        var params: [String: JSONValue] = ["title": .string(draft.title.trimmingCharacters(in: .whitespacesAndNewlines)), "goal": .string(draft.goal), "completion_criteria": .string(draft.completionCriteria), "priority": .number(Double(draft.priority)), "next_action": .string(draft.nextAction)]
        params["due_at"] = draft.dueValue.map(JSONValue.string) ?? .null
        params["scheduled_start"] = draft.scheduledStartValue.map(JSONValue.string) ?? .null
        params["scheduled_end"] = draft.scheduledEndValue.map(JSONValue.string) ?? .null
        params["time_zone"] = .string(draft.timeZoneID)
        let method: String
        if let task = draft.editingTask {
            method = "task.update"; params["task_id"] = .string(task.id); params["expected_revision"] = .number(Double(task.revision)); params["blocked_reason"] = .string(draft.blockedReason); params["parent_id"] = draft.parentID.map(JSONValue.string) ?? .null
        } else {
            method = "task.create"; params["project_id"] = .string(draft.projectID)
            if let parentID = draft.parentID { params["parent_id"] = .string(parentID) }
            if draft.status != .todo { params["status"] = .string(draft.status.rawValue) }
        }
        let success = await workflowMutation(method, params: params, context: draft.workflowContext) != nil
        if success { self.draft = nil }
        return success
    }
    func createProject(name: String, directory: String) async -> Bool {
        let success = await mutate("project.create", params: ["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "directory": .string(directory)])
        if success { selectedProjectID = projects.first(where: { $0.name == name.trimmingCharacters(in: .whitespacesAndNewlines) })?.id; showingNewProject = false }
        return success
    }
    func move(_ task: BoardTask, to status: WorkStatus) async {
        guard lastUpdated != nil else { return }
        guard task.status != status else { return }
        if status == .done { completionTask = task; return }
        var params: [String: JSONValue] = ["task_id": .string(task.id), "expected_revision": .number(Double(task.revision))]
        let method: String
        switch status {
        case .inProgress:
            // A closed task reopens to Todo first; starting it then records a new run.
            if task.status.isClosed { method = "task.update"; params["status"] = .string("todo") }
            else { method = "task.start"; params["agent_id"] = .string(task.assignee ?? "user") }
        case .review: method = "task.review"
        case .backlog, .todo, .canceled: method = "task.update"; params["status"] = .string(status.rawValue)
        case .done: return
        }
        let changed = await mutate(method, params: params)
        if changed && task.status.isClosed && status == .inProgress, let reopened = tasks.first(where: { $0.id == task.id }) { await move(reopened, to: .inProgress) }
    }
    func requestDelete(_ task: BoardTask) {
        guard lastUpdated != nil, !isMutating else { return }
        deletionTask = task
    }
    /// Moves the task and the subtasks the confirmation listed to the trash. The service rejects the
    /// request if the task changed after the confirmation was shown.
    @discardableResult func delete(_ task: BoardTask) async -> Bool {
        let subtasks = descendants(of: task)
        var params: [String: JSONValue] = ["task_id": .string(task.id), "expected_revision": .number(Double(task.revision))]
        if !subtasks.isEmpty { params["with_subtasks"] = .bool(true) }
        guard let result = await workflowMutation("task.delete", params: params) else { return false }
        let moved = max(result["deleted_task_ids"].array.count, 1)
        let message = moved == 1 ? "Moved to Trash." : "Task and \(moved - 1) subtasks moved to Trash."
        notice = message; undoDeletion = UndoDeletion(notice: message, taskID: task.id)
        return true
    }
    /// Restores a deletion, with the subtasks deleted alongside it.
    @discardableResult func restore(_ taskID: String) async -> Bool {
        undoDeletion = nil
        guard let result = await workflowMutation("trash.restore", params: ["task_id": .string(taskID)]) else { return false }
        let restored = max(result["restored_task_ids"].array.count, 1)
        notice = restored == 1 ? "Task restored." : "Task and \(restored - 1) subtasks restored."
        return true
    }
    @discardableResult func purge(_ item: TrashItem) async -> Bool {
        let params: [String: JSONValue] = ["task_id": .string(item.task.id), "expected_revision": .number(Double(item.task.revision))]
        guard await workflowMutation("trash.purge", params: params) != nil else { return false }
        notice = "Deleted permanently."
        return true
    }
    @discardableResult func emptyTrash() async -> Bool {
        guard let result = await workflowMutation("trash.empty", params: [:]) else { return false }
        let removed = result["deleted_task_ids"].array.count
        notice = removed == 1 ? "Trash emptied: 1 task deleted permanently." : "Trash emptied: \(removed) tasks deleted permanently."
        return true
    }
    func complete(_ task: BoardTask, summary: String) async -> Bool {
        let success = await mutate("task.complete", params: ["task_id": .string(task.id), "expected_revision": .number(Double(task.revision)), "summary": .string(summary)])
        if success { completionTask = nil }
        return success
    }
    func claim(_ task: BoardTask, agent: String) async -> Bool {
        await mutate("task.claim", params: ["task_id": .string(task.id), "expected_revision": .number(Double(task.revision)), "agent_id": .string(agent.trimmingCharacters(in: .whitespacesAndNewlines))])
    }
    func release(_ task: BoardTask) async -> Bool {
        guard let assignee = task.assignee else { return true }
        return await mutate("task.release", params: ["task_id": .string(task.id), "agent_id": .string(assignee), "expected_revision": .number(Double(task.revision))])
    }
    func attach(_ task: BoardTask, path: String, description: String) async -> Bool {
        await mutate("task.attach", params: ["task_id": .string(task.id), "expected_revision": .number(Double(task.revision)), "path": .string(path), "description": .string(description), "kind": .string(path.hasPrefix("http") ? "url" : "file")])
    }
    func resumeContext(_ task: BoardTask) async {
        do {
            let context = try await client.call("task.resume_context", params: ["task_id": .string(task.id)], configuration: appearance.connection)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(context.pretty, forType: .string)
            notice = "Resume context copied."
        } catch { actionError = error.localizedDescription }
    }
    func backup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "workboard-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).sqlite"; panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        Task { if await mutate("backup.create", params: ["path": .string(path)]) { notice = "Workboard backed up." } }
    }
    func exportBoard(format: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = format == "json" ? "workboard.json" : "workboard.md"; panel.allowedContentTypes = format == "json" ? [.json] : [.plainText]
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        Task { if await mutate("export", params: ["path": .string(path), "format": .string(format)]) { notice = "Workboard exported." } }
    }
    func restoreBackup() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.message = "Choose a workboard SQLite backup to restore."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let confirmation = NSAlert(); confirmation.messageText = "Restore the workboard from this backup?"; confirmation.informativeText = "Current task data will be replaced by the selected backup. Back up the current board first.\n\n\(url.path)"; confirmation.alertStyle = .warning; confirmation.addButton(withTitle: "Restore"); confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        Task { if await mutate("backup.restore", params: ["path": .string(url.path)]) { notice = "Workboard restored from backup." } }
    }
    @discardableResult func mutate(_ method: String, params: [String: JSONValue]) async -> Bool {
        await workflowMutation(method, params: params) != nil
    }
    @discardableResult func workflowMutation(_ method: String, params: [String: JSONValue], openTask taskToOpen: String? = nil, context: WorkflowEditContext? = nil) async -> JSONValue? {
        if invalidateConnectionIfNeeded() { Task { await self.reload(force: true) } }
        if let context, !isCurrentWorkflow(context) { return nil }
        guard !isMutating, lastUpdated != nil else { return nil }
        let configuration = appearance.connection, identity = configuration.identity(), generation = connectionGeneration
        isMutating = true; defer { isMutating = false }
        do {
            let result = try await client.call(method, params: params, configuration: configuration)
            guard isCurrentConnection(identity, generation: generation) else { return nil }
            await reload(force: true)
            guard isCurrentConnection(identity, generation: generation) else { return nil }
            if let taskToOpen { await openTask(taskToOpen) }
            return isCurrentConnection(identity, generation: generation) ? result : nil
        } catch {
            guard isCurrentConnection(identity, generation: generation) else { return nil }
            actionError = error.localizedDescription; await reload(force: true); return nil
        }
    }
}
