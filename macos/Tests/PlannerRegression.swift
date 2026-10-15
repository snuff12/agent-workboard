import Foundation
import AppKit

@main struct PlannerRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    @MainActor static func main() async throws {
        let zone = "America/Los_Angeles"
        let spring = BoardDate.parse("2027-03-14", timeZone: zone)!
        let fall = BoardDate.parse("2026-11-01", timeZone: zone)!
        try require(PlannerClock.dayInterval(spring, zone: zone).duration == 23 * 3600, "Spring day must have 23 hours")
        try require(PlannerClock.dayInterval(fall, zone: zone).duration == 25 * 3600, "Fall day must have 25 hours")
        try require(PlannerClock.slot(day: spring, hour: 2, zone: zone) == nil, "Nonexistent DST hour accepted")
        try require(PlannerClock.slots(day: spring, zone: zone).count == 23 && PlannerClock.slots(day: fall, zone: zone).count == 25, "DST timeline did not have 23/25 actual slots")
        let foldedStart = BoardDate.parse("2026-11-01T01:45:00-07:00")!
        let foldedEnd = BoardDate.parse("2026-11-01T01:15:00-08:00")!
        try require(PlannerClock.minute(foldedEnd, on: fall, zone: zone) - PlannerClock.minute(foldedStart, on: fall, zone: zone) == 30, "Repeated DST hour inverted the event's calendar position")
        try require(PlannerClock.slots(day: fall, zone: zone).filter { PlannerClock.calendar(zone).component(.hour, from: $0) == 1 }.count == 2, "Repeated hour has no second drop target")
        let springThree = PlannerClock.slot(day: spring, hour: 3, zone: zone)!
        try require(BoardDate.timestamp(springThree) == "2027-03-14T10:00:00Z", "Slot was interpreted in device zone")
        let days = PlannerClock.days(containing: spring, zone: zone)
        try require(days.count == 7 && PlannerClock.calendar(zone).component(.weekday, from: days[0]) == 2, "Week does not start on Monday")
        try require(BoardDate.dateOnly(days.last!, timeZone: zone) == "2027-03-14", "Calendar-day arithmetic skipped DST date")
        try require(PlannerClock.dayLabel(spring, zone: zone, weekday: true) == "Sun", "Planner weekday labels must be English")
        print("✓ Weekly planner: English weekdays, 23/25-hour DST days, nonexistent time rejection, time zones, and Monday week start")
        let a = DateInterval(start: spring, duration: 3600)
        let b = DateInterval(start: a.end, duration: 3600)
        let overlap = DateInterval(start: spring.addingTimeInterval(1800), duration: 3600)
        try require(!PlannerClock.overlaps(a, b) && PlannerClock.overlaps(a, overlap), "Exclusive end overlap rule failed")
        try require(PlannerClock.lanes([a, overlap, DateInterval(start: spring.addingTimeInterval(7200), duration: 3600)]) == [0, 1, 0], "Calendar lanes were not reused after overlap")
        print("✓ Schedule placement: touching boundaries versus overlaps, and column reuse for overlapping cards")
        let task = BoardTask(.object([
            "id": .string("all-day"), "project_id": .string("p"), "title": .string("All day"),
            "scheduled_start": .string("2027-03-14"), "scheduled_end": .string("2027-03-15"),
            "time_zone": .string(zone), "revision": .number(7)
        ]))!
        let connection = ConnectionConfiguration(sharesWidgetSnapshot: false).identity(environment: [:])
        var draft = PlannerDraft(task: task, at: nil, zone: "Asia/Seoul", connection: connection)
        try require(draft.allDay && draft.zone == zone && draft.startValue == "2027-03-14" && draft.endValue == "2027-03-15", "Editing all-day task in foreign display zone shifted its dates")
        try require(draft.end.timeIntervalSince(draft.start) == 23 * 3600, "All-day task lost DST calendar-day duration")
        try draft.changeTimeZone(to: "Asia/Seoul")
        try require(draft.startValue == "2027-03-14" && draft.endValue == "2027-03-15", "Changing all-day timezone shifted its civil date")
        let moved = PlannerDraft(task: task, at: springThree, zone: "UTC", connection: connection)
        try require(!moved.allDay && moved.zone == "UTC" && moved.startValue == "2027-03-14T10:00:00Z", "Drop target instant/zone lost")
        try require(moved.fingerprint != draft.fingerprint && moved.task.revision == 7, "Schedule preview did not depend on exact revision and date fields")
        print("✓ Schedule editing: all-day dates preserved across display zones, drop times and revisions retained")
        let titleOnly = CaptureInput(title: "Title only", source: "", note: "").parameters
        try require(titleOnly["source"] == nil && titleOnly["title"] == .string("Title only"), "Title-only capture sent an invalid empty optional source")
        try require(CaptureInput(title: "Whitespace", source: " \n", note: "").parameters["source"] == nil, "Whitespace-only source was not omitted")
        try require(CaptureInput(title: "File", source: "/tmp/file with space ", note: "").parameters["source"] == .string("/tmp/file with space "), "Nonempty file source was modified")
        print("✓ Quick capture: title-only input, blank source omission, and original file path preservation")
        let calendarEvent = CalendarEvent(.object([
            "id": .string("google-allday"), "start": .string("2026-10-20"), "end": .string("2026-10-21"), "time_zone": .null
        ]), fallbackTimeZone: "America/New_York")!
        let calendarInterval = PlannerClock.interval(start: calendarEvent.start, end: calendarEvent.end, zone: calendarEvent.timeZone)!
        try require(calendarEvent.timeZone == "America/New_York" && BoardDate.timestamp(calendarInterval.start) == "2026-10-20T04:00:00Z", "Google all-day event lost calendar-level timezone fallback")
        let beforeCalendarDay = PlannerClock.dayInterval(BoardDate.parse("2026-10-19", timeZone: "America/New_York")!, zone: "America/New_York")
        try require(!PlannerClock.overlaps(calendarInterval, beforeCalendarDay), "Google all-day event spilled into the previous calendar day")
        print("✓ Google all-day events: calendar time zone fallback preserved without shifting to the previous day")
        let suite = "workboard-planner-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppearanceSettings(defaults: defaults)
        settings.quickCaptureEnabled = false
        settings.quickCaptureShortcut = CaptureShortcut.commandShiftSpace.rawValue
        settings.plannerTimeZone = "Pacific/Auckland"
        let restored = AppearanceSettings(defaults: defaults)
        try require(!restored.quickCaptureEnabled && restored.quickCaptureShortcut == CaptureShortcut.commandShiftSpace.rawValue && restored.plannerTimeZone == "Pacific/Auckland", "Capture/planner settings were not restored")
        let shortcut = GlobalQuickCaptureShortcut(appearance: restored, show: {})
        shortcut.register()
        try require(restored.quickCaptureShortcutStatus == nil && !restored.sharesWidgetSettings, "Isolated tests registered global shortcut")
        defaults.set("invalid/zone", forKey: "plannerTimeZone")
        try require(TimeZone(identifier: AppearanceSettings(defaults: defaults).plannerTimeZone) != nil, "Invalid saved planner zone was accepted")
        print("✓ Quick capture and weekly planner preferences restored; isolated runs do not register global shortcuts")
        if let executable = ProcessInfo.processInfo.environment["WORKBOARD_BIN"] {
            let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("awb-capture-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let service = Process()
            service.executableURL = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("workboard-service")
            service.arguments = ["--data-dir", directory.path, "--socket", directory.appendingPathComponent("workboard.sock").path]
            service.standardOutput = FileHandle.nullDevice; service.standardError = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "WORKBOARD_WIDGET_SNAPSHOT"); service.environment = environment
            try service.run()
            defer {
                if service.isRunning { service.terminate(); service.waitUntilExit() }
                try? FileManager.default.removeItem(at: directory)
            }
            for _ in 0..<50 {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("workboard.sock").path) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let settings = AppearanceSettings(defaults: defaults)
            settings.executablePath = executable; settings.dataDirectory = directory.path
            let store = BoardStore(appearance: settings)
            await store.reload(force: true)
            guard await store.workflowMutation("inbox.capture", params: titleOnly) != nil else { throw Failure(description: store.actionError ?? "Title-only UI capture failed") }
            try require(store.inbox.contains { $0.title == "Title only" && $0.source.isEmpty && $0.status == "pending" }, "UI capture input did not reach the real Inbox")
            print("✓ Actual CLI and service: the UI title-only path saves to Inbox without a source")
        }
    }
}
