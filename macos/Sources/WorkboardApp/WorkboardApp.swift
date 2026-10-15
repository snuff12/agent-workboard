import SwiftUI
import AppKit
import OSLog
import WidgetKit

/// WidgetKit accepts reload requests only from the app that contains the widget. The background service
/// runs this executable with `--reload-widgets` after it updates the shared snapshot, so desktop widgets
/// follow CLI changes while the app window is closed. That mode starts no UI.
@main enum WorkboardLauncher {
    @MainActor static func main() {
        guard CommandLine.arguments.contains("--reload-widgets") else { WorkboardApp.main(); return }
        WidgetCenter.shared.reloadAllTimelines()
        // The reply to this request arrives after the reload message on the same connection.
        let delivered = DispatchSemaphore(value: 0)
        WidgetCenter.shared.getCurrentConfigurations { _ in delivered.signal() }
        _ = delivered.wait(timeout: .now() + 5)
    }
}

struct WorkboardApp: App {
    @NSApplicationDelegateAdaptor(WorkboardAppDelegate.self) private var appDelegate
    @StateObject private var appearance: AppearanceSettings
    @StateObject private var store: BoardStore
    private let capturePanel: QuickCapturePanelController
    private let captureShortcut: GlobalQuickCaptureShortcut

    init() {
        // UI tests keep personal settings and the shared widget snapshot untouched.
        let isolated = ProcessInfo.processInfo.environment["WORKBOARD_DEFAULTS_SUITE"].flatMap(UserDefaults.init(suiteName:))
        let appearance = AppearanceSettings(defaults: isolated ?? .standard)
        let store = BoardStore(appearance: appearance)
        let capturePanel = QuickCapturePanelController(appearance: appearance, store: store)
        _appearance = StateObject(wrappedValue: appearance)
        _store = StateObject(wrappedValue: store)
        self.capturePanel = capturePanel
        captureShortcut = GlobalQuickCaptureShortcut(appearance: appearance) { capturePanel.show() }
    }
    var body: some Scene {
        Window("Agent Workboard", id: "board") {
            BoardView().environmentObject(appearance).environmentObject(store).environment(\.locale, BoardDate.displayLocale)
                .tint(appearance.accent).preferredColorScheme(appearance.theme.appearance.colorScheme)
                .frame(minWidth: 940, minHeight: 620)
                .onOpenURL { store.handle(url: $0) }
                .task { await store.reload(force: true); await store.poll() }
                .onAppear { NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New task") { store.newTask() }.keyboardShortcut("n", modifiers: .command)
                Button("Quick capture…") { capturePanel.show() }
                Button("New project…") { store.showingNewProject = true }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Board") {
                Button("Refresh") { Task { await store.reload(force: true) } }.keyboardShortcut("r", modifiers: .command)
                Divider()
                Toggle("Show Done column", isOn: $appearance.theme.showCompleted)
                Toggle("Show subtasks on the board", isOn: $appearance.theme.showSubtasksOnBoard)
                Divider()
                Button("Create backup…") { store.backup() }
                Button("Export as Markdown…") { store.exportBoard(format: "markdown") }
                Button("Export as JSON…") { store.exportBoard(format: "json") }
            }
        }
        Settings { SettingsView().environmentObject(appearance).environmentObject(store).environment(\.locale, BoardDate.displayLocale) }
        MenuBarExtra("Agent Workboard", systemImage: "rectangle.split.3x1") {
            MenuBarView(capture: { capturePanel.show() }).environmentObject(store).environmentObject(appearance).environment(\.locale, BoardDate.displayLocale)
        }.menuBarExtraStyle(.window)
    }
}

@MainActor final class WorkboardAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "local.agentworkboard.app", category: "windows")
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showBoardWindow() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showBoardWindow()
        return true
    }
    private func showBoardWindow() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.title == "Agent Workboard" }) else {
            logger.info("Board window not yet registered. Native windows: \(NSApp.windows.count)")
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        logger.info("Board window available. Visible: \(window.isVisible), size: \(window.frame.width)×\(window.frame.height)")
    }
}

private struct MenuBarView: View {
    var capture: () -> Void
    @EnvironmentObject private var store: BoardStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("Workboard", systemImage: "rectangle.split.3x1").font(.headline); Spacer(); Button { Task { await store.reload(force: true) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh") }
            if let error = store.connectionError { Text(error).font(.caption).foregroundStyle(Color.secondary).lineLimit(3) }
            else {
                ForEach([WorkStatus.inProgress, .review]) { status in
                    VStack(alignment: .leading, spacing: 7) {
                        Label(status.title, systemImage: status.symbol).font(.caption.weight(.semibold)).foregroundStyle(Color.secondary)
                        let rows = store.tasks.filter { $0.status == status }.prefix(3)
                        if rows.isEmpty { Text("No tasks").font(.caption).foregroundStyle(.tertiary) }
                        ForEach(Array(rows)) { task in
                            Button { openWindow(id: "board"); NSApp.activate(ignoringOtherApps: true); Task { await store.openTask(task.id) } } label: {
                                HStack { Circle().fill(status.color).frame(width: 6, height: 6); Text(task.title).lineLimit(1); Spacer(); Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary) }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            Divider()
            HStack { Button("Open board") { openWindow(id: "board"); NSApp.activate(ignoringOtherApps: true) }; Button("Quick capture", action: capture); Spacer(); SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless) }
        }.padding(18).frame(width: 320)
    }
}
