import Foundation

@main
struct WidgetSnapshotProbe {
    static func main() throws {
        let fixture = """
        {"schema_version":1,"event_sequence":12,"generated_at":"2026-10-15T00:00:00.123Z","tasks":[
          {"id":"now","title":"In progress","status":"in_progress","priority":1,"updated_at":"2026-10-15T00:00:00Z","project_id":"p","assignee":"agent"},
          {"id":"low","title":"Low priority","status":"todo","priority":1,"updated_at":"2026-10-15T00:00:00Z","project_id":"p"},
          {"id":"high","title":"High priority","status":"todo","priority":3,"updated_at":"2026-10-15T00:00:01Z","project_id":"p","parent_id":"now"},
          {"id":"review","title":"Needs review","status":"review","priority":2,"updated_at":"2026-10-15T00:00:00Z","project_id":"p"},
          {"id":"done","title":"Done","status":"done","priority":3,"updated_at":"2026-10-15T00:00:00Z","project_id":"p"},
          {"id":"parked","title":"Backlog","status":"backlog","priority":3,"updated_at":"2026-10-15T00:00:00Z","project_id":"p"},
          {"id":"dropped","title":"Canceled","status":"canceled","priority":3,"updated_at":"2026-10-15T00:00:00Z","project_id":"p"}
        ]}
        """
        let snapshot = try WidgetSnapshot.decode(Data(fixture.utf8))
        precondition(snapshot.tasks(for: .now).map(\.id) == ["now"], "Current task filter")
        precondition(snapshot.tasks(for: .next).map(\.id) == ["high", "low"], "Next task priority")
        precondition(snapshot.tasks(for: .review).map(\.id) == ["review"], "Needs review filter")
        precondition(!snapshot.isStale(at: snapshot.generatedAt.addingTimeInterval(899)), "Immediately after update")
        precondition(snapshot.isStale(at: snapshot.generatedAt.addingTimeInterval(900)), "Stale after 15 minutes")
        precondition(snapshot.tasks[0].url.absoluteString == "workboard://task/now", "Task deep link")
        precondition(snapshot.tasks[2].parentId == "now", "Subtask decoding")
        do {
            _ = try WidgetSnapshot.decode(Data(fixture.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":2").utf8))
            fatalError("An unsupported schema was accepted.")
        } catch WidgetSnapshot.SnapshotError.unsupportedVersion { }
        let empty = try WidgetSnapshot.decode(Data("{\"schema_version\":1,\"event_sequence\":0,\"generated_at\":\"2026-10-15T00:00:00Z\",\"tasks\":[]}".utf8))
        precondition(empty.tasks(for: .now).isEmpty)
        var idle = snapshot
        idle.checkedAt = snapshot.generatedAt.addingTimeInterval(24 * 3600)
        precondition(!idle.isStale(at: idle.lastCheckedAt.addingTimeInterval(899)), "An idle healthy board remains connected")
        precondition(idle.isStale(at: idle.lastCheckedAt.addingTimeInterval(900)), "A stopped service becomes disconnected")
        precondition(idle.generatedAt == snapshot.generatedAt, "A heartbeat must not rewrite data-change time")
        try todaySummary()
        if CommandLine.arguments.count > 1 {
            let actual = try WidgetSnapshot.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            print("Service snapshot read passed: sequence \(actual.eventSequence), \(actual.tasks.count) tasks")
        }
        print("Widget snapshot checks passed: views, ordering, subtasks, deep links, time, schema, daily summary, and collapsing")
    }

    /// 2026-10-15 15:00 in Seoul. Date-only values belong to this Mac's day.
    static func todaySummary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = WidgetSnapshot.parseDate("2026-10-15T06:00:00Z")!
        let fixture = """
        {"schema_version":1,"event_sequence":3,"generated_at":"2026-10-15T06:00:00Z","tasks":[
          {"id":"working","title":"Progress","status":"in_progress","priority":0,"updated_at":"2026-10-14T01:00:00Z","project_id":"p"},
          {"id":"due-today","title":"Due today","status":"todo","priority":0,"updated_at":"2026-10-01T00:00:00Z","project_id":"p","due_at":"2026-10-15"},
          {"id":"due-later","title":"Due this afternoon","status":"todo","priority":3,"updated_at":"2026-10-01T00:00:00Z","project_id":"p","due_at":"2026-10-15T18:00:00+09:00"},
          {"id":"overdue","title":"Due yesterday","status":"todo","priority":0,"updated_at":"2026-10-01T00:00:00Z","project_id":"p","due_at":"2026-10-14"},
          {"id":"meeting","title":"Meeting today","status":"todo","priority":0,"updated_at":"2026-10-01T00:00:00Z","project_id":"p","scheduled_start":"2026-10-15T10:00:00+09:00","scheduled_end":"2026-10-15T11:00:00+09:00"},
          {"id":"tomorrow","title":"Due tomorrow","status":"todo","priority":3,"updated_at":"2026-10-01T00:00:00Z","project_id":"p","due_at":"2026-10-16"},
          {"id":"undated","title":"No date","status":"todo","priority":3,"updated_at":"2026-10-01T00:00:00Z","project_id":"p"},
          {"id":"parked-today","title":"Backlog due today","status":"backlog","priority":0,"updated_at":"2026-10-01T00:00:00Z","project_id":"p","due_at":"2026-10-15T20:00:00+09:00"},
          {"id":"canceled-overdue","title":"Canceled after its deadline","status":"canceled","priority":0,"updated_at":"2026-10-01T00:00:00Z","project_id":"p","due_at":"2026-10-14"},
          {"id":"done-today","title":"Completed today","status":"done","priority":0,"completed_at":"2026-10-15T00:30:00Z","updated_at":"2026-10-15T06:00:00Z","project_id":"p"},
          {"id":"done-yesterday","title":"Edited today, completed yesterday","status":"done","priority":0,"completed_at":"2026-10-14T14:59:00Z","updated_at":"2026-10-15T06:00:00Z","project_id":"p"}
        ]}
        """
        let snapshot = try WidgetSnapshot.decode(Data(fixture.utf8))
        let sections = snapshot.sections(at: now, calendar: calendar)
        precondition(sections.map(\.section) == [.now, .today, .done], "Show Needs review only when it has items")
        precondition(sections[0].tasks.map(\.id) == ["working"], "In progress")
        precondition(sections[1].tasks.map(\.id) == ["overdue", "due-today", "meeting", "due-later", "parked-today"],
            "Due today: order overdue, today’s deadlines and meetings by time; include Backlog deadlines; exclude tomorrow, undated, and canceled tasks")
        precondition(sections[2].tasks.map(\.id) == ["done-today"], "Completed today includes only tasks completed today in Seoul")
        let overdue = snapshot.tasks.first { $0.id == "overdue" }!
        precondition(overdue.isOverdue(at: now, calendar: calendar), "Overdue date-only deadline")
        precondition(!snapshot.tasks.first { $0.id == "due-today" }!.isOverdue(at: now, calendar: calendar), "Today’s deadline is not overdue yet")
        precondition(!snapshot.tasks.first { $0.id == "canceled-overdue" }!.isOverdue(at: now, calendar: calendar), "Canceled work is never overdue")
        precondition(WidgetSnapshot.allocate(rows: 3, among: [5, 0, 5]) == [2, 0, 1], "Allocate rows across expanded sections in round-robin order")
        precondition(WidgetSnapshot.allocate(rows: 9, among: [1, 2, 0]) == [1, 2, 0], "Leave unused rows empty")
        let suite = "local.agentworkboard.probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        WidgetSectionState.toggle("done", in: defaults)
        precondition(WidgetSectionState.collapsed(in: defaults) == ["done"], "Collapse section")
        WidgetSectionState.toggle("done", in: defaults)
        WidgetSectionState.toggle("unknown", in: defaults)
        precondition(WidgetSectionState.collapsed(in: defaults).isEmpty, "Expand again and ignore unknown sections")
    }
}
