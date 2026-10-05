// swift-tools-version: 5.10
import PackageDescription

// Link the executables against the SDK they are built with, not the
// deployment target. SwiftPM's Swift Build engine (the default since Swift
// 6.4 / Xcode 27) runs the link with an environment of PATH only, so the
// SDKROOT the `swift` shim exports never reaches clang, which derives the
// SDK version only from `-isysroot` or SDKROOT, not the `--sysroot` swiftc
// passes; ld then recorded 14.0 as the SDK. macOS then runs the binary with its
// macOS 14 compatibility behaviour, under which the sidebar's scroll view
// insets its clip view below the title bar *and* offsets the content by the
// same 52pt: rows drew one and a half rows below where they took clicks, under
// an empty band. `swift` (the xcrun shim) exports SDKROOT, so hand it on.
// Scripts/check-sdk-linkage.sh, run by `make build`, checks the result.
let linkAgainstBuildSDK: [LinkerSetting] = Context.environment["SDKROOT"].map {
    [.unsafeFlags(["-Xclang-linker", "-isysroot", "-Xclang-linker", $0])]
} ?? []

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

        // This Mac's transcripts: the local stores, byte reads, FSEvents and
        // the shared-facts cache behind `LocalSessionSource`, its one public
        // type. The pure agent formats stay in TempleCore/Formats, where a
        // remote host reuses them. TempleUI names it in one composition file
        // (`Hosts/LocalHost.swift`); templectl imports it directly.
        .target(name: "TempleLocalHost", dependencies: ["TempleCore"]),

        // Terminal seam (PLAN.md "Decoupling interfaces"): TerminalSurface
        // protocol + stub. Imports AppKit; free of ghostty and TempleCore.
        .target(name: "TempleTerminalAPI"),

        // The SwiftUI/AppKit app shell as a library so it is unit-testable
        // (executables can't be imported cleanly). Bundles the agent brand icons.
        .target(
            name: "TempleUI",
            dependencies: ["TempleCore", "TempleLocalHost", "TempleTerminalAPI"],
            resources: [.process("Resources")]
        ),

        // Thin @main entry — launches TempleUI's app scene with the production
        // libghostty terminal factory (the PLAN.md "fuse").
        .executableTarget(name: "Temple", dependencies: ["TempleUI", "TempleTerminal"],
                          linkerSettings: linkAgainstBuildSDK),

        // CLI that prints the real project → session index.
        .executableTarget(name: "templectl", dependencies: ["TempleCore", "TempleLocalHost"],
                          linkerSettings: linkAgainstBuildSDK),

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
        .executableTarget(name: "terminal-demo", dependencies: ["TempleTerminal", "TempleTerminalAPI"],
                          linkerSettings: linkAgainstBuildSDK),

        // Test doubles shared by test targets (FakeHostSource, SQL tracing).
        // Nothing in a product links it.
        .target(name: "TempleTestSupport", dependencies: ["TempleCore"]),

        .testTarget(name: "TempleCoreTests", dependencies: ["TempleCore", "TempleLocalHost", "TempleTestSupport"], exclude: ["Fixtures/session-state-v8.json", "Fixtures/session-state-v9.json", "Fixtures/session-state-v11.json", "Fixtures/format-golden.json"]),
        .testTarget(name: "TempleUITests", dependencies: ["TempleUI", "TempleLocalHost", "TempleTestSupport"]),
        .testTarget(name: "TempleTerminalTests", dependencies: ["TempleTerminal", "TempleUI"]),
    ]
)
