import SwiftUI
import AppKit

/// Repository names as the GitHub plugin accepts them: ASCII `owner/name`, compared case-insensitively.
enum GitHubRepoName {
    static func isValid(_ value: String) -> Bool {
        guard value.unicodeScalars.allSatisfy(\.isASCII) else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let owner = parts[0], name = parts[1]
        func alphanumeric(_ character: Character) -> Bool { character.isASCII && (character.isLetter || character.isNumber) }
        guard (1...39).contains(owner.count), let first = owner.first, alphanumeric(first), owner.allSatisfy({ alphanumeric($0) || $0 == "-" }) else { return false }
        return (1...100).contains(name.count) && name != "." && name != ".." && name.allSatisfy { alphanumeric($0) || "._-".contains($0) }
    }
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}

/// Reads the GitHub repository of a project folder from its Git remote. Every failure returns nil.
enum GitHubRemote {
    static func repository(fromURL raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        var path: Substring
        let scpPrefix = "git@github.com:"
        if value.lowercased().hasPrefix(scpPrefix) { path = value.dropFirst(scpPrefix.count) }
        else if let components = URLComponents(string: value), let scheme = components.scheme?.lowercased(), components.host?.lowercased() == "github.com",
                components.port == nil, components.password == nil, components.query == nil, components.fragment == nil,
                (scheme == "https" && components.user == nil) || (scheme == "ssh" && components.user == "git"), components.percentEncodedPath.hasPrefix("/") {
            path = components.percentEncodedPath.dropFirst()
        } else { return nil }
        if path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        return GitHubRepoName.isValid(String(path)) ? String(path) : nil
    }
    /// Prefers `origin`, then the first remote whose URL is on github.com.
    static func repository(fromConfig text: String) -> String? {
        var current: String?
        var remotes: [(name: String, url: String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = nil
                guard line.hasSuffix("]"), let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close,
                      line[line.index(after: line.startIndex)..<open].trimmingCharacters(in: .whitespaces).lowercased() == "remote" else { continue }
                current = String(line[line.index(after: open)..<close])
            } else if let name = current, let equals = line.firstIndex(of: "="), line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "url" {
                var url = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if url.count >= 2, url.hasPrefix("\""), url.hasSuffix("\"") { url = String(url.dropFirst().dropLast()) }
                if !remotes.contains(where: { $0.name == name }) { remotes.append((name, url)) }
            }
        }
        if let origin = remotes.first(where: { $0.name == "origin" }), let repo = repository(fromURL: origin.url) { return repo }
        return remotes.lazy.compactMap { repository(fromURL: $0.url) }.first
    }
    static func repository(in directory: String) -> String? {
        guard directory.hasPrefix("/"), let config = configURL(for: URL(fileURLWithPath: directory)), let text = read(config) else { return nil }
        return repository(fromConfig: text)
    }
    /// Follows a worktree `.git` file (`gitdir:`) and its `commondir` to the shared config.
    static func configURL(for directory: URL) -> URL? {
        let dotGit = directory.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        var gitDir = dotGit
        if !isDirectory.boolValue {
            guard let text = read(dotGit), let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            gitDir = resolve(path, relativeTo: directory)
        }
        if let common = read(gitDir.appendingPathComponent("commondir"))?.trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty {
            gitDir = resolve(common, relativeTo: gitDir)
        }
        return gitDir.appendingPathComponent("config")
    }
    static func repositories(for projects: [BoardProject]) -> [String: String] {
        var map: [String: String] = [:]
        for project in projects { if let repo = repository(in: project.directory) { map[project.id] = repo } }
        return map
    }
    private static func resolve(_ path: String, relativeTo base: URL) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)).standardizedFileURL
    }
    private static func read(_ url: URL) -> String? {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1 << 20) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A canonical github.com issue or pull request page: `https://github.com/{owner}/{name}/(issues|pull)/{number}`.
struct GitHubItemReference: Hashable, Sendable {
    let repo: String
    let number: Int
    let isPull: Bool
    var key: String { repo.lowercased() + "#\(number)" }
    var locator: String { repo + "#\(number)" }
    init?(url value: String) {
        guard value.unicodeScalars.allSatisfy(\.isASCII), let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com", components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[3] == "issues" || parts[3] == "pull", let number = Int(parts[4]), String(number) == parts[4],
              (1...2_147_483_647).contains(number), GitHubRepoName.isValid(parts[1] + "/" + parts[2]) else { return nil }
        repo = parts[1] + "/" + parts[2]; self.number = number; isPull = parts[3] == "pull"
    }
}

struct GitHubItem: Identifiable, Sendable {
    let repo: String
    let number: Int
    let isPull: Bool
    let title: String
    let state: String
    let stateReason: String?
    let draft: Bool
    let merged: Bool
    let author: String
    let labels: [String]
    let updatedAt: String
    let url: URL?
    let body: String?
    let bodyTruncated: Bool
    let version: String?
    let headRef: String?
    let baseRef: String?
    let headSHA: String?
    var id: String { locator.lowercased() }
    var locator: String { repo + "#\(number)" }
    var kindName: String { isPull ? "pull request" : "issue" }
    init?(_ json: JSONValue) {
        guard let repo = json["repo"].string, GitHubRepoName.isValid(repo), let number = json["number"].int, json["number"] == .number(Double(number)),
              (1...2_147_483_647).contains(number) else { return nil }
        self.repo = repo; self.number = number; isPull = json["type"].string == "pull"
        title = json["title"].string ?? "Untitled"; state = json["state"].string ?? "unknown"; stateReason = json["state_reason"].string
        let pull = json["pull"]
        draft = json["draft"].bool ?? pull["draft"].bool ?? false; merged = json["merged"].bool ?? pull["merged"].bool ?? false
        author = json["author"].string ?? "ghost"; labels = json["labels"].array.compactMap(\.string); updatedAt = json["updated_at"].string ?? ""
        url = Self.itemURL(json["url"].string ?? "", repo: repo, number: number)
        body = json["body"].string; bodyTruncated = json["body_truncated"].bool ?? false; version = json["version"].string
        headRef = pull["head_ref"].string; baseRef = pull["base_ref"].string; headSHA = pull["head_sha"].string
    }
    /// Only an https github.com page of this exact item is opened as its link.
    static func itemURL(_ value: String, repo: String, number: Int) -> URL? {
        guard let reference = GitHubItemReference(url: value), reference.repo.lowercased() == repo.lowercased(), reference.number == number else { return nil }
        return URL(string: value)
    }
    /// Mutations pass the version read by `items.read`, so a changed source is rejected instead of linked.
    func parameters(verified: Bool = false) -> [String: JSONValue] {
        var values: [String: JSONValue] = ["repo": .string(repo), "number": .number(Double(number))]
        if verified, let version { values["expected_version"] = .string(version) }
        return values
    }
}

/// A GitHub issue or pull request linked to a task, re-validated from the artifact path.
struct GitHubLinkedItem: Identifiable, Sendable {
    let reference: GitHubItemReference
    let url: URL
    let sourceVersion: String?
    let linkedState: String?
    var id: String { reference.key }
    static func from(_ artifacts: [TaskArtifact], configuredRepos: [String]) -> [GitHubLinkedItem] {
        let allowed = Set(configuredRepos.map { $0.lowercased() })
        var result: [GitHubLinkedItem] = []
        for artifact in artifacts where artifact.provider == "github" {
            guard let reference = GitHubItemReference(url: artifact.path), allowed.contains(reference.repo.lowercased()), let url = URL(string: artifact.path) else { continue }
            let version = artifact.metadata["source_version"].string.flatMap { (1...64).contains($0.count) ? $0 : nil }
            let item = GitHubLinkedItem(reference: reference, url: url, sourceVersion: version, linkedState: artifact.metadata["state"].string)
            if let index = result.firstIndex(where: { $0.id == item.id }) { result[index] = item } else { result.append(item) }
        }
        return result
    }
    var statusParameters: JSONValue {
        var values: [String: JSONValue] = ["repo": .string(reference.repo), "number": .number(Double(reference.number))]
        if let sourceVersion { values["source_version"] = .string(sourceVersion) }
        return .object(values)
    }
    /// Only an issue or pull request link counts. A status comment on the item has the same locator but is not a link to the item.
    static func isLinked(itemKey key: String, in artifacts: [TaskArtifact]) -> Bool {
        artifacts.contains { $0.provider == "github" && GitHubItemReference(url: $0.path)?.key == key.lowercased() }
    }
    /// One line for an `items.status` entry.
    static func statusSummary(_ entry: JSONValue) -> String {
        var parts = [entry["merged"].bool == true ? "merged" : entry["state"].string ?? "unknown"]
        if entry["draft"].bool == true { parts.append("draft") }
        if let checks = entry["checks"]["state"].string {
            parts.append("checks: " + checks + (entry["checks"]["runs_available"].bool == false ? " (only commit statuses were read; check runs were not available)" : ""))
        }
        else if entry["checks_unavailable"].string != nil { parts.append("checks unavailable") }
        if case .object = entry["reviews"] { parts.append("\(entry["reviews"]["approved"].int ?? 0) approved, \(entry["reviews"]["changes_requested"].int ?? 0) changes requested") }
        else if entry["reviews_unavailable"].string != nil { parts.append("reviews unavailable") }
        let requested = entry["requested_reviewers"].array.compactMap { $0.string ?? $0["login"].string }
        if !requested.isEmpty { parts.append("review requested: " + requested.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// A confirmed GitHub write that may need to be checked again with the same request ID.
struct GitHubWriteOperation: Sendable, Codable {
    enum Kind: String, Sendable, Codable { case comment, issue }
    let kind: Kind
    let taskID: String
    let target: String
    let label: String
    let connection: ConnectionIdentity
    let requestID: String
    let parameters: [String: JSONValue]
    /// Codes the host returns only after the journal found this request ID new and before the provider ran, so no attempt
    /// with this request ID reached GitHub. Earlier host refusals, such as an uninstalled plugin, say nothing about a prior attempt.
    static let preProviderCodes: Set<String> = ["PLUGIN_REVISION_CONFLICT", "PLUGIN_CONTEXT_UNAVAILABLE", "PLUGIN_INVALID_PARAMS"]
    /// The provider ends every failure that happened before a GitHub write, or that GitHub refused, with this sentence.
    static let noWriteSuffix = "No GitHub write was made."

    init(kind: Kind, taskID: String, revision: Int, repo: String, number: Int?, title: String? = nil, configuration: ConnectionConfiguration) {
        self.kind = kind; self.taskID = taskID; target = Self.target(kind: kind, repo: repo, number: number)
        connection = configuration.identity(); requestID = UUID().uuidString
        var values: [String: JSONValue] = ["task_id": .string(taskID), "expected_revision": .number(Double(revision)), "repo": .string(repo), "confirmed_by_user": .bool(true)]
        if kind == .comment, let number { values["number"] = .number(Double(number)); label = repo + "#\(number)" }
        else { label = title.map { "\(repo) (an issue titled \"\($0)\")" } ?? repo }
        parameters = values
    }
    static func target(kind: Kind, repo: String, number: Int?) -> String { kind.rawValue + ":" + repo.lowercased() + (number.map { "#\($0)" } ?? "") }
    /// The task revision is deliberately not compared: a retry must reuse the original request even after the task changed.
    func matches(kind: Kind, task: BoardTask, repo: String, number: Int?, configuration: ConnectionConfiguration) -> Bool {
        self.kind == kind && taskID == task.id && target == Self.target(kind: kind, repo: repo, number: number) && connection == configuration.identity()
    }
    var checkHint: String { "Check GitHub for \(label) before preparing a new write." }
    /// Keeps the request ID after every failure unless it provably happened before any GitHub write.
    /// The host can fail after GitHub accepted the write, for example while linking the result to a deleted task.
    /// An identical retry then applies the saved result without a second write, so a new request ID could post twice.
    static func shouldRetain(afterErrorCode code: String?, message: String?) -> Bool {
        if let message, message.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(noWriteSuffix) { return false }
        guard let code else { return true }
        return !preProviderCodes.contains(code)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, taskID = "task_id", target, label, requestID = "request_id", parameters
        case executable, dataDirectory = "data_directory", socket
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind); taskID = try values.decode(String.self, forKey: .taskID)
        target = try values.decode(String.self, forKey: .target); label = try values.decode(String.self, forKey: .label)
        requestID = try values.decode(String.self, forKey: .requestID); parameters = try values.decode([String: JSONValue].self, forKey: .parameters)
        connection = ConnectionIdentity(executable: try values.decode(String.self, forKey: .executable),
                                        dataDirectory: try values.decode(String.self, forKey: .dataDirectory), socket: try values.decode(String.self, forKey: .socket))
        guard !requestID.isEmpty, parameters["task_id"] == .string(taskID), parameters["confirmed_by_user"] == .bool(true) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The stored GitHub write is incomplete."))
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind); try values.encode(taskID, forKey: .taskID); try values.encode(target, forKey: .target)
        try values.encode(label, forKey: .label); try values.encode(requestID, forKey: .requestID); try values.encode(parameters, forKey: .parameters)
        try values.encode(connection.executable, forKey: .executable); try values.encode(connection.dataDirectory, forKey: .dataDirectory)
        try values.encode(connection.socket, forKey: .socket)
    }
}

/// Keeps pending GitHub writes after the GitHub window closes or the app relaunches.
/// Each board connection holds at most one, and a write is restored only for the connection that started it.
struct GitHubPendingWrites {
    static let key = "github.pendingWrites"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(for identity: ConnectionIdentity) -> GitHubWriteOperation? {
        guard let operation = stored(in: slots(), identity: identity), operation.connection == identity else { return nil }
        return operation
    }
    func save(_ operation: GitHubWriteOperation) {
        guard let data = try? JSONEncoder().encode(operation) else { return }
        var values = slots(); values[Self.slot(operation.connection)] = data
        defaults.set(values, forKey: Self.key)
    }
    /// Removes the stored write only while it is still this operation, so a newer write is never dropped.
    func remove(_ operation: GitHubWriteOperation) {
        var values = slots()
        let slot = Self.slot(operation.connection)
        guard values[slot] != nil else { return }
        if let stored = stored(in: values, identity: operation.connection), stored.requestID != operation.requestID { return }
        values.removeValue(forKey: slot)
        if values.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(values, forKey: Self.key) }
    }
    private func slots() -> [String: Any] { defaults.dictionary(forKey: Self.key) ?? [:] }
    private func stored(in values: [String: Any], identity: ConnectionIdentity) -> GitHubWriteOperation? {
        guard let data = values[Self.slot(identity)] as? Data else { return nil }
        return try? JSONDecoder().decode(GitHubWriteOperation.self, from: data)
    }
    private static func slot(_ identity: ConnectionIdentity) -> String { [identity.executable, identity.dataDirectory, identity.socket].joined(separator: "\n") }
}

struct GitHubWritePreview: Identifiable {
    let id = UUID()
    let kind: GitHubWriteOperation.Kind
    let taskID: String
    let taskRevision: Int
    let repo: String
    let number: Int?
    let title: String?
    let body: String
    let isPublic: Bool
    let login: String
    let blocker: String?
    init(kind: GitHubWriteOperation.Kind, taskID: String, taskRevision: Int, repo: String, number: Int?, result: JSONValue) {
        self.kind = kind; self.taskID = taskID; self.taskRevision = taskRevision; self.repo = repo; self.number = number
        title = kind == .issue ? result["title"].string : nil; body = result["body"].string ?? ""
        isPublic = result["private"].bool != true; login = result["login"].string ?? ""
        if result["write_enabled"].bool != true { blocker = "Enable GitHub writing in this plugin’s settings first." }
        else if result["identity_verified"].bool != true || login.isEmpty { blocker = "Verify the GitHub account first, then prepare the write again." }
        else if result["archived"].bool == true { blocker = "This repository is archived." }
        else if kind == .issue && result["has_issues"].bool == false { blocker = "Issues are turned off for this repository." }
        else if kind == .issue && (title ?? "").isEmpty { blocker = "The task needs a title before an issue can be created." }
        else { blocker = nil }
    }
}

private enum GitHubQuery {
    case list(repo: String, type: String, state: String)
    case search(query: String, repo: String?, type: String?, state: String?)
    var method: String { if case .list = self { return "items.list" }; return "items.search" }
    var usesCursor: Bool { if case .list(_, let type, _) = self { return type == "all" }; return false }
    var parameters: [String: JSONValue] {
        switch self {
        case .list(let repo, let type, let state): return ["repo": .string(repo), "type": .string(type), "state": .string(state), "limit": .number(20)]
        case .search(let query, let repo, let type, let state):
            var values: [String: JSONValue] = ["query": .string(query), "limit": .number(20)]
            if let repo { values["repo"] = .string(repo) }; if let type { values["type"] = .string(type) }; if let state { values["state"] = .string(state) }
            return values
        }
    }
}

struct GitHubItemsView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var board: BoardStore
    let plugin: InstalledPlugin
    @ObservedObject var plugins: PluginStore
    @StateObject private var session: PluginSession
    @State private var auth = "gh"
    @State private var configuredRepos: [String] = []
    @State private var repos: [String] = []
    @State private var unmatched: [JSONValue] = []
    @State private var login: String?
    @State private var writeEnabled = false
    @State private var identityVerified = false
    @State private var repoFilter = ""
    @State private var typeFilter = "all"
    @State private var stateFilter = "open"
    @State private var query = ""
    @State private var items: [GitHubItem] = []
    @State private var lastQuery: GitHubQuery?
    @State private var nextCursor: String?
    @State private var nextPage: Int?
    @State private var ssoPartial = false
    @State private var didLoad = false
    @State private var selected: GitHubItem?
    @State private var projectID = ""
    @State private var remoteMap: [String: String] = [:]
    @State private var statuses: [String: JSONValue] = [:]
    @State private var statusTaskID: String?
    @State private var issueRepo = ""
    @State private var preview: GitHubWritePreview?
    @State private var pendingWrite: GitHubWriteOperation?
    private let pendingWrites: GitHubPendingWrites

    init(plugin: InstalledPlugin, plugins: PluginStore, configuration: ConnectionConfiguration, pendingWrites: GitHubPendingWrites = GitHubPendingWrites()) {
        self.plugin = plugin; self.plugins = plugins; self.pendingWrites = pendingWrites
        _session = StateObject(wrappedValue: PluginSession(configuration: configuration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if auth == "token" { Button("Connect token") { authorize() }; Button("Disconnect") { disconnect() } }
                else { Button("Verify gh sign-in") { authorize() }; Button("Forget verified account") { disconnect() } }
                Spacer()
                Text(accountSummary).font(.caption).foregroundStyle(Color.secondary).lineLimit(1)
                Button { Task { await refreshCheck() } } label: { Image(systemName: "arrow.clockwise") }.help("Check the connection again")
            }.disabled(plugins.busy)
            if !unmatched.isEmpty {
                Text("Not accessible: " + unmatched.map { "\($0["repo"].string ?? "repository") (\($0["reason"].string ?? "unavailable"))" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Picker("Repository", selection: $repoFilter) {
                    Text("All connected repositories").tag("")
                    ForEach(repos, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 320)
                Picker("Type", selection: $typeFilter) { Text("All").tag("all"); Text("Issues").tag("issue"); Text("Pull requests").tag("pull") }.labelsHidden().frame(width: 125)
                Picker("State", selection: $stateFilter) { Text("Open").tag("open"); Text("Closed").tag("closed"); Text("All").tag("all") }.labelsHidden().frame(width: 90)
                Button("Load") { load() }.disabled(repos.isEmpty)
            }.disabled(plugins.busy)
            HStack {
                TextField("Search issues and pull requests", text: $query).textFieldStyle(.roundedBorder).onSubmit { search() }
                Button("Search") { search() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || repos.isEmpty)
                Button("Assigned to me") { search(assignedToMe: true) }.disabled(repos.isEmpty)
            }.disabled(plugins.busy)
            if let pendingWrite, !plugins.busy {
                VStack(alignment: .leading, spacing: 6) {
                    Label(pendingWrite.checkHint, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    HStack { Button("Check the same write again") { retryPendingWrite() }; Button("Prepare a new write after checking GitHub") { finish(pendingWrite) } }.controlSize(.small)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if items.isEmpty { Text(didLoad ? "No issues or pull requests." : "Load a repository or search to list issues and pull requests.").font(.caption).foregroundStyle(Color.secondary).padding(20) }
                        if ssoPartial { Text("Some results are hidden until the token is authorized for the organization’s SAML single sign-on.").font(.caption2).foregroundStyle(.orange).padding(10) }
                        ForEach(items) { item in
                            Button { read(item) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Image(systemName: item.isPull ? "arrow.triangle.pull" : "smallcircle.filled.circle").foregroundStyle(stateColor(item))
                                        Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
                                    }
                                    Text("\(item.locator) · \(stateLabel(item)) · @\(item.author)").font(.caption2).foregroundStyle(Color.secondary).lineLimit(1)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected?.id == item.id ? appearance.accent.opacity(0.08) : .clear)
                            }.buttonStyle(.plain).disabled(plugins.busy)
                            Divider()
                        }
                        if nextCursor != nil || nextPage != nil { Button("Load more") { loadMore() }.padding(12).disabled(plugins.busy) }
                    }
                }.frame(minWidth: 260, idealWidth: 300)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let item = selected { itemDetail(item) }
                        else { Text("Selecting an item reads it again from GitHub.").font(.caption).foregroundStyle(Color.secondary).padding(.top, 20) }
                        Divider()
                        taskSection
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 360)
            }
            Text("Scope comes from the repository picker; repo:, org:, user:, and owner: qualifiers are not accepted. Imported item text stays on GitHub.").font(.caption2).foregroundStyle(Color.secondary)
        }.padding(16).disabled(board.isMutating)
            .task { await open() }
            .onDisappear { session.close() }
            .sheet(item: $preview) { value in
                GitHubWritePreviewSheet(preview: value, accent: appearance.accent, onConfirm: { confirmWrite(value) }, onCancel: { preview = nil })
            }
    }

    @ViewBuilder private func itemDetail(_ item: GitHubItem) -> some View {
        Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
        HStack(spacing: 6) {
            badge(stateLabel(item), stateColor(item))
            if item.draft { badge("Draft", .secondary) }
            ForEach(Array(item.labels.prefix(6).enumerated()), id: \.offset) { badge($0.element, .blue) }
        }
        Text("\(item.locator) · \(item.kindName) opened by @\(item.author) · updated \(BoardDate.shortLocalTimestamp(item.updatedAt))").font(.caption).foregroundStyle(Color.secondary)
        if item.isPull, let head = item.headRef {
            Text("\(head) → \(item.baseRef ?? "base") · \(String((item.headSHA ?? "").prefix(7)))").font(.system(.caption, design: .monospaced)).foregroundStyle(Color.secondary).textSelection(.enabled)
        }
        if let url = item.url { Link("Open on GitHub", destination: url).font(.caption) }
        if let body = item.body, !body.isEmpty {
            Text(body).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if item.bodyTruncated { Text("The description is shortened. Open it on GitHub to read all of it.").font(.caption2).foregroundStyle(Color.secondary) }
        } else { Text("No description.").font(.caption).foregroundStyle(Color.secondary) }
        Divider()
        if let task = board.selectedTask {
            Text("Selected task: \(task.title)").font(.caption).foregroundStyle(Color.secondary)
            if isLinked(item, to: task) { Label("Already linked to this task", systemImage: "link").font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Attach to this task") { attach(item, task: task) }
                Button("Import as a subtask of this task") { importItem(item, parent: task) }
            }.disabled(plugins.busy)
            if writeEnabled { Button("Comment task status…") { preparePreview(.comment, task: task, repo: item.repo, number: item.number) }.disabled(plugins.busy || pendingWrite != nil) }
        }
        Picker("Project", selection: $projectID) {
            Text("Select project").tag("")
            ForEach(board.projects) { Text($0.name).tag($0.id) }
        }
        Button("Import as a new task") { importItem(item) }.buttonStyle(BoardPrimaryButtonStyle(color: appearance.accent)).disabled(projectID.isEmpty || plugins.busy)
        Text("Imported tasks start in To do. GitHub assignees do not become board assignees.").font(.caption2).foregroundStyle(Color.secondary)
    }

    @ViewBuilder private var taskSection: some View {
        if let task = board.selectedTask {
            let links = linkedItems(for: task)
            HStack { Text("Linked GitHub items").font(.subheadline.weight(.medium)); Spacer(); Button("Check linked status") { checkLinked(links, task: task) }.disabled(links.isEmpty || plugins.busy) }
            if links.isEmpty { Text("This task has no linked issues or pull requests in connected repositories.").font(.caption).foregroundStyle(Color.secondary) }
            ForEach(links) { link in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Link(link.reference.locator, destination: link.url).font(.caption.weight(.medium))
                        Spacer()
                        if writeEnabled { Button("Comment task status…") { preparePreview(.comment, task: task, repo: link.reference.repo, number: link.reference.number) }.controlSize(.small).disabled(plugins.busy || pendingWrite != nil) }
                    }
                    if statusTaskID == task.id, let entry = statuses[link.id] {
                        if entry["error"] != .null {
                            Text(entry["error"]["message"].string ?? "Could not check this item.").font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
                        } else {
                            if let title = entry["title"].string { Text(title).font(.caption).lineLimit(2) }
                            Text(GitHubLinkedItem.statusSummary(entry)).font(.caption2).foregroundStyle(Color.secondary)
                            if entry["changed"].bool == true { Label("Changed since linked", systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange) }
                        }
                    } else if let state = link.linkedState { Text("State when linked: \(state)").font(.caption2).foregroundStyle(Color.secondary) }
                }.padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("Checking status only reads GitHub. It never changes the task status.").font(.caption2).foregroundStyle(Color.secondary)
            if writeEnabled {
                Divider()
                HStack {
                    Picker("Repository", selection: $issueRepo) { Text("Select repository").tag(""); ForEach(repos, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 260)
                    Button("Create a GitHub issue from this task…") { preparePreview(.issue, task: task, repo: issueRepo, number: nil) }.disabled(issueRepo.isEmpty || plugins.busy || pendingWrite != nil)
                }
                Text("Writing posts only the task title, status, assignee, next action, due date, ID, and revision, after you review the exact text.").font(.caption2).foregroundStyle(Color.secondary)
            }
        } else { Text("Select a task on the board to link items, check linked status, or write the task status.").font(.caption).foregroundStyle(Color.secondary) }
    }

    private var accountSummary: String {
        guard let login else { return auth == "token" ? "Personal access token" : "gh CLI sign-in" }
        let mode = writeEnabled ? (identityVerified ? "writing enabled, account verified" : "writing enabled, account not verified") : "read only"
        return "@\(login) · \(mode)"
    }
    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2).foregroundStyle(color).background(color.opacity(0.14), in: Capsule())
    }
    private func stateLabel(_ item: GitHubItem) -> String {
        if item.merged { return "Merged" }
        if item.state == "open" { return "Open" }
        return item.stateReason == "not_planned" ? "Closed as not planned" : item.state == "closed" ? "Closed" : item.state
    }
    private func stateColor(_ item: GitHubItem) -> Color { item.merged ? .purple : item.state == "open" ? .green : .secondary }
    private func artifacts(for task: BoardTask) -> [TaskArtifact] { board.detail?.task.id == task.id ? board.detail?.artifacts ?? [] : [] }
    private func linkedItems(for task: BoardTask) -> [GitHubLinkedItem] { GitHubLinkedItem.from(artifacts(for: task), configuredRepos: configuredRepos + repos) }
    private func isLinked(_ item: GitHubItem, to task: BoardTask) -> Bool { GitHubLinkedItem.isLinked(itemKey: item.id, in: artifacts(for: task)) }

    private func run(_ method: String, params: [String: JSONValue] = [:], requestID: String? = nil, also: () -> Bool = { true }) async -> JSONValue? {
        await plugins.run(plugin, method: method, params: params, configuration: session.configuration, requestID: requestID,
                          isCurrent: { session.isCurrent(appearance) && also() })
    }
    private func open() async {
        session.bind(appearance)
        pendingWrite = pendingWrites.load(for: session.configuration.identity())
        projectID = board.projects.first(where: { $0.id == board.selectedProjectID })?.id ?? board.projects.first?.id ?? ""
        let projects = board.projects
        remoteMap = await Task.detached { GitHubRemote.repositories(for: projects) }.value
        if let response = await plugins.call("plugin.config", params: ["id": .string(plugin.id)], configuration: session.configuration, isCurrent: { session.isCurrent(appearance) }) {
            auth = response["config"]["auth"].string ?? "gh"
            configuredRepos = GitHubRepoName.unique(response["config"]["repos"].array.compactMap(\.string).filter(GitHubRepoName.isValid))
            repos = configuredRepos
        }
        await refreshCheck()
    }
    private func refreshCheck() async {
        guard let result = await run("check") else { return }
        auth = result["auth"].string ?? auth
        repos = GitHubRepoName.unique(result["repos"].array.compactMap { $0["repo"].string }.filter(GitHubRepoName.isValid))
        unmatched = result["unmatched"].array; login = result["login"].string
        writeEnabled = result["write_enabled"].bool == true; identityVerified = result["identity_verified"].bool == true
        if !repos.contains(repoFilter) { repoFilter = "" }
        if let task = board.selectedTask, let remote = remoteMap[task.projectID], let match = repos.first(where: { $0.lowercased() == remote.lowercased() }) { issueRepo = match }
        else if !repos.contains(issueRepo) { issueRepo = repos.first ?? "" }
    }
    private func authorize() {
        Task {
            guard let result = await run("authorize") else { return }
            let name = result["login"].string.map { "@" + $0 } ?? "the account"
            plugins.notice = auth == "token" ? "Token verified for \(name) and stored in Keychain." : "gh sign-in verified for \(name)."
            await refreshCheck()
        }
    }
    private func disconnect() {
        Task {
            guard await run("disconnect") != nil else { return }
            identityVerified = false
            if auth == "token" {
                login = nil; items = []; selected = nil; statuses = [:]; nextCursor = nil; nextPage = nil; didLoad = false
                plugins.notice = "Token removed from Keychain. It stays valid on GitHub until you revoke it there."
            } else { plugins.notice = "Verified account forgotten. The gh sign-in itself is unchanged." }
        }
    }
    private func load() {
        guard !plugins.busy else { return }
        if repoFilter.isEmpty { guard let first = repos.first else { return }; repoFilter = first }
        fetch(.list(repo: repoFilter, type: typeFilter, state: stateFilter), more: false)
    }
    private func search(assignedToMe: Bool = false) {
        let text = assignedToMe ? "is:open assignee:@me" : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !plugins.busy else { return }
        if assignedToMe { query = text }
        let repo = repoFilter.isEmpty ? nil : repoFilter
        fetch(.search(query: text, repo: repo, type: assignedToMe || typeFilter == "all" ? nil : typeFilter, state: assignedToMe || stateFilter == "all" ? nil : stateFilter), more: false)
    }
    private func loadMore() { if let lastQuery { fetch(lastQuery, more: true) } }
    private func fetch(_ request: GitHubQuery, more: Bool) {
        var params = request.parameters
        if more {
            if request.usesCursor, let nextCursor { params["cursor"] = .string(nextCursor) }
            else if !request.usesCursor, let nextPage { params["page"] = .number(Double(nextPage)) }
            else { return }
        }
        let values = params
        Task {
            if !more { selected = nil }
            guard let result = await run(request.method, params: values) else { return }
            let rows = result["items"].array.compactMap(GitHubItem.init)
            items = more ? items + rows.filter { row in !items.contains { $0.id == row.id } } : rows
            nextCursor = result["next_cursor"].string; nextPage = result["next_page"].int
            ssoPartial = result["sso_partial"].bool == true; lastQuery = request; didLoad = true
        }
    }
    private func read(_ item: GitHubItem) {
        Task {
            selected = nil
            guard let result = await run("items.read", params: item.parameters()) else { return }
            guard let full = GitHubItem(result), full.id == item.id else { plugins.error = "GitHub returned an item that does not match the selection."; return }
            selected = full
            if let project = board.projects.first(where: { remoteMap[$0.id]?.lowercased() == full.repo.lowercased() }) { projectID = project.id }
        }
    }
    private func attach(_ item: GitHubItem, task: BoardTask) {
        var params = item.parameters(verified: true)
        params["task_id"] = .string(task.id); params["expected_revision"] = .number(Double(task.revision))
        let values = params
        Task {
            if await run("items.attach", params: values) != nil { plugins.notice = "\(item.locator) attached to the task."; await board.reload(force: true) }
            else { sourceChanged(item) }
        }
    }
    private func importItem(_ item: GitHubItem, parent: BoardTask? = nil) {
        var params = item.parameters(verified: true)
        params["project_id"] = .string(parent?.projectID ?? projectID)
        if let parent { params["parent_id"] = .string(parent.id) }
        let values = params
        Task {
            if await run("items.import", params: values) != nil { plugins.notice = parent == nil ? "\(item.locator) imported as a new task." : "\(item.locator) imported as a subtask."; await board.reload(force: true) }
            else { sourceChanged(item) }
        }
    }
    /// A changed source is never linked: drop the stale read so the user reviews the latest version first.
    private func sourceChanged(_ item: GitHubItem) {
        guard plugins.errorCode == "CONFLICT", selected?.id == item.id else { return }
        selected = nil
        plugins.error = "\(item.locator) changed on GitHub after you read it. Select it again and review the latest version before linking it."
    }
    private func checkLinked(_ links: [GitHubLinkedItem], task: BoardTask) {
        let taskID = task.id
        Task {
            var collected: [String: JSONValue] = [:]
            for start in stride(from: 0, to: links.count, by: 10) {
                let batch = links[start..<min(start + 10, links.count)].map(\.statusParameters)
                guard let result = await run("items.status", params: ["items": .array(batch)], also: { board.selectedTaskID == taskID }) else { return }
                for entry in result["items"].array {
                    if let repo = entry["repo"].string, let number = entry["number"].int { collected[repo.lowercased() + "#\(number)"] = entry }
                }
            }
            guard board.selectedTaskID == taskID else { return }
            statuses = collected; statusTaskID = taskID
        }
    }
    private func preparePreview(_ kind: GitHubWriteOperation.Kind, task: BoardTask, repo: String, number: Int?) {
        if let pendingWrite { plugins.error = pendingWrite.checkHint; return }
        var params: [String: JSONValue] = ["task_id": .string(task.id), "expected_revision": .number(Double(task.revision)), "kind": .string(kind.rawValue), "repo": .string(repo)]
        if let number { params["number"] = .number(Double(number)) }
        let values = params, taskID = task.id, revision = task.revision
        Task {
            guard let result = await run("tasks.preview", params: values, also: { board.selectedTaskID == taskID }) else { return }
            guard result["body"].string?.isEmpty == false else { plugins.error = "The preview did not include the text to post."; return }
            preview = GitHubWritePreview(kind: kind, taskID: taskID, taskRevision: revision, repo: repo, number: number, result: result)
        }
    }
    private func confirmWrite(_ value: GitHubWritePreview) {
        preview = nil
        guard value.blocker == nil, session.isCurrent(appearance), !plugins.busy else { return }
        guard let task = board.selectedTask, task.id == value.taskID else { plugins.error = "Select the previewed task again before writing."; return }
        if let pendingWrite, !pendingWrite.matches(kind: value.kind, task: task, repo: value.repo, number: value.number, configuration: session.configuration) {
            plugins.error = "The task, target, or board differs from the previous write. " + pendingWrite.checkHint
            return
        }
        let operation = pendingWrite ?? GitHubWriteOperation(kind: value.kind, taskID: value.taskID, revision: value.taskRevision, repo: value.repo, number: value.number, title: value.title, configuration: session.configuration)
        pendingWrites.save(operation); pendingWrite = operation
        Task { await perform(operation) }
    }
    private func retryPendingWrite() {
        guard let operation = pendingWrite, session.isCurrent(appearance), !plugins.busy else { return }
        let number = operation.parameters["number"]?.int, repo = operation.parameters["repo"]?.string ?? ""
        guard let task = board.selectedTask, operation.matches(kind: operation.kind, task: task, repo: repo, number: number, configuration: session.configuration) else {
            plugins.error = "Select the task of the previous write to check it again."; return
        }
        Task { await perform(operation) }
    }
    private func perform(_ operation: GitHubWriteOperation) async {
        plugins.error = nil
        let method = operation.kind == .comment ? "tasks.comment" : "tasks.create_issue"
        if let result = await run(method, params: operation.parameters, requestID: operation.requestID) {
            finish(operation)
            let target = "\(result["repo"].string ?? "")#\(result["number"].int.map(String.init) ?? "")"
            plugins.notice = operation.kind == .comment ? "Status comment posted on \(target) and linked to the task." : "Created \(target) and linked it to the task."
            await board.reload(force: true)
        } else if session.isCurrent(appearance), !GitHubWriteOperation.shouldRetain(afterErrorCode: plugins.errorCode, message: plugins.errorMessage) {
            finish(operation)
        }
    }
    /// Forgets a write that succeeded or provably never reached GitHub, here and in the stored copy.
    private func finish(_ operation: GitHubWriteOperation?) {
        guard let operation else { return }
        pendingWrites.remove(operation)
        if pendingWrite?.requestID == operation.requestID { pendingWrite = nil }
    }
}

private struct GitHubWritePreviewSheet: View {
    let preview: GitHubWritePreview
    let accent: Color
    let onConfirm: () -> Void
    let onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(preview.kind == .comment ? "Comment task status" : "Create a GitHub issue").font(.title2.weight(.semibold))
                Text(preview.kind == .comment ? "On \(preview.repo)#\(preview.number ?? 0)" : "In \(preview.repo)").font(.callout).foregroundStyle(Color.secondary)
            }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let title = preview.title { LabeledContent("Issue title") { Text(title).textSelection(.enabled) } }
                    Text("Exact text to post").font(.caption.weight(.medium))
                    Text(preview.body).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    if preview.isPublic {
                        Label(preview.kind == .comment ? "This repository is public. Anyone can read this comment." : "This repository is public. Anyone can read this issue.", systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    } else { Label("This repository is private.", systemImage: "lock").font(.caption).foregroundStyle(Color.secondary) }
                    Text(preview.login.isEmpty ? "The posting account is not verified." : "Posts as @\(preview.login). GitHub writes are never retried automatically.").font(.caption).foregroundStyle(Color.secondary)
                    if let blocker = preview.blocker { Text(blocker).font(.caption).foregroundStyle(.red) }
                }.padding(.horizontal, 24).padding(.bottom, 16)
            }
            Divider()
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(preview.kind == .comment ? "Post comment as @\(preview.login)" : "Create issue as @\(preview.login)", action: onConfirm)
                    .buttonStyle(BoardPrimaryButtonStyle(color: accent)).disabled(preview.blocker != nil)
            }.padding(20)
        }.frame(width: 560, height: 520)
    }
}
