// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "pinentry-companion",
    platforms: [.macOS(.v10_13)],
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
        .executableTarget(
            name: "PinentryCompanionUnitTests",
            dependencies: ["PinentryCompanionCore"],
            path: "Tests/PinentryCompanionTests"
        ),
    ]
)
