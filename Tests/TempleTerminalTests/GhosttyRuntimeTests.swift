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

    // Control text must never ride along with a key event: libghostty reads a
    // text-carrying event as "the mods were consumed producing this text", so
    // attaching Return's "\r" costs us the Shift and shift+enter degrades from
    // the kitty-protocol CSI 13;2u (newline) to a bare CR (submit).
    func testControlTextIsNotAttachedToKeyEvents() {
        XCTAssertNil(NSEvent.ghosttyKeyText("\r"), "Return must be encoded from key+mods")
        XCTAssertNil(NSEvent.ghosttyKeyText("\t"))
        XCTAssertNil(NSEvent.ghosttyKeyText("\u{7F}"))
        XCTAssertNil(NSEvent.ghosttyKeyText(""))
        XCTAssertNil(NSEvent.ghosttyKeyText(nil))
        // Printable text still rides along (that's how typing works).
        XCTAssertEqual(NSEvent.ghosttyKeyText("a"), "a")
        XCTAssertEqual(NSEvent.ghosttyKeyText("é"), "é")
        XCTAssertEqual(NSEvent.ghosttyKeyText("日本"), "日本")
    }

    // Dropping a file/image onto an agent must type a path it can actually read.
    @MainActor
    func testDroppedFileBecomesAQuotedPath() {
        let pasteboard = NSPasteboard(name: .init("temple-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([
            URL(fileURLWithPath: "/tmp/my shots/shot 1.png") as NSURL,
            URL(fileURLWithPath: "/tmp/log.txt") as NSURL,
        ])
        // Spaces must not split one file into two arguments.
        XCTAssertEqual(GhosttySurfaceView.droppedText(from: pasteboard),
                       "'/tmp/my shots/shot 1.png' /tmp/log.txt")
    }

    @MainActor
    func testDroppedImageDataIsSpilledToAFileTheAgentCanRead() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 2, height: 2))
        image.unlockFocus()

        let pasteboard = NSPasteboard(name: .init("temple-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(image.tiffRepresentation, forType: .tiff)   // no file URL: pixels only

        let dropped = try XCTUnwrap(GhosttySurfaceView.droppedText(from: pasteboard))
        let path = dropped.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        XCTAssertTrue(path.hasSuffix(".png"), "agents read files, not pasteboards: \(dropped)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: path)
    }

    @MainActor
    func testDroppedTextIsPassedThroughUnescaped() {
        let pasteboard = NSPasteboard(name: .init("temple-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("git status --short", forType: .string)
        // Text may be a command the user means to run — quoting it would break it.
        XCTAssertEqual(GhosttySurfaceView.droppedText(from: pasteboard), "git status --short")
    }

    // T3: clean shutdown. Named to run last — it invalidates the singleton.
    @MainActor
    func testZZZRuntimeShutdown() {
        XCTAssertEqual(GhosttyApp.shared.readiness, .ready)
        GhosttyApp.shared.shutdown()
        XCTAssertNil(GhosttyApp.shared.app, "app handle should be freed after shutdown")
    }
}
