// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "WearableCompanion",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WearableCompanion", targets: ["WearableCompanion"])
    ],
    targets: [
        .executableTarget(name: "WearableCompanion"),
        .testTarget(
            name: "WearableCompanionTests",
            dependencies: ["WearableCompanion"]
        )
    ]
)
