import SwiftUI

struct EvidenceVerification: Identifiable, Sendable {
    let id: String
    let artifactID: String
    let status: String
    let checkedAt: String
    let recordedAt: String
    let detail: String
    let actor: String
    let source: JSONValue
    let observed: JSONValue

    init?(_ json: JSONValue) {
        guard let id = json["id"].string, let artifactID = json["artifact_id"].string else { return nil }
        self.id = id; self.artifactID = artifactID
        status = json["status"].string ?? ""; checkedAt = json["checked_at"].string ?? ""
        recordedAt = json["recorded_at"].string ?? ""; detail = json["detail"].string ?? ""
        actor = json["actor"].string ?? ""; source = json["source"]; observed = json["observed"]
    }
    var title: String {
        switch status {
        case "current": "Matched at check"
        case "changed": "Source changed · review before reuse"
        case "unreadable": "Source unreadable · review before reuse"
        case "integration_failure": "Check failed · no source verdict"
        default: "Unknown check result"
        }
    }
    var symbol: String { status == "current" ? "checkmark.circle" : "exclamationmark.circle" }
    static func exactTime(_ value: String) -> String {
        BoardDate.parseTimestamp(value)?.formatted(Date.FormatStyle.dateTime.month().day().hour().minute().second().locale(BoardDate.displayLocale)) ?? value
    }
    static func history(_ checks: [EvidenceVerification], artifactID: String) -> [EvidenceVerification] {
        // Preserve service order for equal observation times, including after backup restore.
        checks.filter { $0.artifactID == artifactID }.sorted {
            (BoardDate.parseTimestamp($0.checkedAt) ?? .distantPast) > (BoardDate.parseTimestamp($1.checkedAt) ?? .distantPast)
        }
    }
}

struct EvidenceAttachmentView: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.colorScheme) private var colorScheme
    let artifact: TaskArtifact
    let taskID: String
    let checks: [EvidenceVerification]
    @State private var showingHistory: Bool

    init(artifact: TaskArtifact, taskID: String, checks: [EvidenceVerification], showingHistory: Bool = false) {
        self.artifact = artifact; self.taskID = taskID; self.checks = checks
        _showingHistory = State(initialValue: showingHistory)
    }

    private var history: [EvidenceVerification] { EvidenceVerification.history(checks, artifactID: artifact.id) }
    private var canRecheck: Bool { store.memoryPlugin?.savesEvidenceChecks == true }
    private var scope: String {
        let fields = artifact.metadata["scope"].object
        let parts = ["project", "domain"].compactMap { key in fields[key]?.string.map { "\(key):\($0)" } }
        return parts.isEmpty ? "global" : parts.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let latest = history.first {
                Label("\(latest.title) · \(BoardDate.shortLocalTimestamp(latest.checkedAt))", systemImage: latest.symbol)
                    .font(.caption).foregroundStyle(latest.status == "current" ? BoardInk.secondary(colorScheme) : WorkStatus.review.color)
                if latest.status == "integration_failure", let verdict = history.first(where: { $0.status != "integration_failure" }) {
                    Text("Last source result: \(verdict.title) · \(BoardDate.shortLocalTimestamp(verdict.checkedAt))").font(.caption2).foregroundStyle(.secondary)
                }
                if latest.status == "unreadable" {
                    Text("The saved reference may have expired. This does not establish that the source was deleted.").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("No saved recheck").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(store.recheckingArtifactID == artifact.id ? "Checking…" : "Recheck source") {
                    Task { await store.recheckEvidence(taskID: taskID, artifactID: artifact.id) }
                }.font(.caption).disabled(!canRecheck || store.recheckingArtifactID != nil)
                if !canRecheck { Text(store.memoryPlugin == nil ? "Enable agent-memory to recheck" : "Update agent-memory to save rechecks").font(.caption2).foregroundStyle(.secondary) }
            }
            DisclosureGroup("Evidence and check history (\(history.count))", isExpanded: $showingHistory) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Original attachment").font(.caption.weight(.semibold))
                    Text("Verified: \(artifact.metadata["verified_at"].string.map { BoardDate.shortLocalTimestamp($0) } ?? "Not recorded")").font(.caption2)
                    Text("SHA-256: \(artifact.metadata["source_sha256"].string ?? "Not recorded")").font(.caption2).textSelection(.enabled)
                    Text("Collection: \(artifact.metadata["collection"].string ?? "Not recorded") · \(artifact.locator ?? "")").font(.caption2).textSelection(.enabled)
                    Text("Scope: \(scope)").font(.caption2).textSelection(.enabled)
                    if let previous = artifact.metadata["supersedes_artifact_id"].string {
                        Text("Replaces attachment: \(previous)").font(.caption2).textSelection(.enabled)
                    }
                    Text("A matching local hash does not establish that upstream facts are still current.").font(.caption2).foregroundStyle(.secondary)
                    ForEach(history) { check in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(check.title).font(.caption.weight(.medium))
                            Text("Checked \(EvidenceVerification.exactTime(check.checkedAt)) · saved \(EvidenceVerification.exactTime(check.recordedAt)) · \(check.actor)").font(.caption2).foregroundStyle(.secondary)
                            if !check.detail.isEmpty { Text(check.detail).font(.caption2).textSelection(.enabled) }
                            if let hash = check.observed["source_sha256"].string { Text("Observed SHA-256: \(hash)").font(.caption2).textSelection(.enabled) }
                            if let path = check.observed["path"].string { Text("Observed source: \(path)").font(.caption2).textSelection(.enabled) }
                            if let collection = check.observed["collection"].string { Text("Observed collection: \(collection)").font(.caption2).textSelection(.enabled) }
                        }
                    }
                }.foregroundStyle(BoardInk.primary(colorScheme)).padding(.top, 5).fixedSize(horizontal: false, vertical: true)
            }.font(.caption).foregroundStyle(BoardInk.secondary(colorScheme))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
