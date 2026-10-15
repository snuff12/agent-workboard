import Foundation

/// The signed app bundle selects its App Group without changing source code.
enum WorkboardAppGroup {
    static let infoKey = "WorkboardAppGroupIdentifier"
    static let fallbackIdentifier = "group.local.agentworkboard.shared"
    static let identifier = resolve(Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)

    static func resolve(_ configuredIdentifier: String?) -> String {
        guard let identifier = configuredIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty else { return fallbackIdentifier }
        return identifier
    }
}
