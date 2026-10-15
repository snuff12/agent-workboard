import Foundation

/// The widget only reads this derived file. SQLite remains owned by the service.
struct WidgetSnapshot: Decodable, Sendable {
    let schemaVersion: Int
    let eventSequence: Int64
    let generatedAt: Date
    let tasks: [WidgetTask]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", eventSequence = "event_sequence"
        case generatedAt = "generated_at", tasks
    }

    static func decode(_ data: Data) throws -> WidgetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Expected an ISO 8601 timestamp"))
            }
            return date
        }
        let snapshot = try decoder.decode(Self.self, from: data)
        guard snapshot.schemaVersion == 1 else { throw SnapshotError.unsupportedVersion }
        return snapshot
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    func tasks(for mode: WidgetMode) -> [WidgetTask] {
        tasks.filter { $0.status == mode.status }.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.updatedAt != rhs.updatedAt {
                return mode == .next ? lhs.updatedAt < rhs.updatedAt : lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id < rhs.id
        }
    }

    /// The "Today" view. Review appears only while something waits for the user.
    func sections(at now: Date, calendar: Calendar = .current) -> [(section: WidgetSection, tasks: [WidgetTask])] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        let working = tasks(for: .now)
        let review = tasks(for: .review)
        let due = tasks.filter { $0.status == "todo" && $0.isDue(before: tomorrow, from: today, calendar: calendar) }
            .sorted { lhs, rhs in
                let left = lhs.todayOrder(calendar: calendar), right = rhs.todayOrder(calendar: calendar)
                if left != right { return left < right }
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.id < rhs.id
            }
        let finished = tasks.filter { $0.status == "done" && $0.updatedAt >= today && $0.updatedAt < tomorrow }
            .sorted { $0.updatedAt > $1.updatedAt }
        var result: [(section: WidgetSection, tasks: [WidgetTask])] = [(.now, working)]
        if !review.isEmpty { result.append((.review, review)) }
        result.append((.today, due))
        result.append((.done, finished))
        return result
    }

    /// Shares the visible rows among expanded sections one row at a time, so a long list cannot hide the others.
    static func allocate(rows budget: Int, among counts: [Int]) -> [Int] {
        var shown = counts.map { _ in 0 }
        var remaining = max(0, budget)
        while remaining > 0 {
            var progressed = false
            for index in counts.indices where remaining > 0 && shown[index] < counts[index] {
                shown[index] += 1; remaining -= 1; progressed = true
            }
            if !progressed { break }
        }
        return shown
    }

    func isStale(at date: Date) -> Bool { date.timeIntervalSince(generatedAt) >= Self.staleInterval }
    static let staleInterval: TimeInterval = 15 * 60

    enum SnapshotError: Error { case unsupportedVersion }
}

struct WidgetTask: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let status: String
    let assignee: String?
    let nextAction: String?
    let priority: Int
    let updatedAt: Date
    let projectId: String
    let parentId: String?
    var dueAt: String? = nil
    var scheduledStart: String? = nil
    var scheduledEnd: String? = nil
    var timeZone: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, status, assignee, priority
        case nextAction = "next_action", updatedAt = "updated_at"
        case projectId = "project_id", parentId = "parent_id"
        case dueAt = "due_at", scheduledStart = "scheduled_start", scheduledEnd = "scheduled_end"
        case timeZone = "time_zone"
    }

    /// Same rule as the app: a date-only value is that day on this Mac; a timestamp carries its own offset.
    static func parse(_ value: String?, calendar: Calendar) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if value.count == 10 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            return formatter.date(from: value)
        }
        return WidgetSnapshot.parseDate(value)
    }

    /// Due today, overdue, or scheduled during today.
    func isDue(before tomorrow: Date, from today: Date, calendar: Calendar) -> Bool {
        if let due = Self.parse(dueAt, calendar: calendar), due < tomorrow { return true }
        guard let start = Self.parse(scheduledStart, calendar: calendar) else { return false }
        let end = Self.parse(scheduledEnd, calendar: calendar) ?? start
        return start < tomorrow && end > today
    }

    func isOverdue(at now: Date, calendar: Calendar) -> Bool {
        guard status != "done", let due = Self.parse(dueAt, calendar: calendar) else { return false }
        return dueAt?.count == 10 ? due < calendar.startOfDay(for: now) : due < now
    }

    /// Overdue first, then the earliest deadline or start time of the day.
    fileprivate func todayOrder(calendar: Calendar) -> Date {
        [Self.parse(dueAt, calendar: calendar), Self.parse(scheduledStart, calendar: calendar)]
            .compactMap { $0 }.min() ?? .distantFuture
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "workboard"
        components.host = "task"
        components.path = "/\(id)"
        return components.url ?? URL(string: "workboard://board")!
    }
}

enum WidgetMode: String, CaseIterable, Sendable {
    case today, now, next, review

    var title: String {
        switch self {
        case .today: "Today"
        case .now: "In progress"
        case .next: "To do"
        case .review: "Needs review"
        }
    }

    /// `nil` for the combined view, which is built from `sections(at:)`.
    var status: String? {
        switch self {
        case .today: nil
        case .now: "in_progress"
        case .next: "todo"
        case .review: "review"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .now: "circle.lefthalf.filled"
        case .next: "circle.dotted"
        case .review: "checkmark.bubble"
        }
    }

    var emptyMessage: String {
        switch self {
        case .today: "No tasks to show today"
        case .now: "No tasks in progress"
        case .next: "Add your next task"
        case .review: "No tasks awaiting review"
        }
    }
}

enum WidgetSection: String, CaseIterable, Sendable {
    case now, review, today, done

    var title: String {
        switch self {
        case .now: "In progress"
        case .review: "Needs review"
        case .today: "Due today"
        case .done: "Completed today"
        }
    }

    var symbol: String {
        switch self {
        case .now: "circle.lefthalf.filled"
        case .review: "checkmark.bubble"
        case .today: "circle.dotted"
        case .done: "checkmark.circle"
        }
    }
}

/// Folded sections are shared by this Mac's widgets through the App Group preferences.
enum WidgetSectionState {
    static let key = "widgetCollapsedSections"

    static func collapsed(in defaults: UserDefaults? = UserDefaults(suiteName: WidgetSnapshotReader.appGroup)) -> Set<String> {
        Set(defaults?.stringArray(forKey: key) ?? [])
    }

    static func toggle(_ section: String, in defaults: UserDefaults? = UserDefaults(suiteName: WidgetSnapshotReader.appGroup)) {
        guard WidgetSection(rawValue: section) != nil, let defaults else { return }
        var folded = collapsed(in: defaults)
        if folded.remove(section) == nil { folded.insert(section) }
        defaults.set(folded.sorted(), forKey: key)
    }
}

enum WidgetSnapshotReader {
    static var appGroup: String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "WorkboardAppGroupIdentifier") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.flatMap { $0.isEmpty ? nil : $0 } ?? "group.local.agentworkboard.shared"
    }
    static let fileName = "widget-snapshot.json"

    static func read() -> Result<WidgetSnapshot, Error> {
        let manager = FileManager.default
        var locations: [URL] = []
        if let container = manager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            locations.append(container.appendingPathComponent(fileName))
        }
        // Development-only escape hatch. A sandboxed extension cannot use the host's
        // normal Application Support folder; shipping builds use the group container.
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["WORKBOARD_WIDGET_ALLOW_DEV_FALLBACK"] == "1" {
            if let path = environment["WORKBOARD_WIDGET_SNAPSHOT"] {
                locations.append(URL(fileURLWithPath: path))
            }
            if let folder = environment["WORKBOARD_DATA_DIR"] {
                locations.append(URL(fileURLWithPath: folder).appendingPathComponent(fileName))
            }
        }
        #endif
        for location in locations where manager.fileExists(atPath: location.path) {
            do { return .success(try WidgetSnapshot.decode(Data(contentsOf: location))) }
            catch { return .failure(error) }
        }
        return .failure(CocoaError(.fileNoSuchFile))
    }
}
