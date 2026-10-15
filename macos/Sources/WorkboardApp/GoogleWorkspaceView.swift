import SwiftUI

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let detail: String
    let url: String
    let etag: String
    let start: String
    let end: String
    let timeZone: String
    init?(_ json: JSONValue) {
        self.init(json, fallbackTimeZone: TimeZone.current.identifier)
    }
    init?(_ json: JSONValue, fallbackTimeZone: String) {
        let json = json["event"] == .null ? json : json["event"]
        guard let id = json["id"].string else { return nil }
        self.id = id; title = json["title"].string ?? json["summary"].string ?? "Untitled event"
        detail = json["detail"].string ?? json["description"].string ?? ""
        url = json["url"].string ?? json["htmlLink"].string ?? ""; etag = json["etag"].string ?? ""
        start = json["start"].string ?? json["start"]["dateTime"].string ?? json["start"]["date"].string ?? ""
        end = json["end"].string ?? json["end"]["dateTime"].string ?? json["end"]["date"].string ?? ""
        let candidate = json["time_zone"].string ?? json["start"]["timeZone"].string ?? fallbackTimeZone
        timeZone = TimeZone(identifier: candidate) != nil ? candidate : fallbackTimeZone
    }
    var dateLabel: String {
        guard let date = BoardDate.parse(start, timeZone: start.count == 10 ? TimeZone.current.identifier : timeZone) else { return start }
        if start.count == 10 { return date.formatted(.dateTime.month().day().locale(BoardDate.displayLocale)) + " · All day" }
        let startLabel = date.formatted(.dateTime.month().day().hour().minute().locale(BoardDate.displayLocale))
        guard let endDate = BoardDate.parse(end, timeZone: timeZone) else { return startLabel }
        return startLabel + " – " + endDate.formatted(.dateTime.hour().minute().locale(BoardDate.displayLocale))
    }
}

struct GoogleCalendarView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var board: BoardStore
    let plugin: InstalledPlugin
    @ObservedObject var plugins: PluginStore
    @State private var calendars: [JSONValue] = []
    @State private var calendarID = "primary"
    @State private var rangeStart = Date()
    @State private var rangeEnd = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var events: [CalendarEvent] = []
    @State private var selectedEvent: CalendarEvent?
    @State private var projectID = ""
    @State private var showingUpdateConfirmation = false
    @State private var showingPullConfirmation = false
    @State private var didSearch = false
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Button("Connect Google account…") { authorize() }; Button("Read calendars") { Task { await loadCalendars(); await loadEvents() } }; Spacer(); Menu { Button("Check connection") { Task { if await plugins.run(plugin, method: "check", configuration: appearance.connection) != nil { plugins.notice = "Google connection verified." } } }; Button("Disconnect account") { Task { if await plugins.run(plugin, method: "disconnect", configuration: appearance.connection) != nil { plugins.notice = "Google account disconnected."; events = []; calendars = []; selectedEvent = nil } } } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20) }.disabled(plugins.busy)
            HStack {
                Picker("Calendar", selection: $calendarID) {
                    if calendars.isEmpty { Text("Primary calendar").tag("primary") }
                    ForEach(Array(calendars.enumerated()), id: \.offset) { row in Text(row.element["summary"].string ?? row.element["name"].string ?? row.element["id"].string ?? "Calendar").tag(row.element["id"].string ?? "primary") }
                }.frame(maxWidth: .infinity)
                DatePicker("Start", selection: $rangeStart, displayedComponents: [.date]).labelsHidden()
                Text("–").foregroundStyle(.tertiary)
                DatePicker("End", selection: $rangeEnd, displayedComponents: [.date]).labelsHidden()
                Button("Load") { Task { await loadEvents() } }.disabled(plugins.busy || rangeEnd < rangeStart)
            }.font(.caption)
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if events.isEmpty { VStack(spacing: 9) { Image(systemName: "calendar").font(.system(size: 24, weight: .ultraLight)); Text(didSearch ? "No events in this date range." : "Connect an account, then read its calendars.").font(.caption) }.foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 60) }
                        ForEach(events) { event in
                            Button { selectedEvent = event } label: {
                                VStack(alignment: .leading, spacing: 7) { Text(event.title).font(.callout.weight(.medium)).lineLimit(2); Text(event.dateLabel).font(.caption2).foregroundStyle(Color.secondary) }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(selectedEvent?.id == event.id ? appearance.accent.opacity(0.08) : Color.clear)
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }.frame(minWidth: 220)
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
                        if let event = selectedEvent { eventDetail(event) }
                        if let task = board.selectedTask {
                            if selectedEvent != nil { Divider() }
                            taskActions(task)
                        } else if selectedEvent == nil {
                            Text("Select an event to import it as a kanban task.\nSelect a board task to add its deadline or meeting to the calendar.").font(.caption).foregroundStyle(Color.secondary).lineSpacing(5).padding(.top, 40)
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 280)
            }
            Text("Events are not saved or synced automatically. Import tasks or change events using the corresponding buttons.").font(.caption2).foregroundStyle(Color.secondary)
        }.padding(16).onAppear { projectID = board.currentProject?.id ?? board.projects.first?.id ?? "" }
            .confirmationDialog("Update the selected calendar event from this task?", isPresented: $showingUpdateConfirmation, titleVisibility: .visible) {
                Button("Update event") { if let event = selectedEvent, let task = board.selectedTask { update(event, from: task) } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("The event title, description, and time will use the selected task’s values. No invitations or email will be sent.") }
            .confirmationDialog("Apply this calendar event to the selected task?", isPresented: $showingPullConfirmation, titleVisibility: .visible) {
                Button("Apply event to task") { if let event = selectedEvent, let task = board.selectedTask { pull(event, into: task) } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Updates the task’s due date, schedule, and time zone from the event. Its title, goal, assignee, and status are preserved.") }
    }
    @ViewBuilder private func eventDetail(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(event.title).font(.title3.weight(.semibold)); Label(event.dateLabel, systemImage: "calendar").font(.caption).foregroundStyle(appearance.accent)
            if !event.detail.isEmpty { Text(event.detail).font(.caption).textSelection(.enabled).lineLimit(12) }
            if let url = URL(string: event.url), ["https", "http"].contains(url.scheme ?? "") { Link("Open in Google Calendar", destination: url).font(.caption) }
            Picker("Import into project", selection: $projectID) { ForEach(board.projects) { Text($0.name).tag($0.id) } }.font(.caption)
            Button("Import event as a new task") { importEvent(event) }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).disabled(projectID.isEmpty || plugins.busy)
            if let task = board.selectedTask, !event.url.isEmpty { Button("Attach event link to current task") { Task { if await board.attach(task, path: event.url, description: event.title) { plugins.notice = "Event link attached to the current task." } } }.disabled(plugins.busy || board.isMutating) }
        }
    }
    private func taskActions(_ task: BoardTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected task").font(.caption.weight(.semibold)).foregroundStyle(Color.secondary)
            Text(task.title).font(.callout.weight(.medium)).lineLimit(3)
            if let due = task.dueDate { Label { Text(due, format: .dateTime.month().day().locale(BoardDate.displayLocale)) } icon: { Image(systemName: "flag") }.font(.caption).foregroundStyle(Color.secondary) }
            if let start = task.startDate { Label { Text(start, format: .dateTime.month().day().hour().minute().locale(BoardDate.displayLocale)) } icon: { Image(systemName: "clock") }.font(.caption).foregroundStyle(Color.secondary) }
            if task.dueAt != nil { Button("Add deadline to calendar") { create(from: task, deadlineOnly: true) }.disabled(plugins.busy) }
            if task.scheduledStart != nil && task.scheduledEnd != nil { Button("Add meeting to calendar") { create(from: task, deadlineOnly: false) }.disabled(plugins.busy) }
            if task.dueAt == nil && task.scheduledStart == nil { Text("Set a due date or schedule in the task editor first.").font(.caption).foregroundStyle(Color.secondary) }
            if selectedEvent != nil {
                Divider()
                Text("Choose update direction").font(.caption.weight(.medium)).foregroundStyle(Color.secondary)
                if task.dueAt != nil || task.scheduledStart != nil { Button("Task → Update calendar event…") { showingUpdateConfirmation = true }.disabled(plugins.busy || selectedEvent?.etag.isEmpty != false) }
                Button("Apply event to task…") { showingPullConfirmation = true }.disabled(plugins.busy || board.isMutating || selectedEvent?.etag.isEmpty != false)
            }
        }
    }
    private func authorize() { Task { if await plugins.run(plugin, method: "authorize", configuration: appearance.connection) != nil { plugins.notice = "Google account connected."; await loadCalendars(); await loadEvents() } } }
    private func loadCalendars() async {
        guard let result = await plugins.run(plugin, method: "calendar.list", configuration: appearance.connection) else { return }
        calendars = result["calendars"].array
        if !calendars.contains(where: { $0["id"].string == calendarID }) { calendarID = calendars.first(where: { $0["primary"].bool == true })?["id"].string ?? calendars.first?["id"].string ?? "primary" }
    }
    private func loadEvents() async {
        guard rangeEnd >= rangeStart else { return }
        let start = Calendar.current.startOfDay(for: rangeStart)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: rangeEnd)) ?? rangeEnd
        if let result = await plugins.run(plugin, method: "events.list", params: ["calendar_id": .string(calendarID), "time_min": .string(BoardDate.timestamp(start)), "time_max": .string(BoardDate.timestamp(end))], configuration: appearance.connection) {
            events = result["events"].array.compactMap { CalendarEvent($0, fallbackTimeZone: result["time_zone"].string ?? TimeZone.current.identifier) }; didSearch = true
            if let selectedEvent { self.selectedEvent = events.first(where: { $0.id == selectedEvent.id }) }
        }
    }
    private func taskJSON(_ task: BoardTask, deadlineOnly: Bool = false) -> JSONValue {
        .object(["id": .string(task.id), "title": .string(task.title), "goal": .string(task.goal), "revision": .number(Double(task.revision)), "due_at": task.dueAt.map(JSONValue.string) ?? .null, "scheduled_start": deadlineOnly ? .null : task.scheduledStart.map(JSONValue.string) ?? .null, "scheduled_end": deadlineOnly ? .null : task.scheduledEnd.map(JSONValue.string) ?? .null, "time_zone": .string(task.timeZone)])
    }
    private func create(from task: BoardTask, deadlineOnly: Bool) {
        Task { if let result = await plugins.run(plugin, method: "events.create", params: ["calendar_id": .string(calendarID), "task": taskJSON(task, deadlineOnly: deadlineOnly)], configuration: appearance.connection) { selectedEvent = CalendarEvent(result); plugins.notice = deadlineOnly ? "Deadline added to the calendar." : "Meeting added to the calendar."; await board.reload(force: true); await loadEvents() } }
    }
    private func update(_ event: CalendarEvent, from task: BoardTask) {
        Task { if let result = await plugins.run(plugin, method: "events.update", params: ["calendar_id": .string(calendarID), "event_id": .string(event.id), "etag": .string(event.etag), "task": taskJSON(task)], configuration: appearance.connection) { selectedEvent = CalendarEvent(result); plugins.notice = "Calendar event updated."; await board.reload(force: true); await loadEvents() } }
    }
    private func pull(_ event: CalendarEvent, into task: BoardTask) {
        let taskReference: JSONValue = .object(["id": .string(task.id), "revision": .number(Double(task.revision))])
        Task {
            if await plugins.run(plugin, method: "events.pull", params: ["calendar_id": .string(calendarID), "event_id": .string(event.id), "etag": .string(event.etag), "task": taskReference], configuration: appearance.connection) != nil {
                plugins.notice = "Calendar event applied to the selected task."
                await board.reload(force: true)
            }
        }
    }
    private func importEvent(_ event: CalendarEvent) {
        Task { if await plugins.run(plugin, method: "events.import", params: ["calendar_id": .string(calendarID), "event_id": .string(event.id), "project_id": .string(projectID)], configuration: appearance.connection) != nil { plugins.notice = "Calendar event imported as a kanban task."; await board.reload(force: true) } }
    }
}
