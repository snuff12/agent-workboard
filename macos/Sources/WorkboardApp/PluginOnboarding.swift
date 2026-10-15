import SwiftUI
import Combine

struct DetectedRepository: Identifiable {
    let id: String
    let name: String
    let path: String
    init?(_ json: JSONValue) {
        guard let id = json["id"].string, !id.isEmpty, let path = json["path"].string, path.hasPrefix("/") else { return nil }
        self.id = id; name = json["name"].string ?? path; self.path = path
    }
}

struct PluginDiscovery {
    let available: Bool
    let message: String
    let settings: [String: JSONValue]
    let repositories: [DetectedRepository]
    init(_ json: JSONValue, saved: JSONValue) {
        available = json["available"].bool == true
        message = json["message"].string ?? "Check the connection and try again."
        settings = saved.object.merging(json["config"].object) { _, detected in detected }
        repositories = json["repositories"].array.compactMap(DetectedRepository.init)
    }
    func configuration(pluginID: String, repository: String, calendar: Bool, gmail: Bool) throws -> [String: JSONValue] {
        var result = settings
        if pluginID == "orca" {
            guard repositories.contains(where: { "id:" + $0.id == repository }) else { throw WorkboardError(message: "Choose a repository to connect.") }
            result["repo"] = .string(repository)
        } else if pluginID == "google-workspace" {
            guard calendar || gmail else { throw WorkboardError(message: "Choose Calendar, Gmail, or both.") }
            result["calendar_enabled"] = .bool(calendar); result["gmail_enabled"] = .bool(gmail)
        }
        return result
    }
}

@MainActor struct PluginConnectionView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var board: BoardStore
    @Environment(\.dismiss) private var dismiss
    let plugin: InstalledPlugin
    @ObservedObject var plugins: PluginStore
    var openAdvanced: () -> Void
    @State private var discovery: PluginDiscovery?
    @State private var repository = ""
    @State private var calendar = true
    @State private var gmail = false
    @State private var slackToken = ""
    @State private var generation = UUID()
    @State private var expectedGeneration = ""
    @State private var operation: Task<Void, Never>?
    @State private var connecting = false

    private var ready: Bool {
        discovery?.available == true && (plugin.id != "orca" || !repository.isEmpty)
        && (plugin.id != "google-workspace" || calendar || gmail)
        && (plugin.id != "slack" || !slackToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect \(plugin.name)").font(.title2.weight(.semibold))
            if connecting {
                ProgressView(plugin.id == "google-workspace" ? "Finish signing in with your browser…" : "Connecting…")
            } else if let discovery {
                if plugin.id == "google-workspace" {
                    Text("Sign in with your Google account. Choose what to connect.").foregroundStyle(.secondary)
                    Toggle("Calendar — meetings and deadlines", isOn: $calendar)
                    Toggle("Gmail — read and attach messages", isOn: $gmail)
                    Text("Tokens stay in macOS Keychain. Gmail is optional.").font(.caption).foregroundStyle(.secondary)
                } else if plugin.id == "orca", !discovery.repositories.isEmpty {
                    Text("Orca was found on this Mac.").foregroundStyle(.secondary)
                    Picker("Repository", selection: $repository) {
                        Text("Choose a repository").tag("")
                        ForEach(discovery.repositories) { item in Text(item.name).tag("id:" + item.id) }
                    }
                    if let selected = discovery.repositories.first(where: { "id:" + $0.id == repository }) {
                        Text(selected.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else if plugin.id == "slack" {
                    Text("Paste your Slack User OAuth token. Your workspace is detected automatically.").foregroundStyle(.secondary)
                    SecureField("User OAuth token (xoxp-…)", text: $slackToken)
                    Text("The token is stored in macOS Keychain. Sending remains a separate setting.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label(discovery.message, systemImage: discovery.available ? "checkmark.circle" : "magnifyingglass").foregroundStyle(.secondary)
                }
                if !discovery.available {
                    Text(discovery.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Try again") { refresh() }.disabled(plugins.busy)
                }
                DisclosureGroup("Advanced") {
                    Button("Open advanced settings…") { openAdvanced(); dismiss() }
                    Text("Custom paths, account labels, and developer OAuth overrides.").font(.caption).foregroundStyle(.secondary)
                }.font(.caption)
            } else { ProgressView("Finding connection settings…") }
            if let error = plugins.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button("Cancel") { operation?.cancel(); generation = UUID(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(plugin.id == "google-workspace" ? "Sign in with Google" : "Connect") { startConnection() }
                    .buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent))
                    .disabled(!ready || connecting || plugins.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520, height: plugin.id == "google-workspace" ? 420 : 370)
            .task(id: appearance.connection.identity()) { refresh() }
            .onDisappear { operation?.cancel(); generation = UUID(); slackToken = "" }
    }
    private func current(_ token: UUID, _ identity: ConnectionIdentity) -> Bool {
        generation == token && appearance.connection.identity() == identity && !Task.isCancelled
    }
    private func refresh() {
        let previous = operation
        previous?.cancel(); generation = UUID(); discovery = nil; connecting = false
        let token = generation, configuration = appearance.connection, identity = configuration.identity()
        plugins.error = nil
        operation = Task {
            await previous?.value
            guard current(token, identity) else { return }
            let directories = board.currentProject.map { [$0.directory] } ?? board.projects.map(\.directory)
            let params: [String: JSONValue] = ["id": .string(plugin.id), "method": .string("discover"), "params": .object([
                "project_paths": .array(directories.filter { !$0.isEmpty }.map(JSONValue.string)), "launch_app": .bool(plugin.id == "orca")])]
            guard let response = await plugins.call("plugin.setup", params: params, configuration: configuration, isCurrent: { current(token, identity) }) else { return }
            guard current(token, identity) else { return }
            let found = PluginDiscovery(response["result"], saved: response["config"])
            expectedGeneration = response["generation"].string ?? ""
            discovery = found
            repository = found.settings["repo"]?.string ?? ""
            calendar = found.settings["calendar_enabled"]?.bool ?? true
            gmail = found.settings["gmail_enabled"]?.bool ?? false
        }
    }
    private func startConnection() {
        guard let discovery, ready else { return }
        let token = generation, configuration = appearance.connection, identity = configuration.identity()
        let secret = slackToken.trimmingCharacters(in: .whitespacesAndNewlines)
        operation = Task {
            connecting = true
            defer { if current(token, identity) { connecting = false } }
            do {
                var settings = try discovery.configuration(pluginID: plugin.id, repository: repository, calendar: calendar, gmail: gmail)
                if plugin.id == "google-workspace" {
                    let choices = settings.filter { ["account", "calendar_enabled", "gmail_enabled"].contains($0.key) }
                    let params: [String: JSONValue] = ["id": .string(plugin.id), "method": .string("authorize"), "expected_generation": .string(expectedGeneration), "params": .object(["connection_config": .object(choices)])]
                    guard let response = await plugins.call("plugin.setup", params: params, configuration: configuration, isCurrent: { current(token, identity) }) else { return }
                    settings.merge(response["result"]["config"].object) { _, selected in selected }
                } else if plugin.id == "slack" {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workboard-connect-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let file = directory.appendingPathComponent("token.json")
                    FileManager.default.createFile(atPath: file.path, contents: try JSONEncoder().encode(["access_token": secret]), attributes: [.posixPermissions: 0o600])
                    slackToken = ""
                    let params: [String: JSONValue] = ["id": .string(plugin.id), "method": .string("connect"), "expected_generation": .string(expectedGeneration), "params": .object(["credentials_file": .string(file.path)])]
                    guard let response = await plugins.call("plugin.setup", params: params, configuration: configuration, isCurrent: { current(token, identity) }) else { return }
                    settings.merge(response["result"]["config"].object) { _, detected in detected }
                    settings.removeValue(forKey: "credentials_file")
                }
                guard current(token, identity) else { return }
                guard await plugins.call("plugin.enable", params: ["id": .string(plugin.id), "config": .object(settings), "expected_generation": .string(expectedGeneration)], configuration: configuration, isCurrent: { current(token, identity) }) != nil else { return }
                guard current(token, identity) else { return }
                await plugins.reload(configuration: configuration, isCurrent: { current(token, identity) })
                guard current(token, identity) else { return }
                plugins.notice = "\(plugin.name) connected."
                dismiss()
            } catch { if current(token, identity) { plugins.error = error.localizedDescription } }
        }
    }
}
