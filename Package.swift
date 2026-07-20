// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "rollkeep",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "rollkeep", targets: ["rollkeep"]),
        .executable(name: "rollkeep-launcher", targets: ["rollkeepLauncher"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "RollKeepCore",
            dependencies: [],
            resources: [
                .copy("Resources/CameraModelCatalogs"),
            ]
        ),
        .target(
            name: "RollKeepEngine",
            dependencies: ["RollKeepCore"]
        ),
        .executableTarget(
            name: "rollkeep",
            dependencies: [
                "RollKeepCore",
                "RollKeepEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "rollkeepLauncher",
            dependencies: ["RollKeepCore", "RollKeepEngine"]
        ),
        .testTarget(
            name: "rollkeepTests",
            dependencies: ["rollkeep", "RollKeepCore", "RollKeepEngine"],
            // Oracle snapshot JSON is read via #filePath, not bundled.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "RollKeepEngineTests",
            dependencies: ["RollKeepEngine", "RollKeepCore"]
        ),
        .testTarget(
            name: "rollkeepLauncherTests",
            dependencies: ["rollkeepLauncher", "RollKeepCore"]
        ),
    ]
)
