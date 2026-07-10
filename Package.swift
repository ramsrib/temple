// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Temple",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TempleCore", targets: ["TempleCore"]),
        .library(name: "TempleUI", targets: ["TempleUI"]),
        .executable(name: "temple", targets: ["Temple"]),
        .executable(name: "templectl", targets: ["templectl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.3"),
    ],
    targets: [
        // Pure logic — no AppKit/SwiftUI (ADR-006).
        .target(name: "TempleCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),

        // Terminal seam (PLAN.md "Decoupling interfaces"): TerminalSurface
        // protocol + stub. Imports AppKit; free of ghostty and TempleCore.
        .target(name: "TempleTerminalAPI"),

        // The SwiftUI/AppKit app shell as a library so it is unit-testable
        // (executables can't be imported cleanly). Bundles the agent brand icons.
        .target(
            name: "TempleUI",
            dependencies: ["TempleCore", "TempleTerminalAPI"],
            resources: [.process("Resources")]
        ),

        // Thin @main entry — just launches TempleUI's app scene.
        .executableTarget(name: "Temple", dependencies: ["TempleUI"]),

        // CLI that prints the real project → session index.
        .executableTarget(name: "templectl", dependencies: ["TempleCore"]),

        .testTarget(name: "TempleCoreTests", dependencies: ["TempleCore"]),
        .testTarget(name: "TempleUITests", dependencies: ["TempleUI"]),
    ]
)
