import XCTest
import GhosttyKit
@testable import TempleTerminal

/// T2 (SwiftPM interop) + T3 (runtime wrapper) + T6 (adaptation) coverage.
///
/// XCTest runs methods serially within a class. The runtime is a process-wide
/// singleton (`GhosttyApp.shared`) that performs the one-time `ghostty_init`, so
/// only `testZZZRuntimeShutdown` tears it down — named to sort last.
final class GhosttyRuntimeTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Point libghostty at the checkout's installed resources (T7) so init and
        // any runtime lookups resolve un-bundled.
        if ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] == nil {
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // TempleTerminalTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // repo root
            let res = repoRoot.appendingPathComponent("Vendor/ghostty/zig-out/share/ghostty")
            if FileManager.default.fileExists(atPath: res.path) {
                setenv("GHOSTTY_RESOURCES_DIR", res.path, 1)
            }
        }
    }

    // T2: the CGhostty/GhosttyKit binary target links and the C API is callable.
    @MainActor
    func testInteropConfigRoundTrip() throws {
        // Accessing shared performs ghostty_init exactly once.
        XCTAssertEqual(GhosttyApp.shared.readiness, .ready, "libghostty runtime failed to initialize")

        // A config handle round-trip proves the header/link are wired correctly.
        guard let cfg = ghostty_config_new() else {
            return XCTFail("ghostty_config_new returned nil")
        }
        ghostty_config_finalize(cfg)
        ghostty_config_free(cfg)
    }

    // T3: the runtime initializes with a live app handle.
    @MainActor
    func testRuntimeInitialized() {
        XCTAssertEqual(GhosttyApp.shared.readiness, .ready)
        XCTAssertNotNil(GhosttyApp.shared.app, "ghostty_app_new did not produce an app handle")
        // Ticking the runtime must not crash.
        GhosttyApp.shared.tick()
        GhosttyApp.shared.setFocus(true)
    }

    // T6: argv → shell command line quoting.
    func testShellCommandQuoting() {
        XCTAssertNil(GhosttyTerminalSurface.shellCommand(from: []))
        XCTAssertEqual(
            GhosttyTerminalSurface.shellCommand(from: ["claude", "--resume", "abc-123"]),
            "claude --resume abc-123")
        XCTAssertEqual(
            GhosttyTerminalSurface.shellCommand(from: ["/bin/zsh"]),
            "/bin/zsh")
        // Paths/args with spaces and quotes get single-quoted safely.
        XCTAssertEqual(
            GhosttyTerminalSurface.shellCommand(from: ["echo", "hello world"]),
            "echo 'hello world'")
        XCTAssertEqual(
            GhosttyTerminalSurface.shellCommand(from: ["x", "it's"]),
            "x 'it'\\''s'")
    }

    // T3: clean shutdown. Named to run last — it invalidates the singleton.
    @MainActor
    func testZZZRuntimeShutdown() {
        XCTAssertEqual(GhosttyApp.shared.readiness, .ready)
        GhosttyApp.shared.shutdown()
        XCTAssertNil(GhosttyApp.shared.app, "app handle should be freed after shutdown")
    }
}
