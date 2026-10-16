import SwiftUI
import AppKit

struct BoardView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingFilters = false
    @State private var showingTemplates = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar.navigationSplitViewColumnWidth(min: 195, ideal: 225, max: 300)
        } detail: {
            VStack(spacing: 0) {
                boardHeader
                if let error = store.connectionError { connectionBanner(error) }
                if store.isInboxView { InboxView() }
                else if store.isTrashView { TrashView() }
                else if store.projects.isEmpty && !store.isLoading && store.connectionError == nil { firstProject }
                else if store.selectedLayout == "week" { WeeklyPlannerView() }
                else if store.selectedLayout == "list" { TaskListView() }
                else { kanban }
                footer
            }.background(Color(nsColor: .windowBackgroundColor))
                .toolbar { toolbar }
                .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search tasks")
                .inspector(isPresented: Binding(get: { store.selectedTaskID != nil }, set: { if !$0 { store.selectedTaskID = nil; store.detail = nil } })) {
                    TaskDetailView().inspectorColumnWidth(min: 340, ideal: 390, max: 520)
                }
        }
        .onAppear { columnVisibility = appearance.theme.showSidebar ? .all : .detailOnly }
        .onChange(of: appearance.theme.showSidebar) { _, visible in columnVisibility = visible ? .all : .detailOnly }
        .onChange(of: columnVisibility) { _, visibility in appearance.theme.showSidebar = visibility != .detailOnly }
        .onChange(of: store.workflowGeneration) { _, _ in showingFilters = false; showingTemplates = false }
        .sheet(item: $store.draft) { draft in TaskEditorView(draft: draft) }
        .sheet(isPresented: $store.showingNewProject) { NewProjectView() }
        .sheet(item: $store.completionTask) { task in CompleteTaskView(task: task) }
        .confirmationDialog(store.deletionTask.map { "Delete “\($0.title)”?" } ?? "Delete task?", isPresented: Binding(get: { store.deletionTask != nil }, set: { if !$0 { store.deletionTask = nil } }), titleVisibility: .visible, presenting: store.deletionTask) { task in
            Button("Move to Trash", role: .destructive) { Task { await store.delete(task) } }
            Button("Cancel", role: .cancel) {}
        } message: { task in Text(deletionMessage(task)) }
        .sheet(isPresented: $showingFilters) { ViewFilterPanel() }
        .sheet(isPresented: $showingTemplates) { TemplateLibraryView() }
        .alert("Could not process the request", isPresented: Binding(get: { store.actionError != nil }, set: { if !$0 { store.actionError = nil } })) { Button("OK") { store.actionError = nil } } message: { Text(store.actionError ?? "") }
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                let undo = store.undoDeletion?.notice == notice ? store.undoDeletion : nil
                HStack(spacing: 14) {
                    Label(notice, systemImage: undo == nil ? "checkmark.circle.fill" : "trash")
                    if let undo { Button("Undo") { Task { await store.restore(undo.taskID) } }.buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(appearance.accent).disabled(store.isMutating) }
                }.font(.callout).padding(.horizontal, 18).padding(.vertical, 11).background(.regularMaterial, in: Capsule()).shadow(color: .black.opacity(0.08), radius: 12, y: 4).padding(.bottom, 40)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(undo == nil ? 3 : 6))
                        if store.notice == notice { store.notice = nil; if store.undoDeletion?.notice == notice { store.undoDeletion = nil } }
                    }
            }
        }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.3x1.fill").font(.system(size: 22, weight: .medium)).foregroundStyle(appearance.accent)
                VStack(alignment: .leading, spacing: 1) { Text("Workboard").font(.headline); Text("A place to keep work moving").font(.caption2).foregroundStyle(Color.secondary) }
                Spacer()
            }.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sidebarRow("All tasks", symbol: "square.grid.2x2", count: store.tasks.count, id: nil)
                    sidebarRow("Inbox", symbol: "tray", count: store.pendingInbox.count, id: BoardStore.inboxScope)
                    sidebarRow("Today’s schedule", symbol: "calendar", count: store.tasks.filter(\.isScheduledToday).count, id: BoardStore.todayScope)
                    if !store.savedViews.isEmpty {
                        Text("Saved views").font(.system(size: 10, weight: .semibold)).foregroundStyle(BoardInk.secondary(colorScheme)).padding(.horizontal, 10).padding(.top, 20).padding(.bottom, 7)
                        ForEach(store.savedViews) { view in
                            Button { store.selectView(view) } label: { HStack(spacing: 9) { Image(systemName: view.layout == "week" ? "calendar" : view.layout == "list" ? "list.bullet" : "rectangle.split.3x1").frame(width: 16); Text(view.name).lineLimit(1); Spacer() }.font(.system(size: 12)).padding(10).foregroundStyle(store.selectedViewID == view.id ? appearance.accent : BoardInk.primary(colorScheme)).background(store.selectedViewID == view.id ? appearance.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).contextMenu { Button("Edit view…") { store.selectView(view); showingFilters = true } }
                        }
                    }
                    Text("Project").font(.system(size: 10, weight: .semibold)).foregroundStyle(BoardInk.secondary(colorScheme)).padding(.horizontal, 10).padding(.top, 23).padding(.bottom, 7)
                    ForEach(store.projects) { project in
                        sidebarRow(project.name, symbol: "folder", count: store.tasks.filter { $0.projectID == project.id && !$0.status.isClosed }.count, id: project.id)
                            .contextMenu { if !project.directory.isEmpty { Button("Open in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: project.directory)) } } }
                    }
                    Button { store.showingNewProject = true } label: { Label("Add project", systemImage: "plus").font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.buttonStyle(.plain).foregroundStyle(BoardInk.secondary(colorScheme))
                    sidebarRow("Trash", symbol: "trash", count: store.trashedTaskCount, id: BoardStore.trashScope).padding(.top, 14)
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                // Canceled work leaves the scope, as in Linear's progress.
                let scope = store.tasks.filter { $0.status != .canceled }
                if !scope.isEmpty {
                    let done = scope.filter { $0.status == .done }.count
                    HStack { Text("Overall progress").font(.caption).foregroundStyle(Color.secondary); Spacer(); Text("\(done)/\(scope.count)").font(.caption).monospacedDigit().foregroundStyle(Color.secondary) }
                    ProgressView(value: Double(done) / Double(scope.count)).tint(appearance.accent)
                }
                Divider()
                HStack { SettingsLink { Label("Settings", systemImage: "slider.horizontal.3") }.buttonStyle(.plain).font(.callout).foregroundStyle(Color.secondary); Spacer(); Image(systemName: "internaldrive").font(.caption).foregroundStyle(.tertiary).help("Task data is stored on this Mac") }
            }.padding(16)
        }.background(.regularMaterial)
    }
    private func sidebarRow(_ title: String, symbol: String, count: Int, id: String?) -> some View {
        let selected = store.selectedProjectID == id && store.selectedViewID == nil
        return Button { store.clearFilters(); store.selectedProjectID = id } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 16)
                Text(title).font(.system(size: 12, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 10)).monospacedDigit().opacity(0.65)
            }.padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
                .foregroundStyle(selected ? appearance.accent : BoardInk.primary(colorScheme))
                .background(selected ? appearance.accent.opacity(colorScheme == .dark ? 0.18 : 0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : []).accessibilityIdentifier("sidebar.\(id ?? "all")")
    }
    private var boardHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text(store.currentProject == nil ? "Workspace" : "Project").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(0.5).foregroundStyle(Color.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(store.isInboxView ? "Inbox" : store.isTrashView ? "Trash" : store.savedViews.first { $0.id == store.selectedViewID }?.name ?? (store.isTodayView ? "Today’s schedule" : store.currentProject?.name ?? "All tasks")).font(.system(size: 27 * appearance.theme.fontScale, weight: .bold, design: .rounded)).lineLimit(1)
                    Text("\(store.isInboxView ? store.pendingInbox.count : store.isTrashView ? store.trashedTaskCount : store.scopedTasks.count)").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Color.secondary).padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary, in: Capsule())
                }
                Text(store.isInboxView ? "Capture ideas and turn them into tasks when ready." : store.isTrashView ? "Deleted tasks stay here until you empty the trash. Restore brings back their subtasks, runs, and links." : store.scopedTasks.isEmpty ? "Break a large goal into small tasks to get started." : "\(store.scopedTasks.filter { $0.status == .inProgress }.count) in progress · \(store.scopedTasks.filter { $0.status == .review }.count) to review")
                    .font(.system(size: 12 * appearance.theme.fontScale)).foregroundStyle(Color.secondary)
                if !store.filters.isEmpty { HStack { Label("Filters active", systemImage: "line.3.horizontal.decrease"); Button("Reset") { store.clearFilters() }.buttonStyle(.plain).foregroundStyle(appearance.accent) }.font(.caption2).foregroundStyle(Color.secondary) }
            }
            Spacer(minLength: 0)
            if store.isTrashView {
                Button("Empty Trash…", role: .destructive) { store.confirmingEmptyTrash = true }.buttonStyle(BoardSecondaryButtonStyle()).disabled(store.trash.isEmpty || store.isMutating).accessibilityIdentifier("trash-empty")
            }
            if !store.isInboxView && !store.isTrashView {
                Picker("Layout", selection: $store.selectedLayout) { Image(systemName: "rectangle.split.3x1").tag("board").help("Kanban"); Image(systemName: "list.bullet").tag("list").help("List"); Image(systemName: "calendar").tag("week").help("Weekly planner") }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
            }
            if !store.isInboxView && !store.isTrashView {
                Button { store.newTask() } label: { Label("New task", systemImage: "plus").padding(.horizontal, 4).padding(.vertical, 3) }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).keyboardShortcut("n", modifiers: .command).disabled(store.isMutating)
            }
        }.padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 23)
    }
    private var kanban: some View {
        GeometryReader { geometry in
            let statuses = WorkStatus.allCases.filter { appearance.theme.showCompleted || !$0.isClosed }
            let width = max(220, (geometry.size.width - 48 - CGFloat(statuses.count - 1) * 16) / CGFloat(statuses.count))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(statuses) { status in
                        KanbanColumn(status: status, tasks: store.visibleTasks.filter { $0.status == status }).frame(width: width)
                    }
                }.padding(.horizontal, 24).padding(.bottom, 20)
                    .frame(minHeight: geometry.size.height, maxHeight: geometry.size.height, alignment: .topLeading)
                }
        }
        .overlay { if store.isLoading && store.tasks.isEmpty { ProgressView("Loading board…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
    }
    private var firstProject: some View {
        VStack(spacing: 18) {
            ZStack { RoundedRectangle(cornerRadius: 24).fill(appearance.accent.opacity(0.08)).frame(width: 88, height: 88); Image(systemName: "rectangle.split.3x1").font(.system(size: 35, weight: .light)).foregroundStyle(appearance.accent) }
            VStack(spacing: 8) { Text("Start your first project").font(.title2.weight(.semibold)); Text("Organize goals and subtasks,\nand manage the same board in the app and CLI.").font(.callout).foregroundStyle(Color.secondary).multilineTextAlignment(.center) }
            Button("Create project") { store.showingNewProject = true }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).controlSize(.large)
            Text("Get started without integrations or external accounts.").font(.caption).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
    private func connectionBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 5) { Text("Could not connect to the task service").font(.callout.weight(.semibold)); Text(message).font(.caption).foregroundStyle(Color.secondary).textSelection(.enabled).lineLimit(4) }
            Spacer()
            Button("Retry") { Task { await store.reload(force: true) } }.disabled(store.isLoading)
            SettingsLink { Text("Connection settings") }
        }.padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 24).padding(.bottom, 16)
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(store.connectionError == nil && store.lastUpdated != nil ? Color.green.opacity(0.8) : Color.orange).frame(width: 5, height: 5)
            Text(store.connectionError == nil ? "Local workboard" : "Connection needs attention")
            Spacer()
            if store.isMutating { ProgressView().controlSize(.mini); Text("Saving…") }
            else if let date = store.lastUpdated { Text(date, format: .dateTime.hour().minute()).monospacedDigit(); Text("Refresh") }
        }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 26).padding(.vertical, 9)
    }
    private func deletionMessage(_ task: BoardTask) -> String {
        let subtasks = store.descendants(of: task)
        var lines: [String] = []
        if !subtasks.isEmpty { lines.append(subtasks.count == 1 ? "Its subtask moves to Trash too." : "Its \(subtasks.count) subtasks move to Trash too.") }
        let holders = Set(([task] + subtasks).compactMap { $0.status.isClosed ? nil : $0.assignee }).sorted()
        if !holders.isEmpty { lines.append("Held by \(holders.joined(separator: ", ")). Running work stops.") }
        lines.append("Restore it from Trash with its runs and links until you empty the trash.")
        return lines.joined(separator: "\n\n")
    }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await store.reload(force: true) } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh (⌘R)").disabled(store.isLoading)
            Menu {
                Button("Filters and saved views…") { showingFilters = true }
                Button("Task templates…") { showingTemplates = true }
                Divider()
                Toggle("Show Done and Canceled columns", isOn: $appearance.theme.showCompleted)
                Toggle("Show subtasks on the board", isOn: $appearance.theme.showSubtasksOnBoard)
                Picker("Card density", selection: $appearance.theme.density) { ForEach(CardDensity.allCases) { Text($0.title).tag($0) } }
                Divider()
                SettingsLink { Text("Appearance settings…") }
            } label: { Image(systemName: "line.3.horizontal.decrease") }.help("View settings")
        }
    }
}

private struct KanbanColumn: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    let status: WorkStatus
    let tasks: [BoardTask]
    @State private var isTargeted = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: status.symbol).foregroundStyle(status.color).font(.system(size: 12, weight: .semibold))
                Text(status.title).font(.system(size: 12 * appearance.theme.fontScale, weight: .semibold))
                Text("\(tasks.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.08), in: Capsule())
                Spacer()
                if status.acceptsNewTasks { Button { store.newTask(status: status) } label: { Image(systemName: "plus").font(.system(size: 12)) }.buttonStyle(.plain).foregroundStyle(Color.secondary).help("Add task to \(status.title)").accessibilityLabel("Add task to \(status.title)") }
            }.padding(.horizontal, 7).padding(.top, 2).padding(.bottom, 13)
            ScrollView(.vertical) {
                LazyVStack(spacing: 11) {
                    ForEach(tasks) { task in TaskCard(task: task) }
                    if tasks.isEmpty {
                        VStack(spacing: 7) { Image(systemName: status == .done ? "checkmark" : status == .canceled ? "xmark" : "rectangle.dashed").font(.system(size: 20, weight: .ultraLight)); Text(store.searchText.isEmpty ? "No tasks yet" : "No matching tasks").font(.system(size: 11)) }.foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    Spacer(minLength: 36)
                }.padding(3)
            }.scrollIndicators(.hidden)
        }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(isTargeted ? appearance.accent.opacity(0.08) : Color.secondary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(isTargeted ? appearance.accent.opacity(0.6) : Color.clear, lineWidth: 1.5))
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first, let task = store.tasks.first(where: { $0.id == id }), !store.isMutating else { return false }
                Task { await store.move(task, to: status) }; return true
            } isTargeted: { isTargeted = $0 }
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
            .accessibilityElement(children: .contain).accessibilityIdentifier("column.\(status.rawValue)")
    }
}

struct TaskCard: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    let task: BoardTask
    @State private var hovered = false
    private var children: [BoardTask] { store.children(of: task) }
    private var isSelected: Bool { store.selectedTaskID == task.id }
    var body: some View {
        Button { Task { await store.openTask(task.id) } } label: {
            VStack(alignment: .leading, spacing: appearance.theme.density == .compact ? 9 : 13) {
                if store.selectedProjectID == nil || task.parentID != nil {
                    HStack(spacing: 4) { Image(systemName: task.parentID != nil ? "arrow.turn.down.right" : "folder"); Text(task.parentID.flatMap { id in store.tasks.first { $0.id == id }?.title } ?? store.projectName(for: task.projectID)).lineLimit(1) }.font(.system(size: 10 * appearance.theme.fontScale)).foregroundStyle(.tertiary)
                }
                HStack(alignment: .top, spacing: 5) {
                    Text(task.title).font(.system(size: 13 * appearance.theme.fontScale, weight: .medium)).lineLimit(4).multilineTextAlignment(.leading).foregroundStyle(Color.primary)
                    Spacer(minLength: 0)
                    if task.priority >= 3 { Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(.orange).padding(.top, 3).help("High priority") }
                }
                if !task.goal.isEmpty && appearance.theme.density == .comfortable { Text(task.goal).font(.system(size: 11 * appearance.theme.fontScale)).foregroundStyle(Color.secondary).lineLimit(2).multilineTextAlignment(.leading) }
                if !task.blockedReason.isEmpty { Label("Blocked · \(task.blockedReason)", systemImage: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2).multilineTextAlignment(.leading) }
                if !task.blockedBy.isEmpty { Label("Prerequisites remaining: \(task.blockedBy.count)", systemImage: "hourglass").font(.system(size: 10)).foregroundStyle(.orange) }
                else if task.ready { Label("Ready", systemImage: "play.circle").font(.system(size: 10)).foregroundStyle(appearance.accent.opacity(0.8)) }
                if !task.status.isClosed && task.isStale(days: store.filters.staleDays ?? 14) { Label("No recent updates", systemImage: "clock").font(.system(size: 9)).foregroundStyle(Color.secondary).help("No updates for at least \(store.filters.staleDays ?? 14) days") }
                if let start = task.startDate { Label { HStack(spacing: 3) { Text(start, format: task.scheduledStart?.count == 10 ? .dateTime.month().day() : .dateTime.month().day().hour().minute()); if task.scheduledStart?.count == 10 { Text("· All day") } } } icon: { Image(systemName: "calendar") }.font(.system(size: 10)).foregroundStyle(appearance.accent) }
                if let due = task.dueDate { Label { HStack(spacing: 3) { Text(task.isOverdue ? "Overdue" : "Due"); Text(due, format: task.dueAt?.count == 10 ? .dateTime.month().day() : .dateTime.month().day().hour().minute()) } } icon: { Image(systemName: "clock") }.font(.system(size: 10)).foregroundStyle(task.isOverdue ? .red : .secondary) }
                let counted = children.filter { $0.status != .canceled }
                if !counted.isEmpty {
                    let completed = counted.filter { $0.status == .done }.count
                    HStack(spacing: 7) { Image(systemName: "checklist"); ProgressView(value: Double(completed), total: Double(counted.count)).tint(appearance.accent); Text("\(completed)/\(counted.count)").monospacedDigit() }.font(.system(size: 10)).foregroundStyle(Color.secondary)
                }
                HStack(spacing: 6) {
                    if let assignee = task.assignee {
                        Text(String(assignee.prefix(1)).uppercased()).font(.system(size: 9, weight: .medium)).frame(width: 18, height: 18).background(appearance.accent.opacity(0.1), in: Circle()).foregroundStyle(appearance.accent)
                        Text(assignee).font(.system(size: 10)).foregroundStyle(Color.secondary).lineLimit(1)
                        if task.claimStale && !task.status.isClosed { Image(systemName: "exclamationmark.clock").font(.system(size: 10)).foregroundStyle(.orange).help("Check the assignee’s activity") }
                    } else { Image(systemName: "person.crop.circle.dashed").font(.system(size: 14)).foregroundStyle(.tertiary); Text("Unassigned").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    Spacer()
                    if !task.nextAction.isEmpty { Image(systemName: "arrow.right.circle").font(.system(size: 11)).foregroundStyle(appearance.accent.opacity(0.75)).help(task.nextAction) }
                    Image(systemName: "ellipsis").foregroundStyle(.tertiary).font(.system(size: 11))
                }
            }.padding(appearance.theme.density.padding).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? appearance.accent.opacity(0.75) : Color.primary.opacity(hovered ? 0.14 : 0.065), lineWidth: isSelected ? 1.5 : 1))
                .shadow(color: .black.opacity(hovered ? 0.05 : 0.015), radius: hovered ? 6 : 2, y: 2)
        }.buttonStyle(.plain).onHover { hovered = $0 }.draggable(task.id)
            .contextMenu {
                Button("Open task") { Task { await store.openTask(task.id) } }
                Button("Add subtask") { store.newTask(parent: task) }
                Button("Edit…") { store.draft = TaskDraft(projectID: task.projectID, editingTask: task) }
                Divider()
                ForEach(WorkStatus.allCases) { status in Button { Task { await store.move(task, to: status) } } label: { Label(status.title, systemImage: status.symbol) }.disabled(task.status == status || store.isMutating) }
                Divider()
                Button("Copy task link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("workboard://task/\(task.id)", forType: .string); store.notice = "Task link copied." }
                Button("Copy resume context") { Task { await store.resumeContext(task) } }
                Divider()
                Button("Delete…", role: .destructive) { store.requestDelete(task) }.disabled(store.isMutating)
            }
            .accessibilityElement(children: .combine).accessibilityLabel("\(task.title), \(task.status.title), \(task.assignee ?? "Unassigned")")
            .accessibilityIdentifier("task.\(task.id)")
    }
}

struct TrashView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    private var items: [TrashItem] {
        store.searchText.isEmpty ? store.trash : store.trash.filter { item in item.tasks.contains { $0.title.localizedStandardContains(store.searchText) } }
    }
    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(store.trash.isEmpty ? "Trash is empty" : "No matching tasks", systemImage: "trash", description: Text(store.trash.isEmpty ? "Deleted tasks wait here so you can restore them." : "Change the search."))
            } else {
                ScrollView { LazyVStack(spacing: 10) { ForEach(items) { row($0) } }.padding(.horizontal, 26).padding(.bottom, 20) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .confirmationDialog(store.purgeItem.map { "Delete “\($0.task.title)” permanently?" } ?? "Delete permanently?", isPresented: Binding(get: { store.purgeItem != nil }, set: { if !$0 { store.purgeItem = nil } }), titleVisibility: .visible, presenting: store.purgeItem) { item in
                Button("Delete Permanently", role: .destructive) { Task { await store.purge(item) } }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                let count = store.purgeCount(item)
                Text((count > 1 ? "This also deletes \(count - 1) subtasks. " : "") + "Runs, artifact links, checklists, and review history are removed. The change history keeps a record, but this cannot be undone.")
            }
            .confirmationDialog("Empty Trash?", isPresented: $store.confirmingEmptyTrash, titleVisibility: .visible) {
                Button("Empty Trash", role: .destructive) { Task { await store.emptyTrash() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Permanently deletes \(store.trashedTaskCount == 1 ? "1 task" : "\(store.trashedTaskCount) tasks") with their runs and artifact links. This cannot be undone.")
            }
    }
    private func row(_ item: TrashItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.task.status.symbol).foregroundStyle(item.task.status.color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.task.title).font(.headline).textSelection(.enabled)
                HStack(spacing: 10) {
                    Label(store.projectName(for: item.task.projectID), systemImage: "folder")
                    if item.subtaskCount > 0 { Label(item.subtaskCount == 1 ? "1 subtask" : "\(item.subtaskCount) subtasks", systemImage: "checklist") }
                    Text(item.task.status.title)
                }.font(.caption).foregroundStyle(.secondary)
                Text("Deleted \(BoardDate.shortLocalTimestamp(item.deletedAt))" + (item.deletedBy.map { " by \($0)" } ?? "")).font(.caption2).foregroundStyle(.tertiary)
                if let parent = item.parentInTrash { Label("Restore its parent “\(parent)” first.", systemImage: "arrow.uturn.backward").font(.caption).foregroundStyle(.orange) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore") { Task { await store.restore(item.task.id) } }.disabled(!item.restorable || store.isMutating).accessibilityIdentifier("trash-restore-\(item.task.id)")
            Button("Delete Permanently…", role: .destructive) { store.purgeItem = item }.disabled(store.isMutating).accessibilityIdentifier("trash-delete-\(item.task.id)")
        }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain).accessibilityIdentifier("trash.\(item.task.id)")
    }
}
