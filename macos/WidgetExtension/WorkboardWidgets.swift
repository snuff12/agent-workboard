import AppIntents
import SwiftUI
import WidgetKit

enum WorkboardWidgetView: String, AppEnum {
    case today, now, next, review

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Tasks to show" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.today: "Today", .now: "In progress", .next: "To do", .review: "Needs review"]
    }
    var mode: WidgetMode { WidgetMode(rawValue: rawValue) ?? .today }
}

enum WorkboardWidgetAccent: String, AppEnum {
    case app, blue, mint, purple, amber

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Accent color" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.app: "App accent", .blue: "Blue", .mint: "Mint", .purple: "Purple", .amber: "Amber"]
    }
    var color: Color {
        switch self {
        case .app:
            if let hex = UserDefaults(suiteName: WidgetSnapshotReader.appGroup)?.string(forKey: "widgetAccentHex"),
                hex.count == 6, let value = UInt32(hex, radix: 16) {
                Color(red: Double((value >> 16) & 255) / 255,
                    green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
            } else {
                WorkboardWidgetAccent.blue.color
            }
        case .blue: Color(red: 0.24, green: 0.40, blue: 0.92)
        case .mint: Color(red: 0.12, green: 0.59, blue: 0.49)
        case .purple: Color(red: 0.55, green: 0.35, blue: 0.80)
        case .amber: Color(red: 0.79, green: 0.46, blue: 0.13)
        }
    }
}

struct WorkboardWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Workboard widget settings" }
    static var description: IntentDescription { "Choose which tasks to show and the widget accent color." }

    @Parameter(title: "Tasks to show", default: .today)
    var view: WorkboardWidgetView

    @Parameter(title: "Accent color", default: .app)
    var accent: WorkboardWidgetAccent
}

struct WorkboardEntry: TimelineEntry {
    let date: Date
    let mode: WidgetMode
    let accent: WorkboardWidgetAccent
    let snapshot: WidgetSnapshot?
    let failed: Bool
    var collapsed: Set<String> = []

    var tasks: [WidgetTask] { snapshot?.tasks(for: mode) ?? [] }
    var stale: Bool { snapshot?.isStale(at: date) ?? true }

    /// Later entries for the same data: the stale label and the start of the next day.
    func followUps(calendar: Calendar = .current) -> [WorkboardEntry] {
        var dates: [Date] = []
        if let checked = snapshot?.lastCheckedAt { dates.append(checked.addingTimeInterval(WidgetSnapshot.staleInterval)) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) { dates.append(tomorrow) }
        return dates.filter { $0 > date }.sorted().map {
            WorkboardEntry(date: $0, mode: mode, accent: accent, snapshot: snapshot, failed: failed, collapsed: collapsed)
        }
    }
}

/// Folds or unfolds one section of the "Today" widget. WidgetKit reloads the widget after it runs.
struct ToggleWidgetSectionIntent: AppIntent {
    static var title: LocalizedStringResource { "Expand or collapse widget section" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Section")
    var section: String

    init() {}
    init(section: WidgetSection) { self.section = section.rawValue }

    func perform() async throws -> some IntentResult {
        WidgetSectionState.toggle(section)
        return .result()
    }
}

struct WorkboardTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WorkboardEntry {
        WorkboardEntry(date: Date(), mode: .today, accent: .blue, snapshot: nil, failed: false)
    }

    func snapshot(for configuration: WorkboardWidgetConfiguration, in context: Context) async -> WorkboardEntry {
        load(configuration, at: Date())
    }

    func timeline(for configuration: WorkboardWidgetConfiguration, in context: Context) async -> Timeline<WorkboardEntry> {
        let now = Date()
        let entry = load(configuration, at: now)
        // The stale label and "today" change even when the service stops writing.
        return Timeline(entries: [entry] + entry.followUps(), policy: .after(now.addingTimeInterval(5 * 60)))
    }

    private func load(_ configuration: WorkboardWidgetConfiguration, at date: Date) -> WorkboardEntry {
        switch WidgetSnapshotReader.read() {
        case .success(let snapshot):
            WorkboardEntry(date: date, mode: configuration.view.mode, accent: configuration.accent, snapshot: snapshot,
                failed: false, collapsed: WidgetSectionState.collapsed())
        case .failure:
            WorkboardEntry(date: date, mode: configuration.view.mode, accent: configuration.accent, snapshot: nil,
                failed: true, collapsed: WidgetSectionState.collapsed())
        }
    }
}

struct WorkboardWidgetContent: View {
    @Environment(\.widgetFamily) private var family
    let entry: WorkboardEntry

    var body: some View {
        if entry.mode == .today { WorkboardTodayLayout(entry: entry, family: family) }
        else { WorkboardWidgetLayout(entry: entry, family: family) }
    }
}

struct WorkboardWidgetLayout: View {
    let entry: WorkboardEntry
    let family: WidgetFamily

    private var limit: Int { family == .systemLarge ? 4 : family == .systemMedium ? 2 : 1 }
    private var accent: Color { entry.accent.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: entry.mode.symbol).foregroundStyle(accent)
                Text(entry.mode.title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if !entry.tasks.isEmpty {
                    Text("\(entry.tasks.count)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            if entry.tasks.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.failed ? "Open the board in the app" : entry.mode.emptyMessage)
                        .font(.subheadline).foregroundStyle(.secondary)
                    if entry.failed && family != .systemSmall {
                        Text("Your tasks will appear here once loaded.").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                if family == .systemMedium {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(entry.tasks.prefix(limit))) { task in
                            Link(destination: task.url) { taskRow(task) }.buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    ForEach(Array(entry.tasks.prefix(limit))) { task in
                        Link(destination: task.url) {
                            taskRow(task)
                        }.buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            WorkboardWidgetFooter(entry: entry, accent: accent)
        }
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        .widgetURL(entry.tasks.first?.url ?? URL(string: "workboard://board")!)
    }

    private func taskRow(_ task: WidgetTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.8)).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.system(size: family == .systemSmall ? 13 : 14, weight: .medium))
                    .lineLimit(family == .systemLarge ? 1 : 2).foregroundStyle(.primary).privacySensitive()
                if let next = task.nextAction, !next.isEmpty {
                    Text(next).font(.system(size: family == .systemSmall ? 10 : 11))
                        .lineLimit(1).foregroundStyle(.secondary).privacySensitive()
                }
                HStack(spacing: 5) {
                    if let assignee = task.assignee, !assignee.isEmpty {
                        Label(assignee, systemImage: "person.crop.circle").privacySensitive()
                    }
                    if family != .systemSmall {
                        Spacer(minLength: 0)
                        Text("Activity")
                        // Follow the system clock style; omitting the 12-hour marker made 19:43 read as 07:43.
                        Text(task.updatedAt, format: Calendar.current.isDateInToday(task.updatedAt)
                            ? .dateTime.hour().minute() : .dateTime.month().day())
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct WorkboardTaskWidget: Widget {
    let kind = "WorkboardTasks"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: WorkboardWidgetConfiguration.self,
            provider: WorkboardTimelineProvider()) { entry in
                WorkboardWidgetContent(entry: entry).environment(\.locale, Locale(identifier: "en_US"))
            }
            .configurationDisplayName("Agent Workboard")
            .description("See work in progress, tasks to do, and tasks needing review.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct WorkboardWidgetFooter: View {
    let entry: WorkboardEntry
    let accent: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(entry.stale ? Color.orange : accent).frame(width: 4, height: 4)
            if let timestamp = entry.snapshot?.generatedAt {
                Text(timestamp, style: .time)
                Text(entry.stale ? "· Check connection" : "· Synced")
            } else {
                Text("Not updated yet")
            }
            Spacer(minLength: 0)
        }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            .help("Time of the last data change. Connection status uses the service's separate publication check.")
    }
}

/// Group in-progress, due-today, and completed-today tasks in one widget. Tap a heading to expand or collapse its section.
struct WorkboardTodayLayout: View {
    let entry: WorkboardEntry
    let family: WidgetFamily

    private var accent: Color { entry.accent.color }
    private var rowBudget: Int { family == .systemLarge ? 9 : family == .systemMedium ? 3 : 2 }

    var body: some View {
        let sections = entry.snapshot?.sections(at: entry.date) ?? []
        let expanded = sections.map { !entry.collapsed.contains($0.section.rawValue) }
        let shown = WidgetSnapshot.allocate(rows: rowBudget,
            among: sections.indices.map { expanded[$0] ? sections[$0].tasks.count : 0 })
        VStack(alignment: .leading, spacing: family == .systemSmall ? 5 : 7) {
            if entry.snapshot == nil {
                Text(entry.failed ? "Open the board in the app" : WidgetMode.today.emptyMessage)
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(sections.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        header(sections[index].section, count: sections[index].tasks.count, expanded: expanded[index])
                        ForEach(Array(sections[index].tasks.prefix(shown[index]))) { task in
                            row(task, in: sections[index].section)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            WorkboardWidgetFooter(entry: entry, accent: accent)
        }
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        .widgetURL(URL(string: "workboard://board")!)
    }

    private func header(_ section: WidgetSection, count: Int, expanded: Bool) -> some View {
        Button(intent: ToggleWidgetSectionIntent(section: section)) {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary).frame(width: 9)
                Image(systemName: section.symbol).font(.system(size: 10)).foregroundStyle(accent)
                Text(section.title).font(.system(size: family == .systemSmall ? 11 : 12, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func row(_ task: WidgetTask, in section: WidgetSection) -> some View {
        Link(destination: task.url) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(section == .done ? Color.secondary.opacity(0.5) : accent.opacity(0.8))
                    .frame(width: 2, height: 11)
                Text(task.title).font(.system(size: family == .systemSmall ? 11 : 12)).lineLimit(1)
                    .strikethrough(section == .done).foregroundStyle(section == .done ? .secondary : .primary)
                    .privacySensitive()
                Spacer(minLength: 4)
                if family != .systemSmall, let detail = detail(task, in: section) {
                    Text(detail.text).font(.system(size: 10)).lineLimit(1)
                        .foregroundStyle(detail.warning ? Color.red : Color.secondary).privacySensitive()
                }
            }.padding(.leading, 14)
        }.buttonStyle(.plain)
    }

    private func detail(_ task: WidgetTask, in section: WidgetSection) -> (text: String, warning: Bool)? {
        let calendar = Calendar.current
        switch section {
        case .now, .review:
            return task.assignee.flatMap { $0.isEmpty ? nil : ($0, false) }
        case .done:
            return task.completedAt.map { ($0.formatted(.dateTime.hour().minute().locale(Locale(identifier: "en_US"))), false) }
        case .today:
            if task.isOverdue(at: entry.date, calendar: calendar) { return ("Overdue", true) }
            if let due = task.dueAt, let date = WidgetTask.parse(due, calendar: calendar),
                date < (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: entry.date)) ?? date) {
                return due.count == 10 ? ("Due today", false) : (date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "en_US"))) + " due", false)
            }
            if let start = task.scheduledStart, let date = WidgetTask.parse(start, calendar: calendar) {
                return start.count == 10 ? ("All day", false) : (date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "en_US"))), false)
            }
            return nil
        }
    }
}

#if !WORKBOARD_WIDGET_PREVIEW
@main
struct WorkboardWidgetBundle: WidgetBundle {
    var body: some Widget {
        #if WORKBOARD_STATIC_WIDGETS
        TodayWorkboardWidget()
        CurrentWorkboardWidget()
        NextWorkboardWidget()
        ReviewWorkboardWidget()
        #else
        WorkboardTaskWidget()
        #endif
    }
}
#endif

/// CLT builds do not have Xcode's App Intents metadata processor. These native
/// WidgetKit variants expose the same three views without an intent dependency.
@MainActor
private func staticWorkboardConfiguration(mode: WidgetMode) -> some WidgetConfiguration {
        StaticConfiguration(kind: "WorkboardTasks.\(mode.rawValue)",
            provider: StaticWorkboardProvider(mode: mode)) { entry in
                WorkboardWidgetContent(entry: entry).environment(\.locale, Locale(identifier: "en_US"))
            }
            .configurationDisplayName(mode.title)
            .description("View your tasks in Agent Workboard.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
}

struct TodayWorkboardWidget: Widget {
    var body: some WidgetConfiguration { staticWorkboardConfiguration(mode: .today) }
}

struct CurrentWorkboardWidget: Widget {
    var body: some WidgetConfiguration { staticWorkboardConfiguration(mode: .now) }
}

struct NextWorkboardWidget: Widget {
    var body: some WidgetConfiguration { staticWorkboardConfiguration(mode: .next) }
}

struct ReviewWorkboardWidget: Widget {
    var body: some WidgetConfiguration { staticWorkboardConfiguration(mode: .review) }
}

struct StaticWorkboardProvider: TimelineProvider {
    let mode: WidgetMode

    func placeholder(in context: Context) -> WorkboardEntry {
        WorkboardEntry(date: Date(), mode: mode, accent: .blue, snapshot: nil, failed: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (WorkboardEntry) -> Void) {
        completion(load(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WorkboardEntry>) -> Void) {
        let now = Date()
        let entry = load(at: now)
        completion(Timeline(entries: [entry] + entry.followUps(), policy: .after(now.addingTimeInterval(5 * 60))))
    }

    private func load(at date: Date) -> WorkboardEntry {
        let preference = UserDefaults(suiteName: WidgetSnapshotReader.appGroup)?.string(forKey: "widgetAccent")
        let accent = preference.flatMap(WorkboardWidgetAccent.init(rawValue:)) ?? .app
        switch WidgetSnapshotReader.read() {
        case .success(let snapshot):
            return WorkboardEntry(date: date, mode: mode, accent: accent, snapshot: snapshot, failed: false,
                collapsed: WidgetSectionState.collapsed())
        case .failure:
            return WorkboardEntry(date: date, mode: mode, accent: accent, snapshot: nil, failed: true,
                collapsed: WidgetSectionState.collapsed())
        }
    }
}
