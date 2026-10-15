import SwiftUI
import AppKit
import Carbon
import Combine

struct CaptureInput {
    var title: String
    var source: String
    var note: String
    var parameters: [String: JSONValue] {
        var result: [String: JSONValue] = ["title": .string(title), "note": .string(note)]
        if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result["source"] = .string(source) }
        return result
    }
}

enum CaptureShortcut: String, CaseIterable, Identifiable {
    case controlShiftSpace, commandShiftSpace, controlOptionN
    var id: String { rawValue }
    var title: String {
        switch self {
        case .controlShiftSpace: "⌃⇧Space"
        case .commandShiftSpace: "⌘⇧Space"
        case .controlOptionN: "⌃⌥N"
        }
    }
    var keyCode: UInt32 { self == .controlOptionN ? UInt32(kVK_ANSI_N) : UInt32(kVK_Space) }
    var modifiers: UInt32 {
        switch self {
        case .controlShiftSpace: UInt32(controlKey | shiftKey)
        case .commandShiftSpace: UInt32(cmdKey | shiftKey)
        case .controlOptionN: UInt32(controlKey | optionKey)
        }
    }
}

extension Notification.Name {
    static let workboardQuickCapture = Notification.Name("local.agentworkboard.quickCapture")
}

// Registers one shortcut. No keyboard monitoring, Accessibility, or Input Monitoring permission.
@MainActor final class GlobalQuickCaptureShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var observations = Set<AnyCancellable>()
    private let appearance: AppearanceSettings
    private let show: () -> Void
    private var lastConfiguration = ""

    init(appearance: AppearanceSettings, show: @escaping () -> Void) {
        self.appearance = appearance; self.show = show
        NotificationCenter.default.publisher(for: .workboardQuickCapture).sink { [weak self] _ in
            self?.show()
        }.store(in: &observations)
        appearance.$quickCaptureEnabled.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.register() }
        }.store(in: &observations)
        appearance.$quickCaptureShortcut.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.register() }
        }.store(in: &observations)
        register()
    }
    func register() {
        let configuration = "\(appearance.quickCaptureEnabled):\(appearance.quickCaptureShortcut)"
        guard configuration != lastConfiguration else { return }
        lastConfiguration = configuration
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        // Isolated UI tests and renderers never register a global shortcut.
        guard appearance.quickCaptureEnabled, appearance.sharesWidgetSettings else {
            appearance.quickCaptureShortcutStatus = nil; return
        }
        if handler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard status == noErr, identifier.signature == 0x41574251, identifier.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                Task { @MainActor in NotificationCenter.default.post(name: .workboardQuickCapture, object: nil) }
                return noErr
            }, 1, &eventType, nil, &handler)
            guard status == noErr else {
                appearance.quickCaptureShortcutStatus = "Could not register the shortcut. Use Quick capture from the menu. (\(status))"; return
            }
        }
        let shortcut = CaptureShortcut(rawValue: appearance.quickCaptureShortcut) ?? .controlShiftSpace
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                        EventHotKeyID(signature: 0x41574251, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        appearance.quickCaptureShortcutStatus = status == noErr ? nil : "Another app uses this shortcut. Choose a different combination. (\(status))"
    }
}

@MainActor final class QuickCapturePanelController {
    private var panel: NSPanel?
    private let appearance: AppearanceSettings
    private let store: BoardStore
    init(appearance: AppearanceSettings, store: BoardStore) { self.appearance = appearance; self.store = store }
    func show() {
        if let panel, panel.isVisible { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let panel = self.panel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Quick capture"; panel.isReleasedWhenClosed = false; panel.level = .floating
        panel.minSize = NSSize(width: 520, height: 410)
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(rootView:
            QuickCaptureView(onClose: { [weak panel] in panel?.orderOut(nil) })
                .environmentObject(appearance).environmentObject(store).environment(\.locale, BoardDate.displayLocale)
                .tint(appearance.accent).preferredColorScheme(appearance.theme.appearance.colorScheme))
        self.panel = panel
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

struct QuickCaptureView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    var onClose: () -> Void = {}
    @State private var title = ""
    @State private var source = ""
    @State private var note = ""
    @State private var originalConnection: ConnectionIdentity?
    @State private var originalGeneration: UUID?
    @FocusState private var focused: Bool
    private var connectionMatches: Bool { originalConnection == appearance.connection.identity() && originalGeneration == store.workflowGeneration }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text("Capture an idea").font(.title3.weight(.semibold)); Spacer(); Text("Inbox").font(.caption).foregroundStyle(.secondary) }
            TextField("What would you like to do?", text: $title).font(.title3).textFieldStyle(.plain).focused($focused)
                .accessibilityIdentifier("capture-title").onSubmit { capture() }
            Divider()
            TextField("Source URL or file path (optional)", text: $source).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("capture-source")
            TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("capture-note")
            Text("Drop files or URLs here. Their contents are not read automatically.").font(.caption).foregroundStyle(.secondary)
            if !connectionMatches, originalConnection != nil {
                HStack {
                    Text("The board connection changed. Your input has been preserved.").font(.caption).foregroundStyle(.orange)
                    Button("Use current board") { originalConnection = appearance.connection.identity(); originalGeneration = store.workflowGeneration }
                }
            }
            if let error = store.actionError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
            HStack {
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add to Inbox", action: capture).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("capture-save")
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMutating || !connectionMatches)
            }
        }.padding(24).frame(width: 520)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                source = url.isFileURL ? url.path : url.absoluteString
                if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = url.isFileURL ? url.lastPathComponent : (url.host ?? url.absoluteString) }
                return true
            }
            .task { originalConnection = appearance.connection.identity(); originalGeneration = store.workflowGeneration; focused = true; await store.reload(force: true) }
    }
    private func capture() {
        guard connectionMatches, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            guard connectionMatches else { return }
            if await store.workflowMutation("inbox.capture", params: CaptureInput(title: title, source: source, note: note).parameters) != nil {
                store.notice = "Added to Inbox."; onClose()
            }
        }
    }
}

struct InboxView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @State private var showingCapture = false
    @State private var promoting: InboxItem?
    @State private var showProcessed = false
    private var items: [InboxItem] { store.inbox.filter { showProcessed || $0.status == "pending" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                if !store.isInboxView {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Inbox").font(.largeTitle.weight(.semibold))
                        Text("Capture first, then move items into project tasks when ready.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("Processed items", isOn: $showProcessed).toggleStyle(.checkbox).font(.caption)
                Button("Quick capture") { showingCapture = true }.buttonStyle(.borderedProminent).accessibilityIdentifier("inbox-add")
            }
            if items.isEmpty {
                ContentUnavailableView("Inbox is empty", systemImage: "tray", description: Text("Use Quick capture to collect ideas or URLs."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: item.status == "pending" ? "tray" : "checkmark.circle").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title).font(.headline).textSelection(.enabled)
                                    if !item.note.isEmpty { Text(item.note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                                    if !item.source.isEmpty { Text(item.source).font(.caption).foregroundStyle(appearance.accent).lineLimit(2).textSelection(.enabled) }
                                    Text(BoardDate.shortLocalTimestamp(item.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if item.status == "pending" {
                                    Button("Convert to task") { promoting = item }.disabled(store.projects.isEmpty || store.isMutating)
                                        .accessibilityIdentifier("inbox-promote-\(item.id)")
                                    Button("Archive") { dismiss(item) }.disabled(store.isMutating)
                                } else if let taskID = item.taskID {
                                    Button("Open task") { Task { await store.openTask(taskID) } }
                                } else { Text("Archived").font(.caption).foregroundStyle(.secondary) }
                            }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }.padding(24)
            .sheet(isPresented: $showingCapture) { QuickCaptureView(onClose: { showingCapture = false }) }
            .sheet(item: $promoting) { item in InboxPromotionView(item: item) }
    }
    private func dismiss(_ item: InboxItem) {
        let generation = store.workflowGeneration
        Task {
            guard generation == store.workflowGeneration else { return }
            _ = await store.workflowMutation("inbox.dismiss", params: ["item_id": .string(item.id), "expected_revision": .number(Double(item.revision))])
        }
    }
}

private struct InboxPromotionView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    let item: InboxItem
    @State private var projectID = ""
    @State private var parentID = ""
    @State private var title = ""
    @State private var connection: ConnectionIdentity?
    @State private var generation: UUID?
    private var connectionMatches: Bool { connection == appearance.connection.identity() && generation == store.workflowGeneration }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Convert to task").font(.title2.weight(.semibold))
            TextField("Task title", text: $title).textFieldStyle(.roundedBorder).accessibilityIdentifier("inbox-promote-title")
            Picker("Project", selection: $projectID) { ForEach(store.projects) { Text($0.name).tag($0.id) } }
                .onChange(of: projectID) { _, _ in parentID = "" }
            Picker("Parent task", selection: $parentID) {
                Text("None").tag("")
                ForEach(store.tasks.filter { $0.projectID == projectID }) { Text($0.title).tag($0.id) }
            }
            Text("Preserves the source and note, and links the new task to the Inbox item.").font(.caption).foregroundStyle(.secondary)
            if let error = store.actionError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }; Spacer()
                Button("Create task") { promote() }.buttonStyle(.borderedProminent)
                    .disabled(projectID.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMutating || !connectionMatches)
                    .accessibilityIdentifier("inbox-promote-save")
            }
        }.padding(24).frame(width: 480)
            .onAppear { title = item.title; projectID = store.currentProject?.id ?? store.projects.first?.id ?? ""; connection = appearance.connection.identity(); generation = store.workflowGeneration }
    }
    private func promote() {
        guard connectionMatches else { return }
        Task {
            guard connectionMatches else { return }
            let result = await store.workflowMutation("inbox.promote", params: [
                "item_id": .string(item.id), "project_id": .string(projectID),
                "parent_id": parentID.isEmpty ? .null : .string(parentID),
                "title": .string(title), "expected_revision": .number(Double(item.revision))
            ])
            if let taskID = result?["task"]["id"].string { dismiss(); await store.openTask(taskID) }
        }
    }
}

struct QuickCaptureSettingsView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    var body: some View {
        Form {
            Section("Global shortcut") {
                Toggle("Open Quick capture from other apps", isOn: $appearance.quickCaptureEnabled)
                Picker("Shortcut", selection: $appearance.quickCaptureShortcut) {
                    ForEach(CaptureShortcut.allCases) { Text($0.title).tag($0.rawValue) }
                }.disabled(!appearance.quickCaptureEnabled)
                if let message = appearance.quickCaptureShortcutStatus { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            Text("While the app is running, the shortcut can capture items even with the board window closed. URL and path contents are not read automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}
