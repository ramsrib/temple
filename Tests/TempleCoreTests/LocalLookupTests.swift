import XCTest
@testable import TempleCore
@testable import TempleLocalHost

/// Open a session by id on this Mac: the seam's default lookup over the
/// local source (docs/designs/open-existing-sessions.md section 5).
final class LocalLookupTests: XCTestCase {
    private var root: URL!
    private let id = "0199a213-81c0-7800-8aa1-bbab2a035a53"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/temple-local-lookup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("codex/sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("claude/-work-app"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func source() -> LocalSessionSource {
        LocalSessionSource(stores: [ClaudeSessionStore(root: root.appendingPathComponent("claude")),
                                    CodexSessionStore(root: root.appendingPathComponent("codex"))], monitorChanges: false)
    }

    func testFindsAClaudeSessionWithItsFolder() async throws {
        let line = #"{"type":"user","sessionId":"\#(id)","cwd":"/work/app","timestamp":"2026-10-01T10:00:00Z","message":{"content":"hi"}}"#
        try Data((line + "\n").utf8).write(to: root.appendingPathComponent("claude/-work-app/\(id).jsonl"))
        let lookup = try await source().lookup(id: id)
        guard case .found(let locator, let directory) = lookup[.claude] else { return XCTFail("\(lookup)") }
        XCTAssertTrue(locator.path.hasSuffix("\(id).jsonl"))
        XCTAssertEqual(directory, "/work/app")
        XCTAssertEqual(lookup[.codex], .notFound)
    }

    func testNothingAnywhereIsNotFound() async throws {
        let lookup = try await source().lookup(id: id)
        XCTAssertTrue(lookup.notFoundAnywhere, "\(lookup)")
    }
}
