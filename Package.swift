// swift-tools-version:5.9
import PackageDescription

// Sources are expected in Sources/RapidManager (SwiftPM's default layout).
let package = Package(
    name: "rapid-manager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "rapid-manager", targets: ["RapidManager"])
    ],
    targets: [
        .executableTarget(name: "RapidManager")
    ]
)
