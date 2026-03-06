// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "rollkeep",
    products: [
        .executable(name: "rollkeep", targets: ["rollkeep"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "rollkeep",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "rollkeepTests",
            dependencies: ["rollkeep"]
        ),
    ]
)
