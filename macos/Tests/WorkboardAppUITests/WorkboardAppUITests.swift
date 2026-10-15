import XCTest
import AppKit

/// Drives the real app window against an isolated board, socket and settings suite.
/// The user's board, preferences and shared widget snapshot are never touched.
@MainActor
final class WorkboardAppUITests: XCTestCase {
    private static let defaultsSuite = "local.agentworkboard.uitests"
    private var dataDirectory: URL!
    private var socket: String!
    private var app: XCUIApplication!

    /// Debug/WorkboardAppUITests-Runner.app/Contents/PlugIns/WorkboardAppUITests.xctest → Debug/WorkboardApp.app
    private var appBundle: URL {
        var url = Bundle(for: Self.self).bundleURL
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("WorkboardApp.app")
    }
    private var cliExecutable: URL { appBundle.appendingPathComponent("Contents/Helpers/workboard") }

    override func setUp() async throws {
        continueAfterFailure = false
        dataDirectory = URL(fileURLWithPath: "/tmp/wbui-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        socket = dataDirectory.appendingPathComponent("s.sock").path
        UserDefaults(suiteName: Self.defaultsSuite)?.removePersistentDomain(forName: Self.defaultsSuite)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cliExecutable.path), "Bundled CLI missing: \(cliExecutable.path)")
        app = XCUIApplication()
        app.launchEnvironment = [
            "WORKBOARD_DATA_DIR": dataDirectory.path,
            "WORKBOARD_SOCKET": socket,
            "WORKBOARD_DEFAULTS_SUITE": Self.defaultsSuite,
        ]
    }

    override func tearDown() async throws {
        app?.terminate()
        stopService()
        if let dataDirectory { try? FileManager.default.removeItem(at: dataDirectory) }
        UserDefaults(suiteName: Self.defaultsSuite)?.removePersistentDomain(forName: Self.defaultsSuite)
    }

    // MARK: - MVP 1 and 3: CLI tasks and status changes appear in the native window

    func testCLITaskAppearsAndFollowsCLIStatusChanges() throws {
        let project = try createProject("UI verification")
        let task = try cli(["task", "add", "--project", project, "--title", "Task created from the CLI"])["task_id"] as! String
        launch()
        let card = element("task.\(task)")
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The CLI task card did not appear in the window")
        XCTAssertTrue(card.label.contains("To do"))

        try cli(["task", "start", task, "--agent", "agent-ui"])
        waitFor(card, label: "In progress")
        XCTAssertTrue(card.label.contains("agent-ui"), "The assignee did not appear on the card: \(card.label)")

        try cli(["task", "review", task, "--agent", "agent-ui", "--summary", "Request review"])
        waitFor(card, label: "Review")
    }

    // MARK: - Native drag: move cards between columns and record the outcome

    func testDragCardAcrossColumnsAndCompleteWithSummary() throws {
        let project = try createProject("Drag verification")
        let task = try cli(["task", "add", "--project", project, "--title", "Task to drag"])["task_id"] as! String
        launch()
        let card = element("task.\(task)")
        XCTAssertTrue(card.waitForExistence(timeout: 15))

        drag(card, to: "column.review")
        try waitForStatus(task, "review")
        waitFor(card, label: "Review")

        drag(card, to: "column.done")
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The outcome confirmation window did not open")
        sheet.textViews.firstMatch.click()
        sheet.textViews.firstMatch.typeText("Reviewed and completed by dragging")
        sheet.buttons["Mark done"].click()
        try waitForStatus(task, "done")
        let detail = try cli(["task", "show", task])
        XCTAssertEqual((detail["task"] as? [String: Any])?["completion_summary"] as? String, "Reviewed and completed by dragging")
    }

    // MARK: - MVP 9: create parent tasks and subtasks, manage assignees and completion counts

    func testCreateTaskAndSubtaskInAppAndManageSubtask() throws {
        let project = try createProject("Subtask verification")
        launch()
        XCTAssertTrue(element("column.todo").waitForExistence(timeout: 15))

        app.typeKey("n", modifierFlags: .command)
        var sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The new task window did not open")
        sheet.typeText("Parent task created in the app")
        sheet.buttons["Create task"].click()
        let parent = try waitForTask(titled: "Parent task created in the app", project: project)

        let card = element("task.\(parent)")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.rightClick()
        app.menuItems["Add subtask"].click()
        sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The subtask window did not open")
        XCTAssertTrue(sheet.staticTexts["Create subtask"].exists)
        sheet.typeText("Subtask created in the app")
        sheet.buttons["Create task"].click()
        let child = try waitForTask(titled: "Subtask created in the app", project: project)
        XCTAssertEqual(try cli(["task", "show", child])["task"].flatMap { ($0 as? [String: Any])?["parent_id"] as? String }, parent)

        // Read completion counts in parent details, then open a subtask and assign it.
        card.click()
        XCTAssertTrue(app.staticTexts["0/1"].waitForExistence(timeout: 10), "The parent’s subtask completion count is not visible")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Subtask created in the app")).firstMatch.click()
        // Only subtask details contain a link back to the parent task.
        let parentLink = app.buttons["Parent task created in the app"]
        XCTAssertTrue(parentLink.waitForExistence(timeout: 10), "Subtask details did not open")
        app.buttons["Assign task"].firstMatch.click()
        sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let agent = sheet.textFields.firstMatch
        agent.doubleClick()
        agent.typeKey("a", modifierFlags: .command)
        agent.typeText("codex-ui")
        sheet.buttons["Assign task"].click()
        try waitUntil("Assign subtask") { try self.task(child)["assignee"] as? String == "codex-ui" }

        // Start the subtask from the details status menu. Its assignee becomes the run actor.
        app.menuButtons["To do"].firstMatch.click()
        app.menuItems["In progress"].click()
        try waitForStatus(child, "in_progress")

        // Attach a URL to the subtask through the artifact attachment window.
        app.buttons["Add artifacts and links"].click()
        sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The artifact attachment window did not open")
        sheet.textFields.firstMatch.click()
        sheet.textFields.firstMatch.typeText("https://example.com/subtask-result")
        sheet.buttons["Connection"].click()
        try waitUntil("Attach subtask artifact") {
            let artifacts = try self.cli(["task", "show", child])["artifacts"] as? [[String: Any]] ?? []
            return artifacts.contains { $0["path"] as? String == "https://example.com/subtask-result" && $0["kind"] as? String == "url" }
        }

        // Completing a subtask does not complete its parent.
        try cli(["task", "complete", child, "--agent", "codex-ui", "--summary", "Complete subtask"])
        parentLink.click()
        XCTAssertTrue(app.staticTexts["1/1"].waitForExistence(timeout: 10), "The subtask completion count did not change to 1/1")
        XCTAssertEqual(try task(parent)["status"] as? String, "todo")
    }

    // MARK: - MVP 4: handle CLI requests with the window closed and restore after service/app restart

    func testClosingWindowKeepsCLIWorkingAndRelaunchRestores() throws {
        let project = try createProject("Restart verification")
        launch()
        XCTAssertTrue(element("column.todo").waitForExistence(timeout: 15))
        app.windows["board"].buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.windows["board"].waitForNonExistence(timeout: 5), "The board window did not close")
        XCTAssertNotEqual(app.state, .notRunning, "The app exited when its window was closed")

        let task = try cli(["task", "add", "--project", project, "--title", "Task created while the window was closed"])["task_id"] as! String
        app.terminate()
        stopService()
        XCTAssertEqual(try cli(["task", "show", task])["task"].flatMap { ($0 as? [String: Any])?["title"] as? String }, "Task created while the window was closed")

        launch()
        XCTAssertTrue(element("task.\(task)").waitForExistence(timeout: 15), "The task was not restored after relaunch")
    }

    // MARK: - MVP 12: restore themes after relaunch; export and import through native file pickers

    func testThemePersistsAcrossRelaunchAndRoundTripsThroughFilePanels() throws {
        _ = try createProject("Theme verification")
        launch()
        openSettings()
        app.buttons["Dark theme"].click()
        app.buttons["Forest"].click()
        try waitUntil("Save theme") { self.storedTheme()?["appearance"] as? String == "dark" && self.storedTheme()?["accentHex"] as? String == "39836B" }

        app.terminate()
        launch()
        openSettings()
        XCTAssertTrue(app.buttons["Dark theme"].isSelected, "Dark theme was not selected after relaunch")
        XCTAssertTrue(app.buttons["Forest"].isSelected, "The accent color was not restored after relaunch")

        // Export: select a directory in the real save dialog.
        let exportURL = dataDirectory.appendingPathComponent("workboard-theme.json")
        app.buttons["Export theme…"].click()
        chooseInFilePanel(path: dataDirectory.path, confirm: "Save")
        try waitUntil("Export theme file") { FileManager.default.fileExists(atPath: exportURL.path) }
        var exported = try JSONSerialization.jsonObject(with: Data(contentsOf: exportURL)) as! [String: Any]
        XCTAssertEqual(exported["accentHex"] as? String, "39836B")
        dismissThemeAlert()

        // Import: select another user’s theme file in the real open dialog.
        exported["name"] = "Imported theme"; exported["accentHex"] = "9972C4"; exported["appearance"] = "light"
        let importURL = dataDirectory.appendingPathComponent("shared-theme.json")
        try JSONSerialization.data(withJSONObject: exported).write(to: importURL)
        app.buttons["Import theme…"].click()
        chooseInFilePanel(path: importURL.path, confirm: "Open")
        dismissThemeAlert()
        try waitUntil("Import theme") { self.storedTheme()?["accentHex"] as? String == "9972C4" && self.storedTheme()?["name"] as? String == "Imported theme" }
        XCTAssertTrue(app.buttons["Light theme"].isSelected)
    }

    // MARK: - MVP 6: back up and export Markdown through the app menu and real save dialog

    func testBackupAndMarkdownExportThroughAppPanels() throws {
        let project = try createProject("Backup verification")
        try cli(["task", "add", "--project", project, "--title", "Task to preserve in backup"])
        launch()

        app.menuBarItems["Board"].click()
        app.menuItems["Create backup…"].click()
        chooseInFilePanel(path: dataDirectory.path, confirm: "Save")
        var backup: URL?
        try waitUntil("Create backup file") {
            backup = try FileManager.default.contentsOfDirectory(at: self.dataDirectory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("workboard-") && $0.pathExtension == "sqlite" }
            return backup != nil
        }
        let header = try FileHandle(forReadingFrom: XCTUnwrap(backup)).read(upToCount: 16)
        XCTAssertEqual(header.map { String(decoding: $0, as: UTF8.self) }, "SQLite format 3\u{0}", "The backup is not a SQLite database")

        app.menuBarItems["Board"].click()
        app.menuItems["Export as Markdown…"].click()
        chooseInFilePanel(path: dataDirectory.path, confirm: "Save")
        let markdown = dataDirectory.appendingPathComponent("workboard.md")
        try waitUntil("Markdown export") { FileManager.default.fileExists(atPath: markdown.path) }
        let content = try String(contentsOf: markdown, encoding: .utf8)
        XCTAssertTrue(content.contains("## Backup verification") && content.contains("### Task to preserve in backup"), "The exported Markdown does not contain the task")
    }

    // MARK: - Task links: workboard://task/<id> opens the corresponding task details

    func testTaskLinkOpensTaskDetail() async throws {
        let project = try createProject("Link verification")
        let task = try cli(["task", "add", "--project", project, "--title", "Task opened by a link", "--goal", "Check deep link"])["task_id"] as! String
        launch()
        XCTAssertTrue(element("task.\(task)").waitForExistence(timeout: 15))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Send the link to the app bundle under test instead of the LaunchServices default app.
        _ = try await NSWorkspace.shared.open([URL(string: "workboard://task/\(task)")!], withApplicationAt: appBundle, configuration: configuration)
        XCTAssertTrue(app.staticTexts["Task details"].waitForExistence(timeout: 10), "The link did not open task details")
        XCTAssertTrue(app.staticTexts["Check deep link"].waitForExistence(timeout: 10), "The linked task’s goal is not visible")
    }

    // MARK: - Helpers

    /// The columns render while the first snapshot is loading; actions are accepted only after it finishes.
    private func launch() {
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.staticTexts["Refresh"].waitForExistence(timeout: 15), "The board was not loaded from the service")
    }

    private func drag(_ card: XCUIElement, to column: String) {
        let target = element(column).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .click(forDuration: 0.5, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.6)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openSettings() {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Dark theme"].waitForExistence(timeout: 10), "The settings window did not open")
    }

    /// The settings alert reports each theme file result and blocks the window until confirmed.
    /// Its button is exposed only as a Touch Bar element, so Return confirms the default button.
    private func dismissThemeAlert() {
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeKey(.return, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    /// Uses the panel's Go to Folder field so the test never depends on the user's recent folders.
    private func chooseInFilePanel(path: String, confirm: String) {
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "The file picker did not open")
        XCTAssertTrue(app.buttons["OKButton"].waitForExistence(timeout: 5), "The file picker was not ready")
        app.typeKey("g", modifierFlags: [.command, .shift])
        let goTo = app.textFields["PathTextField"]
        XCTAssertTrue(goTo.waitForExistence(timeout: 5), "The Go to Folder field did not open")
        // Typing triggers path autocompletion between keystrokes; pasting enters the exact path.
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents(); pasteboard.setString(path, forType: .string)
        goTo.typeKey("a", modifierFlags: .command)
        goTo.typeKey("v", modifierFlags: .command)
        if let previous { pasteboard.clearContents(); pasteboard.setString(previous, forType: .string) }
        XCTAssertEqual(goTo.value as? String, path)
        goTo.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(goTo.waitForNonExistence(timeout: 5))
        let button = app.buttons["OKButton"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, "The file picker’s \(confirm) button was not enabled")
        button.click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 10), "The file picker did not close")
    }

    private func waitFor(_ card: XCUIElement, label: String, timeout: TimeInterval = 10) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", label), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, "Card status did not change to '\(label)': \(card.label)")
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    private func waitForStatus(_ id: String, _ status: String) throws {
        try waitUntil("Task status \(status)") { try self.task(id)["status"] as? String == status }
    }

    private func waitForTask(titled title: String, project: String) throws -> String {
        var found: String?
        try waitUntil("Create task '\(title)'") {
            let tasks = try self.cli(["task", "list", "--project", project])["tasks"] as? [[String: Any]] ?? []
            found = tasks.first { $0["title"] as? String == title }?["id"] as? String
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private func task(_ id: String) throws -> [String: Any] {
        try XCTUnwrap(try cli(["task", "show", id])["task"] as? [String: Any])
    }

    private func createProject(_ name: String) throws -> String {
        try XCTUnwrap(try cli(["project", "add", "--name", name])["project_id"] as? String)
    }

    private func storedTheme() -> [String: Any]? {
        guard let data = UserDefaults(suiteName: Self.defaultsSuite)?.data(forKey: "local.agentworkboard.appearance.v1") else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The same bundled CLI an agent would use, pointed at this test's isolated service.
    @discardableResult
    private func cli(_ arguments: [String]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = cliExecutable
        process.arguments = ["--data-dir", dataDirectory.path, "--socket", socket] + arguments + ["--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], "The CLI response is not JSON")
        guard envelope["ok"] as? Bool == true else {
            throw NSError(domain: "workboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(arguments): \(envelope["error"] ?? "unknown")"])
        }
        return envelope["result"] as? [String: Any] ?? [:]
    }

    private func stopService() {
        guard let dataDirectory, let socket else { return }
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "workboard-service --data-dir \(dataDirectory.path)"]
        try? kill.run(); kill.waitUntilExit()
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: socket), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    }
}
