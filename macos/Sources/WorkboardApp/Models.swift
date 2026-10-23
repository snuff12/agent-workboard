import Foundation
import SwiftUI

enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
    subscript(_ key: String) -> JSONValue { if case .object(let fields) = self { return fields[key] ?? .null }; return .null }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var int: Int? { if case .number(let value) = self, value.isFinite, value >= Double(Int.min), value < Double(Int.max) { return Int(value) }; return nil }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var array: [JSONValue] { if case .array(let value) = self { return value }; return [] }
    var object: [String: JSONValue] { if case .object(let value) = self { return value }; return [:] }
    var pretty: String { guard let data = try? JSONEncoder.pretty.encode(self) else { return "" }; return String(decoding: data, as: UTF8.self) }
}

extension JSONEncoder {
    static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return encoder }
}

/// Board columns in Linear's default workflow order.
enum WorkStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case backlog, todo, inProgress = "in_progress", review, done, canceled
    var id: String { rawValue }
    var title: String { switch self { case .backlog: "Backlog"; case .todo: "Todo"; case .inProgress: "In Progress"; case .review: "In Review"; case .done: "Done"; case .canceled: "Canceled" } }
    var symbol: String { switch self { case .backlog: "circle.dashed"; case .todo: "circle"; case .inProgress: "circle.lefthalf.filled"; case .review: "eye"; case .done: "checkmark.circle.fill"; case .canceled: "xmark.circle.fill" } }
    var color: Color { switch self { case .backlog, .todo, .canceled: .secondary; case .inProgress: .blue; case .review: .orange; case .done: .green } }
    /// Done and Canceled close a task: it no longer counts as open work or blocks dependents.
    var isClosed: Bool { self == .done || self == .canceled }
    /// New tasks start here. Later columns follow runs, reviews, and recorded outcomes.
    var acceptsNewTasks: Bool { self == .backlog || self == .todo }
}

struct BoardProject: Identifiable, Sendable, Hashable {
    let id: String
    var name: String
    var directory: String
    init?(_ json: JSONValue) {
        guard let id = json["id"].string else { return nil }
        self.id = id; name = json["name"].string ?? "Untitled project"; directory = json["directory"].string ?? ""
    }
}

struct BoardTask: Identifiable, Sendable, Hashable {
    let id: String
    let projectID: String
    let parentID: String?
    let title: String
    let goal: String
    let completionCriteria: String
    let status: WorkStatus
    let priority: Int
    let assignee: String?
    let nextAction: String
    let blockedReason: String
    let completionSummary: String
    let claimStale: Bool
    let dependencyIDs: [String]
    let blockedBy: [String]
    let ready: Bool
    let checklist: [ChecklistItem]
    let dueAt: String?
    let scheduledStart: String?
    let scheduledEnd: String?
    let timeZone: String
    let revision: Int
    let updatedAt: String
    let completedAt: String?
    init?(_ json: JSONValue) {
        guard let id = json["id"].string, let projectID = json["project_id"].string else { return nil }
        self.id = id; self.projectID = projectID; parentID = json["parent_id"].string
        title = json["title"].string ?? "Untitled task"; goal = json["goal"].string ?? ""
        completionCriteria = json["completion_criteria"].string ?? ""; status = WorkStatus(rawValue: json["status"].string ?? "todo") ?? .todo
        priority = json["priority"].int ?? 0; assignee = json["assignee"].string
        nextAction = json["next_action"].string ?? ""; revision = json["revision"].int ?? 0
        blockedReason = json["blocked_reason"].string ?? ""; completionSummary = json["completion_summary"].string ?? ""; claimStale = json["claim_stale"].bool ?? false
        dependencyIDs = json["dependency_ids"].array.compactMap(\.string); blockedBy = json["blocked_by"].array.compactMap(\.string)
        ready = json["ready"].bool ?? (status == .todo && blockedReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && blockedBy.isEmpty)
        checklist = json["checklist"].array.compactMap(ChecklistItem.init)
        dueAt = json["due_at"].string; scheduledStart = json["scheduled_start"].string; scheduledEnd = json["scheduled_end"].string; timeZone = json["time_zone"].string ?? TimeZone.current.identifier
        updatedAt = json["updated_at"].string ?? ""
        completedAt = json["completed_at"].string
    }
    var priorityTitle: String { priority >= 3 ? "High" : priority >= 1 ? "Normal" : "Low" }
    var isBlocked: Bool { !blockedBy.isEmpty || !blockedReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var incompleteRequirements: [ChecklistItem] { checklist.filter { $0.required && !$0.checked } }
    func isStale(days: Int, now: Date = Date()) -> Bool {
        guard let updated = BoardDate.parseTimestamp(updatedAt) else { return false }
        return updated < now.addingTimeInterval(-Double(days) * 86_400)
    }
    var dueDate: Date? { BoardDate.parse(dueAt, timeZone: dueAt?.count == 10 ? TimeZone.current.identifier : timeZone) }
    var startDate: Date? { BoardDate.parse(scheduledStart, timeZone: scheduledStart?.count == 10 ? TimeZone.current.identifier : timeZone) }
    var endDate: Date? { BoardDate.parse(scheduledEnd, timeZone: scheduledEnd?.count == 10 ? TimeZone.current.identifier : timeZone) }
    var isScheduledToday: Bool {
        guard let start = startDate else { return false }
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        return start < tomorrow && (endDate ?? start) > today
    }
    var isOverdue: Bool {
        guard !status.isClosed, let dueDate else { return false }
        if dueAt?.count == 10 { return dueDate < Calendar.current.startOfDay(for: Date()) }
        return dueDate < Date()
    }
}

enum BoardDate {
    static let displayLocale = Locale(identifier: "en_US")
    static func parse(_ value: String?, timeZone: String = TimeZone.current.identifier) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = parseTimestamp(value) { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(identifier: timeZone) ?? .current; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: value)
    }
    static func parseTimestamp(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        return iso.date(from: value)
    }
    static func shortLocalTimestamp(_ value: String, timeZone: TimeZone = .current, locale: Locale = displayLocale) -> String {
        if value.count == 10, parse(value, timeZone: timeZone.identifier) != nil { return value }
        guard let date = parseTimestamp(value) else {
            return value.isEmpty ? "—" : value.replacingOccurrences(of: "T", with: " ").prefix(16).description
        }
        var format = Date.FormatStyle.dateTime.month().day().hour().minute()
        format.timeZone = timeZone; format.locale = locale
        return date.formatted(format)
    }
    static func dateOnly(_ date: Date, timeZone: String = TimeZone.current.identifier) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(identifier: timeZone) ?? .current; formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
    }
    static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

struct TaskArtifact: Identifiable, Sendable {
    let id: String
    let path: String
    let kind: String
    let description: String
    let provider: String?
    let locator: String?
    let metadata: JSONValue
    init(_ json: JSONValue, index: Int) {
        id = json["id"].string ?? "artifact-\(index)"; path = json["path"].string ?? json["url"].string ?? ""
        kind = json["kind"].string ?? "file"; description = json["description"].string ?? ""
        provider = json["provider"].string ?? json["metadata"]["provider"].string; locator = json["locator"].string ?? json["metadata"]["locator"].string
        metadata = .object(json["metadata"].object)
    }
    var isOrcaWorktree: Bool { provider == "orca" && kind == "workspace" && !(locator ?? "").isEmpty }
    /// One entry per linked Orca worktree, newest link first. Agent launches add links to the same worktree.
    static func orcaWorktrees(_ artifacts: [TaskArtifact]) -> [TaskArtifact] {
        var seen = Set<String>()
        return artifacts.reversed().filter { $0.isOrcaWorktree && seen.insert($0.locator ?? "").inserted }
    }
    var url: URL? { if let url = URL(string: path), ["http", "https", "file", "mailto"].contains(url.scheme ?? "") { return url }; return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil }
}

struct TaskRun: Identifiable, Sendable {
    let id: String
    let status: String
    let agent: String
    let summary: String
    let startedAt: String
    init(_ json: JSONValue, index: Int) {
        id = json["id"].string ?? "run-\(index)"; status = json["status"].string ?? ""
        agent = json["agent_id"].string ?? json["agent"].string ?? ""
        summary = json["summary"].string ?? json["resume_summary"].string ?? ""; startedAt = json["started_at"].string ?? ""
    }
}

struct TaskDetail: Sendable {
    let task: BoardTask
    let children: [BoardTask]
    let artifacts: [TaskArtifact]
    let runs: [TaskRun]
    let events: [JSONValue]
    let reviewDecisions: [ReviewDecision]
    let automation: TaskAutomation?
    init?(_ json: JSONValue, events: [JSONValue]? = nil) {
        guard let task = BoardTask(json["task"]) else { return nil }
        self.task = task; children = json["children"].array.compactMap(BoardTask.init)
        artifacts = json["artifacts"].array.enumerated().map { TaskArtifact($0.element, index: $0.offset) }
        runs = json["runs"].array.enumerated().map { TaskRun($0.element, index: $0.offset) }
        self.events = events ?? (json["events"].array.isEmpty ? json["history"].array : json["events"].array)
        reviewDecisions = json["review_decisions"].array.compactMap(ReviewDecision.init)
        automation = TaskAutomation(json["automation"])
    }
}

struct TaskAutomation: Sendable {
    let taskID: String
    let raw: JSONValue
    init?(_ json: JSONValue) {
        guard let id = json["task_id"].string else { return nil }
        taskID = id; raw = json
    }
    var state: String { raw["state"].string ?? "" }
    var stage: String { raw["stage"].string ?? "" }
    var revision: Int { raw["revision"].int ?? 0 }
    var attempts: [JSONValue] { raw["attempts"].array }
    var needsExitConfirmation: Bool { attempts.contains { $0["worker_exited"].bool == false && $0["state"].string != "queued" } }
    var title: String {
        switch state {
        case "armed": "Ready to start"
        case "waiting": "Waiting for status change"
        case "paused": "Paused"
        case "blocked": "Needs attention"
        case "awaiting_approval": "Ready for final approval"
        case "completed": "Approved"
        case "disabled": "Disabled"
        case "canceled": "Canceled"
        default: progressTitle
        }
    }
    var presetName: String? { raw["process"]["preset"]["name"].string }
    var progressTitle: String {
        if raw["single_stage"].bool == true { return Self.stageTitle(stage) }
        if stage == "select" { return "Choose process preset" }
        let process = raw["process"], steps = process["preset"]["steps"].array
        let index = process["cursor"].int ?? 0
        if stage == "rework" && process["rework_resume"].int != nil { return "Rework · " + (presetName ?? "Process") }
        guard index < steps.count else { return Self.stageTitle(stage) }
        return "\(index + 1)/\(steps.count) · \(steps[index]["title"].string ?? Self.stageTitle(stage))"
    }
    static func stageTitle(_ value: String) -> String {
        switch value { case "select": "Choose process preset"; case "plan": "Plan"; case "verify": "Verification"; case "preflight": "Preflight"; case "work": "Implementation"; case "review": "Review"; case "rework": "Rework"; case "release": "Release preparation"; default: value }
    }
}

/// One deletion waiting in the trash: the task the user deleted and the subtasks deleted with it.
struct TrashItem: Identifiable, Sendable {
    let id: String
    let task: BoardTask
    let tasks: [BoardTask]
    let deletedAt: String
    let deletedBy: String?
    let subtaskCount: Int
    let restorable: Bool
    let parentInTrash: String?
    init?(_ json: JSONValue) {
        guard let task = BoardTask(json["task"]) else { return nil }
        self.task = task; id = json["deletion_id"].string ?? task.id
        let tasks = json["tasks"].array.compactMap(BoardTask.init); self.tasks = tasks.isEmpty ? [task] : tasks
        deletedAt = json["deleted_at"].string ?? ""; deletedBy = json["deleted_by"].string
        subtaskCount = json["subtask_count"].int ?? max(self.tasks.count - 1, 0)
        restorable = json["restorable"].bool ?? true; parentInTrash = json["parent_in_trash"]["title"].string
    }
}

/// The notice after a deletion offers Undo while that notice is showing.
struct UndoDeletion: Equatable {
    let notice: String
    let taskID: String
}

enum TaskAutomationMode: String, CaseIterable, Identifiable {
    case inherit, automatic, manual
    var id: String { rawValue }
    var title: String { switch self { case .inherit: "Project default"; case .automatic: "Use automation"; case .manual: "Manual work" } }
}

struct TaskDraft: Identifiable {
    let id = UUID()
    var projectID: String
    var parentID: String?
    var title = ""
    var goal = ""
    var completionCriteria = ""
    var nextAction = ""
    var blockedReason = ""
    var priority = 1
    var status = WorkStatus.todo
    var automationMode = TaskAutomationMode.inherit
    var processPreset = ""
    var hasDueDate = false
    var dueDate = Date()
    var dueIncludesTime = false
    var hasSchedule = false
    var scheduleAllDay = false
    var timeZoneID = TimeZone.current.identifier
    var scheduledStart = Date()
    var scheduledEnd = Date().addingTimeInterval(3600)
    var editingTask: BoardTask?
    var templateID: String?
    var templateRevision: Int?
    var workflowContext: WorkflowEditContext?
    init(projectID: String, parentID: String? = nil, editingTask: BoardTask? = nil) {
        self.projectID = projectID; self.parentID = parentID; self.editingTask = editingTask
        if let task = editingTask {
            title = task.title; goal = task.goal; completionCriteria = task.completionCriteria; nextAction = task.nextAction; blockedReason = task.blockedReason; priority = task.priority; self.parentID = task.parentID
            timeZoneID = task.timeZone
            hasDueDate = task.dueAt != nil; dueDate = BoardDate.parse(task.dueAt, timeZone: task.timeZone) ?? Date(); dueIncludesTime = task.dueAt?.contains("T") ?? false
            hasSchedule = task.scheduledStart != nil; scheduleAllDay = task.scheduledStart?.count == 10; scheduledStart = BoardDate.parse(task.scheduledStart, timeZone: task.timeZone) ?? Date(); scheduledEnd = BoardDate.parse(task.scheduledEnd, timeZone: task.timeZone) ?? scheduledStart.addingTimeInterval(3600)
        }
    }
    var dueValue: String? {
        guard hasDueDate else { return nil }
        if let original = editingTask?.dueAt, editingTask?.timeZone == timeZoneID,
           (original.count != 10) == dueIncludesTime, BoardDate.parse(original, timeZone: timeZoneID) == dueDate { return original }
        return dueIncludesTime ? BoardDate.timestamp(dueDate) : BoardDate.dateOnly(dueDate, timeZone: timeZoneID)
    }
    var scheduledStartValue: String? { scheduleValue(scheduledStart, original: editingTask?.scheduledStart) }
    var scheduledEndValue: String? { scheduleValue(scheduledEnd, original: editingTask?.scheduledEnd) }
    private func scheduleValue(_ date: Date, original: String?) -> String? {
        guard hasSchedule else { return nil }
        if let original, editingTask?.timeZone == timeZoneID, (original.count == 10) == scheduleAllDay,
           BoardDate.parse(original, timeZone: timeZoneID) == date { return original }
        return scheduleAllDay ? BoardDate.dateOnly(date, timeZone: timeZoneID) : BoardDate.timestamp(date)
    }
    mutating func changeTimeZone(to newID: String) {
        guard TimeZone(identifier: newID) != nil, newID != timeZoneID else { return }
        if hasDueDate && !dueIncludesTime {
            dueDate = BoardDate.parse(BoardDate.dateOnly(dueDate, timeZone: timeZoneID), timeZone: newID) ?? dueDate
        }
        if hasSchedule && scheduleAllDay {
            scheduledStart = BoardDate.parse(BoardDate.dateOnly(scheduledStart, timeZone: timeZoneID), timeZone: newID) ?? scheduledStart
            scheduledEnd = BoardDate.parse(BoardDate.dateOnly(scheduledEnd, timeZone: timeZoneID), timeZone: newID) ?? scheduledEnd
        }
        timeZoneID = newID
    }
}

struct WorkboardError: LocalizedError, Sendable {
    let message: String
    /// The service error code, or empty when no service response was read.
    let code: String
    init(message: String, code: String = "") { self.message = message; self.code = code }
    var errorDescription: String? { message }
}
