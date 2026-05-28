// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexTrafficLight",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "CodexTrafficLight",
            targets: ["CodexTrafficLight"]
        )
    ],
    targets: [
        .executableTarget(
            name: "CodexTrafficLight",
            path: "Sources/CodexTrafficLight",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
