import AppKit
import SwiftUI

// Developer-only pixel QA. Every task shown comes from the real service snapshot.
@main struct RenderPreviews {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let environment = ProcessInfo.processInfo.environment
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = sourceDirectory.appendingPathComponent(".build/previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "workboard-preview-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = AppearanceSettings(defaults: defaults)
        appearance.executablePath = environment["WORKBOARD_BIN"] ?? ""
        appearance.dataDirectory = environment["WORKBOARD_DATA_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentWorkboard").path
        appearance.theme.showSubtasksOnBoard = true
        let store = BoardStore(appearance: appearance)
        await store.reload(force: true)
        guard store.connectionError == nil else { throw WorkboardError(message: store.connectionError ?? "Cannot load actual board") }
        store.selectedProjectID = store.projects.first(where: { $0.directory == FileManager.default.currentDirectoryPath })?.id ?? store.projects.first?.id
        if let parent = store.tasks.first(where: { $0.parentID == nil }) { await store.openTask(parent.id) }
        for mode in [AppearanceMode.light, .dark] {
            appearance.theme.appearance = mode
            let root = BoardView().environmentObject(appearance).environmentObject(store).tint(appearance.accent).preferredColorScheme(mode.colorScheme).environment(\.colorScheme, mode == .dark ? .dark : .light)
            try capture(root, size: NSSize(width: 1600, height: 1000), appearance: mode == .dark ? .darkAqua : .aqua, output: output.appendingPathComponent("board-\(mode.rawValue).png"))
        }
        store.selectedTaskID = nil; store.detail = nil
        for mode in [AppearanceMode.light, .dark] {
            appearance.theme.appearance = mode
            let scheme: ColorScheme = mode == .dark ? .dark : .light
            try capture(WeeklyPlannerView().environmentObject(appearance).environmentObject(store).environment(\.colorScheme, scheme),
                        size: NSSize(width: 1240, height: 880), appearance: mode == .dark ? .darkAqua : .aqua,
                        output: output.appendingPathComponent("weekly-planner-\(mode.rawValue).png"))
            try capture(InboxView().environmentObject(appearance).environmentObject(store).environment(\.colorScheme, scheme),
                        size: NSSize(width: 1020, height: 680), appearance: mode == .dark ? .darkAqua : .aqua,
                        output: output.appendingPathComponent("inbox-\(mode.rawValue).png"))
        }
        appearance.theme.appearance = .light
        try capture(QuickCaptureView().environmentObject(appearance).environmentObject(store).environment(\.colorScheme, .light),
                    size: NSSize(width: 550, height: 480), appearance: .aqua, output: output.appendingPathComponent("quick-capture.png"))
        for mode in [AppearanceMode.light, .dark] {
            appearance.theme.appearance = mode
            try capture(SettingsView().environmentObject(appearance).environmentObject(store).environment(\.colorScheme, mode == .dark ? .dark : .light), size: NSSize(width: 660, height: 740), appearance: mode == .dark ? .darkAqua : .aqua, output: output.appendingPathComponent("appearance-settings-\(mode.rawValue).png"))
        }
        appearance.theme.appearance = .light
        if let task = store.tasks.first(where: { $0.title.contains("Personalization") }) ?? store.tasks.first {
            let draft = TaskDraft(projectID: task.projectID, editingTask: task)
            try capture(TaskEditorView(draft: draft).environmentObject(appearance).environmentObject(store).environment(\.colorScheme, .light), size: NSSize(width: 600, height: 770), appearance: .aqua, output: output.appendingPathComponent("task-editor.png"))
        }
        let metadata: [String: Any] = ["source": "real local workboard service", "data_directory": appearance.dataDirectory, "projects": store.projects.count, "tasks": store.tasks.count, "generated_at": ISO8601DateFormatter().string(from: Date()), "kind": "offscreen NSHostingView pixel QA, not a captured running app window"]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("source.json"))
        print("Real board pixel previews: \(output.path)")
        app.terminate(nil)
    }
    @MainActor static func capture<Content: View>(_ content: Content, size: NSSize, appearance: NSAppearance.Name, output: URL) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Agent Workboard · Pixel QA"
        NSApp.appearance = NSAppearance(named: appearance)
        window.appearance = NSAppearance(named: appearance)
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        let host = NSHostingView(rootView: content.environment(\.locale, BoardDate.displayLocale).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFront(nil)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); NSApp.updateWindows()
            CFRunLoopRunInMode(.defaultMode, 0.15, false)
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw WorkboardError(message: "Cannot allocate preview bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw WorkboardError(message: "Cannot encode preview PNG") }
        try png.write(to: output, options: .atomic)
        print("\(output.lastPathComponent): \(bitmap.pixelsWide)×\(bitmap.pixelsHigh), \(png.count) bytes")
        window.orderOut(nil)
        window.contentView = nil
    }
}
