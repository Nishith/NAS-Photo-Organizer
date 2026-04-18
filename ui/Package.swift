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
        .executable(name: "ChronoframeApp", targets: ["ChronoframeApp"]),
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
        .executableTarget(
            name: "ChronoframeApp",
            dependencies: ["ChronoframeAppCore"]
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
    ]
)
