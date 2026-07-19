// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "pinentry-companion",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "pinentry-companion", targets: ["PinentryCompanion"]),
    ],
    targets: [
        .target(name: "PinentryCompanionCore", path: "Sources/PinentryCompanionCore"),
        .executableTarget(
            name: "PinentryCompanion",
            dependencies: ["PinentryCompanionCore"],
            path: "Sources/PinentryCompanion"
        ),
        .testTarget(
            name: "PinentryCompanionUnitTests",
            dependencies: ["PinentryCompanionCore"],
            path: "Tests/PinentryCompanionTests"
        ),
    ]
)
