// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "rollkeep",
    products: [
        .executable(name: "rollkeep", targets: ["rollkeep"]),
    ],
    targets: [
        .executableTarget(
            name: "rollkeep"
        ),
    ]
)
