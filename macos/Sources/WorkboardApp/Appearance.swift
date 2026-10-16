import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WidgetKit
import Combine

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" } }
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
    var symbol: String { switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max"; case .dark: "moon" } }
}

enum CardDensity: String, Codable, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var title: String { self == .comfortable ? "Comfortable" : "Compact" }
    var padding: CGFloat { self == .comfortable ? 16 : 11 }
}

struct ThemeConfiguration: Codable, Equatable {
    var version = 1
    var name = "My theme"
    var appearance: AppearanceMode = .system
    var accentHex = "5473E8"
    var density: CardDensity = .comfortable
    var fontScale = 1.0
    var showSidebar = true
    var showCompleted = true
    var showSubtasksOnBoard = false

    func validated() throws -> ThemeConfiguration {
        guard version == 1 else { throw WorkboardError(message: "Unsupported theme version.") }
        guard Self.normalizedHex(accentHex) != nil else { throw WorkboardError(message: "The theme accent must be a six-digit HEX color.") }
        guard fontScale.isFinite, (0.85...1.3).contains(fontScale) else { throw WorkboardError(message: "Theme text size must be between 85% and 130%.") }
        var theme = self; theme.accentHex = Self.normalizedHex(accentHex)!; theme.name = String(name.prefix(100)); return theme
    }
    static func normalizedHex(_ input: String) -> String? {
        let hex = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "").uppercased()
        guard hex.count == 6, hex.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789ABCDEF").contains($0) }) else { return nil }
        return hex
    }
}

@MainActor final class AppearanceSettings: ObservableObject {
    static let storageKey = "local.agentworkboard.appearance.v1"
    @Published var theme: ThemeConfiguration { didSet { persist() } }
    @Published var executablePath: String { didSet { defaults.set(executablePath, forKey: "workboardExecutablePath"); if oldValue != executablePath { connectionChanges.send() } } }
    @Published var dataDirectory: String { didSet { defaults.set(dataDirectory, forKey: "workboardDataDirectory"); if oldValue != dataDirectory { connectionChanges.send() } } }
    @Published var message: String?
    @Published var quickCaptureEnabled: Bool { didSet { defaults.set(quickCaptureEnabled, forKey: "quickCaptureEnabled") } }
    @Published var quickCaptureShortcut: String { didSet { defaults.set(quickCaptureShortcut, forKey: "quickCaptureShortcut") } }
    @Published var quickCaptureShortcutStatus: String?
    @Published var plannerTimeZone: String { didSet { defaults.set(plannerTimeZone, forKey: "plannerTimeZone") } }
    let connectionChanges = PassthroughSubject<Void, Never>()
    private let defaults: UserDefaults
    let sharesWidgetSettings: Bool
    static let palettes: [(name: String, hex: String)] = [("Iris", "5473E8"), ("Ocean", "168DAD"), ("Forest", "39836B"), ("Plum", "9972C4"), ("Rose", "C75C78"), ("Amber", "B77B2C"), ("Graphite", "657080")]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sharesWidgetSettings = defaults === UserDefaults.standard
        if let data = defaults.data(forKey: Self.storageKey), let stored = try? JSONDecoder().decode(ThemeConfiguration.self, from: data), let valid = try? stored.validated() { theme = valid } else { theme = ThemeConfiguration() }
        executablePath = defaults.string(forKey: "workboardExecutablePath") ?? ""
        dataDirectory = defaults.string(forKey: "workboardDataDirectory") ?? ""
        quickCaptureEnabled = defaults.object(forKey: "quickCaptureEnabled") as? Bool ?? true
        quickCaptureShortcut = defaults.string(forKey: "quickCaptureShortcut") ?? CaptureShortcut.controlShiftSpace.rawValue
        let storedZone = defaults.string(forKey: "plannerTimeZone") ?? TimeZone.current.identifier
        plannerTimeZone = TimeZone(identifier: storedZone) == nil ? TimeZone.current.identifier : storedZone
    }
    var accent: Color { Color(hex: theme.accentHex) }
    var connection: ConnectionConfiguration { ConnectionConfiguration(executablePath: executablePath, dataDirectory: dataDirectory, sharesWidgetSnapshot: sharesWidgetSettings) }
    func persist() {
        if let data = try? JSONEncoder.pretty.encode(theme) { defaults.set(data, forKey: Self.storageKey) }
        if sharesWidgetSettings, FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WorkboardAppGroup.identifier) != nil,
           let shared = UserDefaults(suiteName: WorkboardAppGroup.identifier), shared.string(forKey: "widgetAccentHex") != theme.accentHex {
            shared.set(theme.accentHex, forKey: "widgetAccentHex"); shared.set("app", forKey: "widgetAccent"); WidgetCenter.shared.reloadAllTimelines()
        }
    }
    func reset() { theme = ThemeConfiguration(); message = "Default theme applied." }
    func importTheme(from url: URL) throws {
        theme = try JSONDecoder().decode(ThemeConfiguration.self, from: Data(contentsOf: url)).validated()
    }
    func exportTheme(to url: URL) throws {
        try JSONEncoder.pretty.encode(theme).write(to: url, options: .atomic)
    }
    func importTheme() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Choose an Agent Workboard theme JSON file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try importTheme(from: url); message = "Applied the ‘\(theme.name)’ theme." }
        catch { message = "Could not import the theme. \(error.localizedDescription)" }
    }
    func exportTheme() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "workboard-theme.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try exportTheme(to: url); message = "Theme exported." }
        catch { message = "Could not export the theme. \(error.localizedDescription)" }
    }
}

extension Color {
    init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0x5473E8
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255, opacity: 1)
    }
    var rgbHex: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "5473E8" }
        return String(format: "%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var store: BoardStore
    var body: some View {
        TabView {
            appearanceTab.tabItem { Label("Appearance", systemImage: "paintpalette") }
            connectionTab.tabItem { Label("Connection", systemImage: "point.3.connected.trianglepath.dotted") }
            QuickCaptureSettingsView().tabItem { Label("Quick capture", systemImage: "tray.and.arrow.down") }
            PluginSettingsView().tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
        }
        .padding(20).frame(width: 620, height: 700).background(Color(nsColor: .windowBackgroundColor))
        .tint(appearance.accent).preferredColorScheme(appearance.theme.appearance.colorScheme)
        .alert("Theme", isPresented: Binding(get: { appearance.message != nil }, set: { if !$0 { appearance.message = nil } })) { Button("OK") { appearance.message = nil } } message: { Text(appearance.message ?? "") }
    }
    private var appearanceTab: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Button { appearance.theme.appearance = mode } label: {
                            VStack(spacing: 9) {
                                ZStack(alignment: .topLeading) {
                                    RoundedRectangle(cornerRadius: 9).fill(mode == .dark ? Color(white: 0.15) : mode == .light ? Color(white: 0.97) : Color(white: 0.7))
                                    HStack(spacing: 5) {
                                        RoundedRectangle(cornerRadius: 3).fill(appearance.accent.opacity(0.24)).frame(width: 24)
                                        VStack(spacing: 4) { ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 3).fill(appearance.accent.opacity(0.6)).frame(height: 8) }; Spacer(minLength: 0) }
                                    }.padding(8)
                                }.frame(width: 105, height: 65).overlay(RoundedRectangle(cornerRadius: 9).stroke(appearance.theme.appearance == mode ? appearance.accent : Color.secondary.opacity(0.2), lineWidth: appearance.theme.appearance == mode ? 2 : 1))
                                Label(mode.title, systemImage: mode.symbol).font(.caption)
                            }.padding(4)
                        }.buttonStyle(.plain).accessibilityLabel("\(mode.title) theme").accessibilityAddTraits(appearance.theme.appearance == mode ? [.isSelected] : [])
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 6)
                HStack {
                    Text("Accent color")
                    Spacer()
                    ForEach(AppearanceSettings.palettes, id: \.hex) { palette in
                        Button { appearance.theme.accentHex = palette.hex } label: {
                            Circle().fill(Color(hex: palette.hex)).frame(width: 23, height: 23)
                                .overlay { if appearance.theme.accentHex == palette.hex { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                        }.buttonStyle(.plain).help(palette.name).accessibilityLabel(palette.name).accessibilityAddTraits(appearance.theme.accentHex == palette.hex ? [.isSelected] : [])
                    }
                    ColorPicker("Custom color", selection: Binding(get: { appearance.accent }, set: { appearance.theme.accentHex = $0.rgbHex }), supportsOpacity: false).labelsHidden().help("Custom color")
                }
                TextField("Theme name", text: $appearance.theme.name)
            } header: { Text("Theme") }
            Section {
                Picker("Card density", selection: $appearance.theme.density) { ForEach(CardDensity.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                HStack { Text("Text size"); Slider(value: $appearance.theme.fontScale, in: 0.85...1.3, step: 0.05); Text("\(Int(appearance.theme.fontScale * 100))%").monospacedDigit().frame(width: 45) }
                Toggle("Show sidebar", isOn: $appearance.theme.showSidebar)
                Toggle("Show Done and Canceled columns", isOn: $appearance.theme.showCompleted)
                Toggle("Show subtasks on the board", isOn: $appearance.theme.showSubtasksOnBoard)
            } header: { Text("Board display") }
            Section {
                HStack { Button("Import theme…", action: appearance.importTheme); Button("Export theme…", action: appearance.exportTheme); Spacer(); Button("Restore defaults", action: appearance.reset) }
                Text("Themes are saved on this Mac. Share a JSON file to use someone else’s theme.").font(.caption).foregroundStyle(Color.secondary)
            }
        }.formStyle(.grouped)
    }
    private var connectionTab: some View {
        Form {
            Section {
                Text("The app and CLI use the same local task service.").foregroundStyle(Color.secondary)
                HStack {
                    TextField("Auto-detect", text: $appearance.executablePath).textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.message = "Choose the workboard executable."; panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { appearance.executablePath = url.path }
                    }
                }
                Text("Leave blank to find the bundled CLI or a development build automatically. WORKBOARD_BIN is also supported.").font(.caption).foregroundStyle(Color.secondary)
            } header: { Text("workboard executable") }
            Section {
                HStack {
                    TextField("Default data directory", text: $appearance.dataDirectory).textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { appearance.dataDirectory = url.path }
                    }
                }
                Text("Leave blank to use the CLI’s default location. Changing this path opens the board in that directory.").font(.caption).foregroundStyle(Color.secondary)
                Button("Check connection") { Task { await store.reload(force: true) } }
                if let error = store.connectionError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                else if store.lastUpdated != nil { Label("Connected to the service", systemImage: "checkmark.circle").foregroundStyle(.green) }
                if let warning = store.widgetWarning { Label(warning, systemImage: "rectangle.badge.exclamationmark").font(.caption).foregroundStyle(.orange) }
                HStack { Button("Create backup…") { store.backup() }; Button("Restore backup…") { store.restoreBackup() } }.padding(.top, 8)
            } header: { Text("Task data") }
            Section {
                Text("Integrations are installed separately as plugins. Core task management requires no external account, Python, or agent-memory.").font(.callout).foregroundStyle(Color.secondary)
            } header: { Text("Plugins") }
        }.formStyle(.grouped)
    }
}

// Explicit text colors also keep AppKit-hosted labels readable during appearance changes.
enum BoardInk {
    static func primary(_ scheme: ColorScheme) -> Color { Color(white: scheme == .dark ? 0.90 : 0.14) }
    static func secondary(_ scheme: ColorScheme) -> Color { Color(white: scheme == .dark ? 0.63 : 0.47) }
    static func tertiary(_ scheme: ColorScheme) -> Color { Color(white: scheme == .dark ? 0.46 : 0.61) }
}

struct BoardPrimaryButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(Color.white)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.45)
    }
}

struct BoardSecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium)).foregroundStyle(BoardInk.primary(colorScheme))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(BoardInk.secondary(colorScheme).opacity(configuration.isPressed ? 0.18 : 0.09), in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.45)
    }
}
