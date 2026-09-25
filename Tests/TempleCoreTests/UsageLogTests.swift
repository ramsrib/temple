import XCTest
@testable import TempleCore

/// The file is the diagnostic trail a user hands over days later, so it has
/// to exist, carry every line in order, and never grow without bound.
final class UsageLogTests: XCTestCase {
    private var file: URL!
    private var saved: URL?

    override func setUp() {
        super.setUp()
        saved = UsageLog.fileURL
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-usage-log-\(UUID().uuidString)/logs/usage.log")
        UsageLog.fileURL = file
    }

    override func tearDown() {
        UsageLog.fileURL = saved
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent())
        super.tearDown()
    }

    private func contents() -> String {
        XCTAssertTrue(UsageLog.flush(), "the logging queue must drain")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    func testNoFileUnlessTheAppTurnsItOn() {
        UsageLog.fileURL = saved   // whatever the suite started with
        XCTAssertNil(UsageLog.fileURL, "the default must be nil: tests drive these log lines and must not write into the real state dir")
        UsageLog.fileURL = file
    }

    func testLinesLandInOrderWithLevelAndTimestamp() {
        UsageLog.notice("claude usage: 401 — the token was rejected")
        UsageLog.info("claude credentials: keychain item Claude Code-credentials chosen of 1")
        let text = contents()
        let lines = text.split(separator: "\n")
        XCTAssertTrue(lines[0].contains(" notice claude usage: 401"), String(lines[0]))
        XCTAssertTrue(lines[1].contains(" info claude credentials:"), String(lines[1]))
        // ISO 8601 with fractional seconds and an offset, so lines from two
        // machines can be lined up.
        XCTAssertNotNil(lines[0].range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(Z|[+-]\d{2}:\d{2}) "#, options: .regularExpression), String(lines[0]))
    }

    func testTheFileIsTrimmedToItsNewerHalfPastTheCap() {
        let line = String(repeating: "x", count: 1000)
        for i in 0..<600 { UsageLog.info("\(i) \(line)") }   // ~600 KB > 512 KB cap
        let text = contents()
        let size = text.utf8.count
        XCTAssertLessThan(size, UsageLog.capBytes, "trimmed")
        XCTAssertGreaterThan(size, UsageLog.capBytes / 4, "but not emptied")
        XCTAssertFalse(text.contains("info 0 x"), "the oldest lines are the ones that went")
        XCTAssertTrue(text.contains("info 599 x"), "the newest survive")
        XCTAssertTrue(text.hasPrefix("20"), "cut at a line boundary: the file starts on a timestamp")
    }

    func testAnUnwritableLocationDoesNotCrashOrBlock() {
        // Nothing to assert on the file — there cannot be one — beyond that
        // logging keeps working and returns. The failure itself goes to the
        // unified log, once.
        UsageLog.fileURL = URL(fileURLWithPath: "/nonexistent-root-\(UUID().uuidString)/logs/usage.log")
        UsageLog.notice("still fine")
        UsageLog.info("still fine")
        XCTAssertTrue(UsageLog.flush(timeout: 2), "the failing writes must complete, not stall the queue")
    }
}
