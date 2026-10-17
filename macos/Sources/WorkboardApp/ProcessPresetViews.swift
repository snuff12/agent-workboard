import SwiftUI

struct ProcessPresetPicker: View {
    @Binding var selection: String
    let presets: [JSONValue]
    let includeDefault: Bool
    var body: some View {
        Picker("Process preset", selection: $selection) {
            Text(includeDefault ? "Project default" : "Legacy development process").tag("")
            Text("Let an agent choose").tag("auto")
            ForEach(Array(presets.enumerated()), id: \.offset) { row in
                let preset = row.element
                if let id = preset["id"].string { Text("\(preset["name"].string ?? id) · \(preset["steps"].array.count) stages").tag(id) }
            }
            if !selection.isEmpty && selection != "auto" && !presets.contains(where: { $0["id"].string == selection }) { Text("Saved preset: \(selection)").tag(selection) }
        }.accessibilityIdentifier("process-preset-picker")
    }
}

struct ProcessStepDraft: Identifiable {
    var id: String
    var title: String
    var kind: String
    var settings: AutomationStageDraft
    init(_ value: JSONValue = .null) {
        id = value["id"].string ?? UUID().uuidString
        title = value["title"].string ?? "Implementation"
        kind = value["kind"].string ?? "work"
        settings = AutomationStageDraft(id: id, value: value)
    }
    var json: JSONValue {
        var fields = settings.json.object
        fields["id"] = .string(id); fields["title"] = .string(title); fields["kind"] = .string(kind)
        return .object(fields)
    }
}

struct ProcessPresetDraft: Identifiable {
    let id = UUID()
    var presetID: String
    var name: String
    var description: String
    var whenToUse: String
    var steps: [ProcessStepDraft]
    var rework: ProcessStepDraft
    var maxReworks: Int
    let revision: Int
    let editing: Bool
    init(_ value: JSONValue = .null, duplicate: Bool = false) {
        editing = value != .null && !duplicate
        presetID = editing ? (value["id"].string ?? "") : "process-\(UUID().uuidString.prefix(8).lowercased())"
        name = value["name"].string.map { duplicate ? $0 + " copy" : $0 } ?? "New process"
        description = value["description"].string ?? ""
        whenToUse = value["when_to_use"].string ?? ""
        steps = value["steps"].array.map(ProcessStepDraft.init)
        if steps.isEmpty { steps = [ProcessStepDraft(), ProcessStepDraft(.object(["id": .string("review"), "title": .string("Review"), "kind": .string("review")]))] }
        rework = ProcessStepDraft(value["rework"] == .null ? .object(["id": .string("rework"), "title": .string("Address review findings"), "kind": .string("rework")]) : value["rework"])
        maxReworks = value["max_reworks"].int ?? 2
        revision = editing ? (value["revision"].int ?? 0) : 0
    }
    var json: JSONValue { .object(["id": .string(presetID), "name": .string(name), "description": .string(description), "when_to_use": .string(whenToUse), "steps": .array(steps.map(\.json)), "rework": rework.json, "max_reworks": .number(Double(maxReworks))]) }
}

struct ProcessPresetLibraryView: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProcessPresetDraft?
    @State private var deleting: JSONValue?
    @State private var context: WorkflowEditContext?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Process presets").font(.title2.weight(.semibold))
            Text("Reuse a short process for small tasks and a longer process for larger tasks. Agents use the selection guidance to choose. Changes apply to future selections; configured tasks keep their saved stages.").font(.callout).foregroundStyle(.secondary)
            List(Array(store.processPresets.enumerated()), id: \.offset) { row in
                let preset = row.element
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(preset["name"].string ?? "Process").font(.headline)
                        if preset["builtin"].bool == true { Text("Built-in").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if preset["builtin"].bool != true { Button("Edit…") { draft = ProcessPresetDraft(preset) } }
                        Button("Duplicate…") { draft = ProcessPresetDraft(preset, duplicate: true) }
                        if preset["builtin"].bool != true { Button("Delete…", role: .destructive) { deleting = preset } }
                    }
                    Text(preset["steps"].array.compactMap { $0["title"].string }.joined(separator: " → ")).font(.caption)
                    if let guidance = preset["when_to_use"].string, !guidance.isEmpty { Text(guidance).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 10)
            }.listStyle(.inset)
            if let error = store.actionError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Button("New preset…") { draft = ProcessPresetDraft() }; Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 760, height: 600)
        .sheet(item: $draft) { ProcessPresetEditorView(draft: $0) }
        .confirmationDialog("Delete this process preset?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete preset", role: .destructive) { if let preset = deleting { Task { _ = await store.workflowMutation("automation.presets.delete", params: ["preset_id": preset["id"], "expected_preset_revision": preset["revision"]], context: context); deleting = nil } } }
        } message: { Text("Existing task processes are preserved. Update any project defaults that refer to this preset before creating more tasks.") }
        .onAppear { context = store.workflowContext }
        .onChange(of: store.workflowGeneration) { _, _ in dismiss() }
    }
}

struct ProcessPresetEditorView: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: ProcessPresetDraft
    @State private var context: WorkflowEditContext?
    private let kinds = ["preflight", "plan", "work", "verify", "review", "rework", "release"]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.editing ? "Edit process preset" : "Create process preset").font(.title3.weight(.semibold))
            ScrollView {
                Form {
                    TextField("Preset ID", text: $draft.presetID).disabled(draft.editing)
                    TextField("Name", text: $draft.name)
                    TextField("Description", text: $draft.description, axis: .vertical).lineLimit(2...4)
                    TextField("When should an agent choose this?", text: $draft.whenToUse, axis: .vertical).lineLimit(3...6)
                    Section("Stages in execution order") {
                        Text("Work and rework can edit source files. Other stages inspect and report. Every process ends with human approval.").font(.caption).foregroundStyle(.secondary)
                        ForEach($draft.steps) { $step in
                            DisclosureGroup(step.title) {
                                TextField("Stage title", text: $step.title)
                                Picker("Stage kind", selection: $step.kind) { ForEach(kinds, id: \.self) { Text(TaskAutomation.stageTitle($0)).tag($0) } }
                                AutomationStageFields(draft: $step.settings)
                                HStack {
                                    Button("Move up") { move(step.id, by: -1) }.disabled(draft.steps.first?.id == step.id)
                                    Button("Move down") { move(step.id, by: 1) }.disabled(draft.steps.last?.id == step.id)
                                    Spacer()
                                    Button("Remove", role: .destructive) { draft.steps.removeAll { $0.id == step.id } }.disabled(draft.steps.count == 1)
                                }
                            }
                        }
                        Button("Add stage") { draft.steps.append(ProcessStepDraft()) }.disabled(draft.steps.count >= 20)
                    }
                    Section("When a review requests changes") {
                        Stepper("Maximum rework cycles: \(draft.maxReworks)", value: $draft.maxReworks, in: 0...10)
                        Text("Use this rework stage, then repeat the stages after the nearest implementation. The project's lower rework limit also applies.").font(.caption).foregroundStyle(.secondary)
                        TextField("Rework title", text: $draft.rework.title)
                        AutomationStageFields(draft: $draft.rework.settings)
                    }
                }.formStyle(.grouped)
            }
            if let error = store.actionError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button("Save preset") { Task { if await store.workflowMutation("automation.presets.save", params: ["preset": draft.json, "expected_preset_revision": .number(Double(draft.revision))], context: context) != nil { dismiss() } } }.disabled(store.isMutating || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.steps.contains { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }.padding(24).frame(width: 680, height: 740).onAppear { context = store.workflowContext }.onChange(of: store.workflowGeneration) { _, _ in dismiss() }
    }
    private func move(_ id: String, by offset: Int) {
        guard let index = draft.steps.firstIndex(where: { $0.id == id }), draft.steps.indices.contains(index + offset) else { return }
        draft.steps.swapAt(index, index + offset)
    }
}
