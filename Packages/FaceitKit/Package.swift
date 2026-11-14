// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FaceitKit",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "FaceitKit", targets: ["FaceitKit"]),
        .library(name: "FaceitUI", targets: ["FaceitUI"]),
    ],
    targets: [
        // Data layer: API client, models, statistics, storage, sync. No UI.
        .target(
            name: "FaceitKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Shared SwiftUI: theme, widget layouts, reusable components.
        .target(name: "FaceitUI", dependencies: ["FaceitKit"]),
        // Renders widget layouts to PNG from fixtures (design review / visual checks, macOS only).
        .executableTarget(name: "SnapshotTool", dependencies: ["FaceitKit", "FaceitUI"]),
        .testTarget(
            name: "FaceitKitTests",
            dependencies: ["FaceitKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
