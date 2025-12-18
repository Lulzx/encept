// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Encept",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "Encept",
            targets: ["Encept"]
        ),
        .executable(
            name: "encept-cli",
            targets: ["encept-cli"]
        )
    ],
    targets: [
        // Swift framework
        .target(
            name: "Encept",
            path: "Sources/Encept",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        // CLI tool
        .executableTarget(
            name: "encept-cli",
            dependencies: ["Encept"],
            path: "Sources/CLI"
        ),

        // Tests
        .testTarget(
            name: "EnceptTests",
            dependencies: ["Encept"],
            path: "Tests/EnceptTests"
        )
    ]
)
