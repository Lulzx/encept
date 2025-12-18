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
            name: "encept",
            targets: ["encept"]
        )
    ],
    targets: [
        // Zig core library (pre-built)
        .systemLibrary(
            name: "EnceptCore",
            path: "Sources/EnceptCore",
            pkgConfig: nil,
            providers: []
        ),

        // Swift framework
        .target(
            name: "Encept",
            dependencies: ["EnceptCore"],
            path: "Sources/Encept",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        // CLI tool
        .executableTarget(
            name: "encept",
            dependencies: ["Encept"],
            path: "Sources/encept"
        ),

        // Tests
        .testTarget(
            name: "EnceptTests",
            dependencies: ["Encept"],
            path: "Tests/EnceptTests",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
