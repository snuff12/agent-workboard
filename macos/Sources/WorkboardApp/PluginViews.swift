import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

struct InstalledPlugin: Identifiable {
    let id: String
    let name: String
    let version: String
    let description: String
    let enabled: Bool
    let compatible: Bool
    let methods: [String]
    init?(_ json: JSONValue) {
        guard let id = json["id"].string else { return nil }
        self.id = id; name = json["name"].string ?? id; version = json["version"].string ?? ""
        description = json["description"].string ?? ""; enabled = json["enabled"].bool ?? false
        compatible = json["compatible"].bool ?? false; methods = json["methods"].array.compactMap(\.string)
    }
}

@MainActor final class PluginStore: ObservableObject {
    @Published var entries: [InstalledPlugin] = []
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = false
    private let client = WorkboardClient() // Slow plugins never queue core board requests.
    func reload(configuration: ConnectionConfiguration) async {
        do { let result = try await client.call("plugin.list", configuration: configuration); entries = result["plugins"].array.compactMap(InstalledPlugin.init); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func call(_ method: String, params: [String: JSONValue], configuration: ConnectionConfiguration, requestID: String? = nil, isCurrent: () -> Bool = { true }) async -> JSONValue? {
        guard !busy, isCurrent() else { return nil }
        busy = true; error = nil; defer { busy = false }
        do {
            let result = try await client.call(method, params: params, configuration: configuration, timeoutSeconds: 195, requestID: requestID)
            return isCurrent() ? result : nil
        }
        catch { if isCurrent() { self.error = error.localizedDescription }; return nil }
    }
    func run(_ plugin: InstalledPlugin, method: String, params: [String: JSONValue] = [:], configuration: ConnectionConfiguration, requestID: String? = nil, isCurrent: () -> Bool = { true }) async -> JSONValue? {
        guard isCurrent() else { return nil }
        guard plugin.enabled else { error = "Enable the plugin first."; return nil }
        let response = await call("plugin.run", params: ["id": .string(plugin.id), "method": .string(method), "params": .object(params)], configuration: configuration, requestID: requestID, isCurrent: isCurrent)
        return response?["result"]
    }
}

struct PluginSettingsView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var board: BoardStore
    @StateObject private var plugins = PluginStore()
    @State private var configuring: InstalledPlugin?
    @State private var using: InstalledPlugin?
    @State private var removing: InstalledPlugin?
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("Add the features you need").font(.title3.weight(.semibold)); Text("Plugins run only after you install and enable them.").font(.caption).foregroundStyle(Color.secondary) }; Spacer(); Button("Install…") { install() }.disabled(plugins.busy) }
            ScrollView {
                VStack(spacing: 12) {
                    if plugins.entries.isEmpty {
                        VStack(spacing: 12) { Image(systemName: "puzzlepiece.extension").font(.system(size: 32, weight: .ultraLight)).foregroundStyle(.tertiary); Text("No plugins installed").font(.callout.weight(.medium)); Text("Choose an agent-memory, Google Workspace, Slack, or Orca package directory to install it. Core task management works without plugins.").font(.caption).foregroundStyle(Color.secondary).multilineTextAlignment(.center) }.padding(35).frame(maxWidth: .infinity)
                    }
                    ForEach(plugins.entries) { plugin in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Image(systemName: plugin.id == "google-workspace" ? "calendar" : plugin.id == "slack" ? "bubble.left.and.bubble.right" : plugin.id == "gmail" ? "envelope" : plugin.id == "agent-memory" ? "books.vertical" : plugin.id == "orca" ? "terminal" : "puzzlepiece.extension").font(.system(size: 20)).foregroundStyle(appearance.accent).frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) { HStack { Text(plugin.name).font(.callout.weight(.semibold)); Text(plugin.version).font(.caption2).foregroundStyle(.tertiary) }; Text(plugin.enabled ? "Enabled" : "Disabled").font(.caption2).foregroundStyle(plugin.enabled ? .green : .secondary) }
                                Spacer()
                                if plugin.enabled { Button("Use…") { using = plugin }.disabled(plugins.busy) }
                                Button(plugin.enabled ? "Disable" : "Configure and enable…") {
                                    if plugin.enabled { Task { _ = await plugins.call("plugin.disable", params: ["id": .string(plugin.id)], configuration: appearance.connection); await plugins.reload(configuration: appearance.connection) } }
                                    else { configuring = plugin }
                                }.disabled(plugins.busy || !plugin.compatible)
                                Menu { Button("Settings…") { configuring = plugin }; Button("Check connection") { Task { if await plugins.run(plugin, method: "check", configuration: appearance.connection) != nil { plugins.notice = "Plugin connection verified." } } }.disabled(!plugin.enabled); Divider(); Button("Remove…", role: .destructive) { removing = plugin } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 18).disabled(plugins.busy)
                            }
                            if !plugin.description.isEmpty { Text(plugin.description).font(.caption).foregroundStyle(Color.secondary) }
                            if !plugin.compatible { Label("This protocol is incompatible with the app.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                        }.padding(16).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if plugins.busy { HStack { ProgressView().controlSize(.small); Text("Processing plugin request…").font(.caption).foregroundStyle(Color.secondary) } }
            if let error = plugins.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let notice = plugins.notice { Label(notice, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
            Text("Disabling or removing a plugin preserves tasks, subtasks, artifacts, and existing evidence links.").font(.caption2).foregroundStyle(Color.secondary)
        }.padding(12).task(id: appearance.connection.identity()) { await plugins.reload(configuration: appearance.connection) }
            .sheet(item: $configuring) { plugin in PluginConfigurationView(plugin: plugin, plugins: plugins) }
            .sheet(item: $using) { plugin in PluginBrowserView(plugin: plugin, plugins: plugins) }
            .confirmationDialog("Remove the ‘\(removing?.name ?? "")’ plugin?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove plugin", role: .destructive) { if let plugin = removing { Task { _ = await plugins.call("plugin.remove", params: ["id": .string(plugin.id)], configuration: appearance.connection); await plugins.reload(configuration: appearance.connection); removing = nil } } }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: { Text("Existing tasks and artifacts are preserved.") }
    }
    private func install() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.message = "Choose a plugin package directory containing plugin.json."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { if await plugins.call("plugin.install", params: ["path": .string(url.path)], configuration: appearance.connection) != nil { plugins.notice = "Installed. Configure and enable the plugin to use it."; await plugins.reload(configuration: appearance.connection) } }
    }
}

struct PluginConfigurationDraft {
    private let original: [String: JSONValue]
    var executable: String
    var orcaRepos: String
    private let savedOrcaRepos: [String]
    var credentialsFile: String
    var account: String
    var calendarEnabled: Bool
    var gmailEnabled: Bool
    var slackMessagesEnabled: Bool
    var slackSendEnabled: Bool
    var slackTeamID: String
    var advancedJSON: String

    init(config: JSONValue, defaultsForNewInstall: Bool = false) {
        original = config.object
        executable = config["executable"].string ?? ""
        var repos = config["repos"].array.compactMap(\.string)
        if let legacy = config["repo"].string, !repos.contains(legacy) { repos.insert(legacy, at: 0) }
        savedOrcaRepos = repos
        orcaRepos = repos.joined(separator: "\n")
        credentialsFile = config["credentials_file"].string ?? ""
        account = config["account"].string ?? "default"
        calendarEnabled = config["calendar_enabled"].bool ?? (defaultsForNewInstall && original.isEmpty)
        gmailEnabled = config["gmail_enabled"].bool ?? false
        slackMessagesEnabled = config["messages_enabled"].bool ?? false
        slackSendEnabled = config["send_enabled"].bool ?? false
        slackTeamID = config["team_id"].string ?? ""
        advancedJSON = config.pretty
    }
    /// One Orca repository selector per line, such as `path:/folder`, `id:…`, or `name:…`.
    var orcaRepoSelectors: [String] {
        var selectors: [String] = []
        for line in orcaRepos.split(whereSeparator: \.isNewline) {
            let selector = line.trimmingCharacters(in: .whitespaces)
            if !selector.isEmpty && !selectors.contains(selector) { selectors.append(selector) }
        }
        return selectors
    }
    /// Connects the Orca repository at each board project's folder.
    mutating func addOrcaRepos(for projects: [BoardProject]) {
        var selectors = orcaRepoSelectors
        for project in projects where project.directory.hasPrefix("/") && !selectors.contains("path:" + project.directory) { selectors.append("path:" + project.directory) }
        orcaRepos = selectors.joined(separator: "\n")
    }
    func enableParameters(for pluginID: String) throws -> [String: JSONValue] {
        var config = original
        if pluginID == "agent-memory" {
            if !executable.isEmpty { config["executable"] = .string(executable) }
        } else if pluginID == "orca" {
            let selectors = orcaRepoSelectors
            guard executable.hasPrefix("/"), !selectors.isEmpty else { throw WorkboardError(message: "Enter the absolute path to the Orca executable and at least one repository.") }
            guard selectors.allSatisfy({ selector in ["id:", "path:", "name:"].contains { selector.hasPrefix($0) && selector.count > $0.count } }) else { throw WorkboardError(message: "Write each repository as path:/folder, id:…, or name:….") }
            config["executable"] = .string(executable)
            if selectors != savedOrcaRepos { config["repos"] = .array(selectors.map(JSONValue.string)); config.removeValue(forKey: "repo") }
        } else if pluginID == "gmail" || pluginID == "google-workspace" {
            config["account"] = .string(account.isEmpty ? "default" : account)
            if !credentialsFile.isEmpty { config["credentials_file"] = .string(credentialsFile) }
            if pluginID == "google-workspace" { config["calendar_enabled"] = .bool(calendarEnabled); config["gmail_enabled"] = .bool(gmailEnabled) }
        } else if pluginID == "slack" {
            config["account"] = .string(account.isEmpty ? "default" : account)
            config["credentials_file"] = .string(credentialsFile)
            config["team_id"] = .string(slackTeamID.trimmingCharacters(in: .whitespacesAndNewlines))
            config["messages_enabled"] = .bool(slackMessagesEnabled)
            config["send_enabled"] = .bool(slackSendEnabled)
        } else {
            let edited = try JSONDecoder().decode(JSONValue.self, from: Data(advancedJSON.utf8))
            guard case .object(let fields) = edited else { throw WorkboardError(message: "Configuration must be a JSON object.") }
            config.merge(fields) { _, edited in edited }
        }
        return ["id": .string(pluginID), "config": .object(config)]
    }
}

private struct PluginConfigurationView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var board: BoardStore
    @Environment(\.dismiss) private var dismiss
    let plugin: InstalledPlugin
    @ObservedObject var plugins: PluginStore
    @State private var draft = PluginConfigurationDraft(config: .object([:]))
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) { Text(plugin.name).font(.title2.weight(.semibold)); Text("Save configuration and enable the plugin.").font(.callout).foregroundStyle(Color.secondary) }.padding(24)
            Form {
                if plugin.id == "agent-memory" {
                    HStack { TextField("amem executable path", text: $draft.executable); Button("Choose…") { chooseFile { draft.executable = $0 } } }
                    Text("Only the selected amem CLI is called. Leave blank to keep the previously saved path.").font(.caption).foregroundStyle(Color.secondary)
                } else if plugin.id == "orca" {
                    HStack { TextField("Orca CLI executable path", text: $draft.executable); Button("Choose…") { chooseFile { draft.executable = $0 } } }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Repositories"); Spacer(); Button("Add board project folders") { draft.addOrcaRepos(for: board.projects) }.disabled(board.projects.isEmpty) }
                        TextEditor(text: $draft.orcaRepos).font(.system(.caption, design: .monospaced)).frame(height: 76)
                    }
                    Text("One repository per line: path:/folder, id:…, or name:…. Each board project uses the Orca repository at its folder. Start the Orca app first.").font(.caption).foregroundStyle(Color.secondary)
                } else if plugin.id == "gmail" || plugin.id == "google-workspace" {
                    HStack { TextField("Google Desktop OAuth client JSON", text: $draft.credentialsFile); Button("Choose…") { chooseFile { draft.credentialsFile = $0 } } }
                    TextField("Account label", text: $draft.account)
                    if plugin.id == "google-workspace" {
                        Toggle("Enable Google Calendar", isOn: $draft.calendarEnabled)
                        Toggle("Also enable Gmail (optional)", isOn: $draft.gmailEnabled)
                        Text("Calendar connects deadlines and meetings. Enable Gmail separately if needed. Save, then choose ‘Use’ to connect your Google account. Tokens are stored in macOS Keychain.").font(.caption).foregroundStyle(Color.secondary)
                    } else { Text("Uses read-only mail permissions. After enabling, choose ‘Use’ to connect your Google account. Tokens are stored in macOS Keychain.").font(.caption).foregroundStyle(Color.secondary) }
                } else if plugin.id == "slack" {
                    HStack { TextField("Slack User Token JSON file", text: $draft.credentialsFile); Button("Choose…") { chooseFile { draft.credentialsFile = $0 } } }
                    TextField("Account label", text: $draft.account)
                    TextField("Workspace ID (T…)", text: $draft.slackTeamID)
                    Toggle("Enable Slack message reading", isOn: $draft.slackMessagesEnabled)
                    Toggle("Send selected task status to Slack (optional)", isOn: $draft.slackSendEnabled)
                    Text("Use a User Token with search:read and conversation read permissions. Sending also requires chat:write. Save, then choose ‘Use’ to connect the token. Tokens are stored in macOS Keychain.").font(.caption).foregroundStyle(Color.secondary)
                } else { Section { TextEditor(text: $draft.advancedJSON).font(.system(.caption, design: .monospaced)).frame(height: 100) } header: { Text("Configuration JSON") } }
                if !loaded && plugins.error == nil { ProgressView("Reading current configuration…").controlSize(.small) }
                if let error = plugins.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped).disabled(!loaded || plugins.busy)
            Divider()
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); if plugins.busy { ProgressView().controlSize(.small) }; Button("Save and enable") { enable() }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).keyboardShortcut(.defaultAction).disabled(!loaded || plugins.busy) }.padding(20)
        }.frame(width: 560, height: plugin.id == "slack" ? 500 : plugin.id == "google-workspace" ? 450 : plugin.id == "orca" ? 440 : 365).task {
            plugins.error = nil
            guard let response = await plugins.call("plugin.config", params: ["id": .string(plugin.id)], configuration: appearance.connection) else { return }
            guard case .object = response["config"] else { plugins.error = "Could not read the current plugin configuration."; return }
            draft = PluginConfigurationDraft(config: response["config"], defaultsForNewInstall: !plugin.enabled)
            if plugin.id == "orca" && draft.orcaRepoSelectors.isEmpty { draft.addOrcaRepos(for: board.projects) }
            loaded = true
        }
    }
    private func chooseFile(_ action: (String) -> Void) { let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { action(url.path) } }
    private func enable() {
        let params: [String: JSONValue]
        do { params = try draft.enableParameters(for: plugin.id) }
        catch { plugins.error = error.localizedDescription; return }
        Task { if await plugins.call("plugin.enable", params: params, configuration: appearance.connection) != nil { await plugins.reload(configuration: appearance.connection); dismiss() } }
    }
}

private struct OrcaBrowserView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var board: BoardStore
    let plugin: InstalledPlugin
    @ObservedObject var plugins: PluginStore
    @State private var worktrees: [JSONValue] = []
    @State private var selected: JSONValue?
    @State private var terminals: [JSONValue] = []
    @State private var output = ""
    @State private var projectID = ""
    @State private var agent = "codex"
    @State private var prompt = ""
    @State private var starting = false
    @State private var truncated = false
    @State private var repos: [JSONValue] = []
    @State private var unmatched: [JSONValue] = []
    @State private var repoFilter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Repository", selection: $repoFilter) {
                    Text("All connected repositories").tag("")
                    ForEach(Array(repos.enumerated()), id: \.offset) { Text($0.element["name"].string ?? "Repository").tag($0.element["id"].string ?? "") }
                }.frame(maxWidth: 320).onChange(of: repoFilter) { Task { await load() } }
                Button("Refresh worktrees") { Task { await load() } }
                Spacer()
                if truncated { Text("Showing partial results. Use the CLI for the complete list.").font(.caption).foregroundStyle(Color.secondary) }
            }
            if !unmatched.isEmpty {
                Text("Not found in Orca: " + unmatched.compactMap { $0["selector"].string }.joined(separator: ", ") + ". Check the repositories in this plugin’s configuration.")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if worktrees.isEmpty { Text("No worktrees loaded.").foregroundStyle(Color.secondary).padding(12) }
                        ForEach(Array(worktrees.enumerated()), id: \.offset) { row in
                            let item = row.element
                            if row.offset == 0 || worktrees[row.offset - 1]["repo_id"] != item["repo_id"] {
                                Text(item["repo_name"].string ?? "Repository").font(.caption.weight(.semibold)).foregroundStyle(Color.secondary).padding(.horizontal, 10).padding(.top, row.offset == 0 ? 4 : 12)
                            }
                            Button {
                                selected = item; terminals = []; output = ""
                                if let project = project(for: item) { projectID = project.id }
                                Task { await loadTerminals(item) }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item["title"].string ?? item["path"].string ?? "Worktree").font(.callout.weight(.medium))
                                    Text(item["branch"].string ?? "").font(.caption).foregroundStyle(Color.secondary).lineLimit(1)
                                    Text(item["workspace_status"].string ?? "No status").font(.caption2).foregroundStyle(Color.secondary)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected?["id"] == item["id"] ? appearance.accent.opacity(0.1) : Color.clear)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(minWidth: 180, idealWidth: 210)
                ScrollView {
                    if let item = selected {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(item["title"].string ?? "Worktree").font(.headline)
                            Text(item["path"].string ?? "").font(.caption).textSelection(.enabled)
                            Text(item["comment"].string ?? "").font(.caption).foregroundStyle(Color.secondary)
                            Picker("Import into project", selection: $projectID) {
                                Text("Select project").tag("")
                                ForEach(board.projects) { Text($0.name).tag($0.id) }
                            }
                            Button("Import as a new task") { importWorktree(item) }.disabled(projectID.isEmpty)
                            if let task = board.selectedTask {
                                Text("Selected task: \(task.title)").font(.caption).foregroundStyle(Color.secondary)
                                Button("Attach worktree to this task") { attach(item, task: task) }
                                Button("Import as a subtask of this task") { importWorktree(item, parent: task) }
                                Divider()
                                Picker("Agent", selection: $agent) {
                                    Text("Codex").tag("codex"); Text("Claude").tag("claude")
                                }
                                TextField("Additional instructions (optional)", text: $prompt, axis: .vertical).lineLimit(2...4)
                                if let owner = board.projects.first(where: { $0.id == task.projectID }), project(for: item)?.id != owner.id {
                                    Text("This worktree is in \(item["repo_name"].string ?? "another repository"), not in the folder of the task’s project \(owner.name).").font(.caption2).foregroundStyle(.orange)
                                }
                                Button("Run selected task in Orca") { Task { await start(item, task: task) } }
                                    .buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent))
                                    .disabled(task.status == .done)
                                Text("Records the assignee and run on the board, then opens a terminal. Duplicate starts of the same run are prevented. Terminal exit does not complete the task.")
                                    .font(.caption2).foregroundStyle(Color.secondary)
                            }
                            Divider()
                            HStack { Text("Run terminals").font(.subheadline.weight(.medium)); Spacer(); Button("Load") { Task { await loadTerminals(item) } } }
                            if terminals.isEmpty { Text("No run terminals loaded.").font(.caption).foregroundStyle(Color.secondary) }
                            ForEach(Array(terminals.enumerated()), id: \.offset) { row in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(row.element["title"].string ?? row.element["handle"].string ?? "Terminal").font(.caption)
                                        Text(row.element["connected"].bool == true ? "Connected" : "Disconnected").font(.caption2).foregroundStyle(Color.secondary)
                                    }
                                    Spacer()
                                    Button("Read output") { readOutput(row.element, item: item) }
                                }
                            }
                            if !output.isEmpty { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        }.padding(12)
                    } else { Text("Select a worktree.").foregroundStyle(Color.secondary).padding(20) }
                }.frame(minWidth: 350)
            }
        }.padding(16).disabled(plugins.busy || starting || board.isMutating)
            .task { projectID = board.selectedProjectID ?? board.projects.first?.id ?? ""; await load() }
    }

    private func load() async {
        if repos.isEmpty, let check = await plugins.run(plugin, method: "check", configuration: appearance.connection) {
            repos = check["repos"].array; unmatched = check["unmatched"].array
        }
        let params: [String: JSONValue] = repoFilter.isEmpty ? [:] : ["repo_id": .string(repoFilter)]
        if let result = await plugins.run(plugin, method: "worktrees.list", params: params, configuration: appearance.connection) {
            worktrees = result["worktrees"].array; selected = nil; terminals = []; output = ""
            truncated = result["truncated"].bool ?? false
        }
    }
    /// The board project whose folder is this worktree's Orca repository, or contains the worktree.
    private func project(for item: JSONValue) -> BoardProject? {
        let paths = [item["repo_path"].string, item["path"].string].compactMap { $0 }.map(Self.canonical)
        return board.projects.first { project in
            guard project.directory.hasPrefix("/") else { return false }
            let directory = Self.canonical(project.directory)
            return paths.contains { $0 == directory || $0.hasPrefix(directory + "/") }
        }
    }
    private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    private func loadTerminals(_ item: JSONValue) async {
        if let result = await plugins.run(plugin, method: "terminals.list", params: ["worktree_id": item["id"]], configuration: appearance.connection) {
            terminals = result["terminals"].array
        }
    }
    private func readOutput(_ terminal: JSONValue, item: JSONValue) {
        Task {
            if let result = await plugins.run(plugin, method: "terminals.read", params: ["worktree_id": item["id"], "terminal": terminal["handle"]], configuration: appearance.connection) {
                output = result["tail"].array.compactMap(\.string).joined(separator: "\n")
            }
        }
    }
    private func importWorktree(_ item: JSONValue, parent: BoardTask? = nil) {
        var params: [String: JSONValue] = ["worktree_id": item["id"], "project_id": .string(parent?.projectID ?? projectID)]
        if let parent { params["parent_id"] = .string(parent.id) }
        Task {
            if await plugins.run(plugin, method: "worktrees.import", params: params, configuration: appearance.connection) != nil {
                plugins.notice = "Worktree imported as a task."; await board.reload(force: true)
            }
        }
    }
    private func attach(_ item: JSONValue, task: BoardTask) {
        Task {
            if await plugins.run(plugin, method: "worktrees.attach", params: ["worktree_id": item["id"], "task_id": .string(task.id), "expected_revision": .number(Double(task.revision))], configuration: appearance.connection) != nil {
                plugins.notice = "Worktree attached to the selected task."; await board.reload(force: true)
            }
        }
    }
    private func start(_ item: JSONValue, task: BoardTask) async {
        guard !starting else { return }
        starting = true; defer { starting = false }
        let configuration = appearance.connection
        guard let current = await plugins.call("task.get", params: ["task_id": .string(task.id)], configuration: configuration) else { return }
        let owner = "orca:" + agent
        let runID: JSONValue
        let runs = current["runs"].array
        if current["task"]["status"].string == "in_progress", let latest = runs.last, latest["status"].string == "running", latest["agent_id"].string == owner {
            runID = latest["id"]
        } else {
            guard let started = await plugins.call("task.start", params: ["task_id": .string(task.id), "agent_id": .string(owner), "expected_revision": current["task"]["revision"]], configuration: configuration) else { return }
            runID = started["run_id"]
        }
        if await plugins.run(plugin, method: "agents.start", params: ["worktree_id": item["id"], "task_id": .string(task.id), "run_id": runID, "agent": .string(agent), "prompt": .string(prompt)], configuration: configuration) != nil {
            plugins.notice = "Orca run terminal verified."
            await loadTerminals(item)
        }
        await board.reload(force: true)
    }
}

struct PluginBrowserView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var board: BoardStore
    @Environment(\.dismiss) private var dismiss
    let plugin: InstalledPlugin
    @ObservedObject var plugins: PluginStore
    @State private var query = ""
    @State private var collection = ""
    @State private var memoryProject = ""
    @State private var domain = ""
    @State private var searchScope: [String: JSONValue] = [:]
    @State private var result: JSONValue?
    @State private var selectedMessage: JSONValue?
    @State private var selectedRef = ""
    @State private var verifiedRef = ""
    @State private var sourceText = ""
    @State private var projectID = ""
    @State private var showingCapture = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text(plugin.name).font(.title2.weight(.semibold)); Text(plugin.id == "orca" ? "Browse worktrees and runs, and link them to board tasks." : plugin.id == "gmail" ? "Find mail and attach it to a task or import it as a new task." : plugin.id == "slack" ? "Read source messages and attach or import them as tasks." : "Read search results, verify the source, and attach evidence.").font(.caption).foregroundStyle(Color.secondary) }; Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(22)
            Divider()
            if plugin.id == "google-workspace" {
                TabView {
                    GoogleCalendarView(plugin: plugin, plugins: plugins).tabItem { Label("Calendar", systemImage: "calendar") }
                    gmailContent.tabItem { Label("Gmail (optional)", systemImage: "envelope") }
                }.padding(.horizontal, 12).padding(.top, 10)
            }
            else if plugin.id == "gmail" { gmailContent }
            else if plugin.id == "agent-memory" { memoryContent }
            else if plugin.id == "slack" { SlackMessagesView(plugin: plugin, plugins: plugins, configuration: appearance.connection).id(appearance.connection.identity()) }
            else if plugin.id == "orca" { OrcaBrowserView(plugin: plugin, plugins: plugins).id(appearance.connection.identity()) }
            else { Text("Use this plugin’s features through the CLI.").foregroundStyle(Color.secondary).padding(25); Spacer() }
            if let error = plugins.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 22).padding(.bottom, 12) }
            if let notice = plugins.notice { Label(notice, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green).padding(.horizontal, 22).padding(.bottom, 12) }
            if plugins.busy { HStack { ProgressView().controlSize(.small); Text("Waiting for the plugin…").font(.caption).foregroundStyle(Color.secondary); Spacer() }.padding(.horizontal, 22).padding(.bottom, 15) }
        }.frame(width: 740, height: 650).onAppear { plugins.error = nil; plugins.notice = nil; projectID = board.selectedProjectID ?? board.projects.first?.id ?? "" }
            .sheet(isPresented: $showingCapture) { MemoryCaptureView(plugin: plugin, plugins: plugins) }
    }
    private var gmailContent: some View {
        VStack(spacing: 14) {
            HStack { Button("Connect Google account…") { Task { if await plugins.run(plugin, method: "authorize", configuration: appearance.connection) != nil { plugins.notice = "Google account connected." } } }; Button("Disconnect") { Task { if await plugins.run(plugin, method: "disconnect", configuration: appearance.connection) != nil { plugins.notice = "Account disconnected."; result = nil; selectedMessage = nil } } }; Spacer(); Text("Read only").font(.caption).foregroundStyle(Color.secondary) }.disabled(plugins.busy)
            HStack { TextField("Search Gmail (for example: is:unread)", text: $query).textFieldStyle(.roundedBorder).onSubmit { searchMail() }; Button("Search", action: searchMail).disabled(plugins.busy) }
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if result != nil && result?["messages"].array.isEmpty != false { Text("No search results.").font(.caption).foregroundStyle(Color.secondary).padding(16) }
                        ForEach(Array((result?["messages"].array ?? []).enumerated()), id: \.offset) { row in
                            let message = row.element
                            Button { selectedMessage = message } label: {
                                VStack(alignment: .leading, spacing: 6) { Text(message["subject"].string ?? "Untitled").font(.callout.weight(.medium)).lineLimit(2); Text(message["from"].string ?? "").font(.caption2).foregroundStyle(Color.secondary).lineLimit(1); Text(message["snippet"].string ?? "").font(.caption).foregroundStyle(Color.secondary).lineLimit(2) }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(selectedMessage?["id"] == message["id"] ? appearance.accent.opacity(0.08) : Color.clear)
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }.frame(minWidth: 250)
                ScrollView {
                    if let message = selectedMessage {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(message["subject"].string ?? "Untitled").font(.title3.weight(.semibold)); Text(message["from"].string ?? "").font(.caption).foregroundStyle(Color.secondary); Text(message["snippet"].string ?? "").font(.callout).textSelection(.enabled)
                            if let url = URL(string: message["url"].string ?? "") { Link("Open original in Gmail", destination: url).font(.caption) }
                            Divider()
                            if let task = board.selectedTask { Text("Selected task: \(task.title)").font(.caption).foregroundStyle(Color.secondary); Button("Attach mail to this task") { attachMail(message, task: task) }.disabled(plugins.busy) }
                            Picker("Import into project", selection: $projectID) { ForEach(board.projects) { Text($0.name).tag($0.id) } }
                            Button("Import as a new task") { importMail(message) }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).disabled(projectID.isEmpty || plugins.busy)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    } else { Text("Select a message.").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 220) }
                }.frame(minWidth: 280)
            }
        }.padding(20)
    }
    private var memoryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { TextField("collection", text: $collection); TextField("Project scope (optional)", text: $memoryProject); TextField("Domain scope (optional)", text: $domain) }.textFieldStyle(.roundedBorder)
            HStack { TextField("Documents and memories to find", text: $query).textFieldStyle(.roundedBorder).onSubmit { searchMemory() }; Button("Search", action: searchMemory).disabled(plugins.busy || query.isEmpty || collection.isEmpty); Button("Save a decision…") { showingCapture = true }.disabled(plugins.busy) }
            Text("Search snippets are discovery hints. Read the source with the same scope and attach only verified content.").font(.caption2).foregroundStyle(Color.secondary)
            ScrollView { Text(result?.pretty ?? "Search results appear here.").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.frame(minHeight: 130).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack { TextField("Search result ref", text: $selectedRef).textFieldStyle(.roundedBorder); Button("Read source") { readMemory() }.disabled(selectedRef.isEmpty || searchScope.isEmpty || plugins.busy) }
            if !sourceText.isEmpty { ScrollView { Text(sourceText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.frame(minHeight: 140).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8)) }
            HStack { if let task = board.selectedTask { Text("Attach to task: \(task.title)").font(.caption).foregroundStyle(Color.secondary).lineLimit(1); Spacer(); Button("Attach verified source to task") { attachMemory(task: task) }.disabled(verifiedRef.isEmpty || verifiedRef != selectedRef || plugins.busy) } else { Text("Select a task on the board to attach a verified source.").font(.caption).foregroundStyle(Color.secondary) } }
        }.padding(20)
    }
    private var mailPrefix: String { plugin.id == "google-workspace" ? "gmail." : "" }
    private func searchMail() { Task { result = await plugins.run(plugin, method: mailPrefix + "search", params: ["query": .string(query), "limit": .number(10)], configuration: appearance.connection); selectedMessage = nil } }
    private func attachMail(_ message: JSONValue, task: BoardTask) { Task { if await plugins.run(plugin, method: mailPrefix + "attach", params: ["task_id": .string(task.id), "message_id": message["id"]], configuration: appearance.connection) != nil { plugins.notice = "Mail attached to the selected task."; await board.reload(force: true) } } }
    private func importMail(_ message: JSONValue) { Task { if await plugins.run(plugin, method: mailPrefix + "import", params: ["project_id": .string(projectID), "message_id": message["id"]], configuration: appearance.connection) != nil { plugins.notice = "Mail imported as a new task."; await board.reload(force: true) } } }
    private func searchMemory() {
        var params: [String: JSONValue] = ["collection": .string(collection), "query": .string(query)]
        if !memoryProject.isEmpty { params["project"] = .string(memoryProject) }; if !domain.isEmpty { params["domain"] = .string(domain) }
        searchScope = params; verifiedRef = ""; sourceText = ""
        Task { result = await plugins.run(plugin, method: "search", params: params, configuration: appearance.connection) }
    }
    private func readMemory() {
        var params = searchScope; params["ref"] = .string(selectedRef)
        let ref = selectedRef
        Task { if let response = await plugins.run(plugin, method: "read", params: params, configuration: appearance.connection) { sourceText = response["text"].string ?? response.pretty; verifiedRef = ref } }
    }
    private func attachMemory(task: BoardTask) {
        guard !verifiedRef.isEmpty, verifiedRef == selectedRef else { return }
        var params = searchScope; params["ref"] = .string(verifiedRef); params["task_id"] = .string(task.id)
        Task { if await plugins.run(plugin, method: "attach", params: params, configuration: appearance.connection) != nil { plugins.notice = "Verified source evidence attached."; await board.reload(force: true) } }
    }
}

struct SlackMessage: Identifiable {
    let channelID: String
    let teamID: String
    let ts: String
    let threadTS: String?
    let text: String
    let channelName: String
    let user: String
    let version: String
    let url: URL?
    var id: String { teamID + ":" + channelID + ":" + ts }
    init?(_ json: JSONValue) {
        guard let channel = json["channel_id"].string, let team = json["team_id"].string,
              let ts = json["ts"].string, !channel.isEmpty, !team.isEmpty, !ts.isEmpty else { return nil }
        channelID = channel; teamID = team; self.ts = ts
        threadTS = json["thread_ts"].string; text = json["text"].string ?? ""
        channelName = json["channel_name"].string ?? channel
        user = json["user"].string ?? ""; version = json["version"].string ?? ""
        let candidate = URL(string: json["url"].string ?? "")
        url = candidate?.scheme == "https" && (candidate?.host?.hasSuffix(".slack.com") ?? false) ? candidate : nil
    }
    func parameters(verified: Bool = false) -> [String: JSONValue] {
        var values: [String: JSONValue] = ["channel_id": .string(channelID), "team_id": .string(teamID), "ts": .string(ts)]
        if let threadTS { values["thread_ts"] = .string(threadTS) }
        if verified { values["expected_version"] = .string(version) }
        return values
    }
}

@MainActor final class SlackSession: ObservableObject {
    let configuration: ConnectionConfiguration
    private var active = true
    private var observation: AnyCancellable?

    init(configuration: ConnectionConfiguration) { self.configuration = configuration }
    func bind(_ appearance: AppearanceSettings) {
        guard isCurrent(appearance), observation == nil else { return }
        observation = appearance.connectionChanges.sink { [weak self, weak appearance] in
            guard let self, let appearance else { return }
            if self.configuration.identity() != appearance.connection.identity() { self.close() }
        }
    }
    func isCurrent(_ appearance: AppearanceSettings) -> Bool {
        active && configuration.identity() == appearance.connection.identity()
    }
    func close() { active = false; observation = nil }
}

struct SlackStatusSend {
    let taskID: String
    let revision: Int
    let channelID: String
    let connection: ConnectionIdentity
    let requestID: String

    init(task: BoardTask, channelID: String, configuration: ConnectionConfiguration) {
        taskID = task.id; revision = task.revision; self.channelID = channelID
        connection = configuration.identity(); requestID = UUID().uuidString
    }
    func matches(task: BoardTask, channelID: String, configuration: ConnectionConfiguration) -> Bool {
        taskID == task.id && revision == task.revision && self.channelID == channelID && connection == configuration.identity()
    }
    var parameters: [String: JSONValue] {
        ["task_id": .string(taskID), "expected_revision": .number(Double(revision)), "channel_id": .string(channelID), "confirmed_by_user": .bool(true)]
    }
}

private struct SlackMessagesView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var board: BoardStore
    let plugin: InstalledPlugin
    @ObservedObject var plugins: PluginStore
    @StateObject private var session: SlackSession
    @State private var query = ""
    @State private var searchedQuery = ""
    @State private var messages: [SlackMessage] = []
    @State private var selected: SlackMessage?
    @State private var nextPage: Int?
    @State private var threadRoot: SlackMessage?
    @State private var nextCursor: String?
    @State private var projectID = ""
    @State private var didSearch = false
    @State private var sendChannelID = ""
    @State private var pendingSend: SlackStatusSend?

    init(plugin: InstalledPlugin, plugins: PluginStore, configuration: ConnectionConfiguration) {
        self.plugin = plugin; self.plugins = plugins
        _session = StateObject(wrappedValue: SlackSession(configuration: configuration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Button("Connect token") { connect() }
                Button("Disconnect") { disconnect() }
                Spacer()
                Text("Attach only selected messages and tasks").font(.caption).foregroundStyle(Color.secondary)
            }.disabled(plugins.busy)
            if let task = board.selectedTask {
                DisclosureGroup("Send selected task status · \(task.title)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sends title, status, assignee, next action, due date, and task ID using the connected User Token account.").font(.caption).foregroundStyle(Color.secondary)
                        HStack {
                            TextField("Destination channel ID (C… / G… / D…)", text: $sendChannelID).textFieldStyle(.roundedBorder)
                            Button(pendingSend == nil ? "Send status to Slack" : "Check the same send again") { sendStatus(task) }.disabled(sendChannelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plugins.busy)
                        }
                        if pendingSend != nil {
                            Text("Checking the previous send with the same request ID. Check Slack for the existing message before sending again.").font(.caption2).foregroundStyle(Color.secondary)
                            Button("Prepare a new send after checking Slack") { pendingSend = nil }.disabled(plugins.busy)
                        }
                    }.padding(.top, 8)
                }.font(.caption)
            }
            HStack {
                TextField("Search Slack (for example: in:general deadline)", text: $query).textFieldStyle(.roundedBorder).onSubmit { search() }
                Button("Search") { search() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(plugins.busy)
            if threadRoot != nil { Label("Thread messages · Search to return to search results.", systemImage: "bubble.left.and.bubble.right").font(.caption).foregroundStyle(Color.secondary) }
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if messages.isEmpty { Text(didSearch ? "No messages." : "Connect a token, then search messages.").font(.caption).foregroundStyle(Color.secondary).padding(25) }
                        ForEach(messages) { message in
                            Button { read(message) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.text.isEmpty ? "Message without text" : message.text).font(.callout).lineLimit(3)
                                    Text("\(message.channelName) · \(message.user)").font(.caption2).foregroundStyle(Color.secondary)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected?.id == message.id ? appearance.accent.opacity(0.08) : .clear)
                            }.buttonStyle(.plain).disabled(plugins.busy)
                            Divider()
                        }
                        if let nextPage { Button("Load more search results") { search(page: nextPage) }.padding(12).disabled(plugins.busy) }
                        if let root = threadRoot, let cursor = nextCursor, !cursor.isEmpty {
                            Button("Load more thread messages") { loadThread(root, cursor: cursor) }.padding(12).disabled(plugins.busy)
                        }
                    }
                }.frame(minWidth: 220)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let message = selected {
                            Text(message.text.isEmpty ? "Message without text" : message.text).font(.callout).textSelection(.enabled)
                            if let url = message.url { Link("Open original in Slack", destination: url) }
                            Button("View thread") { loadThread(message) }.disabled(plugins.busy)
                            Divider()
                            if let task = board.selectedTask {
                                Text("Selected task: \(task.title)").font(.caption).foregroundStyle(Color.secondary)
                                Button("Attach message to this task") { attach(message, task: task) }.disabled(plugins.busy)
                                Button("Import as a subtask of this task") { importMessage(message, parent: task) }.disabled(plugins.busy)
                            }
                            Picker("Project", selection: $projectID) {
                                ForEach(board.projects) { project in Text(project.name).tag(project.id) }
                            }
                            Button("Import as a new task") { importMessage(message) }.disabled(projectID.isEmpty || plugins.busy)
                        } else { Text("Selecting a message reads its source again.").font(.caption).foregroundStyle(Color.secondary).padding(.top, 30) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 280)
            }
            Text("Only selected messages are saved to tasks. Review changed source messages again before attaching them.").font(.caption2).foregroundStyle(Color.secondary)
        }.padding(16).onAppear { session.bind(appearance); projectID = board.selectedProjectID ?? board.projects.first?.id ?? "" }
            .onDisappear { session.close() }
    }
    private func run(_ method: String, params: [String: JSONValue] = [:], requestID: String? = nil) async -> JSONValue? {
        await plugins.run(plugin, method: method, params: params, configuration: session.configuration, requestID: requestID,
                          isCurrent: { session.isCurrent(appearance) })
    }
    private func clear() { messages = []; selected = nil; nextPage = nil; nextCursor = nil; threadRoot = nil; didSearch = false }
    private func connect() {
        Task { if await run("authorize") != nil { clear(); plugins.notice = "Slack token connected through Keychain." } }
    }
    private func disconnect() {
        Task { if await run("disconnect") != nil { clear(); plugins.notice = "Local token disconnected. The token remains authorized in Slack." } }
    }
    private func search(page: Int = 1) {
        let searchQuery = page == 1 ? query.trimmingCharacters(in: .whitespacesAndNewlines) : searchedQuery
        guard !searchQuery.isEmpty, !plugins.busy else { return }
        Task {
            selected = nil
            if let result = await run("messages.search", params: ["query": .string(searchQuery), "page": .number(Double(page))]) {
                let rows = result["messages"].array.compactMap(SlackMessage.init)
                messages = page == 1 ? rows : messages + rows.filter { row in !messages.contains { $0.id == row.id } }
                nextPage = result["next_page"].int; nextCursor = nil; threadRoot = nil
                searchedQuery = searchQuery; didSearch = true
            }
        }
    }
    private func read(_ message: SlackMessage) {
        Task {
            selected = nil
            if let result = await run("messages.read", params: message.parameters()) { selected = SlackMessage(result) }
        }
    }
    private func loadThread(_ message: SlackMessage, cursor: String? = nil) {
        var params = message.parameters()
        params["ts"] = .string(message.threadTS ?? message.ts)
        if let cursor { params["cursor"] = .string(cursor) }
        let values = params
        Task {
            if let result = await run("messages.thread", params: values) {
                let rows = result["messages"].array.compactMap(SlackMessage.init)
                messages = cursor == nil ? rows : messages + rows.filter { row in !messages.contains { $0.id == row.id } }
                threadRoot = message; nextCursor = result["next_cursor"].string; nextPage = nil; didSearch = true
            }
        }
    }
    private func attach(_ message: SlackMessage, task: BoardTask) {
        var params = message.parameters(verified: true)
        params["task_id"] = .string(task.id); params["expected_revision"] = .number(Double(task.revision))
        let values = params
        Task { if await run("messages.attach", params: values) != nil { plugins.notice = "Slack message attached to the task."; await board.reload(force: true) } }
    }
    private func sendStatus(_ task: BoardTask) {
        let channel = sendChannelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.isCurrent(appearance), !plugins.busy else { return }
        if let pendingSend, !pendingSend.matches(task: task, channelID: channel, configuration: session.configuration) {
            plugins.error = "The task, revision, or channel differs from the previous send. Check that send in Slack before preparing another."
            return
        }
        let operation = pendingSend ?? SlackStatusSend(task: task, channelID: channel, configuration: session.configuration)
        pendingSend = operation
        Task {
            if let result = await run("tasks.send", params: operation.parameters, requestID: operation.requestID), result["sent"].bool == true {
                pendingSend = nil
                plugins.notice = "Task status sent to \(result["channel_id"].string ?? channel). Message timestamp: \(result["ts"].string ?? "")"
            }
        }
    }
    private func importMessage(_ message: SlackMessage, parent: BoardTask? = nil) {
        var params = message.parameters(verified: true)
        params["project_id"] = .string(parent?.projectID ?? projectID)
        if let parent { params["parent_id"] = .string(parent.id) }
        let values = params
        Task { if await run("messages.import", params: values) != nil { plugins.notice = parent == nil ? "Message imported as a new task." : "Message imported as a subtask."; await board.reload(force: true) } }
    }
}

private struct MemoryCaptureView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    let plugin: InstalledPlugin
    @ObservedObject var plugins: PluginStore
    @State private var title = ""
    @State private var bodyText = ""
    @State private var kind = "decision"
    @State private var confirmed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Save as a memory candidate").font(.title2.weight(.semibold)).padding(24)
            Form {
                Picker("Kind", selection: $kind) { Text("Decision").tag("decision"); Text("Procedure").tag("procedure") }
                TextField("Title", text: $title)
                Section { TextEditor(text: $bodyText).frame(height: 130).scrollContentBackground(.hidden) } header: { Text("Content to save") }
                Toggle("I request that this decision or procedure be saved as a memory candidate", isOn: $confirmed)
                Text("Conversations and search results are not saved automatically. Only this content is sent to the amem inbox as a candidate.").font(.caption).foregroundStyle(Color.secondary)
                if let error = plugins.error { Text(error).font(.caption).foregroundStyle(.red) }
            }.formStyle(.grouped)
            Divider()
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Submit memory candidate") { Task { if await plugins.run(plugin, method: "capture", params: ["kind": .string(kind), "title": .string(title), "body": .string(bodyText), "confirmed_by_user": .bool(true)], configuration: appearance.connection) != nil { plugins.notice = "Submitted as a memory inbox candidate."; dismiss() } } }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).disabled(!confirmed || title.isEmpty || bodyText.isEmpty || plugins.busy) }.padding(20)
        }.frame(width: 560, height: 500)
    }
}
