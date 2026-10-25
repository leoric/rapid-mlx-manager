// swift-tools-version:5.9
import PackageDescription

// Sources are expected in Sources/RapidManager (SwiftPM's default layout).
let package = Package(
    name: "RapidManager",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "RapidManager")
    ]
)
