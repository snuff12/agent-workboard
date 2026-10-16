import SwiftUI

struct LinearState: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let position: Double
    init?(_ json: JSONValue) {
        guard let id = json["id"].string, !id.isEmpty else { return nil }
        self.id = id; name = json["name"].string ?? id; type = json["type"].string ?? ""
        if case .number(let value) = json["position"] { position = value } else { position = 0 }
    }
}

struct LinearTeam: Identifiable, Hashable {
    let id: String
    let key: String
    let name: String
    init?(_ json: JSONValue) {
        guard let id = json["id"].string, !id.isEmpty else { return nil }
        self.id = id; key = json["key"].string ?? ""; name = json["name"].string ?? id
    }
}

struct LinearIssue: Identifiable {
    let id: String
    let identifier: String
    let title: String
    let description: String
    let descriptionTruncated: Bool
    let workspace: String
    let teamID: String
    let stateID: String
    let stateName: String
    let stateType: String
    let assignee: String
    let priorityLabel: String
    let dueDate: String?
    let archived: Bool
    let version: String
    let url: URL?
    let teamStates: [LinearState]
    init?(_ json: JSONValue) {
        guard let id = json["id"].string, let identifier = json["identifier"].string, let workspace = json["workspace"].string,
              !id.isEmpty, !identifier.isEmpty, !workspace.isEmpty else { return nil }
        self.id = id; self.identifier = identifier; self.workspace = workspace
        title = json["title"].string ?? ""; description = json["description"].string ?? ""
        descriptionTruncated = json["description_truncated"].bool ?? false
        teamID = json["team_id"].string ?? ""; stateID = json["state_id"].string ?? ""
        stateName = json["state_name"].string ?? ""; stateType = json["state_type"].string ?? ""
        assignee = json["assignee"].string ?? ""; priorityLabel = json["priority_label"].string ?? ""
        dueDate = json["due_date"].string; archived = json["archived"].bool ?? false; version = json["version"].string ?? ""
        let candidate = URL(string: json["url"].string ?? "")
        url = candidate?.scheme == "https" && candidate?.host == "linear.app" ? candidate : nil
        teamStates = json["team_states"].array.compactMap(LinearState.init).sorted { $0.position < $1.position }
    }
    func parameters(verified: Bool = false) -> [String: JSONValue] {
        var values: [String: JSONValue] = ["issue_id": .string(id), "workspace": .string(workspace)]
        if verified { values["expected_version"] = .string(version) }
        return values
    }
    /// Comments and state changes take the host-read task; a state change also needs this read's version.
    func writeParameters(task: BoardTask, stateID: String? = nil) -> [String: JSONValue] {
        var values = parameters(verified: stateID != nil)
        values["task_id"] = .string(task.id); values["expected_revision"] = .number(Double(task.revision)); values["confirmed_by_user"] = .bool(true)
        if let stateID { values["state_id"] = .string(stateID) }
        return values
    }
    static func suggestedState(for boardStatus: String, in states: [LinearState]) -> LinearState? {
        let type: String? = switch boardStatus { case "todo": "unstarted"; case "in_progress", "review": "started"; case "done": "completed"; default: nil }
        guard let type else { return nil }
        return states.filter { $0.type == type }.min { $0.position < $1.position }
    }
}

struct LinearIssuesView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var board: BoardStore
    let plugin: InstalledPlugin
    @ObservedObject var plugins: PluginStore
    @StateObject private var session: PluginSession
    @State private var query = ""
    @State private var teamID = ""
    @State private var assignedToMe = false
    @State private var includeClosed = false
    @State private var teams: [LinearTeam] = []
    @State private var searchedParams: [String: JSONValue] = [:]
    @State private var issues: [LinearIssue] = []
    @State private var selected: LinearIssue?
    @State private var nextCursor: String?
    @State private var projectID = ""
    @State private var didSearch = false
    @State private var targetStateID = ""

    init(plugin: InstalledPlugin, plugins: PluginStore, configuration: ConnectionConfiguration) {
        self.plugin = plugin; self.plugins = plugins
        _session = StateObject(wrappedValue: PluginSession(configuration: configuration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Button("Connect API key") { connect() }
                Button("Disconnect") { disconnect() }
                Spacer()
                Text("Attach only selected issues and tasks").font(.caption).foregroundStyle(Color.secondary)
            }.disabled(plugins.busy)
            HStack {
                TextField("Search Linear issues (title, text, or ENG-123)", text: $query).textFieldStyle(.roundedBorder).onSubmit { search() }
                Button("Search") { search() }
            }.disabled(plugins.busy)
            HStack(spacing: 14) {
                Picker("Team", selection: $teamID) {
                    Text("All teams").tag("")
                    ForEach(teams) { team in Text(team.key.isEmpty ? team.name : "\(team.key) · \(team.name)").tag(team.id) }
                }.frame(maxWidth: 260)
                Toggle("Assigned to me", isOn: $assignedToMe)
                Toggle("Include closed", isOn: $includeClosed)
                Spacer()
            }.font(.caption).disabled(plugins.busy)
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if issues.isEmpty { Text(didSearch ? "No issues." : "Connect an API key, then search issues.").font(.caption).foregroundStyle(Color.secondary).padding(25) }
                        ForEach(issues) { issue in
                            Button { read(issue) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(issue.identifier) \(issue.title)").font(.callout).lineLimit(2)
                                    Text("\(issue.stateName) · \(issue.assignee.isEmpty ? "Unassigned" : issue.assignee)").font(.caption2).foregroundStyle(Color.secondary)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected?.id == issue.id ? appearance.accent.opacity(0.08) : .clear)
                            }.buttonStyle(.plain).disabled(plugins.busy)
                            Divider()
                        }
                        if let cursor = nextCursor, !cursor.isEmpty { Button("Load more issues") { search(cursor: cursor) }.padding(12).disabled(plugins.busy) }
                    }
                }.frame(minWidth: 220)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let issue = selected { detail(issue) }
                        else { Text("Selecting an issue reads it again from Linear.").font(.caption).foregroundStyle(Color.secondary).padding(.top, 30) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 300)
            }
            Text("Only selected issues are saved to tasks. Review changed issues again before attaching them.").font(.caption2).foregroundStyle(Color.secondary)
        }.padding(16).onAppear { session.bind(appearance); projectID = board.selectedProjectID ?? board.projects.first?.id ?? "" }
            .onChange(of: board.selectedTask?.id) { suggestState() }
            .onDisappear { session.close() }
    }

    @ViewBuilder private func detail(_ issue: LinearIssue) -> some View {
        Text("\(issue.identifier) · \(issue.title)").font(.headline).textSelection(.enabled)
        Text(["State: " + issue.stateName, "Assignee: " + (issue.assignee.isEmpty ? "Unassigned" : issue.assignee), "Priority: " + (issue.priorityLabel.isEmpty ? "None" : issue.priorityLabel), "Due: " + (issue.dueDate ?? "None")].joined(separator: " · ")).font(.caption).foregroundStyle(Color.secondary)
        if issue.archived { Label("Archived in Linear", systemImage: "archivebox").font(.caption).foregroundStyle(.orange) }
        Text(issue.description.isEmpty ? "No description" : issue.description).font(.callout).textSelection(.enabled)
        if issue.descriptionTruncated { Text("The description was shortened.").font(.caption2).foregroundStyle(Color.secondary) }
        if let url = issue.url { Link("Open in Linear", destination: url) }
        Divider()
        if let task = board.selectedTask {
            Text("Selected task: \(task.title)").font(.caption).foregroundStyle(Color.secondary)
            Button("Attach issue to this task") { attach(issue, task: task) }.disabled(plugins.busy)
            Button("Import as a subtask of this task") { importIssue(issue, parent: task) }.disabled(plugins.busy)
        }
        Picker("Project", selection: $projectID) {
            ForEach(board.projects) { project in Text(project.name).tag(project.id) }
        }
        Button("Import as a new task") { importIssue(issue) }.disabled(projectID.isEmpty || plugins.busy)
        if let task = board.selectedTask {
            Divider()
            DisclosureGroup("Post selected task status to Linear · \(task.title)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Posts title, status, blocking, assignee, next action, due date, and task ID as a comment on the selected issue. The same task revision is posted only once.").font(.caption).foregroundStyle(Color.secondary)
                    Button("Post status comment") { postStatus(task, issue: issue) }.disabled(plugins.busy)
                }.padding(.top, 8)
            }.font(.caption)
            DisclosureGroup("Change Linear issue state · \(issue.identifier)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Changes only the selected issue’s workflow state. If a change fails, the issue is read again so you can check its current state.").font(.caption).foregroundStyle(Color.secondary)
                    HStack {
                        Picker("New state", selection: $targetStateID) {
                            Text("Choose a state").tag("")
                            ForEach(issue.teamStates) { state in Text(state.name).tag(state.id) }
                        }.frame(maxWidth: 260)
                        Button("Change state in Linear") { changeState(task, issue: issue) }.disabled(targetStateID.isEmpty || plugins.busy)
                    }
                }.padding(.top, 8)
            }.font(.caption)
        }
    }

    private func run(_ method: String, params: [String: JSONValue] = [:], requestID: String? = nil) async -> JSONValue? {
        await plugins.run(plugin, method: method, params: params, configuration: session.configuration, requestID: requestID,
                          isCurrent: { session.isCurrent(appearance) })
    }
    private func clear() { issues = []; selected = nil; nextCursor = nil; didSearch = false }
    private func connect() {
        Task { if await run("authorize") != nil { clear(); teams = []; teamID = ""; plugins.notice = "Linear API key connected through Keychain."; await loadTeams() } }
    }
    private func disconnect() {
        Task { if await run("disconnect") != nil { clear(); teams = []; teamID = ""; plugins.notice = "Local API key disconnected. The key remains valid in Linear." } }
    }
    private func loadTeams() async {
        guard teams.isEmpty, let result = await run("teams.list") else { return }
        teams = result["teams"].array.compactMap(LinearTeam.init)
    }
    private func search(cursor: String? = nil) {
        guard !plugins.busy else { return }
        var params = searchedParams
        if let cursor { params["cursor"] = .string(cursor) }
        else {
            params = ["limit": .number(20), "assigned_to_me": .bool(assignedToMe), "include_closed": .bool(includeClosed)]
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { params["query"] = .string(text) }
            if !teamID.isEmpty { params["team_id"] = .string(teamID) }
        }
        let values = params
        Task {
            if cursor == nil { selected = nil }
            if let result = await run("issues.search", params: values) {
                let rows = result["issues"].array.compactMap(LinearIssue.init)
                issues = cursor == nil ? rows : issues + rows.filter { row in !issues.contains { $0.id == row.id } }
                nextCursor = result["next_cursor"].string
                if cursor == nil { searchedParams = values }
                didSearch = true
                // Teams load after the first successful call, so opening the screen before connecting shows no error.
                if teams.isEmpty { await loadTeams() }
            }
        }
    }
    private func read(_ issue: LinearIssue) {
        Task {
            selected = nil
            if let result = await run("issues.read", params: issue.parameters()), let fresh = LinearIssue(result) { show(fresh) }
        }
    }
    private func show(_ issue: LinearIssue) {
        selected = issue
        if let index = issues.firstIndex(where: { $0.id == issue.id }) { issues[index] = issue }
        suggestState()
    }
    private func suggestState() {
        guard let issue = selected, let task = board.selectedTask else { targetStateID = ""; return }
        targetStateID = LinearIssue.suggestedState(for: task.isBlocked ? "blocked" : task.status.rawValue, in: issue.teamStates)?.id ?? ""
    }
    private func attach(_ issue: LinearIssue, task: BoardTask) {
        var params = issue.parameters(verified: true)
        params["task_id"] = .string(task.id); params["expected_revision"] = .number(Double(task.revision))
        let values = params
        Task { if await run("issues.attach", params: values) != nil { plugins.notice = "Linear issue attached to the task."; await board.reload(force: true) } }
    }
    private func importIssue(_ issue: LinearIssue, parent: BoardTask? = nil) {
        var params = issue.parameters(verified: true)
        params["project_id"] = .string(parent?.projectID ?? projectID)
        if let parent { params["parent_id"] = .string(parent.id) }
        let values = params
        Task { if await run("issues.import", params: values) != nil { plugins.notice = parent == nil ? "Issue imported as a new task." : "Issue imported as a subtask."; await board.reload(force: true) } }
    }
    // Each click uses a new request ID. The provider finds an existing comment for the same task revision,
    // and a state change that already reached Linear fails its version check instead of applying twice.
    private func postStatus(_ task: BoardTask, issue: LinearIssue) {
        guard session.isCurrent(appearance), !plugins.busy else { return }
        let params = issue.writeParameters(task: task)
        Task {
            if let result = await run("issues.comment", params: params, requestID: UUID().uuidString), result["posted"].bool == true {
                let identifier = result["identifier"].string ?? issue.identifier
                plugins.notice = result["reused"].bool == true ? "This task status was already posted to \(identifier). No duplicate comment was created." : "Task status posted to \(identifier)."
            }
        }
    }
    private func changeState(_ task: BoardTask, issue: LinearIssue) {
        let stateID = targetStateID
        guard !stateID.isEmpty, session.isCurrent(appearance), !plugins.busy else { return }
        let params = issue.writeParameters(task: task, stateID: stateID)
        Task {
            if let result = await run("issues.update_state", params: params, requestID: UUID().uuidString), let updated = LinearIssue(result) {
                show(updated)
                plugins.notice = result["changed"].bool == false ? "The issue is already in that state." : "\(updated.identifier) moved to \(updated.stateName) in Linear."
                await board.reload(force: true)
            } else if session.isCurrent(appearance), let failure = plugins.error {
                // The change may have reached Linear. Read the issue again so the next attempt starts from its current state.
                if let result = await run("issues.read", params: issue.parameters()), let fresh = LinearIssue(result) { show(fresh) }
                plugins.error = failure
            }
        }
    }
}
