// swift-tools-version:5.10
// Command-Line-Tools build of the macOS app + widget (no Xcode needed) — used by build.sh / release.sh.
// The Xcode project (project.yml → XcodeGen) builds the same sources for macOS and iOS.
import PackageDescription

let package = Package(
    name: "SimpleFaceitWidget",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "Packages/FaceitKit")],
    targets: [
        .executableTarget(
            name: "SimpleFaceit",
            dependencies: [.product(name: "FaceitKit", package: "FaceitKit"), .product(name: "FaceitUI", package: "FaceitKit")],
            path: "App/Shared",
            exclude: ["Assets.xcassets"],
            swiftSettings: [.define("CLT_BUILD")]
        ),
        .executableTarget(
            name: "SimpleFaceitWidget",
            dependencies: [.product(name: "FaceitKit", package: "FaceitKit"), .product(name: "FaceitUI", package: "FaceitKit")],
            path: "Widget",
            exclude: ["Info-macOS.plist", "Info-iOS.plist", "Widget-macOS.entitlements", "Widget-iOS.entitlements"],
            // Without Xcode there is no App Intents metadata processor, so the widget ships one static
            // widget per style instead of an AppIntent-configured one.
            swiftSettings: [.define("CLT_BUILD")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
    ]
)
