import XCTest
@testable import TempleCore

/// Interleavings inside one local `read`, made deterministic with the
/// source's read-phase seam.
final class LocalSourceReadTests: XCTestCase {
    private var root: URL!
    private let thread = "0199a213-81c0-7800-8aa1-bbab2a035a53"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/temple-local-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("codex/sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("claude/-work"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var history: URL { root.appendingPathComponent("codex/history.jsonl") }

    private func writeHistory(_ title: String) throws {
        try Data(#"{"session_id":"\#(thread)","ts":1,"text":"\#(title)"}"#.utf8).write(to: history)
    }

    /// C5: the revision a read reports is the one its shared facts were read
    /// at. Observation moving on mid-read must not stamp the old facts with
    /// the newer revision.
    func testSharedFactsKeepTheRevisionTheyWereReadAtWhenObservationMovesOnMidRead() async throws {
        let rollout = root.appendingPathComponent("codex/sessions/rollout-2026-10-01T10-00-00-\(thread).jsonl")
        try Data(#"{"type":"session_meta","payload":{"id":"\#(thread)","cwd":"/w"}}"#.utf8).write(to: rollout)
        try writeHistory("Old title")
        let store = CodexSessionStore(root: root.appendingPathComponent("codex"))
        let source = LocalSessionSource(stores: [store], monitorChanges: false)
        let before = try await source.locate([]).sharedRevision[.codex]
        let fired = Flag()
        let history = self.history, thread = self.thread
        source.readPhaseHook = { phase, _ in
            guard phase == .sharedFactsAcquired, fired.setOnce() else { return }
            // The inputs change and observation sees it before this read finishes.
            try? Data(#"{"session_id":"\#(thread)","ts":1,"text":"New, longer title"}"#.utf8).write(to: history)
            _ = store.sharedRevision()
        }
        let locator = TranscriptLocator(localURL: rollout)
        let stale = try await source.read(locator, agent: .codex, expecting: thread, facts: true)
        XCTAssertEqual(stale.summary?.historyPrompt, "Old title")
        XCTAssertEqual(stale.sharedRevision, before, "old facts keep their own revision")
        let after = try await source.locate([]).sharedRevision[.codex]
        XCTAssertGreaterThan(try XCTUnwrap(after), try XCTUnwrap(stale.sharedRevision))
        let fresh = try await source.read(locator, agent: .codex, expecting: thread, facts: true)
        XCTAssertEqual(fresh.summary?.historyPrompt, "New, longer title")
        XCTAssertEqual(fresh.sharedRevision, after)
    }

    func testTheSharedCacheReadsOncePerRevisionAndNeverMovesBackwards() throws {
        try writeHistory("One")
        let store = CodexSessionStore(root: root.appendingPathComponent("codex"))
        let first = store.sharedFactsSnapshot()
        XCTAssertEqual(store.sharedFactsSnapshot().revision, first.revision)
        XCTAssertEqual(store.sharedRevision(), first.revision)
        try writeHistory("Two, changed")
        let revision = try XCTUnwrap(store.sharedRevision())
        XCTAssertGreaterThan(revision, try XCTUnwrap(first.revision))
        let second = store.sharedFactsSnapshot()
        XCTAssertEqual(second.revision, revision)
        XCTAssertEqual(second.facts.prompts[thread], "Two, changed")
        XCTAssertEqual(first.facts.prompts[thread], "One", "a held snapshot is a value")
        XCTAssertNil(ClaudeSessionStore(root: root.appendingPathComponent("claude")).sharedRevision())
    }
}


