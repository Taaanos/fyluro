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
            dependencies: []
        ),
        .executableTarget(
            name: "rollkeep",
            dependencies: [
                "RollKeepCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "rollkeepLauncher",
            dependencies: ["RollKeepCore"]
        ),
        .testTarget(
            name: "rollkeepTests",
            dependencies: ["rollkeep", "RollKeepCore"]
        ),
        .testTarget(
            name: "rollkeepLauncherTests",
            dependencies: ["rollkeepLauncher", "RollKeepCore"]
        ),
    ]
)
