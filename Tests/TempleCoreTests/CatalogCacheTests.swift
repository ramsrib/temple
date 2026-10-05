import XCTest
import GRDB
@testable import TempleCore
@testable import TempleLocalHost

/// The local catalog's kept summaries (ADR-032), beyond what the host
/// contract asks of every source: the disk cache across launches, failed
/// and cancelled reads, store roots, versions and corruption. Work counts
/// (`catalogParses`) are asserted here; timing is the bench's business.
final class CatalogCacheTests: XCTestCase {
    private var root: URL!
    private var claudeRoot: URL { root.appendingPathComponent("claude") }
    private var codexRoot: URL { root.appendingPathComponent("codex") }
    private var project: URL { claudeRoot.appendingPathComponent("-work-project") }
    private var rollouts: URL { codexRoot.appendingPathComponent("sessions/2026/10/01") }
    private var cacheURL: URL { root.appendingPathComponent("state/history-catalog-cache.sqlite") }
    private var locked: [URL] = []
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/temple-catalog-cache-\(UUID().uuidString)")
        for dir in [project, rollouts, root.appendingPathComponent("state")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        for url in locked { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Helpers

    private func uuid() -> String { UUID().uuidString.lowercased() }

    /// A source over this test's stores, with the disk cache when asked;
    /// `claude` replaces the Claude root (a symlink to it, say).
    private func source(disk: Bool = true, claude: URL? = nil) -> (LocalSessionSource, CatalogDiskCache?) {
        let cache = disk ? CatalogDiskCache(url: cacheURL) : nil
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: claude ?? claudeRoot), CodexSessionStore(root: codexRoot)],
                                        monitorChanges: false, catalogDisk: cache)
        return (source, cache)
    }

    @discardableResult
    private func claude(_ id: String, prompt: String = "First prompt", recording: String? = nil) throws -> URL {
        let file = project.appendingPathComponent("\(id).jsonl")
        let lines = [#"{"type":"user","sessionId":"\#(recording ?? id)","cwd":"/work/project","timestamp":"2026-10-01T10:00:00.5Z","gitBranch":"main","message":{"content":"\#(prompt)","model":"m"}}"#,
                     #"{"type":"summary","summary":"Recorded"}"#]
        try write(lines.joined(separator: "\n"), to: file)
        return file
    }

    @discardableResult
    private func codex(_ id: String, prompt: String = "Codex prompt", subagent: Bool = false) throws -> URL {
        let file = rollouts.appendingPathComponent("rollout-2026-10-01T10-00-00-\(id).jsonl")
        let extra = subagent ? #","thread_source":"subagent""# : ""
        let lines = [#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/work/codex","timestamp":"2026-10-01T10:00:00Z","originator":"codex_cli_rs","git":{"branch":"dev"}\#(extra)}}"#,
                     #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(prompt)"}}"#]
        try write(lines.joined(separator: "\n"), to: file)
        return file
    }

    private func write(_ text: String, to file: URL) throws {
        try Data(text.utf8).write(to: file)
        clock = clock.addingTimeInterval(1)
        try FileManager.default.setAttributes([.modificationDate: clock], ofItemAtPath: file.path)
    }

    private func read(_ source: LocalSessionSource, until stop: ((CatalogBatch) -> Bool)? = nil) async throws
        -> (summaries: [TranscriptSummary], events: [CatalogBatch]) {
        var events: [CatalogBatch] = []
        for try await batch in source.catalog(CatalogQuery(batchSize: 1)) {
            events.append(batch)
            if stop?(batch) == true { break }
        }
        let summaries = events.flatMap { batch -> [TranscriptSummary] in
            if case .sessions(let rows, _, _) = batch { return rows }
            return []
        }
        return (summaries.sorted { ($0.agent.rawValue, $0.id) < ($1.agent.rawValue, $1.id) }, events)
    }

    private func parses(_ source: LocalSessionSource) -> UInt64 { source.metrics.catalogParses }

    private func setMeta(_ key: String, _ value: String) throws {
        let queue = try DatabaseQueue(path: cacheURL.path)
        try queue.write { try $0.execute(sql: "UPDATE meta SET value = ? WHERE key = ?", arguments: [value, key]) }
    }

    private func meta(_ key: String) throws -> String? {
        let queue = try DatabaseQueue(path: cacheURL.path)
        return try queue.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    // MARK: Launches

    /// The first read after a relaunch takes every unchanged summary from
    /// disk — identical, field for field and to the nanosecond — and parses
    /// nothing; one written while Temple was not running is read again.
    func testARelaunchReadsFromDiskAndParsesOnlyWhatChanged() async throws {
        let a = uuid(), b = uuid(), c = uuid()
        try claude(a); try claude(b); try codex(c)
        let (first, disk) = source()
        let launched = try await read(first)
        XCTAssertEqual(launched.summaries.count, 3)
        XCTAssertEqual(parses(first), 3)
        disk?.sync()

        let (second, _) = source()
        let relaunched = try await read(second)
        XCTAssertEqual(parses(second), 0, "nothing changed: nothing parsed")
        XCTAssertEqual(relaunched.summaries, launched.summaries)
        for (x, y) in zip(relaunched.summaries, launched.summaries) {
            XCTAssertEqual(x.modifiedAt.timeIntervalSinceReferenceDate, y.modifiedAt.timeIntervalSinceReferenceDate)
            XCTAssertEqual(x.createdAt, y.createdAt)
            XCTAssertEqual(x.cwd, y.cwd); XCTAssertEqual(x.firstPrompt, y.firstPrompt)
            XCTAssertEqual(x.recordedTitle, y.recordedTitle); XCTAssertEqual(x.gitBranch, y.gitBranch)
            XCTAssertEqual(x.originator, y.originator); XCTAssertEqual(x.selectionKey, y.selectionKey)
        }

        try claude(b, prompt: "Changed while away")
        let (third, _) = source()
        let changed = try await read(third)
        XCTAssertEqual(parses(third), 1)
        XCTAssertEqual(changed.summaries.first { $0.id == b }?.firstPrompt, "Changed while away")
    }

    /// Every field of a summary but the two shared ones survives the disk.
    /// A new field on `TranscriptSummary` fails this count: add its column
    /// to `CatalogDiskCache` and bump `schemaVersion`.
    func testTheDiskKeepsEverySummaryField() throws {
        let summary = TranscriptSummary(
            id: "id", agent: .claude, locator: TranscriptLocator(localURL: URL(fileURLWithPath: "/p/id.jsonl")),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7), cwd: "/cwd", firstPrompt: "first",
            historyPrompt: nil, createdAt: Date(timeIntervalSinceReferenceDate: 812_000_000.987_654_3), gitBranch: "b",
            model: "m", messageCount: 7, lastMessagePreview: "preview", originator: "o", recordedTitle: "recorded",
            sharedTitle: nil, directoryHint: "/hint", laterPromptHint: "later", legacyTitleHint: "legacy", selectionKey: "key")
        XCTAssertEqual(Mirror(reflecting: summary).children.count, 19,
                       "TranscriptSummary changed: keep the new field in CatalogDiskCache and bump its schemaVersion")
        let disk = CatalogDiskCache(url: cacheURL)
        let stamp = CatalogStamp(size: 10, modifiedNanos: 1, changedNanos: 2, inode: UInt64.max)
        let root = CatalogRoot(path: "/p", inode: 9)
        disk.write(.init(roots: [.claude: root], files: [.claude: ["/p/id.jsonl": .init(stamp: stamp, outcome: .summary(summary)),
                                                                     "/p/sub.jsonl": .init(stamp: stamp, outcome: .noSession)]]))
        let loaded = expectation(description: "loaded")
        let box = SnapshotBox()
        disk.load { box.value = $0; loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        let snapshot = box.value
        XCTAssertEqual(snapshot[.claude]?.root, root)
        XCTAssertEqual(snapshot[.claude]?.files["/p/id.jsonl"], .init(stamp: stamp, outcome: .summary(summary)))
        guard case .summary(let back)? = snapshot[.claude]?.files["/p/id.jsonl"]?.outcome else { return XCTFail() }
        XCTAssertEqual(back.modifiedAt.timeIntervalSinceReferenceDate, summary.modifiedAt.timeIntervalSinceReferenceDate)
        XCTAssertEqual(back.createdAt?.timeIntervalSinceReferenceDate, summary.createdAt?.timeIntervalSinceReferenceDate)
        XCTAssertEqual(back.messageCount, 7); XCTAssertEqual(back.directoryHint, "/hint")
        XCTAssertEqual(back.laterPromptHint, "later"); XCTAssertEqual(back.legacyTitleHint, "legacy")
        XCTAssertEqual(snapshot[.claude]?.files["/p/sub.jsonl"]?.outcome, .noSession)
    }

    /// A cache file that is not a database is a cache lost, nothing more:
    /// everything is read again, and the file is rebuilt for next time.
    func testACorruptDiskCacheIsDiscardedAndRebuilt() async throws {
        try claude(uuid()); try codex(uuid())
        try Data("not a database, not even close".utf8).write(to: cacheURL)
        let (first, disk) = source()
        let rows = try await read(first).summaries
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(parses(first), 2)
        disk?.sync()
        let (second, _) = source()
        let value1 = try await read(second).summaries
        XCTAssertEqual(value1, rows)
        XCTAssertEqual(parses(second), 0, "rebuilt")
    }

    /// A file written by older parsers (or an older layout) is discarded and
    /// rewritten; one from a newer build is left exactly as it is, and this
    /// process keeps its summaries in memory only.
    func testAnOlderCacheIsDiscardedAndANewerOneLeftAlone() async throws {
        try claude(uuid()); try codex(uuid())
        let (first, disk) = source()
        _ = try await read(first)
        disk?.sync()

        try setMeta("facts", String(TranscriptFormats.factsVersion - 1))
        let (older, olderDisk) = source()
        _ = try await read(older)
        XCTAssertEqual(parses(older), 2, "older parsers' summaries are not used")
        olderDisk?.sync()
        XCTAssertEqual(try meta("facts"), String(TranscriptFormats.factsVersion), "rewritten at this version")

        try setMeta("schema", "999")
        let (newer, newerDisk) = source()
        _ = try await read(newer)
        XCTAssertEqual(parses(newer), 2)
        _ = try await read(newer)
        XCTAssertEqual(parses(newer), 2, "kept in memory all the same")
        newerDisk?.sync()
        XCTAssertEqual(try meta("schema"), "999", "a newer build's file is left alone")
    }

    // MARK: Roots

    /// Summaries are kept per store root. The same files reached through
    /// another root path are another store, and nothing kept applies.
    func testAnotherStoreRootReadsEverythingAgain() async throws {
        try claude(uuid()); try claude(uuid())
        let (first, disk) = source()
        _ = try await read(first)
        disk?.sync()
        let alias = root.appendingPathComponent("claude-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: claudeRoot)
        let (moved, _) = source(claude: alias)
        _ = try await read(moved)
        XCTAssertEqual(parses(moved), 2)

        // In memory too: a root whose identity changed drops what was kept.
        let cache = CatalogSummaryCache()
        let stamp = CatalogStamp(size: 1, modifiedNanos: 1, changedNanos: 1, inode: 1)
        let old = CatalogRoot(path: "/r", inode: 1), new = CatalogRoot(path: "/r", inode: 2)
        cache.begin(.claude, root: old)
        cache.record(.claude, root: old, key: "/r/a", entry: .init(stamp: stamp, outcome: .noSession))
        XCTAssertEqual(cache.lookup(.claude, root: old, key: "/r/a", stamp: stamp), .noSession)
        cache.begin(.claude, root: new)
        XCTAssertNil(cache.lookup(.claude, root: new, key: "/r/a", stamp: stamp))
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: Coverage

    /// A listing that failed proves nothing: nothing kept is forgotten, the
    /// agent is not named complete, and once it lists again nothing is read.
    func testAFailedListingKeepsEverythingAndCompletesNothing() async throws {
        try claude(uuid()); try claude(uuid()); try codex(uuid())
        let (source, _) = source(disk: false)
        _ = try await read(source)
        XCTAssertEqual(source.catalogCache.count, 3)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: claudeRoot.path)
        locked.append(claudeRoot)
        let failed = try await read(source)
        XCTAssertTrue(failed.events.contains { if case .storeFailed(.claude?, _) = $0 { return true }; return false })
        XCTAssertEqual(failed.events.last, .completed(agents: [.codex]))
        XCTAssertEqual(source.catalogCache.count, 3, "a failed listing forgets nothing")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claudeRoot.path)
        let before = parses(source)
        let value2 = try await read(source).summaries.count
        XCTAssertEqual(value2, 3)
        XCTAssertEqual(parses(source), before)
    }

    /// A read that ends early completes nothing and forgets nothing, even
    /// for a file it would have found gone.
    func testACancelledReadCompletesAndForgetsNothing() async throws {
        let ids = (0..<8).map { _ in uuid() }
        let files = try ids.map { try claude($0) }
        let source = LocalSessionSource(stores: [SlowClaudeStore(root: claudeRoot)], monitorChanges: false)
        _ = try await read(source)
        XCTAssertEqual(source.catalogCache.count, 8)
        // Every file changes, so the next read parses (slowly) one per batch;
        // one is deleted.
        for id in ids { try claude(id, prompt: "Again") }
        try FileManager.default.removeItem(at: files[0])
        let cut = try await read(source) { if case .sessions = $0 { return true }; return false }
        XCTAssertFalse(cut.events.contains { if case .completed = $0 { return true }; return false })
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(source.catalogCache.count, 8, "a cancelled read forgets nothing")
        let whole = try await read(source)
        XCTAssertEqual(whole.events.last, .completed(agents: [.claude]))
        XCTAssertEqual(source.catalogCache.count, 7, "a completed listing forgets the deleted file")
    }

    /// A deletion after a completed listing is forgotten on disk as well.
    func testADeletionIsForgottenOnDiskToo() async throws {
        let gone = try claude(uuid())
        try claude(uuid())
        let (first, disk) = source()
        _ = try await read(first)
        try FileManager.default.removeItem(at: gone)
        _ = try await read(first)
        disk?.sync()
        let (second, _) = source()
        second.catalogCache.startLoading()
        second.catalogCache.waitUntilLoaded()
        XCTAssertEqual(second.catalogCache.count, 1)
    }

    // MARK: What is kept

    /// A file that records another session is read again every time, never
    /// kept, and lists nothing.
    func testAnIdentityMismatchIsNeverKept() async throws {
        let id = uuid()
        let file = try claude(id)
        let (source, _) = source(disk: false)
        let value3 = try await read(source).summaries.map(\.id)
        XCTAssertEqual(value3, [id])
        try write(try String(contentsOf: file).replacingOccurrences(of: id, with: uuid()), to: file)
        let value4 = try await read(source).summaries
        XCTAssertEqual(value4, [])
        XCTAssertEqual(source.catalogCache.count, 0)
        let value5 = try await read(source).summaries
        XCTAssertEqual(value5, [])
    }

    /// A verified rollout whose bytes state no session (a subagent's) is
    /// kept as such: not listed, and not parsed again while unchanged.
    func testARolloutThatIsNoSessionIsKeptAsSuch() async throws {
        try codex(uuid(), subagent: true)
        let (source, _) = source(disk: false)
        let value6 = try await read(source).summaries
        XCTAssertEqual(value6, [])
        XCTAssertEqual(parses(source), 1)
        let value7 = try await read(source).summaries
        XCTAssertEqual(value7, [])
        XCTAssertEqual(parses(source), 1)
    }

    /// One id in both agents' stores is two threads, each kept and shown
    /// under its own agent.
    func testTheSameIDUnderTwoAgentsIsTwoRows() async throws {
        let id = uuid()
        try claude(id); try codex(id)
        let (first, disk) = source()
        let rows = try await read(first).summaries
        XCTAssertEqual(rows.map(\.agent), [.claude, .codex])
        XCTAssertEqual(Set(rows.map(\.id)), [id])
        disk?.sync()
        let (second, _) = source()
        let value8 = try await read(second).summaries
        XCTAssertEqual(value8, rows)
        XCTAssertEqual(parses(second), 0)
    }

    /// An atomic replacement (a new inode at the path) and a truncation
    /// are both read again.
    func testAReplacementAndATruncationAreReadAgain() async throws {
        let id = uuid()
        let file = try claude(id, prompt: "Before")
        let (source, _) = source(disk: false)
        _ = try await read(source)
        try Data(try String(contentsOf: file).replacingOccurrences(of: "Before", with: "After").utf8).write(to: file, options: .atomic)
        let value9 = try await read(source).summaries.first?.firstPrompt
        XCTAssertEqual(value9, "After")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 20); try handle.close()
        let value10 = try await read(source).summaries
        XCTAssertEqual(value10, [], "a truncated header records no session")
        XCTAssertEqual(parses(source), 2)
    }
}

private final class SnapshotBox: @unchecked Sendable {
    var value: [Agent: CatalogSummaryCache.AgentEntries] = [:]
}

/// Claude's store with a parser slow enough that a read is still going
/// when its consumer leaves.
private struct SlowClaudeStore: IncrementalSessionStore {
    let inner: ClaudeSessionStore
    init(root: URL) { inner = ClaudeSessionStore(root: root) }
    var agent: Agent { .claude }
    var catalogRoot: URL? { inner.catalogRoot }
    func loadSummaries() -> [TranscriptSummary] { inner.loadSummaries() }
    func sessionFileURLs() -> [URL] { inner.sessionFileURLs() }
    func enumerateSessionFiles() throws -> [URL] { try inner.enumerateSessionFiles() }
    func loadSummary(at fileURL: URL) -> TranscriptSummary? {
        Thread.sleep(forTimeInterval: 0.1)
        return inner.loadSummary(at: fileURL)
    }
}
