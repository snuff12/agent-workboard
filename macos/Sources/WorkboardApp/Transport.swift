import Foundation

struct ConnectionConfiguration: Sendable {
    var executablePath = ""
    var dataDirectory = ""
    var sharesWidgetSnapshot = true

    func identity(environment: [String: String] = ProcessInfo.processInfo.environment) -> ConnectionIdentity {
        func path(_ value: String?, automatic: String) -> String {
            guard let value, !value.isEmpty else { return automatic }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        return ConnectionIdentity(
            executable: path(executablePath.isEmpty ? environment["WORKBOARD_BIN"] : executablePath, automatic: "<automatic-core-cli>"),
            dataDirectory: path(dataDirectory.isEmpty ? environment["WORKBOARD_DATA_DIR"] : dataDirectory, automatic: "<default-data-directory>"),
            socket: path(environment["WORKBOARD_SOCKET"], automatic: "<data-directory-socket>")
        )
    }
}

struct ConnectionIdentity: Sendable, Hashable {
    let executable: String
    let dataDirectory: String
    let socket: String
}

actor WorkboardClient {
    func call(_ method: String, params: [String: JSONValue] = [:], configuration: ConnectionConfiguration, timeoutSeconds: Double = 45, requestID: String? = nil) async throws -> JSONValue {
        let executable = try Self.resolveExecutable(override: configuration.executablePath)
        let process = Process()
        process.executableURL = executable
        var arguments: [String] = []
        if let requestID { arguments += ["--request-id", requestID] }
        if !configuration.dataDirectory.isEmpty { arguments += ["--data-dir", (configuration.dataDirectory as NSString).expandingTildeInPath] }
        arguments += ["rpc", method, "--params", String(decoding: try JSONEncoder().encode(JSONValue.object(params)), as: UTF8.self), "--json"]
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"; process.environment = environment
        if configuration.sharesWidgetSnapshot, let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WorkboardAppGroup.identifier) {
            environment["WORKBOARD_WIDGET_SNAPSHOT"] = container.appendingPathComponent("widget-snapshot.json").path
            process.environment = environment
        }
        let output = Pipe(); process.standardOutput = output
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("workboard-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorURL) }
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }
        process.standardError = errorHandle
        do { try process.run() }
        catch { throw WorkboardError(message: "Could not connect to the task service. Check the workboard executable in Settings.\n\(error.localizedDescription)") }
        let running = RunningProcess(process)
        let timeout = DispatchWorkItem { if running.process.isRunning { running.process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        guard !data.isEmpty else {
            let stderr = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw WorkboardError(message: stderr.isEmpty ? "No response from the service. Check its status before retrying." : String(stderr.prefix(2000)))
        }
        let envelope: JSONValue
        do { envelope = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw WorkboardError(message: "Could not read the service response format. Check the app and CLI versions.") }
        if envelope["ok"].bool == false || envelope["error"] != .null {
            let message = envelope["error"]["message"].string ?? envelope["error"].string ?? "Could not process the request."
            let code = envelope["error"]["code"].string ?? ""
            if code.lowercased().contains("conflict") || code.lowercased().contains("revision") {
                throw WorkboardError(message: "The task was changed elsewhere. Read the latest version before retrying.\n\(message)")
            }
            throw WorkboardError(message: message)
        }
        if process.terminationStatus != 0 { throw WorkboardError(message: "The request exited with code \(process.terminationStatus).") }
        return envelope["result"] == .null ? envelope : envelope["result"]
    }

    static func resolveExecutable(override: String, environment: [String: String] = ProcessInfo.processInfo.environment, bundleURL: URL = Bundle.main.bundleURL, executableURL: URL? = Bundle.main.executableURL, currentDirectory: String = FileManager.default.currentDirectoryPath) throws -> URL {
        let manager = FileManager.default
        if !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            guard manager.isExecutableFile(atPath: url.path) else { throw WorkboardError(message: "Configured workboard executable not found: \(url.path)") }
            return url
        }
        if let path = environment["WORKBOARD_BIN"], !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard manager.isExecutableFile(atPath: url.path) else { throw WorkboardError(message: "WORKBOARD_BIN executable not found: \(url.path)") }
            return url
        }
        var candidates = [bundleURL.appendingPathComponent("Contents/Helpers/workboard"), bundleURL.appendingPathComponent("Contents/MacOS/workboard")]
        if let executableURL {
            var directory = executableURL.deletingLastPathComponent()
            for _ in 0..<7 {
                candidates.append(directory.appendingPathComponent("workboard"))
                candidates.append(directory.appendingPathComponent("target/debug/workboard"))
                candidates.append(directory.appendingPathComponent("target/release/workboard"))
                directory.deleteLastPathComponent()
            }
        }
        candidates.append(URL(fileURLWithPath: currentDirectory).appendingPathComponent("target/debug/workboard"))
        candidates.append(URL(fileURLWithPath: currentDirectory).appendingPathComponent("target/release/workboard"))
        // Only the core CLI is discovered here. Disabled plugins are never searched for or invoked.
        for candidate in candidates where manager.isExecutableFile(atPath: candidate.path) { return candidate }
        throw WorkboardError(message: "workboard executable not found. Choose its path in Settings → Connection. For development, run cargo build first.")
    }
}

private final class RunningProcess: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}
