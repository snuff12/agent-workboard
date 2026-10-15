// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentWorkboard",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WorkboardApp", targets: ["WorkboardApp"])],
    targets: [
        .executableTarget(name: "WorkboardApp", path: "Sources/WorkboardApp")
    ]
)
