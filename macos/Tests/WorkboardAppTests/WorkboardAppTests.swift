import Foundation
import AppKit
import Darwin

// This runner does not require the XCTest framework absent from Command Line Tools.
@main struct WorkboardUITests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw Failure(description: message) } }
    @MainActor static func main() async throws {
        if let mode = ProcessInfo.processInfo.environment["WORKBOARD_THEME_PROBE"] { try themeProbe(mode); return }
        try modelContract()
        try appGroupConfiguration()
        try calendarContract()
        try timeZoneEditing()
        try timestampDisplay()
        try themeValidationAndPersistence()
        try themeFilesAndFreshProcess()
        try connectionIdentities()
        try pluginConfigurationValues()
        try orcaWorktreeLinks()
        try slackContract()
        try linearContract()
        try githubConfiguration()
        try githubItemContract()
        try githubArtifactLinks()
        try githubRemoteParsing()
        try githubPendingWrites()
        try await rpcArgumentsAndErrors()
        try await githubErrorCodes()
        if let executable = ProcessInfo.processInfo.environment["WORKBOARD_BIN"], !executable.isEmpty {
            try await actualService(executable)
            try await linearWorkflowAndDeletion(executable)
            try await connectionSwitchRecoveryAndPluginConfig(executable)
            try await githubActualHost(executable)
        }
        print("✓ SwiftUI models, theme persistence and validation, RPC arguments, and error handling verified")
    }
    static func modelContract() throws {
        let data = Data(#"{"task":{"id":"child","project_id":"project","parent_id":"parent","title":"Subtask","goal":"Goal","completion_criteria":"Build succeeded","status":"in_progress","priority":3,"assignee":"codex-ui","next_action":"Check the screen","revision":12,"updated_at":"2026-10-15T01:00:00Z"},"children":[],"artifacts":[{"id":"a","path":"https://example.com/result","kind":"url","description":"Outcome"}],"runs":[{"id":"r","agent_id":"codex-ui","status":"running","started_at":"2026-10-15T01:00:00Z"}]}"#.utf8)
        guard let detail = TaskDetail(try JSONDecoder().decode(JSONValue.self, from: data)) else { throw Failure(description: "Task contract did not decode") }
        try require(detail.task.parentID == "parent", "Subtask relationship lost")
        try require(detail.task.status == .inProgress && detail.task.revision == 12, "Status or revision lost")
        try require(detail.artifacts.first?.url?.host == "example.com" && detail.runs.first?.agent == "codex-ui", "Artifact or run lost")
    }
    static func appGroupConfiguration() throws {
        try require(WorkboardAppGroup.resolve(nil) == "group.local.agentworkboard.shared", "Missing App Group setting did not use development fallback")
        try require(WorkboardAppGroup.resolve(" \n ") == WorkboardAppGroup.fallbackIdentifier, "Empty App Group setting did not use fallback")
        try require(WorkboardAppGroup.resolve("TEAM123456.group.local.agentworkboard.shared") == "TEAM123456.group.local.agentworkboard.shared", "Signed Team App Group identifier was changed")
        try require(WorkboardAppGroup.resolve("  TEAM123456.custom.workboard \n") == "TEAM123456.custom.workboard", "Configured App Group identifier did not trim whitespace")
        print("✓ App Group Info.plist configuration: Team ID preservation and default restoration verified")
    }
    static func calendarContract() throws {
        let data = Data(#"{"id":"event","summary":"Design meeting","description":"Item to check","htmlLink":"https://calendar.google.com/event/123","etag":"version-2","start":{"dateTime":"2026-10-15T09:00:00+09:00","timeZone":"Asia/Seoul"},"end":{"dateTime":"2026-10-15T10:00:00+09:00"}}"#.utf8)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let event = CalendarEvent(json) else { throw Failure(description: "Calendar event missing") }
        try require(event.title == "Design meeting" && event.etag == "version-2", "Calendar title or etag lost")
        try require(BoardDate.parse(event.start, timeZone: event.timeZone) != nil, "Calendar time not parsed")
        try require(BoardDate.parse("2026-10-15", timeZone: "Asia/Seoul") != nil, "All-day deadline not parsed")
        try require(BoardDate.parse("not a date") == nil, "Malformed calendar time accepted")
        let allDayJSON = JSONValue.object(["id": .string("allday"), "project_id": .string("p"), "due_at": .string("2026-10-15"), "time_zone": .string("Pacific/Kiritimati")])
        guard let task = BoardTask(allDayJSON), let date = task.dueDate else { throw Failure(description: "All-day task missing") }
        try require(BoardDate.dateOnly(date) == "2026-10-15", "All-day deadline shifted because of time zone")
    }
    static var foreignSchedules: [[String: JSONValue]] {
        [
            ["due_at": .string("2027-03-14T04:00:00-04:00"), "scheduled_start": .string("2027-03-14T01:30:00-05:00"), "scheduled_end": .string("2027-03-14T03:30:00-04:00")],
            ["due_at": .string("2026-11-01T02:00:00-05:00"), "scheduled_start": .string("2026-11-01T01:30:00-04:00"), "scheduled_end": .string("2026-11-01T01:30:00-05:00")],
            ["due_at": .string("2027-03-14"), "scheduled_start": .string("2027-03-13"), "scheduled_end": .string("2027-03-15")]
        ]
    }
    static func timeZoneEditing() throws {
        for (index, fields) in foreignSchedules.enumerated() {
            var json = fields; json["id"] = .string("foreign-\(index)"); json["project_id"] = .string("p"); json["time_zone"] = .string("America/New_York")
            guard let task = BoardTask(.object(json)) else { throw Failure(description: "Foreign task missing") }
            var draft = TaskDraft(projectID: task.projectID, editingTask: task); draft.title = "Change title only"
            try require(draft.timeZoneID == "America/New_York" && draft.dueValue == task.dueAt && draft.scheduledStartValue == task.scheduledStart && draft.scheduledEndValue == task.scheduledEnd, "Title edit changed original timezone or date strings")
            let originalStart = draft.scheduledStart
            draft.changeTimeZone(to: "Asia/Seoul")
            if draft.scheduleAllDay {
                try require(draft.dueValue == task.dueAt && draft.scheduledStartValue == task.scheduledStart && draft.scheduledEndValue == task.scheduledEnd, "Changing all-day zone shifted calendar dates")
                draft.changeTimeZone(to: "America/New_York")
                try require(draft.scheduledEnd.timeIntervalSince(draft.scheduledStart) == 47 * 3600, "DST all-day range did not retain calendar-day length")
            } else {
                try require(draft.scheduledStart == originalStart, "Changing timed event zone shifted its instant")
                try require(draft.scheduledEnd.timeIntervalSince(draft.scheduledStart) == 3600, "DST crossing meeting changed duration")
            }
        }
    }
    static func timestampDisplay() throws {
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        let newYork = TimeZone(identifier: "America/New_York")!
        let locale = Locale(identifier: "en_GB")
        let fractionalZ = BoardDate.shortLocalTimestamp("2026-10-15T08:28:19.123Z", timeZone: seoul, locale: locale)
        let seoulOffset = BoardDate.shortLocalTimestamp("2026-10-15T17:28:19+09:00", timeZone: seoul, locale: locale)
        let usOffset = BoardDate.shortLocalTimestamp("2026-10-15T04:28:19-04:00", timeZone: seoul, locale: locale)
        try require(fractionalZ.contains("17:28") && fractionalZ == seoulOffset && fractionalZ == usOffset, "Equivalent fractional UTC/Seoul/US timestamps did not display Seoul 17:28: \(fractionalZ), \(seoulOffset), \(usOffset)")
        let defaultEnglish = BoardDate.shortLocalTimestamp("2026-10-15T08:28:19.123Z", timeZone: seoul)
        try require(defaultEnglish.contains("Oct") && defaultEnglish.contains("5:28") && defaultEnglish.contains("PM"), "Default display must use English while retaining the selected time zone: \(defaultEnglish)")
        let displayedInUS = BoardDate.shortLocalTimestamp("2026-10-15T08:28:19.123Z", timeZone: newYork, locale: locale)
        try require(displayedInUS.contains("04:28"), "UTC timestamp did not display New York local time: \(displayedInUS)")
        let nextDay = BoardDate.shortLocalTimestamp("2026-10-15T23:28:19.123Z", timeZone: seoul, locale: locale)
        try require(nextDay.contains("16") && nextDay.contains("08:28"), "Local timestamp did not cross midnight into October 16: \(nextDay)")
        try require(BoardDate.shortLocalTimestamp("2026-10-15", timeZone: seoul, locale: locale) == "2026-10-15" && BoardDate.shortLocalTimestamp("2026-10-15", timeZone: newYork, locale: locale) == "2026-10-15", "Date-only value changed during local timestamp formatting")
        try require(BoardDate.shortLocalTimestamp("") == "—" && BoardDate.shortLocalTimestamp("badTtimestamp") == "bad timestamp", "Invalid timestamp fallback changed")
        print("✓ Change, run, and history timestamps: fractional UTC, Seoul, and US offsets, local conversion, date-only and invalid-value fallback verified")
    }
    @MainActor static func themeValidationAndPersistence() throws {
        var theme = ThemeConfiguration()
        theme.version = 2; try require((try? theme.validated()) == nil, "Unsupported theme accepted")
        theme.version = 1; theme.accentHex = "not-a-color"; try require((try? theme.validated()) == nil, "Invalid color accepted")
        theme.accentHex = "#123aBC"; theme.fontScale = 9; try require((try? theme.validated()) == nil, "Invalid font scale accepted")
        theme.fontScale = 1.15; let valid = try theme.validated(); try require(valid.accentHex == "123ABC", "Valid custom color changed")
        let suite = "workboard-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "No test defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = AppearanceSettings(defaults: defaults)
        appearance.theme.appearance = .dark; appearance.theme.accentHex = "23896A"; appearance.theme.showCompleted = false; appearance.theme.density = .compact
        let restored = AppearanceSettings(defaults: defaults)
        try require(restored.theme == appearance.theme, "Personalization did not persist")
        let decoded = try JSONDecoder().decode(ThemeConfiguration.self, from: JSONEncoder().encode(restored.theme)).validated()
        try require(decoded == appearance.theme, "Theme import/export lost settings")
    }
    static var probeTheme: ThemeConfiguration {
        var value = ThemeConfiguration(); value.name = "Relaunch test theme"; value.appearance = .dark; value.accentHex = "23896A"; value.density = .compact; value.fontScale = 1.2; value.showSidebar = false; value.showCompleted = false; value.showSubtasksOnBoard = true; return value
    }
    @MainActor static func themeProbe(_ mode: String) throws {
        guard let suite = ProcessInfo.processInfo.environment["WORKBOARD_THEME_SUITE"], let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "Missing preference probe suite") }
        let appearance = AppearanceSettings(defaults: defaults)
        if mode == "write" { appearance.theme = probeTheme; defaults.synchronize() }
        else if mode != "read" { throw Failure(description: "Unknown preference probe mode") }
        print(String(decoding: try JSONEncoder().encode(appearance.theme), as: UTF8.self))
    }
    @MainActor static func themeFilesAndFreshProcess() throws {
        let suite = "workboard-process-theme-\(UUID().uuidString)"
        let fileSuite = suite + "-file"
        let defaults = UserDefaults(suiteName: suite)!, fileDefaults = UserDefaults(suiteName: fileSuite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); defaults.synchronize(); fileDefaults.removePersistentDomain(forName: fileSuite); try? FileManager.default.removeItem(at: directory) }
        func process(_ mode: String) throws -> ThemeConfiguration {
            let child = Process(); child.executableURL = Bundle.main.executableURL
            child.environment = ProcessInfo.processInfo.environment.merging(["WORKBOARD_THEME_PROBE": mode, "WORKBOARD_THEME_SUITE": suite]) { _, new in new }
            let output = Pipe(), errors = Pipe(); child.standardOutput = output; child.standardError = errors
            try child.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
            guard child.terminationStatus == 0 else { throw Failure(description: "Theme probe failed: \(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))") }
            return try JSONDecoder().decode(ThemeConfiguration.self, from: data)
        }
        let written = try process("write"), restored = try process("read")
        try require(written == probeTheme && restored == probeTheme, "Fresh process did not restore all theme preferences")
        let appearance = AppearanceSettings(defaults: fileDefaults); appearance.theme = probeTheme
        let url = directory.appendingPathComponent("theme.json")
        try appearance.exportTheme(to: url)
        appearance.theme = ThemeConfiguration(); try appearance.importTheme(from: url)
        try require(appearance.theme == probeTheme, "Actual theme JSON file roundtrip lost preferences")
        try Data("{\"version\":999}".utf8).write(to: url)
        do { try appearance.importTheme(from: url); throw Failure(description: "Invalid theme file accepted") }
        catch is DecodingError { }
        catch is WorkboardError { }
        try require(appearance.theme == probeTheme, "Rejected theme file changed active preferences")
        print("✓ Cross-process UserDefaults restoration, real JSON import/export, and theme preservation on failure")
    }
    static func connectionIdentities() throws {
        let configuration = ConnectionConfiguration()
        let base = configuration.identity(environment: ["WORKBOARD_BIN": "/tmp/bin-a", "WORKBOARD_DATA_DIR": "/tmp/data-a", "WORKBOARD_SOCKET": "/tmp/socket-a"])
        try require(base != configuration.identity(environment: ["WORKBOARD_BIN": "/tmp/bin-b", "WORKBOARD_DATA_DIR": "/tmp/data-a", "WORKBOARD_SOCKET": "/tmp/socket-a"]), "CLI change did not invalidate connection identity")
        try require(base != configuration.identity(environment: ["WORKBOARD_BIN": "/tmp/bin-a", "WORKBOARD_DATA_DIR": "/tmp/data-b", "WORKBOARD_SOCKET": "/tmp/socket-a"]), "Data directory change did not invalidate connection identity")
        try require(base != configuration.identity(environment: ["WORKBOARD_BIN": "/tmp/bin-a", "WORKBOARD_DATA_DIR": "/tmp/data-a", "WORKBOARD_SOCKET": "/tmp/socket-b"]), "Socket change did not invalidate connection identity")
    }
    static func orcaWorktreeLinks() throws {
        func link(_ id: String, locator: String, provider: String = "orca", kind: String = "workspace", title: String) -> JSONValue {
            .object(["id": .string(id), "path": .string("/w/" + title), "kind": .string(kind), "provider": .string(provider), "locator": .string(locator), "metadata": .object(["title": .string(title)])])
        }
        let artifacts = [link("1", locator: "repo::/w/a", title: "first link"), link("2", locator: "repo::/w/b", title: "other"),
                         link("3", locator: "repo::/w/a", title: "run link"), link("4", locator: "", title: "no locator"),
                         link("5", locator: "x", provider: "agent-memory", title: "memory"), link("6", locator: "y", kind: "url", title: "url")]
            .enumerated().map { TaskArtifact($0.element, index: $0.offset) }
        try require(TaskArtifact.orcaWorktrees(artifacts).map(\.id) == ["3", "2"], "Linked Orca worktrees were not one per worktree with the newest link first")
        let repos: [JSONValue] = [.object(["id": .string("app"), "path": .string("/code/app")]), .object(["id": .string("lib"), "path": .string("/code/lib")]),
                                  .object(["id": .string("tools"), "path": .string("/code/app-tools")])]
        try require(OrcaPaths.repositories(repos, for: "/code/app") == ["app"], "A project folder did not match its own repository only")
        try require(OrcaPaths.repositories(repos, for: "/code/app/services/api") == ["app"], "A project folder inside a repository did not match it")
        try require(OrcaPaths.repositories(repos, for: "/code") == ["app", "lib", "tools"], "A parent project folder did not match the repositories inside it")
        try require(OrcaPaths.repositories(repos, for: "").isEmpty && OrcaPaths.repositories(repos, for: "/elsewhere").isEmpty, "An unrelated or empty folder matched a repository")
        try require(OrcaPaths.summary(repository: "app", branch: "refs/heads/feature/x", status: "") == "app · feature/x", "Worktree summary was not shortened")
        print("✓ Orca worktree links: one entry per worktree, project folder matching, and summaries verified")
    }
    static func pluginConfigurationValues() throws {
        let saved: JSONValue = .object(["calendar_enabled": .bool(false), "gmail_enabled": .bool(true), "account": .string("work-mail"), "credentials_file": .string("/custom/oauth.json"), "future_option": .object(["keep": .bool(true)])])
        var draft = PluginConfigurationDraft(config: saved)
        try require(!draft.calendarEnabled && draft.gmailEnabled && draft.account == "work-mail" && draft.credentialsFile == "/custom/oauth.json", "Plugin editor did not load saved service/account/path values")
        let unchanged = try draft.enableParameters(for: "google-workspace")["config"]
        try require(unchanged == saved, "Unchanged plugin save did not preserve configuration")
        draft.credentialsFile = "/updated/oauth.json"
        let edited = try draft.enableParameters(for: "google-workspace")["config"]!
        try require(edited["future_option"] == saved["future_option"] && edited["account"] == saved["account"] && edited["gmail_enabled"].bool == true, "Plugin save lost unshown configuration")
        let invalidBoolean = PluginConfigurationDraft(config: .object(["calendar_enabled": .string("true"), "gmail_enabled": .number(1)]))
        try require(!invalidBoolean.calendarEnabled && !invalidBoolean.gmailEnabled, "Non-Boolean plugin values enabled a service")
        let orcaSaved: JSONValue = .object(["executable": .string("/custom/orca"), "repo": .string("id:repo-1"), "agent_commands": .object(["codex": .array([.string("/custom/codex")])])])
        var orcaDraft = PluginConfigurationDraft(config: orcaSaved)
        try require(orcaDraft.orcaRepoSelectors == ["id:repo-1"] && orcaDraft.executable == "/custom/orca", "Orca settings were not restored")
        let orcaUnchanged = try orcaDraft.enableParameters(for: "orca")["config"]
        try require(orcaUnchanged == orcaSaved, "Orca save lost custom agent command")
        orcaDraft.orcaRepos = "id:repo-1\n  path:/new/repo  \n\npath:/new/repo"
        orcaDraft.addOrcaRepos(for: [BoardProject(.object(["id": .string("p1"), "directory": .string("/board/app")]))!, BoardProject(.object(["id": .string("p2"), "directory": .string("")]))!])
        let orcaEdited = try orcaDraft.enableParameters(for: "orca")["config"]!
        try require(orcaEdited["repos"] == .array([.string("id:repo-1"), .string("path:/new/repo"), .string("path:/board/app")]) && orcaEdited["repo"] == .null && orcaEdited["agent_commands"] == orcaSaved["agent_commands"], "Orca repository edit lost saved options or repositories")
        orcaDraft.orcaRepos = "id:repo-1\n/no/prefix"
        try require((try? orcaDraft.enableParameters(for: "orca")) == nil, "Orca accepted a repository without a selector prefix")
        for pluginID in ["slack", "linear", "google-workspace"] {
            for label in ["O'Brien", "work\nlist-keychains", "two words"] {
                var unsafe = PluginConfigurationDraft(config: .object(["credentials_file": .string("/keys/key.json")])); unsafe.account = label
                try require((try? unsafe.enableParameters(for: pluginID)) == nil, "\(pluginID) saved a Keychain account label that `security -i` cannot store safely: \(label)")
            }
            var earlier = PluginConfigurationDraft(config: .object(["credentials_file": .string("/keys/key.json"), "account": .string("two words")]))
            let kept = try earlier.enableParameters(for: pluginID)
            try require(kept["config"]?["account"].string == "two words", "\(pluginID) refused to save other settings with a label saved before labels were checked")
            earlier.account = "O'Brien"
            try require((try? earlier.enableParameters(for: pluginID)) == nil, "\(pluginID) accepted a changed label that `security -i` cannot store safely")
            var safe = PluginConfigurationDraft(config: .object(["credentials_file": .string("/keys/key.json")])); safe.account = "work-mail@example.com"
            let saved = try safe.enableParameters(for: pluginID)
            try require(saved["config"]?["account"].string == "work-mail@example.com", "\(pluginID) refused a valid account label")
        }
        let slackSaved: JSONValue = .object(["account": .string("work-slack"), "team_id": .string("T123"), "credentials_file": .string("/custom/slack.credentials.json"), "messages_enabled": .bool(true), "send_enabled": .bool(false), "future_option": .string("keep")])
        var slackDraft = PluginConfigurationDraft(config: slackSaved)
        try require(slackDraft.slackMessagesEnabled && !slackDraft.slackSendEnabled, "Slack sending was enabled without an explicit setting")
        let slackUnchanged = try slackDraft.enableParameters(for: "slack")["config"]
        try require(slackUnchanged == slackSaved, "Slack configuration did not round-trip")
        slackDraft.slackSendEnabled = true
        let slackEdited = try slackDraft.enableParameters(for: "slack")["config"]!
        try require(slackEdited["send_enabled"].bool == true && slackEdited["future_option"] == slackSaved["future_option"], "Slack edit lost settings or failed to enable sending")
        let invalidSlack = PluginConfigurationDraft(config: .object(["messages_enabled": .string("true"), "send_enabled": .number(1)]))
        try require(!invalidSlack.slackMessagesEnabled && !invalidSlack.slackSendEnabled, "Non-Boolean Slack flags enabled access")
        let linearSaved: JSONValue = .object(["account": .string("work-linear"), "workspace": .string("acme"), "credentials_file": .string("/custom/linear.credentials.json"), "issues_enabled": .bool(true), "comments_enabled": .bool(false), "state_changes_enabled": .bool(false), "future_option": .string("keep")])
        var linearDraft = PluginConfigurationDraft(config: linearSaved)
        try require(linearDraft.linearIssuesEnabled && !linearDraft.linearCommentsEnabled && !linearDraft.linearStateChangesEnabled && linearDraft.linearWorkspace == "acme", "Linear writes were enabled without an explicit setting")
        let linearUnchanged = try linearDraft.enableParameters(for: "linear")["config"]
        try require(linearUnchanged == linearSaved, "Linear configuration did not round-trip")
        linearDraft.linearStateChangesEnabled = true; linearDraft.linearWorkspace = "  acme \n"
        let linearEdited = try linearDraft.enableParameters(for: "linear")["config"]!
        try require(linearEdited["state_changes_enabled"].bool == true && linearEdited["comments_enabled"].bool == false && linearEdited["workspace"].string == "acme" && linearEdited["future_option"] == linearSaved["future_option"], "Linear edit lost settings or changed the wrong write permission")
        let invalidLinear = PluginConfigurationDraft(config: .object(["issues_enabled": .string("true"), "comments_enabled": .number(1), "state_changes_enabled": .string("yes")]))
        try require(!invalidLinear.linearIssuesEnabled && !invalidLinear.linearCommentsEnabled && !invalidLinear.linearStateChangesEnabled, "Non-Boolean Linear flags enabled access")
    }
    static func slackContract() throws {
        let json: JSONValue = .object(["channel_id": .string("C123"), "team_id": .string("T123"), "ts": .string("1792034000.000123"), "thread_ts": .string("1792033000.000001"), "text": .string("Request review"), "version": .string("source-v1"), "url": .string("https://example.slack.com/archives/C123/p1792034000000123")])
        guard let message = SlackMessage(json) else { throw Failure(description: "Slack message did not decode") }
        try require(message.parameters()["ts"] == json["ts"] && message.parameters()["thread_ts"] == json["thread_ts"], "Slack timestamp precision or thread identity was lost")
        try require(message.parameters()["expected_version"] == nil, "Search preview incorrectly supplied a verified source version")
        try require(message.parameters(verified: true)["expected_version"] == json["version"], "Verified Slack source version was not passed to mutations")
        try require(message.url?.host == "example.slack.com", "Slack source link was lost")
        var unsafe = json.object; unsafe["url"] = .string("https://example.slack.com.evil.test/")
        try require(SlackMessage(.object(unsafe))?.url == nil, "Non-Slack URL was treated as a source link")
        print("✓ Slack configuration, string timestamps, threads, source versions, and links verified")
    }
    static func linearContract() throws {
        let states: [JSONValue] = [
            .object(["id": .string("s-progress"), "name": .string("In Progress"), "type": .string("started"), "position": .number(2)]),
            .object(["id": .string("s-todo-late"), "name": .string("Ready"), "type": .string("unstarted"), "position": .number(5)]),
            .object(["id": .string("s-todo"), "name": .string("Todo"), "type": .string("unstarted"), "position": .number(1)]),
            .object(["id": .string("s-done"), "name": .string("Done"), "type": .string("completed"), "position": .number(3)])
        ]
        let json: JSONValue = .object(["id": .string("2f1c6c1e-0000-4000-8000-000000000001"), "identifier": .string("ENG-123"), "title": .string("Fix login"), "description": .string("Steps"), "workspace": .string("acme"), "team_id": .string("team-1"), "state_id": .string("s-todo"), "state_name": .string("Todo"), "state_type": .string("unstarted"), "assignee": .string(""), "priority": .number(2), "priority_label": .string("High"), "due_date": .string("2026-10-20"), "archived": .bool(false), "version": .string("issue-v1"), "url": .string("https://linear.app/acme/issue/ENG-123/fix-login"), "team_states": .array(states)])
        guard let issue = LinearIssue(json) else { throw Failure(description: "Linear issue did not decode") }
        try require(issue.parameters()["issue_id"] == json["id"] && issue.parameters()["workspace"] == json["workspace"], "Linear issue identity or workspace was lost")
        try require(issue.parameters()["expected_version"] == nil, "Search preview incorrectly supplied a verified issue version")
        try require(issue.parameters(verified: true)["expected_version"] == json["version"], "Verified Linear issue version was not passed to mutations")
        try require(issue.url?.host == "linear.app" && issue.dueDate == "2026-10-20", "Linear source link or due date was lost")
        try require(issue.teamStates.map(\.id) == ["s-todo", "s-progress", "s-done", "s-todo-late"], "Linear team states were not ordered by position")
        var unsafe = json.object; unsafe["url"] = .string("https://linear.app.evil.test/acme/issue/ENG-123")
        try require(LinearIssue(.object(unsafe))?.url == nil, "Non-Linear URL was treated as a source link")
        unsafe["url"] = .string("http://linear.app/acme/issue/ENG-123")
        try require(LinearIssue(.object(unsafe))?.url == nil, "Unencrypted Linear URL was treated as a source link")
        var missing = json.object; missing["workspace"] = .string("")
        try require(LinearIssue(.object(missing)) == nil, "Linear issue without a workspace decoded")
        try require(LinearIssue.suggestedState(for: "todo", in: issue.teamStates)?.id == "s-todo", "To do did not suggest the first unstarted state")
        try require(LinearIssue.suggestedState(for: "in_progress", in: issue.teamStates)?.id == "s-progress" && LinearIssue.suggestedState(for: "review", in: issue.teamStates)?.id == "s-progress", "Active work did not suggest a started state")
        try require(LinearIssue.suggestedState(for: "done", in: issue.teamStates)?.id == "s-done", "Done did not suggest a completed state")
        try require(LinearIssue.suggestedState(for: "blocked", in: issue.teamStates) == nil && LinearIssue.suggestedState(for: "done", in: []) == nil, "Blocked work or a team without states suggested a state")
        try require(LinearIssue.suggestedState(for: "backlog", in: issue.teamStates) == nil && LinearIssue.suggestedState(for: "canceled", in: issue.teamStates) == nil, "A team without backlog or canceled states suggested another type")
        let closing = issue.teamStates + [
            .object(["id": .string("s-backlog"), "name": .string("Backlog"), "type": .string("backlog"), "position": .number(0)]),
            .object(["id": .string("s-canceled"), "name": .string("Canceled"), "type": .string("canceled"), "position": .number(4)]),
            .object(["id": .string("s-duplicate"), "name": .string("Duplicate"), "type": .string("canceled"), "position": .number(6)])
        ].compactMap(LinearState.init)
        try require(LinearIssue.suggestedState(for: "backlog", in: closing)?.id == "s-backlog" && LinearIssue.suggestedState(for: "canceled", in: closing)?.id == "s-canceled", "Backlog or Canceled did not suggest the matching Linear state")
        guard let task = BoardTask(.object(["id": .string("task-1"), "project_id": .string("project-1"), "revision": .number(4)])) else { throw Failure(description: "Board task did not decode") }
        let comment = issue.writeParameters(task: task)
        try require(comment["task_id"] == .string("task-1") && comment["expected_revision"] == .number(4) && comment["confirmed_by_user"] == .bool(true) && comment["workspace"] == json["workspace"], "Linear comment lost the host task or confirmation")
        try require(comment["expected_version"] == nil && comment["state_id"] == nil, "Linear comment carried state-change fields")
        let change = issue.writeParameters(task: task, stateID: "s-done")
        try require(change["state_id"] == .string("s-done") && change["expected_version"] == json["version"], "Linear state change lost its target or read version")
        print("✓ Linear configuration, issue identity, source versions, links, write parameters, and state suggestions verified")
    }
    static func githubConfiguration() throws {
        let saved: JSONValue = .object(["auth": .string("gh"), "gh_executable": .string("/opt/homebrew/bin/gh"), "repos": .array([.string("Octo-Org/app.web"), .string("octo/tools")]), "write_enabled": .bool(true), "host": .string("github.com"), "future_option": .object(["keep": .bool(true)])])
        var draft = PluginConfigurationDraft(config: saved)
        try require(draft.githubAuth == "gh" && draft.githubExecutable == "/opt/homebrew/bin/gh" && draft.githubWriteEnabled && draft.githubRepoList == ["Octo-Org/app.web", "octo/tools"], "GitHub settings were not restored")
        let unchanged = try draft.enableParameters(for: "github")["config"]
        try require(unchanged == saved, "Unchanged GitHub save changed the configuration")
        let minimal: JSONValue = .object(["gh_executable": .string("/usr/local/bin/gh"), "repos": .array([.string("octo/app")])])
        let minimalSaved = try PluginConfigurationDraft(config: minimal).enableParameters(for: "github")["config"]
        try require(minimalSaved == minimal, "GitHub save added auth, account, or write keys the user did not change")
        draft.githubRepos = " Octo-Org/app.web \n\nocto/tools\nOCTO/TOOLS"
        let collapsed = try draft.enableParameters(for: "github")["config"]
        try require(collapsed == saved, "Whitespace or duplicate repository lines rewrote the saved repository list")
        draft.githubRepos += "\nocto/new-repo"; draft.githubWriteEnabled = false
        let edited = try draft.enableParameters(for: "github")["config"]!
        try require(edited["repos"] == .array([.string("Octo-Org/app.web"), .string("octo/tools"), .string("octo/new-repo")]) && edited["write_enabled"] == .bool(false) && edited["future_option"] == saved["future_option"] && edited["host"] == saved["host"], "GitHub edit lost repositories, unknown keys, or the write flag")
        var tokenDraft = PluginConfigurationDraft(config: saved); tokenDraft.githubAuth = "token"; tokenDraft.credentialsFile = ""
        try require((try? tokenDraft.enableParameters(for: "github")) == nil, "Token sign-in was saved without a credentials file")
        tokenDraft.credentialsFile = "/secure/github-token.json"
        let tokenConfig = try tokenDraft.enableParameters(for: "github")["config"]!
        try require(tokenConfig["auth"].string == "token" && tokenConfig["credentials_file"].string == "/secure/github-token.json" && tokenConfig["account"] == .null && tokenConfig["gh_executable"] == saved["gh_executable"], "Token sign-in settings were not written as chosen")
        for label in ["bob's token", "work token", "caf\u{E9}", "quote\"label", "back\\slash", "tab\tlabel", String(repeating: "a", count: 81)] {
            var invalid = tokenDraft; invalid.account = label
            do { _ = try invalid.enableParameters(for: "github"); throw Failure(description: "Unsafe GitHub account label was accepted: \(label.prefix(40))") }
            catch let error as WorkboardError { try require(error.message.contains("account label"), "Account label error did not name the field: \(error.message)") }
        }
        var labeled = tokenDraft; labeled.account = "Work.bot_1@example-org"
        let labeledConfig = try labeled.enableParameters(for: "github")["config"]
        try require(labeledConfig?["account"].string == "Work.bot_1@example-org", "A valid GitHub account label was not saved")
        labeled.account = String(repeating: "a", count: 80)
        try require((try? labeled.enableParameters(for: "github")) != nil, "An 80-character account label was rejected")
        labeled.account = ""
        let defaultConfig = try labeled.enableParameters(for: "github")["config"]
        try require(defaultConfig?["account"] == .null, "An empty account label did not fall back to the default")
        var ghLabel = PluginConfigurationDraft(config: saved); ghLabel.account = "bob's token"
        try require((try? ghLabel.enableParameters(for: "github")) != nil, "gh sign-in was blocked by the unused token account label")
        var relative = PluginConfigurationDraft(config: saved); relative.githubExecutable = "gh"
        try require((try? relative.enableParameters(for: "github")) == nil, "A gh executable found on PATH was accepted")
        var unknownAuth = PluginConfigurationDraft(config: saved); unknownAuth.githubAuth = "oauth"
        try require((try? unknownAuth.enableParameters(for: "github")) == nil, "An unknown sign-in method was accepted")
        let invalidRepos = ["", (1...21).map { "octo/repo-\($0)" }.joined(separator: "\n"), "-octo/app", "octo/..", "octo/.", "octo/app/extra", "octo", "caf\u{E9}/app", "octo/app name", String(repeating: "a", count: 40) + "/app", "octo/" + String(repeating: "r", count: 101), "octo_org/app"]
        for repos in invalidRepos {
            var invalid = PluginConfigurationDraft(config: saved); invalid.githubRepos = repos
            try require((try? invalid.enableParameters(for: "github")) == nil, "Invalid GitHub repository list was accepted: \(repos.prefix(40))")
        }
        var twenty = PluginConfigurationDraft(config: saved); twenty.githubRepos = (1...20).map { "octo/repo-\($0)" }.joined(separator: "\n")
        try require((try? twenty.enableParameters(for: "github")) != nil, "Twenty repositories were rejected")
        for value in [JSONValue.string("true"), .number(1), .null] {
            try require(!PluginConfigurationDraft(config: .object(["write_enabled": value])).githubWriteEnabled, "Non-Boolean write_enabled enabled GitHub writing")
        }
        let leaked: JSONValue = .object(["gh_executable": .string("/opt/homebrew/bin/gh"), "repos": .array([.string("octo/app")]), "token": .string("placeholder-not-a-token"), "Access_Token": .string("placeholder"), "pat": .null, "password": .number(1), "notes": .string("keep")])
        let cleaned = try PluginConfigurationDraft(config: leaked).enableParameters(for: "github")["config"]!
        try require(cleaned.object.keys.contains("token") && cleaned["token"] == .null && cleaned["Access_Token"] == .null && cleaned["password"] == .null && cleaned["pat"] == .null && cleaned["notes"].string == "keep", "Saved secret-named GitHub keys were not cleared")
        print("✓ GitHub configuration: round trip, unchanged keys, repository validation, token account label characters, non-Boolean write flag, and secret key clearing verified")
    }
    static func githubItemContract() throws {
        let row: JSONValue = .object(["repo": .string("Octo/App"), "number": .number(42), "type": .string("pull"), "title": .string("Fix sign-in"), "state": .string("open"), "state_reason": .null, "draft": .bool(true), "merged": .bool(false), "author": .string("octocat"), "labels": .array([.string("bug")]), "assignees": .array([]), "comments": .number(3), "created_at": .string("2026-10-14T01:00:00Z"), "updated_at": .string("2026-10-15T01:00:00Z"), "closed_at": .null, "url": .string("https://github.com/Octo/App/pull/42")])
        guard let item = GitHubItem(row) else { throw Failure(description: "GitHub row did not decode") }
        try require(item.isPull && item.draft && !item.merged && item.locator == "Octo/App#42" && item.labels == ["bug"] && item.url?.absoluteString == "https://github.com/Octo/App/pull/42", "GitHub row fields or link were lost")
        try require(item.parameters() == ["repo": .string("Octo/App"), "number": .number(42)], "A list row claimed a verified source version")
        let unsafeLinks = ["https://github.com.evil.test/Octo/App/pull/42", "http://github.com/Octo/App/pull/42", "https://github.com/Octo/Other/pull/42", "https://github.com/Other/App/pull/42", "https://github.com/Octo/App/pull/43", "https://user@github.com/Octo/App/pull/42", "https://github.com:8443/Octo/App/pull/42", "https://github.com/Octo/App/commits/42", "https://github.com/Octo/App/pull/42?tab=files", "file:///Octo/App/pull/42", ""]
        for unsafe in unsafeLinks {
            var json = row.object; json["url"] = .string(unsafe)
            try require(GitHubItem(.object(json))?.url == nil, "Unsafe GitHub link accepted: \(unsafe)")
        }
        var lowercase = row.object; lowercase["url"] = .string("https://github.com/octo/app/pull/42")
        try require(GitHubItem(.object(lowercase))?.url != nil, "Case-insensitive repository link rejected")
        var full = row.object; full["body"] = .string("Steps to reproduce"); full["version"] = .string("source-v1"); full["pull"] = .object(["head_ref": .string("fix-sign-in"), "base_ref": .string("main"), "head_sha": .string("0123456789abcdef")])
        guard let read = GitHubItem(.object(full)) else { throw Failure(description: "Full GitHub read did not decode") }
        let verified = read.parameters(verified: true)
        try require(verified["expected_version"] == .string("source-v1") && verified["repo"] == .string("Octo/App") && verified["number"] == .number(42), "Verified GitHub mutations did not pass expected_version")
        try require(read.headRef == "fix-sign-in" && read.baseRef == "main" && read.body == "Steps to reproduce", "Pull request branch or body lost")
        for (key, value) in [("repo", JSONValue.string("octo/app/extra")), ("repo", .string("octo")), ("number", .number(0)), ("number", .number(4.5)), ("number", .string("42"))] {
            var bad = row.object; bad[key] = value
            try require(GitHubItem(.object(bad)) == nil, "Malformed GitHub row accepted: \(key)")
        }
        try require(GitHubItemReference(url: "https://github.com/Octo/App/issues/7")?.key == "octo/app#7" && GitHubItemReference(url: "https://github.com/Octo/App/issues/7")?.isPull == false, "Issue link not parsed")
        for url in ["https://github.com/Octo/App/issues/7#issuecomment-1", "https://github.com/Octo/App/issues/007", "https://github.com/Octo/App/issues/+7", "https://github.com/Octo/App/issues/7/files", "https://github.com/Octo/App/issues/99999999999"] {
            try require(GitHubItemReference(url: url) == nil, "Non-canonical GitHub item link accepted: \(url)")
        }
        print("✓ GitHub items: row decoding, link validation, and verified source versions in mutations verified")
    }
    static func githubArtifactLinks() throws {
        let data = Data(#"{"task":{"id":"t","project_id":"p","title":"Task","revision":3},"artifacts":[{"id":"a1","path":"https://github.com/octo/app/issues/12","kind":"url","provider":"github","locator":"octo/app#12","description":"GitHub issue octo/app#12: Crash","metadata":{"provider":"github","repo":"octo/app","number":12,"state":"open","source_version":"v1"}},{"id":"a2","path":"https://github.com/octo/app/issues/12#issuecomment-99","kind":"url","provider":"github","locator":"octo/app#12","metadata":{"kind":"status_comment"}},{"id":"a3","path":"https://github.com/other/repo/pull/5","provider":"github","metadata":{}},{"id":"a4","path":"https://github.com.evil.test/octo/app/issues/13","provider":"github"},{"id":"a5","path":"https://github.com/octo/app/pull/14","provider":"slack"},{"id":"a6","path":"https://github.com/Octo/App/issues/12","provider":"github","metadata":{"source_version":"v2","state":"closed"}},{"id":"a7","path":"/local/file.md"},{"id":"a8","path":"https://github.com/octo/app/pull/15","provider":"github","metadata":{"source_version":"x"}}]}"#.utf8)
        guard let detail = TaskDetail(try JSONDecoder().decode(JSONValue.self, from: data)) else { throw Failure(description: "Task detail with GitHub artifacts did not decode") }
        let first = detail.artifacts[0]
        try require(first.provider == "github" && first.locator == "octo/app#12" && first.metadata["source_version"].string == "v1" && first.metadata["number"].int == 12, "TaskArtifact lost provider, locator, or metadata")
        try require(detail.artifacts[6].provider == nil && detail.artifacts[6].locator == nil && detail.artifacts[6].metadata == .object([:]), "A plain artifact gained provider data")
        let linked = GitHubLinkedItem.from(detail.artifacts, configuredRepos: ["Octo/App"])
        try require(linked.map(\.id) == ["octo/app#12", "octo/app#15"] && linked[0].sourceVersion == "v2" && linked[0].linkedState == "closed" && linked[1].reference.isPull, "Linked GitHub items were not filtered and deduplicated: \(linked.map(\.id))")
        try require(linked[0].statusParameters == .object(["repo": .string("Octo/App"), "number": .number(12), "source_version": .string("v2")]), "Status request lost the linked source version")
        try require(GitHubLinkedItem.from(detail.artifacts, configuredRepos: []).isEmpty, "Items outside connected repositories were listed")
        try require(GitHubLinkedItem.isLinked(itemKey: "Octo/App#12", in: detail.artifacts) && GitHubLinkedItem.isLinked(itemKey: "octo/app#15", in: detail.artifacts), "A canonical issue or pull request link was not recognized")
        let commentOnly = [detail.artifacts[1]]
        try require(commentOnly[0].locator == "octo/app#12" && !GitHubLinkedItem.isLinked(itemKey: "octo/app#12", in: commentOnly), "A status comment on the issue counted as a link to the issue")
        try require(!GitHubLinkedItem.isLinked(itemKey: "octo/app#14", in: detail.artifacts) && !GitHubLinkedItem.isLinked(itemKey: "octo/app#13", in: detail.artifacts), "A link from another provider or host counted as a GitHub link")
        let statusOnly: JSONValue = .object(["state": .string("open"), "checks": .object(["state": .string("success"), "runs_available": .bool(false)])])
        let summary = GitHubLinkedItem.statusSummary(statusOnly)
        try require(summary.contains("checks: success") && summary.contains("only commit statuses were read"), "Missing check runs were not reported: \(summary)")
        for checks in [JSONValue.object(["state": .string("success"), "runs_available": .bool(true)]), .object(["state": .string("success")])] {
            let full = GitHubLinkedItem.statusSummary(.object(["state": .string("open"), "checks": checks]))
            try require(full == "open · checks: success", "Readable check runs were reported as missing: \(full)")
        }
        print("✓ GitHub links: artifact provider, locator, and metadata decoding, link re-validation, status comments not counted as links, status parameters, and status-only checks verified")
    }
    static func githubRemoteParsing() throws {
        let accepted = ["https://github.com/octo/app": "octo/app", "https://github.com/octo/app.git": "octo/app", "https://github.com/octo/app/": "octo/app", "https://github.com/octo/app.git/": "octo/app", "https://GitHub.com/Octo/App": "Octo/App", "git@github.com:Octo-Org/my.repo.git": "Octo-Org/my.repo", "git@github.com:octo/app": "octo/app", "ssh://git@github.com/octo/app.git": "octo/app", "  https://github.com/octo/app.git  ": "octo/app"]
        for (url, repo) in accepted { try require(GitHubRemote.repository(fromURL: url) == repo, "GitHub remote not parsed: \(url)") }
        let rejected = ["https://gitlab.com/octo/app.git", "https://github.com.evil.test/octo/app", "git@example.com:octo/app.git", "git@github.com:/octo/app.git", "ssh://git@github.com:2222/octo/app.git", "ssh://deploy@github.com/octo/app.git", "https://token@github.com/octo/app.git", "http://github.com/octo/app", "https://github.com/octo", "https://github.com/octo/app/tree/main", "https://github.com/-octo/app", "https://github.com/octo/app%20name", "/local/path/app.git", ""]
        for url in rejected { try require(GitHubRemote.repository(fromURL: url) == nil, "Non-GitHub or malformed remote accepted: \(url)") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workboard-github-remotes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ text: String, _ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("[core]\n\trepositoryformatversion = 0\n[remote \"upstream\"]\n\turl = git@github.com:upstream-org/app.git\n[remote \"origin\"]\n\turl = https://github.com/octo/app.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n", "main/.git/config")
        try write("../..\n", "main/.git/worktrees/feature/commondir")
        try write("gitdir: ../main/.git/worktrees/feature\n", "feature/.git")
        try write("[remote \"origin\"]\n\turl = https://gitlab.com/octo/app.git\n[remote \"backup\"]\n\turl = \"ssh://git@github.com/backup-org/app.git\"\n", "mixed/.git/config")
        try write("[remote \"origin\"]\n\turl = https://gitlab.com/octo/other.git\n", "other/.git/config")
        try write("gitdir: /does/not/exist\n", "broken/.git")
        func repo(_ name: String) -> String? { GitHubRemote.repository(in: root.appendingPathComponent(name).path) }
        try require(repo("main") == "octo/app", "origin was not preferred over another GitHub remote")
        try require(repo("feature") == "octo/app", "Worktree .git file and commondir were not followed")
        try require(repo("mixed") == "backup-org/app", "The first GitHub remote was not used when origin is elsewhere")
        try require(repo("other") == nil && repo("broken") == nil && repo("missing") == nil && GitHubRemote.repository(in: "relative/path") == nil, "A missing or non-GitHub remote produced a repository")
        var draft = PluginConfigurationDraft(config: .object(["repos": .array([.string("Octo/App")])]))
        let projects = ["main", "feature", "mixed", "other"].compactMap { BoardProject(.object(["id": .string($0), "directory": .string(root.appendingPathComponent($0).path)])) }
        draft.addGitHubRepos(for: projects)
        try require(draft.githubRepoList == ["Octo/App", "backup-org/app"], "Board project repositories were not added once each: \(draft.githubRepoList)")
        try require(GitHubRemote.repositories(for: projects) == ["main": "octo/app", "feature": "octo/app", "mixed": "backup-org/app"], "Project to repository map was wrong")
        print("✓ GitHub remotes: https, scp, and ssh forms, .git suffix, trailing slash, wrong hosts, and worktree commondir verified")
    }
    static func githubPendingWrites() throws {
        let configA = ConnectionConfiguration(executablePath: "/tmp/workboard-a", dataDirectory: "/tmp/board-a")
        let configB = ConnectionConfiguration(executablePath: "/tmp/workboard-a", dataDirectory: "/tmp/board-b")
        func task(_ id: String, revision: Int) -> BoardTask { BoardTask(.object(["id": .string(id), "project_id": .string("p"), "title": .string("Report"), "revision": .number(Double(revision))]))! }
        let comment = GitHubWriteOperation(kind: .comment, taskID: "task-1", revision: 4, repo: "Octo/App", number: 12, configuration: configA)
        try require(comment.parameters == ["task_id": .string("task-1"), "expected_revision": .number(4), "repo": .string("Octo/App"), "number": .number(12), "confirmed_by_user": .bool(true)], "Comment write parameters were wrong")
        try require(comment.matches(kind: .comment, task: task("task-1", revision: 4), repo: "Octo/App", number: 12, configuration: configA), "Pending write did not match the same task, target, and board")
        try require(comment.matches(kind: .comment, task: task("task-1", revision: 9), repo: "octo/app", number: 12, configuration: configA) && comment.parameters["expected_revision"] == .number(4), "A revision change dropped the pending write or its original revision")
        try require(!comment.matches(kind: .comment, task: task("task-2", revision: 4), repo: "Octo/App", number: 12, configuration: configA), "Pending write matched another task")
        try require(!comment.matches(kind: .comment, task: task("task-1", revision: 4), repo: "Octo/App", number: 13, configuration: configA) && !comment.matches(kind: .comment, task: task("task-1", revision: 4), repo: "Octo/Other", number: 12, configuration: configA), "Pending write matched another target")
        try require(!comment.matches(kind: .comment, task: task("task-1", revision: 4), repo: "Octo/App", number: 12, configuration: configB) && !comment.matches(kind: .issue, task: task("task-1", revision: 4), repo: "Octo/App", number: nil, configuration: configA), "Pending write matched another board or write kind")
        let issue = GitHubWriteOperation(kind: .issue, taskID: "task-1", revision: 4, repo: "Octo/App", number: nil, title: "Ship the release", configuration: configA)
        try require(issue.parameters["number"] == nil && issue.parameters["confirmed_by_user"] == .bool(true) && issue.requestID != comment.requestID, "Issue write parameters or request IDs were wrong")
        try require(comment.checkHint.contains("Octo/App#12") && issue.checkHint.contains("Ship the release"), "Pending write hint did not name the GitHub target")
        // Failures after the provider ran can follow a GitHub write, so they keep the request ID. So do host refusals that come
        // before the journal lookup, such as an uninstalled plugin, because a retry can follow an earlier attempt that posted.
        let afterProvider = ["PLUGIN_ERROR", "PLUGIN_DISABLED", "PLUGIN_NOT_INSTALLED", "PLUGIN_METHOD_NOT_FOUND", "INVALID_PARAMS", "PLUGIN_CANCELLED", "PLUGIN_JOURNAL_ERROR", "PLUGIN_REQUEST_IN_PROGRESS", "REQUEST_ID_CONFLICT", "PLUGIN_EXTERNAL_RESULT_UNKNOWN", "PLUGIN_RESULT_UNCERTAIN", "PLUGIN_TIMEOUT", "INTEGRATION_UNAVAILABLE", "AUTHORIZATION_REQUIRED", "CONFLICT", "PLUGIN_FUTURE_CODE", ""]
        for code in afterProvider {
            try require(GitHubWriteOperation.shouldRetain(afterErrorCode: code, message: "NOT_FOUND: Task not found"), "Pending write was cleared after \(code.isEmpty ? "no service response" : code)")
        }
        try require(GitHubWriteOperation.shouldRetain(afterErrorCode: nil, message: nil), "Pending write was cleared without a recorded failure")
        try require(GitHubWriteOperation.shouldRetain(afterErrorCode: "PLUGIN_ERROR", message: "No GitHub write was made. Then the link failed."), "A message that only starts with the no-write sentence cleared the pending write")
        for code in ["PLUGIN_REVISION_CONFLICT", "PLUGIN_CONTEXT_UNAVAILABLE", "PLUGIN_INVALID_PARAMS"] {
            try require(!GitHubWriteOperation.shouldRetain(afterErrorCode: code, message: "The host stopped first."), "Pending write was kept after a failure before the provider ran: \(code)")
        }
        for (code, message) in [("INVALID_REQUEST", "INVALID_REQUEST: This repository is archived. No GitHub write was made."), ("AUTHORIZATION_REQUIRED", "AUTHORIZATION_REQUIRED: Verify the GitHub account first. No GitHub write was made.\n"),
                                ("INTEGRATION_DISABLED", "INTEGRATION_DISABLED: Enable GitHub writing separately. No GitHub write was made."), ("CONFLICT", "The task was changed elsewhere. Read the latest version before retrying.\nCONFLICT: Locked. No GitHub write was made."), ("PLUGIN_ERROR", "  PLUGIN_ERROR: Refused. No GitHub write was made.  ")] {
            try require(!GitHubWriteOperation.shouldRetain(afterErrorCode: code, message: message), "Pending write was kept after a failure that made no GitHub write: \(code)")
        }
        let suite = "workboard-github-pending-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "No test defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GitHubPendingWrites(defaults: defaults)
        try require(store.load(for: configA.identity()) == nil, "A new store restored a pending write")
        let first = GitHubWriteOperation(kind: .comment, taskID: "task-1", revision: 4, repo: "Octo/App", number: 1, configuration: configA)
        store.save(first)
        guard let restored = GitHubPendingWrites(defaults: defaults).load(for: configA.identity()) else { throw Failure(description: "A pending GitHub write was not restored") }
        try require(restored.requestID == first.requestID && restored.parameters == first.parameters && restored.kind == .comment && restored.label == first.label && restored.checkHint == first.checkHint, "A restored pending write lost its request ID or parameters")
        try require(restored.parameters["number"] == .number(1) && restored.parameters["confirmed_by_user"] == .bool(true), "Restoring changed a number into a Boolean or lost the confirmation")
        try require(restored.matches(kind: .comment, task: task("task-1", revision: 7), repo: "octo/app", number: 1, configuration: configA), "A restored pending write no longer matched its task and board")
        try require(store.load(for: configB.identity()) == nil, "A pending write was restored for another board connection")
        let other = GitHubWriteOperation(kind: .issue, taskID: "task-2", revision: 1, repo: "Octo/App", number: nil, title: "Other board", configuration: configB)
        store.save(other)
        try require(store.load(for: configA.identity())?.requestID == first.requestID && store.load(for: configB.identity())?.requestID == other.requestID, "Pending writes of two board connections replaced each other")
        let newer = GitHubWriteOperation(kind: .comment, taskID: "task-1", revision: 5, repo: "Octo/App", number: 2, configuration: configA)
        store.save(newer); store.remove(first)
        try require(store.load(for: configA.identity())?.requestID == newer.requestID, "Removing an older write dropped the newer pending write")
        store.remove(newer)
        try require(store.load(for: configA.identity()) == nil && store.load(for: configB.identity())?.requestID == other.requestID, "Removing a write cleared the wrong board connection")
        store.remove(other)
        try require(defaults.object(forKey: GitHubPendingWrites.key) == nil, "Removing the last pending write left stored data")
        defaults.set([configA.identity().executable + "\n" + configA.identity().dataDirectory + "\n" + configA.identity().socket: Data("{\"kind\":\"comment\"}".utf8)], forKey: GitHubPendingWrites.key)
        try require(store.load(for: configA.identity()) == nil, "An incomplete stored write was restored")
        print("✓ GitHub pending writes: matching ignores revision, requires the same task, target, and board; request IDs are kept unless the failure happened before any GitHub write; stored writes survive a new view and stay with their board connection")
    }
    @MainActor static func githubErrorCodes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workboard github codes \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("workboard stub")
        let configuration = ConnectionConfiguration(executablePath: executable.path, dataDirectory: directory.path, sharesWidgetSnapshot: false)
        func stub(_ body: String) throws {
            try ("#!/bin/sh\n" + body).write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try stub("printf '%s\\n' '{\"ok\":false,\"error\":{\"code\":\"PLUGIN_EXTERNAL_RESULT_UNKNOWN\",\"message\":\"The GitHub write may have succeeded.\"}}'\nexit 1\n")
        do { _ = try await WorkboardClient().call("plugin.run", configuration: configuration); throw Failure(description: "Plugin failure treated as success") }
        catch let error as WorkboardError { try require(error.code == "PLUGIN_EXTERNAL_RESULT_UNKNOWN" && error.message.contains("may have succeeded"), "Service error code did not reach WorkboardError") }
        let plugins = PluginStore()
        _ = await plugins.call("plugin.run", params: [:], configuration: configuration)
        try require(plugins.errorCode == "PLUGIN_EXTERNAL_RESULT_UNKNOWN" && plugins.error != nil && plugins.errorMessage == plugins.error, "PluginStore did not record the error code and message with the error")
        plugins.error = nil
        try require(plugins.errorCode == nil && plugins.errorMessage == nil, "Clearing the plugin error kept a stale error code or message")
        try stub("printf '%s\\n' '{\"ok\":false,\"error\":{\"code\":\"PLUGIN_REVISION_CONFLICT\",\"message\":\"The task has changed.\"}}'\nexit 1\n")
        _ = await plugins.call("plugin.run", params: [:], configuration: configuration)
        try require(plugins.errorCode == "PLUGIN_REVISION_CONFLICT" && (plugins.error?.contains("changed elsewhere") ?? false), "Revision conflict lost its code or message")
        try stub("printf '%s\\n' '{\"ok\":false,\"error\":{\"code\":\"CONFLICT\",\"message\":\"CONFLICT: The conversation is locked. No GitHub write was made.\"}}'\nexit 1\n")
        _ = await plugins.call("plugin.run", params: [:], configuration: configuration)
        try require(plugins.errorCode == "CONFLICT" && (plugins.errorMessage?.hasPrefix("The task was changed elsewhere") ?? false) && !GitHubWriteOperation.shouldRetain(afterErrorCode: plugins.errorCode, message: plugins.errorMessage), "The no-write sentence was not found after the transport prefix: \(plugins.errorMessage ?? "none")")
        try stub("printf '%s\\n' '{\"ok\":false,\"error\":{\"code\":\"REQUEST_ID_CONFLICT\",\"message\":\"REQUEST_ID_CONFLICT: A request_id cannot be reused for a different request.\"}}'\nexit 1\n")
        _ = await plugins.call("plugin.run", params: [:], configuration: configuration)
        try require(plugins.errorCode == "REQUEST_ID_CONFLICT" && GitHubWriteOperation.shouldRetain(afterErrorCode: plugins.errorCode, message: plugins.errorMessage), "A request ID conflict cleared the pending write")
        try stub("exit 1\n")
        _ = await plugins.call("plugin.run", params: [:], configuration: configuration)
        try require(plugins.errorCode == "" && GitHubWriteOperation.shouldRetain(afterErrorCode: plugins.errorCode, message: plugins.errorMessage), "A missing service response was not recorded as an empty code")
        let disabled = InstalledPlugin(.object(["id": .string("github"), "enabled": .bool(false)]))!
        _ = await plugins.run(disabled, method: "tasks.comment", configuration: configuration)
        try require(plugins.errorCode == "PLUGIN_DISABLED" && plugins.errorMessage == "Enable the plugin first.", "A disabled plugin did not record its code and message")
        print("✓ Service error codes reach WorkboardError and PluginStore, and clear together with the error")
    }
    @MainActor static func githubActualHost(_ executable: String) async throws {
        let directory = URL(fileURLWithPath: "/tmp/wbgh-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try await startService(executable, directory: directory)
        defer { if service.isRunning { service.terminate() }; service.waitUntilExit() }
        func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let configuration = ConnectionConfiguration(executablePath: executable, dataDirectory: directory.path, sharesWidgetSnapshot: false)
        let client = WorkboardClient()
        let project = try await client.call("project.create", params: ["name": .string("GitHub fixture")], configuration: configuration)
        let created = try await client.call("task.create", params: ["project_id": project["project_id"], "title": .string("Report status")], configuration: configuration)
        guard let taskID = created["task_id"].string else { throw Failure(description: "GitHub fixture task missing") }
        func currentTask() async throws -> BoardTask {
            guard let task = BoardTask(try await client.call("task.get", params: ["task_id": .string(taskID)], configuration: configuration)["task"]) else { throw Failure(description: "GitHub fixture task unreadable") }
            return task
        }
        // A fake provider that never contacts GitHub: it records each invocation and reports an uncertain write.
        let package = directory.appendingPathComponent("github-package"), posts = directory.appendingPathComponent("fake-github-posts")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest: JSONValue = .object(["id": .string("github"), "name": .string("GitHub fixture"), "version": .string("0.1.0"), "protocol_version": .number(1), "executable": .string("provider.sh"), "methods": .array([.string("tasks.comment")]), "task_context_methods": .array([.string("tasks.comment")]), "allowed_requests": .array([.string("task.attach")])])
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("plugin.json"))
        let provider = package.appendingPathComponent("provider.sh")
        try "#!/bin/sh\nprintf 'post\\n' >> \(quote(posts.path))\nprintf '%s\\n' '{\"ok\":false,\"error\":{\"code\":\"PLUGIN_EXTERNAL_RESULT_UNKNOWN\",\"message\":\"The GitHub write may have succeeded. Check octo/app#12 on GitHub before trying again; do not repeat it with a new request ID.\"}}'\n".write(to: provider, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: provider.path)
        let plugins = PluginStore()
        _ = await plugins.call("plugin.install", params: ["path": .string(package.path)], configuration: configuration)
        guard let enabled = await plugins.call("plugin.enable", params: ["id": .string("github")], configuration: configuration), let github = InstalledPlugin(enabled) else { throw Failure(description: plugins.error ?? "GitHub fixture enable failed") }
        func postCount() -> Int { ((try? String(contentsOf: posts, encoding: .utf8)) ?? "").split(separator: "\n").count }
        let task = try await currentTask()
        let operation = GitHubWriteOperation(kind: .comment, taskID: task.id, revision: task.revision, repo: "octo/app", number: 12, configuration: configuration)
        let first = await plugins.run(github, method: "tasks.comment", params: operation.parameters, configuration: configuration, requestID: operation.requestID)
        try require(first == nil && plugins.errorCode == "PLUGIN_EXTERNAL_RESULT_UNKNOWN" && GitHubWriteOperation.shouldRetain(afterErrorCode: plugins.errorCode, message: plugins.errorMessage) && postCount() == 1, "Uncertain GitHub write was not reported with its code: \(plugins.errorCode ?? "none") \(plugins.error ?? "")")
        let retry = await plugins.run(github, method: "tasks.comment", params: operation.parameters, configuration: configuration, requestID: operation.requestID)
        try require(retry == nil && plugins.errorCode == "PLUGIN_RESULT_UNCERTAIN" && GitHubWriteOperation.shouldRetain(afterErrorCode: plugins.errorCode, message: plugins.errorMessage) && postCount() == 1, "Identical retry ran the provider again or lost the uncertain code: \(plugins.errorCode ?? "none")")
        _ = try await client.call("task.update", params: ["task_id": .string(taskID), "expected_revision": .number(Double(task.revision)), "title": .string("Report status again")], configuration: configuration)
        let changed = try await currentTask()
        try require(changed.revision != task.revision && operation.matches(kind: .comment, task: changed, repo: "Octo/App", number: 12, configuration: configuration), "A task revision change dropped the pending GitHub write")
        let stale = GitHubWriteOperation(kind: .comment, taskID: taskID, revision: task.revision, repo: "octo/app", number: 12, configuration: configuration)
        let rejected = await plugins.run(github, method: "tasks.comment", params: stale.parameters, configuration: configuration, requestID: stale.requestID)
        try require(rejected == nil && plugins.errorCode == "PLUGIN_REVISION_CONFLICT" && !GitHubWriteOperation.shouldRetain(afterErrorCode: plugins.errorCode, message: plugins.errorMessage) && postCount() == 1, "Stale revision reached the provider or kept the pending write: \(plugins.errorCode ?? "none")")
        // The fake provider now reports a posted comment, but linking it fails the way it does for a task deleted during the write.
        let installedProvider = directory.appendingPathComponent("plugins/github/provider.sh")
        try "#!/bin/sh\nprintf 'post\\n' >> \(quote(posts.path))\nprintf '%s\\n' '{\"ok\":true,\"result\":{\"commented\":true,\"repo\":\"octo/app\",\"number\":12},\"requests\":[{\"method\":\"task.attach\",\"params\":{\"task_id\":\"deleted-task\",\"path\":\"https://github.com/octo/app/issues/12#issuecomment-7\",\"kind\":\"url\",\"provider\":\"github\",\"locator\":\"octo/app#12\"}}]}'\n".write(to: installedProvider, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installedProvider.path)
        let suite = "workboard-github-host-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "No test defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let linkFailure = GitHubWriteOperation(kind: .comment, taskID: changed.id, revision: changed.revision, repo: "octo/app", number: 12, configuration: configuration)
        GitHubPendingWrites(defaults: defaults).save(linkFailure)
        let posted = await plugins.run(github, method: "tasks.comment", params: linkFailure.parameters, configuration: configuration, requestID: linkFailure.requestID)
        try require(posted == nil && plugins.errorCode == "PLUGIN_ERROR" && GitHubWriteOperation.shouldRetain(afterErrorCode: plugins.errorCode, message: plugins.errorMessage) && postCount() == 2, "A link failure after the GitHub write cleared the pending write: \(plugins.errorCode ?? "none") \(plugins.error ?? "")")
        // Relaunching restores the same request ID, and the identical retry replays the saved result instead of posting again.
        guard let reopened = GitHubPendingWrites(defaults: defaults).load(for: configuration.identity()), reopened.requestID == linkFailure.requestID else { throw Failure(description: "The pending write was not restored after the link failure") }
        let replayed = await plugins.run(github, method: "tasks.comment", params: reopened.parameters, configuration: configuration, requestID: reopened.requestID)
        try require(replayed == nil && plugins.errorCode == "PLUGIN_ERROR" && GitHubWriteOperation.shouldRetain(afterErrorCode: plugins.errorCode, message: plugins.errorMessage) && postCount() == 2, "The identical retry ran the provider again or cleared the pending write: \(plugins.errorCode ?? "none")")
        print("✓ GitHub Swift→actual CLI: uncertain writes and link failures after a post keep the request ID, identical retries never post again, restored writes reuse their request ID, and stale revisions clear the pending write")
    }
    static func rpcArgumentsAndErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workboard ui tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("workboard stub")
        let argumentsFile = directory.appendingPathComponent("arguments")
        let path = "'" + argumentsFile.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > \(path)\nprintf '%s\\n' '{\"ok\":true,\"result\":{\"projects\":[],\"tasks\":[],\"event_sequence\":7}}'\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let literal = "Title $(touch /tmp/never-run) `literal`"
        let result = try await WorkboardClient().call("task.create", params: ["title": .string(literal)], configuration: ConnectionConfiguration(executablePath: executable.path, dataDirectory: directory.path))
        try require(result["event_sequence"].int == 7, "RPC envelope did not decode")
        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        try require(Array(arguments.prefix(5)) == ["--data-dir", directory.path, "rpc", "task.create", "--params"], "RPC argument order incorrect")
        try require(arguments.last == "--json" && arguments.count == 7, "JSON must be one literal argument")
        let received = try JSONDecoder().decode(JSONValue.self, from: Data(arguments[5].utf8))
        try require(received["title"].string == literal, "JSON was interpreted as shell code")
        try "#!/bin/sh\nprintf '%s\\n' '{\"ok\":false,\"error\":{\"code\":\"revision_conflict\",\"message\":\"stale revision\"}}'\nexit 2\n".write(to: executable, atomically: true, encoding: .utf8)
        do { _ = try await WorkboardClient().call("task.update", configuration: ConnectionConfiguration(executablePath: executable.path)); throw Failure(description: "Service error treated as success") }
        catch let error as WorkboardError { try require(error.message.contains("The task was changed elsewhere"), "Conflict did not reach user") }
        do { _ = try WorkboardClient.resolveExecutable(override: "/does/not/exist/workboard", environment: [:]); throw Failure(description: "Invalid configured executable ignored") }
        catch let error as WorkboardError { try require(error.message.contains("Configured workboard executable"), "Executable error not actionable") }
    }
    @MainActor static func actualService(_ executable: String) async throws {
        let directory = URL(fileURLWithPath: "/tmp/wbui-\(UUID().uuidString.prefix(8))")
        let suite = "workboard-service-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "No test defaults") }
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let appearance = AppearanceSettings(defaults: defaults); appearance.executablePath = executable; appearance.dataDirectory = directory.path
        let service = Process()
        service.executableURL = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("workboard-service")
        service.arguments = ["--data-dir", directory.path, "--socket", directory.appendingPathComponent("workboard.sock").path]
        service.standardOutput = FileHandle.nullDevice; service.standardError = FileHandle.nullDevice
        try service.run()
        defer { if service.isRunning { service.terminate() }; service.waitUntilExit() }
        for _ in 0..<80 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("workboard.sock").path) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let store = BoardStore(appearance: appearance)
        await store.reload(force: true)
        try require(store.connectionError == nil && store.tasks.isEmpty, "Empty real board failed: \(store.connectionError ?? "")")
        let created = await store.createProject(name: "UI integration verification", directory: directory.path)
        try require(created && store.projects.count == 1, "Real project creation failed: \(store.actionError ?? "")")
        guard let project = store.projects.first else { throw Failure(description: "No project") }
        var parent = TaskDraft(projectID: project.id); parent.title = "Parent task"; parent.completionCriteria = "Verify subtasks"; parent.hasDueDate = true; parent.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())!; parent.hasSchedule = true; parent.scheduledStart = Date(); parent.scheduledEnd = Date().addingTimeInterval(1800); _ = await store.save(parent)
        guard let task = store.tasks.first else { throw Failure(description: "No parent: \(store.actionError ?? "")") }
        try require(task.dueAt == BoardDate.dateOnly(parent.dueDate) && task.startDate != nil && task.endDate != nil && task.timeZone == TimeZone.current.identifier, "Actual deadline/schedule/time zone did not persist")
        var child = TaskDraft(projectID: project.id, parentID: task.id); child.title = "Subtask"; child.hasSchedule = true; child.scheduleAllDay = true; child.scheduledStart = Calendar.current.startOfDay(for: Date()); child.scheduledEnd = Calendar.current.date(byAdding: .day, value: 1, to: child.scheduledStart)!; _ = await store.save(child)
        try require(store.children(of: task).count == 1, "Real subtask missing")
        try require(store.children(of: task).first?.scheduledStart?.count == 10, "All-day schedule changed to timed event")
        store.selectedProjectID = BoardStore.todayScope
        try require(store.scopedTasks.count == 2 && store.visibleTasks.contains(where: { $0.parentID == task.id }), "Today view did not show scheduled subtask")
        store.selectedProjectID = nil
        await store.move(task, to: .inProgress)
        try require(store.tasks.first(where: { $0.id == task.id })?.status == .inProgress, "Real start failed: \(store.actionError ?? "")")
        await store.openTask(task.id)
        try require(store.detail?.children.count == 1 && store.detail?.runs.count == 1 && (store.detail?.events.count ?? 0) >= 1, "Real task details incomplete: \(store.actionError ?? "")")
        guard let current = store.selectedTask else { throw Failure(description: "No selected task") }
        _ = await store.attach(current, path: "https://example.com/result", description: "Verification results")
        try require(store.detail?.artifacts.count == 1, "Real attachment failed")
        guard let latest = store.selectedTask else { throw Failure(description: "No latest task") }
        _ = await store.complete(latest, summary: "Verify actual service behavior through the app transport")
        try require(store.tasks.first(where: { $0.id == task.id })?.status == .done, "Real complete failed: \(store.actionError ?? "")")
        try require(store.children(of: task).first?.status == .todo, "Parent completion changed child status")
        if let completed = store.selectedTask {
            await store.move(completed, to: .inProgress)
            try require(store.selectedTask?.status == .inProgress && store.detail?.runs.count == 2, "Completed task did not reopen with a new run")
        }
        var otherParent = TaskDraft(projectID: project.id); otherParent.title = "Another parent task"; _ = await store.save(otherParent)
        guard let alternate = store.tasks.first(where: { $0.title == otherParent.title }), let originalChild = store.children(of: task).first else { throw Failure(description: "Reparent fixtures missing") }
        var reparent = TaskDraft(projectID: project.id, editingTask: originalChild); reparent.parentID = alternate.id; _ = await store.save(reparent)
        try require(store.children(of: task).isEmpty && store.children(of: alternate).count == 1, "Moving child to another parent did not update hierarchy")
        guard let moved = store.children(of: alternate).first else { throw Failure(description: "Reparented child missing") }
        var detached = TaskDraft(projectID: project.id, editingTask: moved); detached.parentID = nil; _ = await store.save(detached)
        try require(store.children(of: alternate).isEmpty && store.tasks.first(where: { $0.id == moved.id })?.parentID == nil, "Detaching child did not send explicit null parent")
        guard let independent = store.tasks.first(where: { $0.id == moved.id }) else { throw Failure(description: "Detached task missing") }
        var returned = TaskDraft(projectID: project.id, editingTask: independent); returned.parentID = task.id; _ = await store.save(returned)
        guard let returnedChild = store.children(of: task).first else { throw Failure(description: "Returned child missing") }
        _ = await store.complete(returnedChild, summary: "Verify subtask outcomes")
        try require(store.children(of: task).filter { $0.status == .done }.count == 1 && store.tasks.first(where: { $0.id == task.id })?.status == .inProgress, "Child completion count or independent parent status changed incorrectly")
        store.newTask(parent: alternate)
        try require(store.draft?.parentID == alternate.id && store.draft?.projectID == project.id, "Subtask action lost parent/project scope")
        store.draft = nil
        print("✓ Actual service: subtask reparenting, detaching, completion counts, and no automatic parent completion")
        for (index, fields) in foreignSchedules.enumerated() {
            var params = fields; params["project_id"] = .string(project.id); params["title"] = .string("Imported New York event \(index)"); params["time_zone"] = .string("America/New_York")
            let created = try await WorkboardClient().call("task.create", params: params, configuration: appearance.connection)
            guard let imported = BoardTask(created["task"]) else { throw Failure(description: "Imported timezone fixture did not create") }
            var edit = TaskDraft(projectID: project.id, editingTask: imported); edit.title += " · Title edited"
            _ = await store.save(edit)
            guard let saved = store.tasks.first(where: { $0.id == imported.id }) else { throw Failure(description: "Edited imported task missing") }
            try require(saved.timeZone == "America/New_York" && saved.dueAt == imported.dueAt && saved.scheduledStart == imported.scheduledStart && saved.scheduledEnd == imported.scheduledEnd, "Real service title edit changed imported timezone/date strings: \(store.actionError ?? "")")
        }
        print("✓ New York spring/fall DST and all-day events: title edits preserve original time zones and date strings")
        let reloaded = BoardStore(appearance: appearance); await reloaded.reload(force: true)
        try require(reloaded.tasks.count == 3 + foreignSchedules.count, "Tasks did not persist")
        print("✓ Actual Rust service: projects, parent/subtasks, deadlines/meetings, today’s schedule, runs, history, attachments, completion, and reload verified")
    }
    @MainActor static func linearWorkflowAndDeletion(_ executable: String) async throws {
        let directory = URL(fileURLWithPath: "/tmp/wbdel-\(UUID().uuidString.prefix(8))")
        let suite = "workboard-deletion-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "No test defaults") }
        let service = try await startService(executable, directory: directory)
        defer { if service.isRunning { service.terminate() }; service.waitUntilExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let appearance = AppearanceSettings(defaults: defaults); appearance.executablePath = executable; appearance.dataDirectory = directory.path
        let store = BoardStore(appearance: appearance)
        await store.reload(force: true)
        _ = await store.createProject(name: "Linear workflow", directory: directory.path)
        guard let project = store.projects.first else { throw Failure(description: "No project: \(store.actionError ?? "")") }
        store.newTask(status: .backlog)
        guard var parked = store.draft else { throw Failure(description: "Backlog column did not open a draft") }
        try require(parked.status == .backlog, "Backlog draft started in \(parked.status)")
        parked.title = "Parked idea"; _ = await store.save(parked)
        guard let idea = store.tasks.first(where: { $0.title == "Parked idea" }) else { throw Failure(description: "Backlog task missing: \(store.actionError ?? "")") }
        try require(idea.status == .backlog && !idea.ready, "Backlog task was \(idea.status), ready \(idea.ready)")
        store.newTask(status: .review)
        try require(store.draft?.status == .todo, "A review column draft did not fall back to Todo")
        store.draft = nil
        await store.move(idea, to: .canceled)
        guard let canceled = store.tasks.first(where: { $0.id == idea.id }), canceled.status == .canceled else { throw Failure(description: "Cancel failed: \(store.actionError ?? "")") }
        try require(!canceled.isOverdue, "Canceled task reported as overdue")
        await store.move(canceled, to: .inProgress)
        try require(store.tasks.first(where: { $0.id == idea.id })?.status == .inProgress, "Canceled task did not reopen and start: \(store.actionError ?? "")")
        var parent = TaskDraft(projectID: project.id); parent.title = "Parent with subtasks"; _ = await store.save(parent)
        guard let root = store.tasks.first(where: { $0.title == parent.title }) else { throw Failure(description: "Parent missing") }
        var child = TaskDraft(projectID: project.id, parentID: root.id); child.title = "Child"; _ = await store.save(child)
        guard let firstChild = store.children(of: root).first else { throw Failure(description: "Child missing") }
        var grandchild = TaskDraft(projectID: project.id, parentID: firstChild.id); grandchild.title = "Grandchild"; _ = await store.save(grandchild)
        try require(store.descendants(of: root).count == 2, "Descendants should include the grandchild")
        await store.openTask(root.id)
        guard let stale = store.tasks.first(where: { $0.id == root.id }) else { throw Failure(description: "Root missing") }
        var renamed = TaskDraft(projectID: project.id, editingTask: stale); renamed.title = "Renamed elsewhere"; _ = await store.save(renamed)
        let refused = await store.delete(stale)
        try require(!refused && store.tasks.contains(where: { $0.id == root.id }) && store.actionError != nil, "A stale delete was not refused")
        store.actionError = nil
        guard let current = store.tasks.first(where: { $0.id == root.id }) else { throw Failure(description: "Root disappeared after refusal") }
        store.requestDelete(current)
        try require(store.deletionTask?.id == root.id, "Delete confirmation was not requested")
        let deleted = await store.delete(current)
        try require(deleted && store.notice == "Task and 2 subtasks moved to Trash.", "Delete failed: \(store.actionError ?? store.notice ?? "")")
        try require(!store.tasks.contains(where: { [root.id, firstChild.id].contains($0.id) }) && store.tasks.count == 1, "Deleted tasks remain on the board")
        try require(store.selectedTaskID == nil && store.detail == nil, "Details of the deleted task stayed open")
        try require(store.trash.count == 1 && store.trash.first?.subtaskCount == 2 && store.trashedTaskCount == 3, "Trash did not list the deletion")
        try require(store.undoDeletion == UndoDeletion(notice: "Task and 2 subtasks moved to Trash.", taskID: root.id), "Undo was not offered")
        guard let undo = store.undoDeletion else { throw Failure(description: "No undo") }
        let undone = await store.restore(undo.taskID)
        try require(undone && store.undoDeletion == nil, "Undo failed: \(store.actionError ?? "")")
        try require(store.trash.isEmpty && store.descendants(of: store.tasks.first { $0.id == root.id }!).count == 2 && store.notice == "Task and 2 subtasks restored.", "Undo did not restore the subtree")
        guard let back = store.tasks.first(where: { $0.id == root.id }), let backChild = store.children(of: back).first else { throw Failure(description: "Restored tasks missing") }
        _ = await store.delete(backChild)
        _ = await store.delete(back)
        try require(store.trash.count == 2, "Separate deletions did not stay separate")
        guard let parentItem = store.trash.first(where: { $0.task.id == root.id }), let childItem = store.trash.first(where: { $0.task.id == backChild.id }) else { throw Failure(description: "Trash items missing") }
        try require(!childItem.restorable && childItem.parentInTrash == "Renamed elsewhere", "A subtask whose parent is in the trash looked restorable")
        try require(store.purgeCount(parentItem) == 3, "Purge count \(store.purgeCount(parentItem)) did not include the earlier subtask deletion")
        let purged = await store.purge(parentItem)
        try require(purged && store.trash.isEmpty && store.notice == "Deleted permanently.", "Purge failed: \(store.actionError ?? "")")
        guard let remaining = store.tasks.first else { throw Failure(description: "No remaining task") }
        _ = await store.delete(remaining)
        store.selectedProjectID = BoardStore.trashScope
        try require(store.isTrashView && store.trashedTaskCount == 1, "Trash scope missing")
        await store.reload(force: true)
        try require(store.selectedProjectID == BoardStore.trashScope, "Reload left the Trash view")
        let emptied = await store.emptyTrash()
        try require(emptied && store.trash.isEmpty && store.tasks.isEmpty, "Empty Trash failed: \(store.actionError ?? "")")
        print("✓ Actual service: Backlog column drafts, cancel and reopen, stale delete refusal, Trash with undo, restore, permanent delete, and Empty Trash")
    }
    @MainActor static func startService(_ executable: String, directory: URL) async throws -> Process {
        let service = Process(); service.executableURL = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("workboard-service")
        service.arguments = ["--data-dir", directory.path, "--socket", directory.appendingPathComponent("workboard.sock").path]
        var environment = ProcessInfo.processInfo.environment; environment.removeValue(forKey: "WORKBOARD_WIDGET_SNAPSHOT"); service.environment = environment
        service.standardOutput = FileHandle.nullDevice; service.standardError = FileHandle.nullDevice; try service.run()
        for _ in 0..<100 {
            if !service.isRunning { service.waitUntilExit(); throw Failure(description: "Temporary service exited during start") }
            if canConnectSocket(directory.appendingPathComponent("workboard.sock").path) { return service }
            try await Task.sleep(for: .milliseconds(20))
        }
        service.terminate(); service.waitUntilExit(); throw Failure(description: "Temporary service did not create its socket")
    }
    static func canConnectSocket(_ path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 } }
    }
    @MainActor static func connectionSwitchRecoveryAndPluginConfig(_ executable: String) async throws {
        let suffix = String(UUID().uuidString.prefix(8)), directoryA = URL(fileURLWithPath: "/tmp/wb-a-\(UUID().uuidString.prefix(8))"), directoryB = URL(fileURLWithPath: "/tmp/wb-b-\(UUID().uuidString.prefix(8))")
        let suite = "workboard-connections-\(suffix)", defaults = UserDefaults(suiteName: "workboard-connections-\(suffix)")!
        var services: [Process] = []
        defer {
            for service in services { if service.isRunning { service.terminate() }; service.waitUntilExit() }
            defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directoryA); try? FileManager.default.removeItem(at: directoryB)
        }
        services.append(try await startService(executable, directory: directoryA)); services.append(try await startService(executable, directory: directoryB))
        let client = WorkboardClient()
        let configA = ConnectionConfiguration(executablePath: executable, dataDirectory: directoryA.path, sharesWidgetSnapshot: false)
        let configB = ConnectionConfiguration(executablePath: executable, dataDirectory: directoryB.path, sharesWidgetSnapshot: false)
        var taskBID = ""
        for (name, config) in [("Board A", configA), ("Board B", configB)] {
            let project = try await client.call("project.create", params: ["name": .string(name)], configuration: config)
            let created = try await client.call("task.create", params: ["project_id": project["project_id"], "title": .string(name + " task")], configuration: config)
            if name == "Board B" { taskBID = created["task_id"].string ?? "" }
        }
        let snapshotA = try await client.call("board.snapshot", configuration: configA), snapshotB = try await client.call("board.snapshot", configuration: configB)
        try require(snapshotA["event_sequence"] == snapshotB["event_sequence"], "Connection fixtures need equal event sequences")
        let gate = directoryA.appendingPathComponent("cli-gate"), outage = directoryA.appendingPathComponent("outage"), delayed = directoryA.appendingPathComponent("delay"), gateStarted = directoryA.appendingPathComponent("gate-started")
        func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // The gate holds a chosen real CLI request until released; it never fabricates board data.
        let script = """
        #!/bin/sh
        if [ -f \(quote(outage.path)) ]; then
          printf '%s\\n' '{"ok":false,"error":{"code":"SERVICE_UNAVAILABLE","message":"Test service stopped"}}'
          exit 1
        fi
        previous=''
        method=''
        for argument in "$@"; do
          if [ "$previous" = rpc ]; then method="$argument"; break; fi
          previous="$argument"
        done
        if [ "$(cat \(quote(delayed.path)) 2>/dev/null)" = "$method" ]; then
          printf '%s' "$method" > \(quote(gateStarted.path))
          while [ "$(cat \(quote(delayed.path)) 2>/dev/null)" = "$method" ]; do sleep 0.02; done
        fi
        exec \(quote(executable)) "$@"
        """
        try script.write(to: gate, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gate.path)
        func holdGate(_ method: String) throws {
            try? FileManager.default.removeItem(at: gateStarted)
            try method.write(to: delayed, atomically: true, encoding: .utf8)
        }
        func waitForGate(_ method: String) async throws {
            for _ in 0..<100 {
                if (try? String(contentsOf: gateStarted, encoding: .utf8)) == method { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw Failure(description: "Real CLI did not reach delayed \(method)")
        }
        func waitForBoard(_ title: String) async throws {
            for _ in 0..<100 {
                if store.tasks.first?.title == title && !store.isLoading { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw Failure(description: "Queued board did not finish loading: \(title)")
        }
        func requireInvalidated() throws {
            try require(store.projects.isEmpty && store.tasks.isEmpty && store.selectedProjectID == nil && store.selectedTaskID == nil && store.detail == nil && store.draft == nil && store.completionTask == nil && !store.showingNewProject && store.lastUpdated == nil && store.isLoading, "Connection switch retained a visible/editable old board while a real request was pending")
        }
        let appearance = AppearanceSettings(defaults: defaults); appearance.executablePath = gate.path; appearance.dataDirectory = directoryA.path
        let store = BoardStore(appearance: appearance); await store.reload()
        try require(store.tasks.first?.title == "Board A task", "Board A did not load")
        if let task = store.tasks.first { await store.openTask(task.id) }
        appearance.dataDirectory = directoryB.path; await store.reload()
        try require(store.tasks.count == 1 && store.tasks.first?.title == "Board B task" && store.selectedTaskID == nil && store.detail == nil, "Equal-sequence board switch kept old tasks or selection")
        let oldService = services[1]; oldService.terminate(); oldService.waitUntilExit()
        try Data().write(to: outage); await store.reload()
        try require(store.connectionError != nil, "Outage did not reach the existing Store")
        services.append(try await startService(executable, directory: directoryB))
        _ = try await client.call("task.update", params: ["task_id": .string(taskBID), "expected_revision": .number(1), "title": .string("Task changed after restart")], configuration: configB)
        try FileManager.default.removeItem(at: outage); await store.reload()
        try require(store.connectionError == nil && store.tasks.first?.title == "Task changed after restart", "Same Store did not recover after service restart")
        await store.openTask(taskBID)
        guard let selectedB = store.selectedTask else { throw Failure(description: "No selected task before delayed switch") }
        store.draft = TaskDraft(projectID: selectedB.projectID, editingTask: selectedB); store.completionTask = selectedB; store.showingNewProject = true
        try holdGate("board.snapshot")
        let oldSnapshot = Task { await store.reload() }
        try await waitForGate("board.snapshot")
        appearance.dataDirectory = directoryA.path
        try requireInvalidated() // The settings setter itself must clear the old UI before another reload starts.
        await store.reload(); try requireInvalidated()
        try FileManager.default.removeItem(at: delayed)
        await oldSnapshot.value
        try await waitForBoard("Board A task")
        appearance.dataDirectory = directoryB.path; await store.reload()
        await store.openTask(taskBID)
        try holdGate("task.get")
        let oldDetailReload = Task { await store.reload(force: true) }
        try await waitForGate("task.get") // The first snapshot identity check has already passed.
        appearance.dataDirectory = directoryA.path; try requireInvalidated()
        try holdGate("board.snapshot") // Release the old detail, but hold the queued new snapshot.
        await oldDetailReload.value
        try await waitForGate("board.snapshot")
        try requireInvalidated() // A stale post-detail continuation must not restore lastUpdated or selection.
        try FileManager.default.removeItem(at: delayed)
        try await waitForBoard("Board A task")
        appearance.dataDirectory = directoryB.path; await store.reload(); await store.openTask(taskBID)
        try holdGate("task.get")
        let returningConnection = Task { await store.reload(force: true) }
        try await waitForGate("task.get")
        appearance.dataDirectory = directoryA.path; appearance.dataDirectory = directoryB.path
        try requireInvalidated()
        try holdGate("board.snapshot"); await returningConnection.value
        try await waitForGate("board.snapshot"); try requireInvalidated()
        try FileManager.default.removeItem(at: delayed)
        try await waitForBoard("Task changed after restart")
        print("✓ Actual DB switching at the same sequence, immediate list/editor invalidation during delayed reads, stale context rejection after await, and service restart recovery")

        let backup = directoryB.appendingPathComponent("clone.sqlite3")
        _ = try await client.call("backup.create", params: ["path": .string(backup.path)], configuration: configB)
        _ = try await client.call("backup.restore", params: ["path": .string(backup.path)], configuration: configA)
        let clone = try await client.call("task.get", params: ["task_id": .string(taskBID)], configuration: configA)
        let source = try await client.call("task.get", params: ["task_id": .string(taskBID)], configuration: configB)
        _ = try await client.call("task.update", params: ["task_id": .string(taskBID), "expected_revision": source["task"]["revision"], "title": .string("Original clone B task")], configuration: configB)
        appearance.dataDirectory = directoryB.path; await store.reload()
        guard let sourceTask = store.tasks.first else { throw Failure(description: "Cloned task fixture missing") }
        try require(sourceTask.id == clone["task"]["id"].string && sourceTask.revision == clone["task"]["revision"].int, "Clone regression needs the same task ID and revision in two real databases")
        await store.openTask(sourceTask.id)
        var staleDraft = TaskDraft(projectID: sourceTask.projectID, editingTask: sourceTask); staleDraft.title = "Old edit leaked into the new DB"
        store.draft = staleDraft; store.completionTask = sourceTask
        try holdGate("board.snapshot")
        let clonedSnapshot = Task { await store.reload() }
        try await waitForGate("board.snapshot")
        appearance.dataDirectory = directoryA.path; try requireInvalidated()
        let staleSaved = await store.save(staleDraft)
        try require(!staleSaved && !store.isMutating, "Old editor sent a write to a newly selected cloned database")
        try requireInvalidated()
        let unchangedClone = try await client.call("task.get", params: ["task_id": .string(taskBID)], configuration: configA)
        try require(unchangedClone["task"] == clone["task"], "Blocked old editor changed the real cloned task")
        try FileManager.default.removeItem(at: delayed); await clonedSnapshot.value
        try await waitForBoard(clone["task"]["title"].string ?? "")
        print("✓ Actual cloned DB with identical IDs/revisions: stale saves rejected during connection switching and original tasks preserved")
        let package = directoryA.appendingPathComponent("workspace-package"), invoked = directoryA.appendingPathComponent("provider-invoked")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest: JSONValue = .object(["id": .string("google-workspace"), "name": .string("Configuration fixture"), "version": .string("1.0.0"), "protocol_version": .number(1), "executable": .string("provider.sh"), "methods": .array([.string("check")])])
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("plugin.json"))
        let provider = package.appendingPathComponent("provider.sh")
        try "#!/bin/sh\ntouch \(quote(invoked.path))\nexit 1\n".write(to: provider, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: provider.path)
        let plugins = PluginStore()
        guard await plugins.call("plugin.install", params: ["path": .string(package.path)], configuration: configB) != nil else { throw Failure(description: plugins.error ?? "Plugin fixture install failed") }
        let saved: JSONValue = .object(["calendar_enabled": .bool(false), "gmail_enabled": .bool(true), "account": .string("work-mail"), "credentials_file": .string("/custom/client.json"), "unshown_setting": .object(["retain": .string("original")])])
        guard await plugins.call("plugin.enable", params: ["id": .string("google-workspace"), "config": saved], configuration: configB) != nil else { throw Failure(description: plugins.error ?? "Plugin fixture enable failed") }
        _ = await plugins.call("plugin.disable", params: ["id": .string("google-workspace")], configuration: configB)
        guard let loaded = await plugins.call("plugin.config", params: ["id": .string("google-workspace")], configuration: configB) else { throw Failure(description: plugins.error ?? "Disabled plugin config read failed") }
        let editor = PluginConfigurationDraft(config: loaded["config"])
        try require(editor.gmailEnabled && !editor.calendarEnabled && editor.account == "work-mail" && editor.credentialsFile == "/custom/client.json", "Real saved settings did not reopen correctly")
        _ = await plugins.call("plugin.enable", params: try editor.enableParameters(for: "google-workspace"), configuration: configB)
        guard let reopened = await plugins.call("plugin.config", params: ["id": .string("google-workspace")], configuration: configB) else { throw Failure(description: plugins.error ?? "Plugin config reread failed") }
        try require(reopened["config"] == saved && !FileManager.default.fileExists(atPath: invoked.path), "Unchanged plugin save reset config or invoked provider")
        var edited = PluginConfigurationDraft(config: reopened["config"]); edited.credentialsFile = "/changed/client.json"
        _ = await plugins.call("plugin.enable", params: try edited.enableParameters(for: "google-workspace"), configuration: configB)
        guard let final = await plugins.call("plugin.config", params: ["id": .string("google-workspace")], configuration: configB) else { throw Failure(description: plugins.error ?? "Final plugin config read failed") }
        try require(final["config"]["unshown_setting"] == saved["unshown_setting"] && final["config"]["gmail_enabled"].bool == true && final["config"]["account"].string == "work-mail" && final["config"]["credentials_file"].string == "/changed/client.json", "Editing visible settings lost unshown config/service/account values")
        print("✓ Actual plugin.config: disabled Workspace configuration reload, Gmail/account preservation, unknown-key merging, and no provider execution")

        // Exercise the app's request IDs through the real Rust host journal, without Slack access.
        let slackPackage = directoryB.appendingPathComponent("slack-package"), sends = directoryB.appendingPathComponent("fake-slack-sends")
        try FileManager.default.createDirectory(at: slackPackage, withIntermediateDirectories: true)
        let slackManifest: JSONValue = .object(["id": .string("slack"), "name": .string("Slack fixture"), "version": .string("0.1.0"), "protocol_version": .number(1), "executable": .string("provider.sh"), "methods": .array([.string("tasks.send")]), "task_context_methods": .array([.string("tasks.send")])])
        try JSONEncoder().encode(slackManifest).write(to: slackPackage.appendingPathComponent("plugin.json"))
        let fakeProvider = slackPackage.appendingPathComponent("provider.sh")
        try "#!/bin/sh\nprintf 'sent\\n' >> \(quote(sends.path))\nprintf '%s\\n' '{\"ok\":true,\"result\":{\"sent\":true,\"channel_id\":\"C123\",\"ts\":\"1792034000.000123\"}}'\n".write(to: fakeProvider, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeProvider.path)
        _ = await plugins.call("plugin.install", params: ["path": .string(slackPackage.path)], configuration: configB)
        guard let enabled = await plugins.call("plugin.enable", params: ["id": .string("slack")], configuration: configB), let slack = InstalledPlugin(enabled) else { throw Failure(description: plugins.error ?? "Slack fixture enable failed") }
        let detailB = try await client.call("task.get", params: ["task_id": .string(taskBID)], configuration: configB)
        guard let taskB = BoardTask(detailB["task"]) else { throw Failure(description: "Missing Slack test task") }
        appearance.executablePath = gate.path; appearance.dataDirectory = directoryB.path
        let slackSession = PluginSession(configuration: appearance.connection); slackSession.bind(appearance)
        let operation = SlackStatusSend(task: taskB, channelID: "C123", configuration: slackSession.configuration)
        try require(!operation.matches(task: taskB, channelID: "COTHER", configuration: slackSession.configuration) && !operation.matches(task: taskB, channelID: "C123", configuration: configA), "An old send accepted a different destination or board")
        let response = await plugins.run(slack, method: "tasks.send", params: operation.parameters, configuration: slackSession.configuration, requestID: operation.requestID)
        let retry = await plugins.run(slack, method: "tasks.send", params: operation.parameters, configuration: slackSession.configuration, requestID: operation.requestID)
        try require(response?["sent"].bool == true && retry == response, "Swift request-ID retry did not replay the original send receipt")
        func sendCount() -> Int { ((try? String(contentsOf: sends, encoding: .utf8)) ?? "").split(separator: "\n").count }
        try require(sendCount() == 1, "Swift retry repeated an external send")
        try holdGate("plugin.run")
        let delayedSend = Task { await plugins.run(slack, method: "tasks.send", params: operation.parameters, configuration: slackSession.configuration, requestID: UUID().uuidString, isCurrent: { slackSession.isCurrent(appearance) }) }
        try await waitForGate("plugin.run")
        appearance.dataDirectory = directoryA.path; appearance.dataDirectory = directoryB.path
        try require(!slackSession.isCurrent(appearance), "Returning to the same board revived an invalidated Slack session")
        try FileManager.default.removeItem(at: delayed)
        let staleResult = await delayedSend.value
        try require(staleResult == nil && plugins.error == nil && sendCount() == 2, "A late Slack response reached the new session or targeted a different board")
        let blocked = await plugins.run(slack, method: "tasks.send", params: operation.parameters, configuration: slackSession.configuration, isCurrent: { slackSession.isCurrent(appearance) })
        try require(blocked == nil && sendCount() == 2, "An invalidated Slack session started an external send")
        slackSession.close()

        // Simulate a provider that writes but loses the response; the UI must reuse the pending ID.
        let installedProvider = directoryB.appendingPathComponent("plugins/slack/provider.sh")
        try "#!/bin/sh\nprintf 'sent\\n' >> \(quote(sends.path))\nprintf '%s\\n' '{\"ok\":false,\"error\":{\"code\":\"INTEGRATION_UNAVAILABLE\",\"message\":\"test response lost\"}}'\n".write(to: installedProvider, atomically: true, encoding: .utf8)
        let uncertain = SlackStatusSend(task: taskB, channelID: "C123", configuration: configB)
        _ = await plugins.run(slack, method: "tasks.send", params: uncertain.parameters, configuration: configB, requestID: uncertain.requestID)
        let repeated = await plugins.run(slack, method: "tasks.send", params: uncertain.parameters, configuration: configB, requestID: uncertain.requestID)
        try require(repeated == nil && sendCount() == 3 && (plugins.error?.contains("uncertain") ?? false), "A failed Swift send was repeated instead of reporting its uncertain result")
        print("✓ Slack Swift→actual CLI: request ID reuse, no duplicate sends after lost responses, A→B→A connection switching, and delayed response rejection")
    }
}
