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
        try slackContract()
        try linearContract()
        try await rpcArgumentsAndErrors()
        if let executable = ProcessInfo.processInfo.environment["WORKBOARD_BIN"], !executable.isEmpty {
            try await actualService(executable)
            try await connectionSwitchRecoveryAndPluginConfig(executable)
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
        guard let task = BoardTask(.object(["id": .string("task-1"), "project_id": .string("project-1"), "revision": .number(4)])) else { throw Failure(description: "Board task did not decode") }
        let comment = issue.writeParameters(task: task)
        try require(comment["task_id"] == .string("task-1") && comment["expected_revision"] == .number(4) && comment["confirmed_by_user"] == .bool(true) && comment["workspace"] == json["workspace"], "Linear comment lost the host task or confirmation")
        try require(comment["expected_version"] == nil && comment["state_id"] == nil, "Linear comment carried state-change fields")
        let change = issue.writeParameters(task: task, stateID: "s-done")
        try require(change["state_id"] == .string("s-done") && change["expected_version"] == json["version"], "Linear state change lost its target or read version")
        print("✓ Linear configuration, issue identity, source versions, links, write parameters, and state suggestions verified")
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
