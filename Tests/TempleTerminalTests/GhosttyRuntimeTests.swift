import XCTest
import GhosttyKit
@testable import TempleTerminal
import TempleTerminalAPI

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

    /// The generated config goes where the factory says (the app passes its
    /// state directory, so `TEMPLE_STATE_DIR` covers it), and nothing that
    /// does not say — this test process included — writes the installed
    /// app's file in Application Support.
    @MainActor
    func testTheConfigFileGoesToTheDirectoryTheFactoryNames() throws {
        let realDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Temple").standardizedFileURL.path
        XCTAssertFalse(GhosttyApp.configDirectory.standardizedFileURL.path.hasPrefix(realDirectory))
        XCTAssertEqual(GhosttyApp.shared.readiness, .ready)

        let original = GhosttyApp.configDirectory
        defer { GhosttyApp.configDirectory = original }
        let state = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("temple-ghostty-conf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        _ = GhosttyTerminalSurfaceFactory(configDirectory: state)
        XCTAssertEqual(GhosttyApp.configDirectory, state)
        GhosttyApp.shared.update(appearance: TerminalAppearance(fontSize: 17, colorScheme: .dark))
        let written = try String(contentsOf: state.appendingPathComponent("ghostty.conf"), encoding: .utf8)
        XCTAssertTrue(written.contains("font-size = 17"))
        XCTAssertTrue(written.contains("macos-option-as-alt = left"),
                      "the agents' ⌥ shortcuts need the left ⌥ as Meta (ADR-037)")
        XCTAssertFalse(written.contains("cursor-click-to-move"),
                       "libghostty's own prompt-click behaviour, app-wide, as before remote")
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

    // `macos-option-as-alt = left` only works if the core can tell the two
    // ⌥ keys apart and the text is composed without the ⌥ it takes (ADR-037).
    func testOptionSidesReachTheCore() {
        let left = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
        let right = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
        XCTAssertEqual(NSEvent.ghosttyMods(left).rawValue & GHOSTTY_MODS_ALT_RIGHT.rawValue, 0)
        XCTAssertNotEqual(NSEvent.ghosttyMods(right).rawValue & GHOSTTY_MODS_ALT_RIGHT.rawValue, 0)
        XCTAssertNotEqual(NSEvent.ghosttyMods(left).rawValue & GHOSTTY_MODS_ALT.rawValue, 0)
        XCTAssertEqual(NSEvent.modifierFlags(NSEvent.ghosttyMods([.option, .shift])), [.option, .shift])
    }

    func testATakenOptionComposesThePlainLetter() throws {
        let optionP = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0,
            context: nil, characters: "π", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        XCTAssertTrue(optionP.ghosttyTranslationEvent(mods: .option) === optionP, "⌥ kept: the event as it was")
        let translated = optionP.ghosttyTranslationEvent(mods: [])
        XCTAssertEqual(translated.characters, "p", "⌥ is the terminal's Alt, so no π")
        XCTAssertFalse(translated.modifierFlags.contains(.option))
        let key = optionP.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS, translationMods: translated.modifierFlags)
        XCTAssertNotEqual(key.mods.rawValue & GHOSTTY_MODS_ALT.rawValue, 0, "Alt is still sent")
        XCTAssertEqual(key.consumed_mods.rawValue & GHOSTTY_MODS_ALT.rawValue, 0, "but not spent on the text")
    }

    // After a composition commits, only arrows act as keys (upstream's rule).
    @MainActor
    func testOnlyArrowsReplayAfterACommit() throws {
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: code))
        }
        XCTAssertFalse(GhosttySurfaceView.replaysAfterCommit(try key(14, .option)), "⌥E finishing a dead key")
        XCTAssertTrue(GhosttySurfaceView.replaysAfterCommit(try key(125)))
        XCTAssertFalse(GhosttySurfaceView.replaysAfterCommit(try key(123)), "plain ←: AppKit kept the caret")
        XCTAssertTrue(GhosttySurfaceView.replaysAfterCommit(try key(123, .shift)))
    }

    // Dropping a file/image onto an agent must type a path it can actually read.
    @MainActor
    func testDroppedFileBecomesAQuotedPath() throws {
        let pasteboard = NSPasteboard(name: .init("temple-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        try XCTSkipUnless(pasteboard.writeObjects([
            URL(fileURLWithPath: "/tmp/my shots/shot 1.png") as NSURL,
            URL(fileURLWithPath: "/tmp/log.txt") as NSURL,
        ]), "Pasteboard service unavailable in this execution environment")
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
        try XCTSkipUnless(pasteboard.setData(image.tiffRepresentation, forType: .tiff),
                          "Pasteboard service unavailable in this execution environment") // pixels only

        let dropped = try XCTUnwrap(GhosttySurfaceView.droppedText(from: pasteboard))
        let path = dropped.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        XCTAssertTrue(path.hasSuffix(".png"), "agents read files, not pasteboards: \(dropped)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: path)
    }

    @MainActor
    func testDroppedTextIsPassedThroughUnescaped() throws {
        let pasteboard = NSPasteboard(name: .init("temple-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        try XCTSkipUnless(pasteboard.setString("git status --short", forType: .string),
                          "Pasteboard service unavailable in this execution environment")
        // Text may be a command the user means to run — quoting it would break it.
        XCTAssertEqual(GhosttySurfaceView.droppedText(from: pasteboard), "git status --short")
    }

    // ⌘V of a screenshot taken to the clipboard (pixels, no text) hands
    // over a file, as a drop of it would; text on the clipboard is an
    // ordinary paste, image or not.
    @MainActor
    func testPastingAnImageWithNoTextHandsOverAFile() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.blue.drawSwatch(in: NSRect(x: 0, y: 0, width: 2, height: 2))
        image.unlockFocus()

        let pasteboard = NSPasteboard(name: .init("temple-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        try XCTSkipUnless(pasteboard.setData(image.tiffRepresentation, forType: .tiff),
                          "Pasteboard service unavailable in this execution environment")
        let files = try XCTUnwrap(GhosttySurfaceView.pastedFiles(from: pasteboard))
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].lastPathComponent, "image.png", "named for what it is: a host's tab shows it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].path))
        try? FileManager.default.removeItem(at: files[0].deletingLastPathComponent())

        pasteboard.clearContents()
        pasteboard.setData(image.tiffRepresentation, forType: .tiff)
        pasteboard.setString("a caption", forType: .string)
        XCTAssertNil(GhosttySurfaceView.pastedFiles(from: pasteboard), "text wins: an ordinary paste")

        pasteboard.clearContents()
        pasteboard.setString("plain", forType: .string)
        XCTAssertNil(GhosttySurfaceView.pastedFiles(from: pasteboard))
    }

    // A file copied in Finder pastes as its path (Finder's text is only its
    // name), as Ghostty's own app does.
    @MainActor
    func testPastingACopiedFileHandsOverItsPath() throws {
        let pasteboard = NSPasteboard(name: .init("temple-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        try XCTSkipUnless(pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/shot 1.png") as NSURL]),
                          "Pasteboard service unavailable in this execution environment")
        pasteboard.setString("shot 1.png", forType: .string)
        XCTAssertEqual(GhosttySurfaceView.pastedFiles(from: pasteboard), [URL(fileURLWithPath: "/tmp/shot 1.png")])

        // Finder leaves out an extension it hides.
        XCTAssertTrue(GhosttySurfaceView.isNames("shot 1", of: [URL(fileURLWithPath: "/tmp/shot 1.png")]))
        XCTAssertFalse(GhosttySurfaceView.isNames("shot 1\nother", of: [URL(fileURLWithPath: "/tmp/shot 1.png")]))
        XCTAssertFalse(GhosttySurfaceView.isNames("a.png\na.png", of: [URL(fileURLWithPath: "/tmp/a.png"),
                                                                       URL(fileURLWithPath: "/tmp/b.png")]),
                       "each line names a file of its own")
        XCTAssertTrue(GhosttySurfaceView.isNames("report\nreport.txt", of: [URL(fileURLWithPath: "/tmp/report.txt"),
                                                                           URL(fileURLWithPath: "/tmp/report")]),
                      "an exact name is matched before a hidden extension")

        // Text that is more than the file's name is what the person meant.
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/shot 1.png") as NSURL])
        pasteboard.setString("see shot 1.png for the bug", forType: .string)
        XCTAssertNil(GhosttySurfaceView.pastedFiles(from: pasteboard))
    }

    // Files and web links dropped together are typed as they always were.
    @MainActor
    func testAMixedDropOfFilesAndLinksKeepsBoth() throws {
        let pasteboard = NSPasteboard(name: .init("temple-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        try XCTSkipUnless(pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.png") as NSURL,
                                                   URL(string: "https://example.com/x?y=1")! as NSURL]),
                          "Pasteboard service unavailable in this execution environment")
        XCTAssertEqual(GhosttySurfaceView.droppedText(from: pasteboard), "/tmp/a.png 'https://example.com/x?y=1'")
    }

    // A drop's files reach the handoff, and what it answers is what is typed.
    @MainActor
    func testADropIsTypedAsWhatTheHandoffAnswers() throws {
        let pasteboard = NSPasteboard(name: .init("temple-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        try XCTSkipUnless(pasteboard.writeObjects([URL(fileURLWithPath: "/Users/me/shot.png") as NSURL]),
                          "Pasteboard service unavailable in this execution environment")
        XCTAssertEqual(GhosttySurfaceView.droppedContent(from: pasteboard),
                       .files([URL(fileURLWithPath: "/Users/me/shot.png")]))
        XCTAssertEqual(GhosttySurfaceView.typed(["/tmp/temple-501-files/ab/shot.png", "/a b"]),
                       "/tmp/temple-501-files/ab/shot.png '/a b'")
    }

    // T3: clean shutdown. Named to run last — it invalidates the singleton.
    @MainActor
    func testZZZRuntimeShutdown() {
        XCTAssertEqual(GhosttyApp.shared.readiness, .ready)
        GhosttyApp.shared.shutdown()
        XCTAssertNil(GhosttyApp.shared.app, "app handle should be freed after shutdown")
    }
}
