// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Temple",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TempleCore", targets: ["TempleCore"]),
        .library(name: "TempleUI", targets: ["TempleUI"]),
        // Exposed so the U6 Xcode app target can link the ghostty engine.
        .library(name: "TempleTerminal", targets: ["TempleTerminal"]),
        .executable(name: "temple", targets: ["Temple"]),
        .executable(name: "templectl", targets: ["templectl"]),
        // Track T dev harness: one window, one libghostty surface.
        .executable(name: "terminal-demo", targets: ["terminal-demo"]),
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

        // Thin @main entry — launches TempleUI's app scene with the production
        // libghostty terminal factory (the PLAN.md "fuse").
        .executableTarget(name: "Temple", dependencies: ["TempleUI", "TempleTerminal"]),

        // CLI that prints the real project → session index.
        .executableTarget(name: "templectl", dependencies: ["TempleCore"]),

        // Track T — libghostty engine.
        // Prebuilt embeddable artifact from Scripts/build-ghostty.sh (see
        // docs/BUILDING-GHOSTTY.md). Not in git; run the script to produce it.
        .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),

        // Production TerminalSurface backed by libghostty.
        // The linker settings satisfy libghostty-fat.a's system dependencies
        // (C++ deps like harfbuzz/glslang; TIS keyboard APIs live in Carbon).
        .target(
            name: "TempleTerminal",
            dependencies: ["TempleTerminalAPI", "GhosttyKit"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),

        // Dev harness executable (like templectl is for TempleCore).
        .executableTarget(name: "terminal-demo", dependencies: ["TempleTerminal", "TempleTerminalAPI"]),

        .testTarget(name: "TempleCoreTests", dependencies: ["TempleCore"]),
        .testTarget(name: "TempleUITests", dependencies: ["TempleUI"]),
        .testTarget(name: "TempleTerminalTests", dependencies: ["TempleTerminal"]),
    ]
)
