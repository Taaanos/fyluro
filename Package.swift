// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "fyluro",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "fyluro", targets: ["fyluro"]),
        .executable(name: "fyluro-launcher", targets: ["fyluroLauncher"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "FyluroCore",
            dependencies: []
        ),
        .target(
            name: "FyluroEngine",
            dependencies: ["FyluroCore"]
        ),
        .executableTarget(
            name: "fyluro",
            dependencies: [
                "FyluroCore",
                "FyluroEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "fyluroLauncher",
            dependencies: ["FyluroCore", "FyluroEngine"]
        ),
        .testTarget(
            name: "fyluroTests",
            dependencies: ["fyluro", "FyluroCore", "FyluroEngine"],
            // Oracle snapshot JSON is read via #filePath, not bundled.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "FyluroEngineTests",
            dependencies: ["FyluroEngine", "FyluroCore"]
        ),
        .testTarget(
            name: "fyluroLauncherTests",
            dependencies: ["fyluroLauncher", "FyluroCore"]
        ),
    ]
)
