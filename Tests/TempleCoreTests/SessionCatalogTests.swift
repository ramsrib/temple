import XCTest
@testable import TempleCore

/// The History tab reads the whole disk through `SessionCatalog.stream`: rows
/// must arrive newest first, a batch at a time, with a total to count against,
/// a failed store named rather than silently missing, and a read that stops
/// when nobody is listening any more.
final class SessionCatalogTests: XCTestCase {
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

    private func collect(_ stream: AsyncStream<SessionCatalog.Event>) async -> [SessionCatalog.Event] {
        var events: [SessionCatalog.Event] = []
        for await event in stream { events.append(event) }
        return events
    }

    func testStreamListsThenYieldsNewestFirstInBatches() async throws {
        let root = try claudeRoot([
            ("old", "a", 300), ("newest", "b", 10), ("middle", "a", 100),
            ("older", "b", 200), ("new", "a", 50),
        ])
        let catalog = SessionCatalog(stores: [ClaudeSessionStore(root: root)])

        let events = await collect(catalog.stream(batchSize: 2))

        XCTAssertEqual(events.first, .listed(total: 5))
        let batches: [([AgentSession], Int)] = events.compactMap {
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
        let catalog = SessionCatalog(stores: [ClaudeSessionStore(root: root), FailingStore()])

        let events = await collect(catalog.stream())

        XCTAssertTrue(events.contains(.storeFailed(.codex, message: FailingStore.error.localizedDescription)))
        let ids = events.flatMap { event -> [String] in
            if case .sessions(let sessions, _, _) = event { return sessions.map(\.id) }
            return []
        }
        XCTAssertEqual(ids, ["kept"])
    }

    func testEmptyDiskListsZeroAndFinishes() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-catalog-missing-\(UUID().uuidString)")
        let events = await collect(SessionCatalog(stores: [ClaudeSessionStore(root: missing)]).stream())
        XCTAssertEqual(events, [.listed(total: 0)])
    }

    /// The tab cancels its read when it goes away. The reader must notice at
    /// the next batch, not parse the remaining thousands for nobody.
    func testCancellingTheConsumerStopsTheRead() async throws {
        let store = SlowStore(count: 60)
        let firstBatch = expectation(description: "first batch")
        let consumer = Task {
            var fulfilled = false
            for await event in SessionCatalog(stores: [store]).stream(batchSize: 1) {
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
        XCTAssertEqual(store.catalogParser()(file), store.loadSession(at: file))
    }
}

private struct FailingStore: IncrementalSessionStore {
    static let error = CocoaError(.fileReadNoPermission)
    let agent: Agent = .codex
    func loadSessions() -> [AgentSession] { [] }
    func sessionFileURLs() -> [URL] { [] }
    func loadSession(at fileURL: URL) -> AgentSession? { nil }
    func enumerateSessionFiles() throws -> [URL] { throw Self.error }
}

private final class SlowStore: IncrementalSessionStore, @unchecked Sendable {
    let agent: Agent = .claude
    let count: Int
    private let lock = NSLock()
    private var parsedCount = 0
    var parsed: Int { lock.lock(); defer { lock.unlock() }; return parsedCount }

    init(count: Int) { self.count = count }

    func loadSessions() -> [AgentSession] { [] }
    func sessionFileURLs() -> [URL] {
        (0..<count).map { URL(fileURLWithPath: "/nonexistent/slow-\($0).jsonl") }
    }
    func loadSession(at fileURL: URL) -> AgentSession? {
        Thread.sleep(forTimeInterval: 0.02)
        lock.lock(); parsedCount += 1; lock.unlock()
        return AgentSession(id: fileURL.lastPathComponent, agent: .claude, projectPath: "/p",
                            title: "t", createdAt: nil, updatedAt: Date(), filePath: fileURL)
    }
}
