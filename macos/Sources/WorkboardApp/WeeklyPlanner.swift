import SwiftUI

enum PlannerClock {
    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
    static func days(containing date: Date, zone: String) -> [Date] {
        let calendar = calendar(zone)
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    static func slot(day: Date, hour: Int, zone: String) -> Date? {
        let calendar = calendar(zone)
        guard let value = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day, matchingPolicy: .strict),
              calendar.isDate(value, inSameDayAs: day), calendar.component(.hour, from: value) == hour else { return nil }
        return value
    }
    static func interval(start: String?, end: String?, zone: String) -> DateInterval? {
        guard let start = BoardDate.parse(start, timeZone: zone), let end = BoardDate.parse(end, timeZone: zone), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
    static func overlaps(_ first: DateInterval, _ second: DateInterval) -> Bool {
        first.start < second.end && second.start < first.end
    }
    static func dayInterval(_ day: Date, zone: String) -> DateInterval {
        let calendar = calendar(zone), start = calendar.startOfDay(for: day)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }
    static func minute(_ date: Date, on day: Date, zone: String) -> Double {
        let bounds = dayInterval(day, zone: zone)
        if date <= bounds.start { return 0 }
        if date >= bounds.end { return bounds.duration / 60 }
        return date.timeIntervalSince(bounds.start) / 60
    }
    static func slots(day: Date, zone: String) -> [Date] {
        let bounds = dayInterval(day, zone: zone)
        return stride(from: 0.0, to: bounds.duration, by: 3600).map { bounds.start.addingTimeInterval($0) }
    }
    static func label(_ date: Date, zone: String, includeZone: Bool = false) -> String {
        let formatter = DateFormatter(); formatter.locale = BoardDate.displayLocale; formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = includeZone ? "HH:mm z" : "HH:mm"
        return formatter.string(from: date)
    }
    static func dayLabel(_ date: Date, zone: String, weekday: Bool) -> String {
        let formatter = DateFormatter(); formatter.locale = BoardDate.displayLocale; formatter.timeZone = TimeZone(identifier: zone)
        formatter.setLocalizedDateFormatFromTemplate(weekday ? "EEE" : "d")
        return formatter.string(from: date)
    }
    static func lanes(_ intervals: [DateInterval]) -> [Int] {
        var ends: [Date] = []
        return intervals.map { interval in
            if let lane = ends.firstIndex(where: { $0 <= interval.start }) { ends[lane] = interval.end; return lane }
            ends.append(interval.end); return ends.count - 1
        }
    }
}

private struct PlannerEntry: Identifiable {
    let id: String
    let title: String
    let interval: DateInterval
    let allDay: Bool
    let task: BoardTask?
    var external: Bool { task == nil }
}

struct PlannerDraft: Identifiable {
    let id = UUID()
    let task: BoardTask
    let connection: ConnectionIdentity
    let generation: UUID
    var start: Date
    var end: Date
    var allDay: Bool
    var zone: String
    init(task: BoardTask, at date: Date?, zone: String, connection: ConnectionIdentity, generation: UUID = UUID()) {
        let interval = PlannerClock.interval(start: task.scheduledStart, end: task.scheduledEnd, zone: task.timeZone)
        self.task = task; self.zone = date == nil && interval != nil ? task.timeZone : zone; self.connection = connection; self.generation = generation
        allDay = date == nil && task.scheduledStart?.count == 10
        start = date ?? interval?.start ?? Date()
        end = date.map { $0.addingTimeInterval(min(max(interval?.duration ?? 3600, 900), 86_400)) } ?? interval?.end ?? start.addingTimeInterval(3600)
    }
    var startValue: String { allDay ? BoardDate.dateOnly(start, timeZone: zone) : BoardDate.timestamp(start) }
    var endValue: String { allDay ? BoardDate.dateOnly(end, timeZone: zone) : BoardDate.timestamp(end) }
    var fingerprint: String { "\(task.id)|\(task.revision)|\(startValue)|\(endValue)|\(zone)" }
    mutating func changeTimeZone(to newZone: String) throws {
        guard TimeZone(identifier: newZone) != nil else { throw WorkboardError(message: "Enter a valid IANA time zone.") }
        guard zone != newZone else { return }
        if allDay {
            let first = startValue, last = endValue
            guard let newStart = BoardDate.parse(first, timeZone: newZone),
                  let newEnd = BoardDate.parse(last, timeZone: newZone),
                  BoardDate.dateOnly(newStart, timeZone: newZone) == first,
                  BoardDate.dateOnly(newEnd, timeZone: newZone) == last else {
                throw WorkboardError(message: "This all-day date does not exist in the selected time zone.")
            }
            start = newStart; end = newEnd
        }
        zone = newZone
    }
}

struct WeeklyPlannerView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @StateObject private var plugins = PluginStore()
    @State private var anchor = Date()
    @State private var draft: PlannerDraft?
    @State private var googleEvents: [CalendarEvent] = []
    @State private var fetchedRange = ""
    @State private var calendarID = "primary"
    @State private var calendars: [JSONValue] = []
    @State private var usingPlugin: InstalledPlugin?
    private let minuteHeight: CGFloat = 0.75
    private var zone: String { appearance.plannerTimeZone }
    private var days: [Date] { PlannerClock.days(containing: anchor, zone: zone) }
    private var tasks: [BoardTask] { store.visibleTasks.filter { !$0.status.isClosed } }
    private var entries: [PlannerEntry] {
        let local = tasks.compactMap { task -> PlannerEntry? in
            guard let interval = PlannerClock.interval(start: task.scheduledStart, end: task.scheduledEnd, zone: task.timeZone) else { return nil }
            return PlannerEntry(id: task.id, title: task.title, interval: interval, allDay: task.scheduledStart?.count == 10, task: task)
        }
        let external = googleEvents.compactMap { event -> PlannerEntry? in
            guard let interval = PlannerClock.interval(start: event.start, end: event.end, zone: event.timeZone) else { return nil }
            return PlannerEntry(id: "google-\(event.id)", title: event.title, interval: interval, allDay: event.start.count == 10, task: nil)
        }
        return local + external
    }
    private var rangeKey: String { (days.first.map { BoardDate.dateOnly($0, timeZone: zone) } ?? "") + "|" + zone + "|" + calendarID }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            unscheduled
            googleControls
            if let error = plugins.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            calendarCanvas
            Text("Drop a task into a time slot to check conflicts before saving. Google events appear only for the range you explicitly read.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(20)
            .sheet(item: $draft) { value in
                PlannerScheduleEditor(draft: value, googleEvents: googleEvents)
            }
            .sheet(item: $usingPlugin) { plugin in PluginBrowserView(plugin: plugin, plugins: plugins) }
            .onChange(of: rangeKey) { _, _ in googleEvents = []; fetchedRange = "" }
            .onChange(of: appearance.connection.identity()) { _, _ in draft = nil; usingPlugin = nil; googleEvents = []; calendars = []; fetchedRange = "" }
            .onChange(of: store.workflowGeneration) { _, _ in draft = nil; usingPlugin = nil; googleEvents = []; calendars = []; fetchedRange = "" }
    }
    private var calendarCanvas: some View {
        GeometryReader { geometry in
            let width = max(132, (geometry.size.width - 1) / 7)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 1)
                        ForEach(days, id: \.self) { day in dayHeader(day, width: width) }
                    }.frame(height: 104)
                    Divider()
                    ScrollViewReader { reader in
                        ScrollView(.vertical) {
                            HStack(alignment: .top, spacing: 0) {
                                VStack(spacing: 0) {
                                    ForEach(0..<25) { hour in
                                        Color.clear.frame(width: 1, height: minuteHeight * 60).id("hour-\(hour)")
                                    }
                                }
                                ForEach(days, id: \.self) { day in dayTimeline(day, width: width) }
                            }
                        }.onAppear { reader.scrollTo("hour-8", anchor: .top) }
                    }
                }.frame(width: width * 7 + 1, height: geometry.size.height)
            }
        }.background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Weekly planner").font(.title2.weight(.semibold))
                if let first = days.first, let last = days.last {
                    Text("\(BoardDate.dateOnly(first, timeZone: zone)) – \(BoardDate.dateOnly(last, timeZone: zone))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu(zone) {
                ForEach(Array(Set([TimeZone.current.identifier, "Asia/Seoul", "UTC", "America/Los_Angeles", "America/New_York", "Europe/London"])).sorted(), id: \.self) { value in
                    Button(value) { appearance.plannerTimeZone = value }
                }
            }.fixedSize()
            Button { moveWeek(-1) } label: { Image(systemName: "chevron.left") }.help("Previous week")
            Button("This week") { anchor = Date() }
            Button { moveWeek(1) } label: { Image(systemName: "chevron.right") }.help("Next week")
        }
    }
    private var unscheduled: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Unscheduled").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    let rows = tasks.filter { $0.scheduledStart == nil }
                    if rows.isEmpty { Text("No unscheduled tasks.").font(.caption).foregroundStyle(.tertiary) }
                    ForEach(rows) { task in
                        Button { edit(task) } label: { Label(task.title, systemImage: "plus.circle").font(.caption).lineLimit(1).padding(8) }
                            .buttonStyle(.plain).background(appearance.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .draggable(task.id).accessibilityIdentifier("planner-unscheduled-\(task.id)")
                    }
                }
            }
        }
    }
    private var googleControls: some View {
        ScrollView(.horizontal) {
          HStack {
            Image(systemName: "calendar").foregroundStyle(.secondary)
            Text("Google Calendar").font(.caption)
            if !calendars.isEmpty {
                Picker("Calendar", selection: $calendarID) {
                    Text("Primary calendar").tag("primary")
                    ForEach(Array(calendars.enumerated()), id: \.offset) { row in
                        Text(row.element["summary"].string ?? row.element["id"].string ?? "").tag(row.element["id"].string ?? "")
                    }
                }.labelsHidden().frame(maxWidth: 200)
            }
            Button("Read this week") { Task { await readGoogle() } }.disabled(plugins.busy)
            Button("Integration settings and updates…") { Task { await openGoogle() } }.disabled(plugins.busy)
            if plugins.busy { ProgressView().controlSize(.small) }
            if !fetchedRange.isEmpty { Text("\(googleEvents.count) events loaded").font(.caption2).foregroundStyle(.secondary) }
            Spacer()
          }
        }
        .frame(height: 30)
    }
    private func dayHeader(_ day: Date, width: CGFloat) -> some View {
        let bounds = PlannerClock.dayInterval(day, zone: zone)
        let rows = entries.filter { PlannerClock.overlaps($0.interval, bounds) }
        return VStack(spacing: 4) {
                Text(PlannerClock.dayLabel(day, zone: zone, weekday: true)).font(.caption).foregroundStyle(.secondary)
                Text(PlannerClock.dayLabel(day, zone: zone, weekday: false)).font(.headline)
                    .foregroundStyle(PlannerClock.calendar(zone).isDateInToday(day) ? appearance.accent : .primary)
                HStack(spacing: 3) {
                    ForEach(rows.filter(\.allDay).prefix(2)) { row in
                        Button { if let task = row.task { edit(task) } } label: {
                            Text(row.title).font(.system(size: 9)).lineLimit(1).padding(3).background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        }.buttonStyle(.plain).help(row.title)
                    }
                }.frame(height: 20)
                if rows.filter(\.allDay).count > 2 {
                    Menu("+\(rows.filter(\.allDay).count - 2)") {
                        ForEach(rows.filter(\.allDay).dropFirst(2)) { row in
                            Button(row.title) { if let task = row.task { edit(task) } }
                        }
                    }.font(.system(size: 9)).menuStyle(.borderlessButton).fixedSize()
                }
        }.frame(width: width, height: 104)
    }
    private func dayTimeline(_ day: Date, width: CGFloat) -> some View {
        let bounds = PlannerClock.dayInterval(day, zone: zone)
        let slots = PlannerClock.slots(day: day, zone: zone)
        let rows = entries.filter { PlannerClock.overlaps($0.interval, bounds) }
        return ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(slots, id: \.self) { slot in
                        Rectangle().fill(.clear).frame(height: minuteHeight * CGFloat(min(3600, bounds.end.timeIntervalSince(slot))) / 60)
                            .overlay(alignment: .topLeading) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Divider()
                                    Text(PlannerClock.label(slot, zone: zone, includeZone: bounds.duration != 86_400)).font(.system(size: 9)).foregroundStyle(.secondary).padding(.leading, 3)
                                }
                            }
                            .contentShape(Rectangle())
                            .dropDestination(for: String.self) { identifiers, _ in
                                guard let id = identifiers.first, let task = tasks.first(where: { $0.id == id }) else { return false }
                                edit(task, at: slot); return true
                            }
                    }
                }
                let timed = rows.filter { !$0.allDay }.sorted { $0.interval.start < $1.interval.start }
                let lanes = PlannerClock.lanes(timed.map(\.interval))
                let laneWidth = (width - 4) / CGFloat((lanes.max() ?? 0) + 1)
                ForEach(Array(timed.enumerated()), id: \.element.id) { index, row in
                    let top = PlannerClock.minute(row.interval.start, on: day, zone: zone)
                    let bottom = PlannerClock.minute(row.interval.end, on: day, zone: zone)
                    entryButton(row).frame(width: max(1, laneWidth - 3), height: max(24, CGFloat(bottom - top) * minuteHeight - 2))
                        .offset(x: CGFloat(lanes[index]) * laneWidth + 2, y: CGFloat(top) * minuteHeight + 1)
                }
        }.frame(width: width, height: CGFloat(bounds.duration / 60) * minuteHeight).overlay(alignment: .leading) { Divider() }
    }
    private func entryButton(_ row: PlannerEntry) -> some View {
        Button { if let task = row.task { edit(task) } } label: {
            PlannerEntryCard(title: row.title, time: PlannerClock.label(row.interval.start, zone: zone, includeZone: true),
                             external: row.external, accent: appearance.accent)
        }.buttonStyle(.plain).help(row.title)
            .draggable(row.task?.id ?? "")
    }
    private func moveWeek(_ amount: Int) { anchor = PlannerClock.calendar(zone).date(byAdding: .day, value: amount * 7, to: anchor) ?? anchor }
    private func edit(_ task: BoardTask, at date: Date? = nil) {
        let target = date ?? (task.scheduledStart == nil ? days.first.flatMap { PlannerClock.slot(day: $0, hour: 9, zone: zone) } : nil)
        draft = PlannerDraft(task: task, at: target, zone: zone, connection: appearance.connection.identity(), generation: store.workflowGeneration)
    }
    private func enabledGoogle() async -> InstalledPlugin? {
        let connection = appearance.connection.identity(), generation = store.workflowGeneration
        await plugins.reload(configuration: appearance.connection)
        guard connection == appearance.connection.identity(), generation == store.workflowGeneration else { return nil }
        guard let plugin = plugins.entries.first(where: { $0.id == "google-workspace" && $0.enabled && $0.compatible }) else {
            plugins.error = "Install and enable the Google Workspace plugin. The local weekly planner works without a connection."; return nil
        }
        return plugin
    }
    private func openGoogle() async {
        guard let plugin = await enabledGoogle() else { return }
        usingPlugin = plugin
    }
    private func readGoogle() async {
        guard let plugin = await enabledGoogle(), let first = days.first, let last = days.last else { return }
        let connection = appearance.connection.identity(), key = rangeKey, generation = store.workflowGeneration
        let configuration = appearance.connection
        if let response = await plugins.run(plugin, method: "calendar.list", configuration: configuration),
           connection == appearance.connection.identity(), generation == store.workflowGeneration, key == rangeKey {
            calendars = response["calendars"].array
        }
        let end = PlannerClock.calendar(zone).date(byAdding: .day, value: 1, to: last)!
        guard connection == appearance.connection.identity(), generation == store.workflowGeneration, key == rangeKey else { return }
        guard let result = await plugins.run(plugin, method: "events.list", params: [
            "calendar_id": .string(calendarID), "time_min": .string(BoardDate.timestamp(first)), "time_max": .string(BoardDate.timestamp(end))
        ], configuration: configuration), connection == appearance.connection.identity(), generation == store.workflowGeneration, key == rangeKey else { return }
        googleEvents = result["events"].array.compactMap { CalendarEvent($0, fallbackTimeZone: result["time_zone"].string ?? zone) }; fetchedRange = key
    }
}

private struct PlannerEntryCard: View {
    let title: String
    let time: String
    let external: Bool
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .medium)).lineLimit(2)
            Text(time).font(.system(size: 8)).lineLimit(1)
            if external { Text("Google").font(.system(size: 8)) }
        }.padding(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background((external ? Color.teal : accent).opacity(0.17), in: RoundedRectangle(cornerRadius: 5))
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct PlannerScheduleEditor: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    @State var draft: PlannerDraft
    let googleEvents: [CalendarEvent]
    @State private var preview: JSONValue?
    @State private var checkedFingerprint = ""
    @State private var previewBusy = false
    @State private var error: String?
    @State private var confirmOverlap = false
    @State private var zoneInput = ""
    private let client = WorkboardClient()
    private var matchesConnection: Bool { draft.connection == appearance.connection.identity() && draft.generation == store.workflowGeneration }
    private var externalConflicts: [CalendarEvent] {
        guard let interval = PlannerClock.interval(start: draft.startValue, end: draft.endValue, zone: draft.zone) else { return [] }
        return googleEvents.filter { event in
            guard let other = PlannerClock.interval(start: event.start, end: event.end, zone: event.timeZone) else { return false }
            return PlannerClock.overlaps(interval, other)
        }
    }
    private var hasConflicts: Bool { preview?["has_conflicts"].bool == true || !externalConflicts.isEmpty }
    private var previewCurrent: Bool { preview != nil && checkedFingerprint == draft.fingerprint && matchesConnection && zoneInput == draft.zone }
    private var inclusiveEnd: Binding<Date> {
        Binding(get: { PlannerClock.calendar(draft.zone).date(byAdding: .day, value: -1, to: draft.end) ?? draft.end },
                set: { draft.end = PlannerClock.calendar(draft.zone).date(byAdding: .day, value: 1, to: $0) ?? $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Schedule task").font(.title2.weight(.semibold))
            Text(draft.task.title).font(.headline)
            Toggle("All day", isOn: $draft.allDay).onChange(of: draft.allDay) { _, allDay in
                if allDay {
                    let calendar = PlannerClock.calendar(draft.zone)
                    draft.start = calendar.startOfDay(for: draft.start)
                    draft.end = max(calendar.startOfDay(for: draft.end), calendar.date(byAdding: .day, value: 1, to: draft.start)!)
                }
            }
            DatePicker("Start", selection: $draft.start, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                .accessibilityIdentifier("planner-start")
            DatePicker(draft.allDay ? "Last day" : "End", selection: draft.allDay ? inclusiveEnd : $draft.end,
                       displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute]).accessibilityIdentifier("planner-end")
            TextField("Time zone", text: $zoneInput).textFieldStyle(.roundedBorder).onSubmit { Task { await check() } }
            if let zone = TimeZone(identifier: draft.zone) {
                Text("\(PlannerClock.label(draft.start, zone: zone.identifier, includeZone: true)) – \(PlannerClock.label(draft.end, zone: zone.identifier, includeZone: true))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(previewBusy ? "Checking…" : "Check schedule conflicts") { Task { await check() } }.disabled(previewBusy || !matchesConnection)
                .accessibilityIdentifier("planner-preview")
            if previewCurrent {
                ForEach(Array((preview?["invalid_tasks"].array ?? []).enumerated()), id: \.offset) { row in
                    Text("Check dates for task: \(row.element["title"].string ?? row.element["task_id"].string ?? "") · \(row.element["reason"].string ?? "")")
                        .font(.caption).foregroundStyle(.orange)
                }
                if hasConflicts {
                    Label("Schedule conflicts found", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    ForEach(Array((preview?["conflicts"].array ?? []).enumerated()), id: \.offset) { row in
                        Text("• " + (row.element["title"].string ?? row.element["task"]["title"].string ?? "Task")).font(.caption)
                    }
                    ForEach(externalConflicts) { event in Text("• Google: \(event.title)").font(.caption) }
                } else { Label("No schedule conflicts", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
            }
            if !matchesConnection { Text("The board connection changed. Close this window and select the task again.").font(.caption).foregroundStyle(.orange) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let error = store.actionError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if draft.task.scheduledStart != nil {
                    Button("Clear schedule") { Task { await clear() } }.disabled(store.isMutating || !matchesConnection)
                }
                Spacer()
                Button("Save") { if hasConflicts { confirmOverlap = true } else { Task { await save() } } }
                    .buttonStyle(.borderedProminent).disabled(!previewCurrent || previewBusy || store.isMutating)
                    .accessibilityIdentifier("planner-save")
            }
        }.padding(24).frame(width: 500).environment(\.timeZone, TimeZone(identifier: draft.zone) ?? .current)
            .task { zoneInput = draft.zone; await check() }
            .confirmationDialog("Save despite schedule conflicts?", isPresented: $confirmOverlap, titleVisibility: .visible) {
                Button("Save with conflicts") { Task { await save() } }
                Button("Cancel", role: .cancel) { }
            }
    }
    private func check() async {
        guard matchesConnection else { return }
        do { try draft.changeTimeZone(to: zoneInput) } catch { self.error = error.localizedDescription; return }
        previewBusy = true; error = nil; preview = nil
        let fingerprint = draft.fingerprint
        defer { previewBusy = false }
        do {
            let result = try await client.call("task.schedule.preview", params: [
                "task_id": .string(draft.task.id), "scheduled_start": .string(draft.startValue),
                "scheduled_end": .string(draft.endValue), "time_zone": .string(draft.zone)
            ], configuration: appearance.connection)
            guard matchesConnection, fingerprint == draft.fingerprint else { return }
            preview = result; checkedFingerprint = fingerprint
        } catch { if matchesConnection { self.error = error.localizedDescription } }
    }
    private func save() async {
        guard previewCurrent else { return }
        if await store.workflowMutation("task.update", params: [
            "task_id": .string(draft.task.id), "expected_revision": .number(Double(draft.task.revision)),
            "scheduled_start": .string(draft.startValue), "scheduled_end": .string(draft.endValue), "time_zone": .string(draft.zone)
        ]) != nil { dismiss() }
    }
    private func clear() async {
        guard matchesConnection else { return }
        if await store.workflowMutation("task.update", params: [
            "task_id": .string(draft.task.id), "expected_revision": .number(Double(draft.task.revision)),
            "scheduled_start": .null, "scheduled_end": .null
        ]) != nil { dismiss() }
    }
}
