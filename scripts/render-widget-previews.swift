import AppKit
import Foundation
import SwiftUI
import WidgetKit

/// An off-screen layout preview, not an installed WidgetKit host verification.
@main
struct RenderWidgetPreviews {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".build/widget-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        let today = day.string(from: now)
        let yesterday = day.string(from: now.addingTimeInterval(-86_400))
        let laterToday = ISO8601DateFormatter().string(from: Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: now) ?? now)
        let fixture = """
        {"schema_version":1,"event_sequence":15,"generated_at":"\(timestamp)","tasks":[
          {"id":"current","title":"Connect CLI and kanban task status","status":"in_progress","priority":3,"assignee":"Codex","next_action":"Verify the app and service connection","updated_at":"\(timestamp)","project_id":"p"},
          {"id":"current-2","title":"Refine the widget layout","status":"in_progress","priority":2,"assignee":"UI agent","next_action":"Keep it readable at small sizes","updated_at":"\(timestamp)","project_id":"p"},
          {"id":"next","title":"Check subtask completion criteria","status":"todo","priority":2,"assignee":"Codex","next_action":"Check artifacts and next actions","updated_at":"\(timestamp)","project_id":"p"},
          {"id":"review","title":"Review the first app screen","status":"review","priority":2,"assignee":"User","next_action":"Check card spacing and accent colors","updated_at":"\(timestamp)","project_id":"p"},
          {"id":"overdue","title":"Organize last week’s meeting notes","status":"todo","priority":1,"updated_at":"\(timestamp)","project_id":"p","due_at":"\(yesterday)"},
          {"id":"due","title":"Check the release checklist","status":"todo","priority":2,"updated_at":"\(timestamp)","project_id":"p","due_at":"\(today)"},
          {"id":"late","title":"Draft release notes","status":"todo","priority":1,"updated_at":"\(timestamp)","project_id":"p","due_at":"\(laterToday)"},
          {"id":"done","title":"Fix CLI assignee validation","status":"done","priority":1,"updated_at":"\(timestamp)","project_id":"p"}
        ]}
        """
        let snapshot = try WidgetSnapshot.decode(Data(fixture.utf8))
        let sizes: [(String, WidgetFamily, CGFloat, CGFloat)] = [
            ("small", .systemSmall, 170, 170), ("medium", .systemMedium, 360, 170),
            ("large", .systemLarge, 360, 380)
        ]
        let variants: [(String, WidgetMode, Set<String>)] = [("", .now, []), ("today-", .today, []), ("today-folded-", .today, ["done", "review"])]
        for (prefix, mode, collapsed) in variants {
        for (name, family, width, height) in sizes {
            let entry = WorkboardEntry(date: now, mode: mode, accent: .blue, snapshot: snapshot, failed: false, collapsed: collapsed)
            let root = Group {
                if mode == .today { WorkboardTodayLayout(entry: entry, family: family) }
                else { WorkboardWidgetLayout(entry: entry, family: family) }
            }
                .padding(16)
                .frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.locale, Locale(identifier: "en_US"))
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = bitmap.representation(using: .png, properties: [:])!
            let path = output.appendingPathComponent("widget-\(prefix)\(name).png")
            try data.write(to: path)
            window.close()
            print(path.path)
        }
        }
    }
}
