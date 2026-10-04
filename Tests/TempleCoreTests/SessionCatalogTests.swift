import XCTest
@testable import TempleCore
import TempleTestSupport

/// The History tab reads the whole disk through `LocalSessionCatalog.stream`: rows
/// must arrive newest first, a batch at a time, with a total to count against,
/// a failed store named rather than silently missing, and a read that stops
/// when nobody is listening any more.
final class LocalSessionCatalogTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func claudeRoot(_ sessions: [(id: String, project: String, age: TimeInterval)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-catalog-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let now = Date()
        for session in sessions {
            let dir = root.appendingPathComponent("-p-\(session.project)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(session.id).jsonl")
            let line = #"{"type":"user","cwd":"/p/\#(session.project)","message":{"role":"user","content":"prompt \#(session.id)"}}"#
            try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-session.age)], ofItemAtPath: file.path)
        }
        return root
    }

    private func collect(_ stream: AsyncStream<CatalogBatch>) async -> [CatalogBatch] {
        var events: [CatalogBatch] = []
        for await event in stream { events.append(event) }
        return events
    }

    func testStreamListsThenYieldsNewestFirstInBatches() async throws {
        let root = try claudeRoot([
            ("old", "a", 300), ("newest", "b", 10), ("middle", "a", 100),
            ("older", "b", 200), ("new", "a", 50),
        ])
        let catalog = LocalSessionCatalog(stores: [ClaudeSessionStore(root: root)])

        let events = await collect(catalog.stream(batchSize: 2))

        XCTAssertEqual(events.first, .listed(total: 5))
        let batches: [([TranscriptSummary], Int)] = events.compactMap {
            if case .sessions(let sessions, let read, let total) = $0 {
                XCTAssertEqual(total, 5)
                return (sessions, read)
            }
            return nil
        }
        XCTAssertEqual(batches.map(\.1), [2, 4, 5], "read counts files consumed, batch by batch")
        XCTAssertEqual(batches.flatMap(\.0).map(\.id), ["newest", "new", "middle", "older", "old"])
    }

    func testAFailedStoreIsNamedAndTheOthersStillArrive() async throws {
        let root = try claudeRoot([("kept", "a", 10)])
        let catalog = LocalSessionCatalog(stores: [ClaudeSessionStore(root: root), FailingStore()])

        let events = await collect(catalog.stream())

        XCTAssertTrue(events.contains(.storeFailed(agent: .codex, message: FailingStore.error.localizedDescription)))
        let ids = events.flatMap { event -> [String] in
            if case .sessions(let sessions, _, _) = event { return sessions.map(\.id) }
            return []
        }
        XCTAssertEqual(ids, ["kept"])
    }

    func testEmptyDiskListsZeroAndFinishes() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-catalog-missing-\(UUID().uuidString)")
        let events = await collect(LocalSessionCatalog(stores: [ClaudeSessionStore(root: missing)]).stream())
        XCTAssertEqual(events, [.listed(total: 0)])
    }

    /// The tab cancels its read when it goes away. The reader must notice at
    /// the next batch, not parse the remaining thousands for nobody.
    func testCancellingTheConsumerStopsTheRead() async throws {
        let store = SlowStore(count: 60)
        let firstBatch = expectation(description: "first batch")
        let consumer = Task {
            var fulfilled = false
            for await event in LocalSessionCatalog(stores: [store]).stream(batchSize: 1) {
                if case .sessions = event, !fulfilled { fulfilled = true; firstBatch.fulfill() }
            }
        }
        await fulfillment(of: [firstBatch], timeout: 5)
        consumer.cancel()
        let atCancel = store.parsed
        try await Task.sleep(nanoseconds: 300_000_000)
        // At most the batch already in flight finishes; 300ms would be ~15 more.
        XCTAssertLessThanOrEqual(store.parsed, atCancel + 1, "parsing continued after the consumer left")
    }

    /// A store with no shared input parses each file exactly as the live
    /// engine does (Codex overrides this to read its title files once).
    func testCatalogParserDefaultsToLoadSession() throws {
        let root = try claudeRoot([("one", "a", 10)])
        let store = ClaudeSessionStore(root: root)
        let file = try XCTUnwrap(store.sessionFileURLs().first)
        XCTAssertEqual(store.catalogParser()(file), store.loadSummary(at: file))
    }
}

// MARK: - One row per thread, chosen before parsing (C9)

final class CatalogSelectionTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-catalog-select-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return root
    }

    private func summaries(_ stream: AsyncStream<CatalogBatch>) async -> [TranscriptSummary] {
        var all: [TranscriptSummary] = []
        for await event in stream { if case .sessions(let batch, _, _) = event { all += batch } }
        return all
    }

    private func codexLine(_ id: String, prompt: String) -> String {
        #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/work","timestamp":"2026-10-01T10:00:00Z"}}"#
            + "\n" + #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(prompt)"}}"#
    }

    /// Two files with one selection key (the same name under two day
    /// folders): the tie goes to the path that sorts last, as member
    /// resolution breaks it — not to whichever was modified last.
    func testEqualSelectionKeysBreakTheTieByPathLikeResolution() async throws {
        let root = try root()
        let thread = UUID().uuidString.lowercased()
        let name = "rollout-2026-10-01T10-00-00-\(thread).jsonl"
        let early = root.appendingPathComponent("sessions/2026/10/01/\(name)")
        let late = root.appendingPathComponent("sessions/2026/10/02/\(name)")
        for (url, prompt, age) in [(early, "early folder", 10.0), (late, "late folder", 500.0)] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try codexLine(thread, prompt: prompt).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        let store = CodexSessionStore(root: root)
        let selected = TranscriptCandidates.assign(id: thread, format: CodexFormat(),
            listed: try store.enumerateSessionFiles().map(\.path), hint: nil).first
        XCTAssertEqual(selected?.role, .selected)

        let rows = await summaries(LocalSessionCatalog(stores: [store]).stream())
        XCTAssertEqual(rows.map(\.locator.path), [selected?.path].compactMap { $0 })
        XCTAssertEqual(rows.first?.firstPrompt, "late folder", "the newer mtime of the other copy does not win")

        let fake = FakeHostSource()
        for (day, prompt) in [("01", "early folder"), ("02", "late folder")] {
            fake.write("/home/me/.agent-b/sessions/2026/10/\(day)/\(name)", agent: .codex,
                       data: Data(codexLine(thread, prompt: prompt).utf8),
                       modifiedAt: Date(timeIntervalSince1970: day == "01" ? 2_000 : 1_000))
        }
        var remote: [TranscriptSummary] = []
        for try await batch in fake.catalog(CatalogQuery()) { if case .sessions(let rows, _, _) = batch { remote += rows } }
        XCTAssertEqual(remote.map(\.locator.path), ["/home/me/.agent-b/sessions/2026/10/02/\(name)"])
    }

    /// Claude has no selection: a session id in two project folders is one
    /// row — the first file in resolution's order that reads — not two.
    func testAClaudeIDInTwoProjectFoldersIsOneRow() async throws {
        let root = try root()
        let id = UUID().uuidString.lowercased()
        for project in ["-a", "-b"] {
            let dir = root.appendingPathComponent(project, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"type":"user","sessionId":"\#(id)","cwd":"/\#(project)","message":{"content":"from \#(project)"}}"#
                .write(to: dir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        }
        let rows = await summaries(LocalSessionCatalog(stores: [ClaudeSessionStore(root: root)]).stream())
        XCTAssertEqual(rows.map(\.id), [id])
        XCTAssertEqual(rows.first?.cwd, "/-a")
    }

    func testTheCatalogPickFallsThroughOnlyPastMissingFilesWhenThereIsASelection() {
        let selected = TranscriptCandidates.CatalogThread(threadID: "t", paths: ["new", "old"], hasSelection: true)
        let none = TranscriptCandidates.CatalogThread(threadID: "t", paths: ["a", "b"], hasSelection: false)
        XCTAssertNil(TranscriptCandidates.catalogPick(selected) { $0 == "new" ? .failed : .read($0) })
        XCTAssertEqual(TranscriptCandidates.catalogPick(selected) { $0 == "new" ? .missing : .read($0) }, "old")
        XCTAssertEqual(TranscriptCandidates.catalogPick(none) { $0 == "a" ? .failed : .read($0) }, "b")
    }
}

private struct FailingStore: IncrementalSessionStore {
    static let error = CocoaError(.fileReadNoPermission)
    let agent: Agent = .codex
    func loadSummaries() -> [TranscriptSummary] { [] }
    func sessionFileURLs() -> [URL] { [] }
    func loadSummary(at fileURL: URL) -> TranscriptSummary? { nil }
    func enumerateSessionFiles() throws -> [URL] { throw Self.error }
}

private final class SlowStore: IncrementalSessionStore, @unchecked Sendable {
    let agent: Agent = .claude
    let count: Int
    private let lock = NSLock()
    private var parsedCount = 0
    var parsed: Int { lock.lock(); defer { lock.unlock() }; return parsedCount }

    init(count: Int) { self.count = count }

    func loadSummaries() -> [TranscriptSummary] { [] }
    func sessionFileURLs() -> [URL] {
        (0..<count).map { URL(fileURLWithPath: "/nonexistent/slow-\($0).jsonl") }
    }
    func loadSummary(at fileURL: URL) -> TranscriptSummary? {
        Thread.sleep(forTimeInterval: 0.02)
        lock.lock(); parsedCount += 1; lock.unlock()
        return catalogFixture(id: fileURL.deletingPathExtension().lastPathComponent, agent: .claude, projectPath: "/p",
                            title: "t", createdAt: nil, updatedAt: Date(), filePath: fileURL)
    }
}
