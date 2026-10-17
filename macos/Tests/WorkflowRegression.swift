import Foundation
import AppKit
import Darwin

@main struct WorkflowRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(description: message) } }
    @MainActor static func main() async throws {
        try models()
        guard let executable = ProcessInfo.processInfo.environment["WORKBOARD_BIN"], executable.hasPrefix("/") else { throw Failure(description: "WORKBOARD_BIN must be the absolute isolated build CLI path") }
        try await service(executable)
        print("✓ Workflow Swift model and Store regression checks passed with the actual service (separate from native click validation)")
    }
    static func models() throws {
        let now = BoardDate.parseTimestamp("2026-10-15T12:00:00Z")!
        let json: JSONValue = .object(["id": .string("t"), "project_id": .string("p"), "title": .string("API verification"), "status": .string("todo"), "assignee": .string("codex"), "updated_at": .string("2026-10-01T12:00:00Z"), "ready": .bool(false), "dependency_ids": .array([.string("pre")]), "blocked_by": .array([.string("pre")]), "checklist": .array([.object(["id": .string("c"), "text": .string("Regression check"), "required": .bool(true), "checked": .bool(false), "evidence": .string("log")])])])
        guard let task = BoardTask(json) else { throw Failure(description: "Workflow task did not decode") }
        try check(task.isBlocked && !task.ready && task.incompleteRequirements.count == 1 && task.checklist.first?.evidence == "log", "Task dependency/checklist metadata lost")
        var filters = TaskFilters(); filters.projectID = "p"; filters.status = "todo"; filters.assignee = "codex"; filters.blockedOnly = true; filters.staleDays = 13; filters.query = "API"
        try check(filters.matches(task, now: now) && TaskFilters(filters.json) == filters, "Saved filter roundtrip or all conditions failed")
        filters.readyOnly = true; try check(!filters.matches(task, now: now), "Ready filter accepted blocked task")
        filters.readyOnly = false; filters.staleDays = 14; try check(!filters.matches(task, now: now), "stale_days must be a strict 24-hour threshold")
        filters.staleDays = nil; filters.assignee = "other"; try check(!filters.matches(task, now: now), "Assignee filter ignored")
        filters.assignee = ""; filters.unassignedOnly = true
        try check(!filters.matches(task, now: now) && TaskFilters(filters.json).unassignedOnly, "Unassigned filter lost explicit null")
        let child = BoardTask(.object(["id": .string("child"), "project_id": .string("p"), "parent_id": .string("t"), "title": .string("Child"), "status": .string("done")]))!
        let grandchild = BoardTask(.object(["id": .string("grandchild"), "project_id": .string("p"), "parent_id": .string("child"), "title": .string("Grandchild")]))!
        let definition = TaskTemplate.definition(from: task, tasks: [task, child, grandchild])
        try check(definition["children"].array.first?["children"].array.first?["title"].string == "Grandchild", "Template save flattened nested subtasks")
        try check(definition["assignee"] == .null && definition["status"] == .null && definition["checklist"].array.first?["checked"] == .null && definition["checklist"].array.first?["required"].bool == true, "Template copied runtime state or lost required flag")
        print("✓ Dependency/checklist models, combined filters, 24-hour stale boundary, and run state excluded from recursive templates")
        let automation = TaskAutomation(.object(["task_id": .string("t"), "state": .string("blocked"), "stage": .string("review"), "revision": .number(3), "attempts": .array([.object(["state": .string("superseded"), "worker_exited": .bool(false)])])]))
        let single = TaskAutomation(.object(["task_id": .string("t"), "state": .string("running"), "stage": .string("review"), "single_stage": .bool(true), "process": .object(["cursor": .number(0), "preset": .object(["steps": .array([.object(["title": .string("Implementation")])])])])]))
        try check(single?.title == "Review", "Single-stage action displayed an unrelated preset stage")
        try check(automation?.title == "Needs attention" && automation?.needsExitConfirmation == true && automation?.revision == 3, "Automation authority or display metadata lost")
    }
    @MainActor static func service(_ executable: String) async throws {
        let directory = URL(fileURLWithPath: "/tmp/wb-flow-\(UUID().uuidString.prefix(8))"), suite = "workboard-workflow-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!, process = Process()
        process.executableURL = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("workboard-service")
        process.arguments = ["--data-dir", directory.path, "--socket", directory.appendingPathComponent("workboard.sock").path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        for key in ["WORKBOARD_DATA_DIR", "WORKBOARD_SOCKET", "WORKBOARD_WIDGET_SNAPSHOT"] { environment.removeValue(forKey: key) }; process.environment = environment
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let appearance = AppearanceSettings(defaults: defaults); appearance.executablePath = executable; appearance.dataDirectory = directory.path
        let store = BoardStore(appearance: appearance), client = WorkboardClient()
        for _ in 0..<100 {
            if !process.isRunning { throw Failure(description: "Isolated service exited") }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("workboard.sock").path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await store.reload(force: true)
        try check(store.connectionError == nil && store.templates.count == 3, "Builtin templates did not load from snapshot: \(store.connectionError ?? "")")
        let createdProject = await store.createProject(name: "Workflow regression", directory: directory.path)
        try check(createdProject, "Project create failed")
        let project = store.projects[0]
        func task(_ id: String) throws -> BoardTask { guard let value = store.tasks.first(where: { $0.id == id }) else { throw Failure(description: "Task missing: \(id)") }; return value }
        func create(_ title: String) async throws -> BoardTask {
            var draft = TaskDraft(projectID: project.id); draft.title = title
            let saved = await store.save(draft); try check(saved, "Task create failed: \(store.actionError ?? "")")
            return store.tasks.first { $0.title == title }!
        }
        var fromTemplate = TaskDraft(projectID: project.id); fromTemplate.templateID = "builtin-feature"; fromTemplate.templateRevision = store.templates.first { $0.id == "builtin-feature" }?.revision; fromTemplate.title = "Feature created from a template"
        let applied = await store.save(fromTemplate); try check(applied, "Template selection did not apply: \(store.actionError ?? "")")
        guard let templated = store.tasks.first(where: { $0.title == fromTemplate.title }) else { throw Failure(description: "Applied root missing") }
        try check(!store.children(of: templated).isEmpty && templated.assignee == nil && templated.checklist.allSatisfy { !$0.checked }, "Applied template lost children or retained execution state")
        let predecessor = try await create("Prerequisite regression"), dependent = try await create("Dependent regression")
        let linked = await store.taskWorkflowMutation("task.dependency.add", task: dependent, fields: ["depends_on_id": .string(predecessor.id)])
        try check(linked && (try task(dependent.id)).blockedBy == [predecessor.id] && !(try task(dependent.id)).ready, "Adding dependency did not block work")
        let stale = await store.taskWorkflowMutation("task.dependency.remove", task: dependent, fields: ["depends_on_id": .string(predecessor.id)])
        try check(!stale && (try task(dependent.id)).dependencyIDs == [predecessor.id], "UI mutation omitted revision conflict protection")
        let prerequisiteCompleted = await store.complete(try task(predecessor.id), summary: "Prerequisite complete")
        try check(prerequisiteCompleted && (try task(dependent.id)).ready && (try task(dependent.id)).blockedBy.isEmpty, "Predecessor completion did not refresh readiness")
        let unlinked = await store.taskWorkflowMutation("task.dependency.remove", task: try task(dependent.id), fields: ["depends_on_id": .string(predecessor.id)])
        try check(unlinked && (try task(dependent.id)).dependencyIDs.isEmpty, "Dependency unlink failed")
        print("✓ Actual Store: prerequisite add/remove, revision conflicts, and readiness after prerequisite completion")
        let addedCheck = await store.taskWorkflowMutation("task.checklist.add", task: try task(dependent.id), fields: ["text": .string("Required verification"), "required": .bool(true)])
        try check(addedCheck, "Checklist add failed")
        let blockedCompletion = await store.complete(try task(dependent.id), summary: "Required item unchecked")
        try check(!blockedCompletion && (try task(dependent.id)).status != .done, "Unchecked requirement allowed completion")
        let itemID = try task(dependent.id).checklist[0].id
        let checklistSnapshot = try task(dependent.id), checklistContext = store.workflowContext
        _ = try await client.call("task.checklist.update", params: ["task_id": .string(dependent.id), "expected_revision": .number(Double(checklistSnapshot.revision)), "item_id": .string(itemID), "text": .string("Item edited in another window")], configuration: store.configuration)
        await store.reload(force: true)
        let staleChecklist = await store.taskWorkflowMutation("task.checklist.update", task: checklistSnapshot, fields: ["item_id": .string(itemID), "text": .string("Stale edit overwrote changes")], context: checklistContext)
        try check(!staleChecklist && (try task(dependent.id)).checklist[0].text == "Item edited in another window", "Checklist editor silently upgraded its captured revision")
        let updatedCheck = await store.taskWorkflowMutation("task.checklist.update", task: try task(dependent.id), fields: ["item_id": .string(itemID), "text": .string("Required regression passed"), "checked": .bool(true), "evidence": .string("/tmp/isolated-result.txt")])
        try check(updatedCheck && (try task(dependent.id)).incompleteRequirements.isEmpty && (try task(dependent.id)).checklist[0].evidence == "/tmp/isolated-result.txt", "Checklist edit/check/evidence lost")
        await store.move(try task(dependent.id), to: .inProgress); await store.move(try task(dependent.id), to: .review)
        let reviewSnapshot = try task(dependent.id), reviewContext = store.workflowContext
        _ = try await client.call("task.update", params: ["task_id": .string(dependent.id), "expected_revision": .number(Double(reviewSnapshot.revision)), "goal": .string("Goal changed externally during review")], configuration: store.configuration)
        await store.reload(force: true)
        let staleApproval = await store.taskWorkflowMutation("task.review.decide", task: reviewSnapshot, fields: ["decision": .string("approve"), "summary": .string("Approve stale content")], context: reviewContext)
        try check(!staleApproval && (try task(dependent.id)).status == .review, "Review editor approved an unseen new revision")
        let changes = await store.taskWorkflowMutation("task.review.decide", task: try task(dependent.id), fields: ["decision": .string("request_changes"), "summary": .string("Add error paths")])
        try check(changes && (try task(dependent.id)).status == .todo && (try task(dependent.id)).nextAction == "Add error paths", "Request changes transition failed")
        await store.move(try task(dependent.id), to: .inProgress); await store.move(try task(dependent.id), to: .review)
        let rejected = await store.taskWorkflowMutation("task.review.decide", task: try task(dependent.id), fields: ["decision": .string("reject"), "summary": .string("Completion criteria not met")])
        try check(rejected && (try task(dependent.id)).isBlocked, "Review rejection did not preserve reason")
        var unblocked = TaskDraft(projectID: project.id, editingTask: try task(dependent.id)); unblocked.blockedReason = ""; _ = await store.save(unblocked)
        await store.move(try task(dependent.id), to: .inProgress); await store.move(try task(dependent.id), to: .review)
        let approved = await store.taskWorkflowMutation("task.review.decide", task: try task(dependent.id), fields: ["decision": .string("approve"), "summary": .string("Check completion criteria")])
        await store.openTask(dependent.id)
        try check(approved && (try task(dependent.id)).status == .done && store.detail?.reviewDecisions.map(\.decision) == ["request_changes", "reject", "approve"], "Review approval or decision history lost")
        let removedCheck = await store.taskWorkflowMutation("task.checklist.remove", task: try task(dependent.id), fields: ["item_id": .string(itemID)])
        try check(removedCheck && (try task(dependent.id)).checklist.isEmpty, "Checklist deletion failed")
        print("✓ Actual required checklist creation/editing/checking/evidence/deletion, incomplete checklist guards, and review changes/rejection/approval history")
        let templateResult = await store.workflowMutation("template.save", params: ["name": .string("My hierarchical template"), "definition": TaskTemplate.definition(from: templated, tasks: store.tasks)])
        guard let templateID = templateResult?["template"]["id"].string, let template = store.templates.first(where: { $0.id == templateID }) else { throw Failure(description: "User template did not reload") }
        _ = try await client.call("template.save", params: ["id": .string(templateID), "expected_revision": .number(Double(template.revision)), "name": .string("Template edited in another window"), "definition": template.definition], configuration: store.configuration)
        let staleTemplateSave = await store.workflowMutation("template.save", params: ["id": .string(templateID), "expected_revision": .number(Double(template.revision)), "name": .string("Stale template edit"), "definition": template.definition], context: store.workflowContext)
        try check(staleTemplateSave == nil && store.templates.first { $0.id == templateID }?.name == "Template edited in another window", "Template editor overwrote a newer definition revision")
        var staleTemplateDraft = TaskDraft(projectID: project.id); staleTemplateDraft.templateID = templateID; staleTemplateDraft.templateRevision = template.revision; staleTemplateDraft.title = "Do not apply an unseen template revision"; staleTemplateDraft.workflowContext = store.workflowContext
        let staleApplied = await store.save(staleTemplateDraft)
        try check(!staleApplied && !store.tasks.contains { $0.title == staleTemplateDraft.title }, "Template apply ignored the selected definition revision")
        guard let latestTemplate = store.templates.first(where: { $0.id == templateID }) else { throw Failure(description: "Updated template missing") }
        var reuse = TaskDraft(projectID: project.id, parentID: templated.id); reuse.templateID = templateID; reuse.templateRevision = latestTemplate.revision; reuse.title = "Reusable subtask"
        let reused = await store.save(reuse)
        try check(reused && store.tasks.first(where: { $0.title == reuse.title })?.parentID == templated.id, "User template apply lost requested parent")
        let deletedTemplate = await store.workflowMutation("template.delete", params: ["template_id": .string(templateID), "expected_revision": .number(Double(latestTemplate.revision))])
        try check(deletedTemplate != nil && !store.templates.contains { $0.id == templateID } && store.tasks.contains { $0.title == reuse.title }, "Deleting template changed created tasks")
        let assigned = await store.claim(try task(templated.id), agent: "workflow-agent")
        try check(assigned, "Assignee filter fixture failed")
        var filters = TaskFilters(); filters.projectID = project.id; filters.status = "todo"; filters.assignee = "workflow-agent"; filters.readyOnly = true; filters.query = "Feature template"; filters.staleDays = 0
        let viewResult = await store.workflowMutation("view.save", params: ["name": .string("Feature to start"), "filters": filters.json, "layout": .string("list")])
        guard let viewID = viewResult?["view"]["id"].string, let saved = store.savedViews.first(where: { $0.id == viewID }) else { throw Failure(description: "Saved view did not load") }
        store.selectView(saved)
        await store.reload(force: true)
        let serverTasks = try await client.call("task.list", params: ["view_id": .string(viewID)], configuration: store.configuration)
        try check(store.visibleTasks.contains { $0.id == templated.id } && Set(store.visibleTasks.map(\.id)) == Set(serverTasks["tasks"].array.compactMap { $0["id"].string }) && store.selectedLayout == "list", "Local saved view differs from FTS prefix AND query/assignee/service filters")
        let viewContext = store.workflowContext
        _ = try await client.call("view.save", params: ["id": .string(viewID), "expected_revision": .number(Double(saved.revision)), "name": .string("View edited in another window"), "filters": filters.json, "layout": .string("list")], configuration: store.configuration)
        await store.reload(force: true)
        let staleView = await store.workflowMutation("view.save", params: ["id": .string(viewID), "expected_revision": .number(Double(saved.revision)), "name": .string("Stale view edit"), "filters": filters.json, "layout": .string("board")], context: viewContext)
        try check(staleView == nil && store.savedViews.first { $0.id == viewID }?.name == "View edited in another window", "Saved view editor silently upgraded its captured revision")
        let viewRevision = store.savedViews.first { $0.id == viewID }!.revision
        let editedView = await store.workflowMutation("view.save", params: ["id": .string(viewID), "expected_revision": .number(Double(viewRevision)), "name": .string("Weekly feature to start"), "filters": filters.json, "layout": .string("week")])
        try check(editedView?["view"]["layout"].string == "week" && store.selectedLayout == "week", "Saved view update did not refresh the active layout")
        let reopened = BoardStore(appearance: appearance); await reopened.reload(force: true)
        try check(reopened.savedViews.first(where: { $0.id == viewID })?.layout == "week", "Saved view did not persist")
        let deletedView = await store.workflowMutation("view.delete", params: ["view_id": .string(viewID), "expected_revision": editedView?["view"]["revision"] ?? .null])
        try check(deletedView != nil && !store.savedViews.contains { $0.id == viewID }, "Saved view delete failed")
        let captured = await store.workflowMutation("inbox.capture", params: ["title": .string("New idea"), "note": .string("Capture for now"), "source": .string("https://example.com/capture")])
        try check(captured != nil && store.pendingInbox.first?.note == "Capture for now", "Snapshot Inbox integration missing")
        guard let capturedItem = store.pendingInbox.first else { throw Failure(description: "Inbox item missing") }
        let promoted = await store.workflowMutation("inbox.promote", params: ["item_id": .string(capturedItem.id), "expected_revision": .number(Double(capturedItem.revision)), "project_id": .string(project.id), "parent_id": .string(templated.id)])
        guard let promotedID = promoted?["task"]["id"].string else { throw Failure(description: "Inbox promote failed: \(store.actionError ?? "")") }
        await store.openTask(promotedID)
        try check(store.pendingInbox.isEmpty && (try task(promotedID)).parentID == templated.id && (try task(promotedID)).goal.contains("Capture for now") && store.detail?.artifacts.first?.path == "https://example.com/capture", "Inbox promotion lost parent, note, source or pending state")
        _ = await store.workflowMutation("inbox.capture", params: ["title": .string("Idea to dismiss without categorizing")])
        guard let dismissedItem = store.pendingInbox.first else { throw Failure(description: "Dismiss fixture missing") }
        let dismissed = await store.workflowMutation("inbox.dismiss", params: ["item_id": .string(dismissedItem.id), "expected_revision": .number(Double(dismissedItem.revision))])
        try check(dismissed != nil && store.pendingInbox.isEmpty && store.inbox.contains { $0.id == dismissedItem.id && $0.status == "dismissed" }, "Inbox dismiss did not persist without deleting tasks")
        let automated = try await create("Automation contract regression")
        let armed = await store.taskWorkflowMutation("automation.configure", task: automated, fields: ["configuration": .object(["plugin_id": .string("fixture"), "method": .string("automation.start"), "resource_key": .string("fixture-workspace"), "params": .object([:]), "max_reworks": .number(2), "timeout_seconds": .number(60)])])
        await store.openTask(automated.id)
        try check(armed && store.automations[automated.id]?.state == "armed" && store.detail?.automation?.stage == "preflight", "Automation did not reach the card and task details through the actual service")
        let disabledAutomation = await store.taskWorkflowMutation("automation.disable", task: try task(automated.id), fields: ["expected_automation_revision": .number(Double(store.detail?.automation?.revision ?? 0))])
        try check(disabledAutomation && store.automations[automated.id]?.state == "disabled", "Automation disable did not refresh the board")
        print("✓ Actual automation configuration, card/detail state, captured revisions, and disable without an executor")
        let rule = AutomationRuleDraft(.object(["id": .string("review-rule"), "status": .string("review"), "action": .string("stage"), "stage": .string("review"), "skills": .array([.string("review-skill")]), "prompt": .string("Check acceptance"), "instructions": .string("Preserve source")]))
        try check(rule.json["skills"].array == [.string("review-skill")] && rule.json["prompt"].string == "Check acceptance", "Rule editor lost selected skills or prompt")
        let defaultsConfig: JSONValue = .object(["plugin_id": .string("fixture"), "method": .string("automation.start"), "resource_key": .string("fixture-workspace"), "params": .object([:]), "max_reworks": .number(1), "timeout_seconds": .number(60), "rules": .array([rule.json])])
        let savedDefaults = await store.workflowMutation("automation.defaults.set", params: ["project_id": .string(project.id), "enabled": .bool(true), "expected_defaults_revision": .number(0), "configuration": defaultsConfig])
        try check(savedDefaults?["defaults"]["revision"].int == 1, "Project defaults did not save through the service")
        let inherited = try await create("Inherited status rules")
        await store.openTask(inherited.id)
        try check(store.detail?.automation?.raw["inherited_revision"].int == 1 && store.detail?.automation?.raw["configuration"]["rules"].array.first?["prompt"].string == "Check acceptance", "New card did not inherit project defaults")
        _ = await store.taskWorkflowMutation("task.update", task: try task(inherited.id), fields: ["goal": .string("Verify inherited review"), "completion_criteria": .string("Review evidence is recorded")])
        await store.move(try task(inherited.id), to: .review)
        try check(store.automations[inherited.id]?.stage == "review" && store.automations[inherited.id]?.attempts.count == 1, "Native card move contract did not trigger the review rule")
        try check(store.automationDefaults[project.id]?["enabled"].bool == true, "Project defaults missing from task creation state")
        var manualDraft = TaskDraft(projectID: project.id); manualDraft.title = "Manual card skips automation"; manualDraft.goal = "Work by hand"; manualDraft.completionCriteria = "User checks the result"; manualDraft.automationMode = .manual
        let manualSaved = await store.save(manualDraft)
        guard let manualCard = store.tasks.first(where: { $0.title == manualDraft.title }) else { throw Failure(description: "Manual creation missing") }
        try check(manualSaved && store.automations[manualCard.id] == nil, "Manual selection inherited automation")
        await store.move(manualCard, to: .inProgress)
        try check(store.automations[manualCard.id] == nil && (try task(manualCard.id)).status == .inProgress, "Manual card move started automation")
        var manualTemplate = TaskDraft(projectID: project.id); manualTemplate.title = "Manual template family"; manualTemplate.templateID = "builtin-feature"; manualTemplate.templateRevision = store.templates.first { $0.id == "builtin-feature" }?.revision; manualTemplate.automationMode = .manual
        let manualTemplateSaved = await store.save(manualTemplate)
        guard let manualParent = store.tasks.first(where: { $0.title == manualTemplate.title }) else { throw Failure(description: "Manual template missing") }
        try check(manualTemplateSaved && ([manualParent] + store.descendants(of: manualParent)).allSatisfy { store.automations[$0.id] == nil }, "Manual template selection armed a child")
        var automaticDraft = TaskDraft(projectID: project.id); automaticDraft.title = "Explicit automatic card"; automaticDraft.automationMode = .automatic
        let automaticSaved = await store.save(automaticDraft)
        try check(automaticSaved && store.tasks.first(where: { $0.title == automaticDraft.title }).flatMap { store.automations[$0.id] }?.state == "armed", "Explicit automation selection failed")
        try check(store.processPresets.count == 3, "Built-in process presets missing from the Store")
        var presetDraft = ProcessPresetDraft(store.processPresets.first { $0["id"].string == "small" }!, duplicate: true)
        presetDraft.presetID = "swift-docs"; presetDraft.name = "Documentation process"; presetDraft.whenToUse = "Small documentation edits"
        presetDraft.steps[0].settings.skills = "documentation-skill"; presetDraft.steps[0].settings.prompt = "Inspect the guide"
        let savedPreset = await store.workflowMutation("automation.presets.save", params: ["preset": presetDraft.json, "expected_preset_revision": .number(0)])
        try check(savedPreset != nil && store.processPresets.count == 4, "Preset editor data did not reach the service")
        var selectedDraft = TaskDraft(projectID: project.id); selectedDraft.title = "Selected custom process"; selectedDraft.processPreset = "swift-docs"
        let selectedSaved = await store.save(selectedDraft)
        guard let selectedCard = store.tasks.first(where: { $0.title == selectedDraft.title }), let selectedProcess = store.automations[selectedCard.id] else { throw Failure(description: "Custom process creation missing") }
        try check(selectedSaved && selectedProcess.raw["process"]["preset"]["id"].string == "swift-docs" && selectedProcess.raw["process"]["preset"]["steps"].array.first?["skills"].array == [.string("documentation-skill")], "Task creation lost the selected preset or stage settings")
        manualDraft.title = "Manual choice ignores old picker"; manualDraft.processPreset = "swift-docs"
        let manualWithPresetSaved = await store.save(manualDraft)
        try check(manualWithPresetSaved && store.tasks.first(where: { $0.title == manualDraft.title }).flatMap { store.automations[$0.id] } == nil, "Hidden preset picker overrode manual work")
        let removedPreset = await store.workflowMutation("automation.presets.delete", params: ["preset_id": .string("swift-docs"), "expected_preset_revision": savedPreset!["preset"]["revision"]])
        try check(removedPreset != nil && store.processPresets.count == 3 && store.automations[selectedCard.id]?.presetName == "Documentation process", "Deleting a library preset changed a configured task")
        print("✓ Preset library, editable stage settings, task selection, manual opt-out, and frozen task copy through actual Store/service")
        print("✓ Creation modes: manual cards and template children skip automation; explicit automation arms without launching")
        print("✓ Project defaults, rule editor data, inherited cards, and manual status moves through the actual Store/service")
        let oldContext = store.workflowContext
        appearance.dataDirectory = directory.appendingPathComponent("other-board").path; appearance.dataDirectory = directory.path
        await store.reload(force: true)
        try check(store.lastUpdated != nil && oldContext.connection == store.workflowContext.connection && oldContext.generation != store.workflowGeneration, "ABA fixture did not return to the same loaded connection with a new generation")
        let beforeABA = try task(templated.id)
        let staleConnectionSave = await store.taskWorkflowMutation("task.update", task: beforeABA, fields: ["title": .string("Edit leaked from the previous board")], context: oldContext)
        try check(!staleConnectionSave && (try task(templated.id)).title == beforeABA.title, "Old editor wrote after a connection ABA with the same ID/revision")
        let staleConnectionTemplate = await store.workflowMutation("template.save", params: ["name": .string("Template leaked from the previous board"), "definition": template.definition], context: oldContext)
        try check(staleConnectionTemplate == nil && !store.templates.contains { $0.name == "Template leaked from the previous board" }, "Old template editor wrote after a connection ABA")
        print("✓ Editor revision pinning: external changes rejected for checklists/reviews/views/templates, including ABA connection changes")
        print("✓ Actual built-in/custom template save/select/subtask application/deletion with task preservation, saved view CRUD/reload/server filter parity, and Inbox snapshot")
    }
}
