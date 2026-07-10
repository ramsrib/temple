// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Temple",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TempleCore", targets: ["TempleCore"]),
        .executable(name: "temple", targets: ["Temple"]),
        .executable(name: "templectl", targets: ["templectl"]),
    ],
    targets: [
        // Pure logic — no AppKit/SwiftUI (ADR-006).
        .target(name: "TempleCore"),

        // The SwiftUI/AppKit app shell (terminal pane is stubbed until Phase 3).
        .executableTarget(name: "Temple", dependencies: ["TempleCore"]),

        // CLI that prints the real project → session index.
        .executableTarget(name: "templectl", dependencies: ["TempleCore"]),

        .testTarget(name: "TempleCoreTests", dependencies: ["TempleCore"]),
    ]
)
