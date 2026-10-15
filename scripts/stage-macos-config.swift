import Foundation

guard CommandLine.arguments.count == 4 else {
    fatalError("Usage: stage-macos-config.swift APP_GROUP SOURCE_DIR OUTPUT_DIR")
}
let group = CommandLine.arguments[1]
guard group.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$"#, options: .regularExpression) != nil,
      group.contains("."), !group.contains("..") else { fatalError("Invalid App Group identifier") }
let source = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let destination = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for filename in ["App-Info.plist", "Widget-Info.plist", "App.entitlements", "Widget.entitlements", "Service.entitlements"] {
    let data = try Data(contentsOf: source.appendingPathComponent(filename))
    var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
    if filename.hasSuffix(".entitlements") {
        plist["com.apple.security.application-groups"] = [group]
    } else {
        plist["WorkboardAppGroupIdentifier"] = group
    }
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: destination.appendingPathComponent(filename), options: .atomic)
}
