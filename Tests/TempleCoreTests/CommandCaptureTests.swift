import XCTest
@testable import TempleCore

final class CommandCaptureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func script(_ name: String, _ body: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testCapturesOutputAndStatus() throws {
        let ok = try script("ok", "echo hello; exit 0")
        let result = try XCTUnwrap(CommandCapture.run(ok, [], timeout: 5))
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.succeeded)
    }

    func testMergesStderr() throws {
        let noisy = try script("noisy", "echo to-err >&2; exit 3")
        let result = try XCTUnwrap(CommandCapture.run(noisy, [], timeout: 5))
        XCTAssertTrue(result.output.contains("to-err"))
        XCTAssertEqual(result.status, 3)
    }

    func testMissingBinaryReturnsNil() {
        XCTAssertNil(CommandCapture.run("/nonexistent/binary", [], timeout: 1))
    }

    /// The one that matters: a process that **ignores SIGTERM**. `terminate()` alone
    /// leaves it holding the pipe, and a read-to-EOF never returns — which, on the
    /// login-shell path, hangs app launch. We must escalate to SIGKILL and come back.
    func testHangingProcessThatIgnoresSIGTERMIsKilledAndReturns() throws {
        let stubborn = try script("stubborn", """
        trap '' TERM
        echo starting
        sleep 30
        """)
        let started = Date()
        let result = try XCTUnwrap(CommandCapture.run(stubborn, [], timeout: 1))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.timedOut)
        // Bounded: the 1s timeout plus the SIGTERM grace, nowhere near the 30s sleep.
        XCTAssertLessThan(elapsed, 8, "capture did not return promptly — it hung")
    }

    /// A binary that floods its output must not be allowed to eat memory until the
    /// timeout expires; we cap it and kill the process.
    func testFloodingOutputIsCappedRatherThanExhaustingMemory() throws {
        let flood = try script("flood", "while :; do echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; done")
        let started = Date()
        let result = try XCTUnwrap(CommandCapture.run(flood, [], timeout: 10, limit: 8 * 1024))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.output.utf8.count, 8 * 1024)
        // It stopped because of the cap, not because it ran out the 10s clock.
        XCTAssertLessThan(elapsed, 8)
    }
}
