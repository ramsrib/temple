// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Temple",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TempleCore", targets: ["TempleCore"]),
        .executable(name: "temple", targets: ["Temple"]),
        .executable(name: "templectl", targets: ["templectl"]),
        // Track T dev harness: one window, one libghostty surface.
        .executable(name: "terminal-demo", targets: ["terminal-demo"]),
    ],
    targets: [
        // Pure logic — no AppKit/SwiftUI (ADR-006).
        .target(name: "TempleCore"),

        // Terminal seam (PLAN.md "Decoupling interfaces"): TerminalSurface
        // protocol + stub. Imports AppKit; free of ghostty and TempleCore.
        .target(name: "TempleTerminalAPI"),

        // The SwiftUI/AppKit app shell (terminal pane is stubbed until Phase 3).
        .executableTarget(name: "Temple", dependencies: ["TempleCore", "TempleTerminalAPI"]),

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
        .testTarget(name: "TempleTerminalTests", dependencies: ["TempleTerminal"]),
    ]
)
