import Foundation

struct WorkflowEditContext: Sendable, Equatable {
    let connection: ConnectionIdentity
    let generation: UUID
}

struct ChecklistItem: Identifiable, Sendable, Hashable {
    let id: String
    let text: String
    let required: Bool
    let checked: Bool
    let evidence: String?
    init?(_ json: JSONValue) {
        guard let id = json["id"].string else { return nil }
        self.id = id; text = json["text"].string ?? ""; required = json["required"].bool ?? true
        checked = json["checked"].bool ?? false; evidence = json["evidence"].string
    }
}

struct ReviewDecision: Identifiable, Sendable {
    let id: String
    let decision: String
    let summary: String
    let actor: String?
    let createdAt: String
    init?(_ json: JSONValue) {
        guard let id = json["id"].string else { return nil }
        self.id = id; decision = json["decision"].string ?? ""; summary = json["summary"].string ?? ""
        actor = json["actor"].string; createdAt = json["created_at"].string ?? ""
    }
    var title: String { Self.title(for: decision) }
    static func title(for decision: String) -> String {
        switch decision { case "approve": "Approve"; case "request_changes": "Request changes"; case "reject": "Reject"; default: decision }
    }
}

struct InboxItem: Identifiable, Sendable {
    let id: String
    let title: String
    let source: String
    let note: String
    let status: String
    let taskID: String?
    let revision: Int
    let createdAt: String
    let updatedAt: String
    init?(_ json: JSONValue) {
        guard let id = json["id"].string else { return nil }
        self.id = id; title = json["title"].string ?? ""; source = json["source"].string ?? ""
        note = json["note"].string ?? ""; status = json["status"].string ?? "pending"; taskID = json["task_id"].string
        revision = json["revision"].int ?? 0; createdAt = json["created_at"].string ?? ""; updatedAt = json["updated_at"].string ?? ""
    }
}

struct SavedTaskView: Identifiable, Sendable {
    let id: String
    let name: String
    let filters: TaskFilters
    let layout: String
    let revision: Int
    init?(_ json: JSONValue) {
        guard let id = json["id"].string else { return nil }
        self.id = id; name = json["name"].string ?? "Untitled view"; filters = TaskFilters(json["filters"])
        layout = ["board", "list", "week"].contains(json["layout"].string ?? "") ? json["layout"].string! : "board"
        revision = json["revision"].int ?? 0
    }
}

struct TaskFilters: Sendable, Equatable {
    var projectID = ""
    var status = ""
    var assignee = ""
    var unassignedOnly = false
    var readyOnly = false
    var staleDays: Int?
    var blockedOnly = false
    var query = ""
    init() {}
    init(_ json: JSONValue) {
        projectID = json["project_id"].string ?? ""; status = json["status"].string ?? ""; assignee = json["assignee"].string ?? ""
        unassignedOnly = json.object["assignee"] == .null
        readyOnly = json["ready_only"].bool ?? false; staleDays = json["stale_days"].int
        blockedOnly = json["blocked_only"].bool ?? false; query = json["query"].string ?? ""
    }
    var json: JSONValue {
        var result: [String: JSONValue] = [:]
        for (key, value) in [("project_id", projectID), ("status", status), ("query", query)] where !value.isEmpty { result[key] = .string(value) }
        if unassignedOnly { result["assignee"] = .null } else if !assignee.isEmpty { result["assignee"] = .string(assignee) }
        if readyOnly { result["ready_only"] = .bool(true) }; if blockedOnly { result["blocked_only"] = .bool(true) }
        if let staleDays { result["stale_days"] = .number(Double(staleDays)) }
        return .object(result)
    }
    var isEmpty: Bool { json.object.isEmpty }
    func matches(_ task: BoardTask, now: Date = Date()) -> Bool {
        if !projectID.isEmpty && task.projectID != projectID { return false }
        if !status.isEmpty && task.status.rawValue != status { return false }
        if unassignedOnly { if task.assignee != nil { return false } }
        else if !assignee.isEmpty && task.assignee != assignee { return false }
        if readyOnly && !task.ready { return false }; if blockedOnly && !task.isBlocked { return false }
        if let staleDays, !task.isStale(days: staleDays, now: now) { return false }
        return query.isEmpty || [task.title, task.goal, task.completionCriteria, task.nextAction, task.assignee ?? ""].joined(separator: " ").localizedStandardContains(query)
    }
}

struct TaskTemplate: Identifiable, Sendable {
    let id: String
    let name: String
    let builtin: Bool
    let revision: Int
    let definition: JSONValue
    init?(_ json: JSONValue) {
        guard let id = json["id"].string else { return nil }
        self.id = id; name = json["name"].string ?? "Untitled template"; builtin = json["builtin"].bool ?? false
        revision = json["revision"].int ?? 0; definition = json["definition"]
    }
    var title: String { definition["title"].string ?? name }
    var childCount: Int {
        func count(_ node: JSONValue) -> Int { node["children"].array.reduce(0) { $0 + 1 + count($1) } }
        return count(definition)
    }
    static func definition(from task: BoardTask, tasks: [BoardTask]) -> JSONValue {
        .object(["title": .string(task.title), "goal": .string(task.goal), "completion_criteria": .string(task.completionCriteria), "priority": .number(Double(task.priority)),
                 "checklist": .array(task.checklist.map { .object(["text": .string($0.text), "required": .bool($0.required)]) }),
                 "children": .array(tasks.filter { $0.parentID == task.id }.map { definition(from: $0, tasks: tasks) })])
    }
}
