// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ChronoframeUI",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "ChronoframeCore", targets: ["ChronoframeCore"]),
        .library(name: "ChronoframeAppCore", targets: ["ChronoframeAppCore"]),
        .library(name: "ChronoframeCLIKit", targets: ["ChronoframeCLIKit"]),
        .library(name: "ChronoframePackaging", targets: ["ChronoframePackaging"]),
        .executable(name: "ChronoframeApp", targets: ["ChronoframeApp"]),
        .executable(name: "ChronoframeCLI", targets: ["ChronoframeCLI"]),
        .executable(name: "ChronoframePackagingTool", targets: ["ChronoframePackagingTool"]),
        .executable(name: "ChronoframeIconTool", targets: ["ChronoframeIconTool"]),
    ],
    targets: [
        .target(
            name: "ChronoframeCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "ChronoframeAppCore",
            dependencies: ["ChronoframeCore"]
        ),
        .target(
            name: "ChronoframeCLIKit",
            dependencies: ["ChronoframeAppCore", "ChronoframeCore"]
        ),
        .target(
            name: "ChronoframePackaging"
        ),
        .executableTarget(
            name: "ChronoframeApp",
            dependencies: ["ChronoframeAppCore"]
        ),
        .executableTarget(
            name: "ChronoframeCLI",
            dependencies: ["ChronoframeCLIKit"]
        ),
        .executableTarget(
            name: "ChronoframePackagingTool",
            dependencies: ["ChronoframePackaging"]
        ),
        // Procedural renderer for the macOS app icon. Run via
        // `swift run ChronoframeIconTool <output-dir>` to regenerate every
        // PNG variant (Any / Dark / Tinted × all sizes) for the
        // `Assets.xcassets/AppIcon.appiconset`. The tool is the single
        // source of truth for the icon design — colors and geometry live
        // in code, not in a Sketch/Figma file.
        .executableTarget(
            name: "ChronoframeIconTool"
        ),
        .testTarget(
            name: "ChronoframeAppCoreTests",
            dependencies: ["ChronoframeAppCore", "ChronoframeCore"],
            path: "Tests/ChronoframeAppCoreTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "ChronoframeAppTests",
            dependencies: ["ChronoframeApp"],
            path: "Tests/ChronoframeAppTests"
        ),
        .testTarget(
            name: "ChronoframeCLIKitTests",
            // Depending on the executable target forces SwiftPM to
            // build the CLI binary as part of `swift test`, which lets
            // the subprocess-boundary regression tests exec it directly
            // (PHASE2_FINDINGS.md NEW15).
            dependencies: ["ChronoframeCLIKit", "ChronoframeCLI"],
            path: "Tests/ChronoframeCLIKitTests"
        ),
        .testTarget(
            name: "ChronoframePackagingTests",
            dependencies: ["ChronoframePackaging"],
            path: "Tests/ChronoframePackagingTests"
        ),
    ]
)
