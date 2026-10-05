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
    private var stateDir: URL { root.appendingPathComponent("state") }
    private var cacheURL: URL { stateDir.appendingPathComponent(CatalogDiskCache.fileName()) }
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
        let cache = disk ? CatalogDiskCache(directory: stateDir) : nil
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
        let disk = CatalogDiskCache(directory: stateDir)
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

    /// Other parsers use another file: a build with older (or newer) facts
    /// never reads this one's summaries, and neither deletes the other's,
    /// even while the other has its file open.
    func testAnotherVersionUsesItsOwnFileAndLeavesThisOneOpen() async throws {
        try claude(uuid()); try codex(uuid())
        let (first, disk) = source()
        _ = try await read(first)
        disk?.sync()
        let older = CatalogDiskCache(directory: stateDir, facts: TranscriptFormats.factsVersion - 1)
        XCTAssertNotEqual(older.url, cacheURL)
        let olderSource = LocalSessionSource(stores: [ClaudeSessionStore(root: claudeRoot), CodexSessionStore(root: codexRoot)],
                                             monitorChanges: false, catalogDisk: older)
        _ = try await read(olderSource)
        XCTAssertEqual(parses(olderSource), 2, "another version's summaries are not used")
        older.sync()
        XCTAssertFalse(older.isMemoryOnly)
        XCTAssertFalse(disk?.isMemoryOnly ?? true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: older.url.path))
        // The first file, still open in `first`, is whole and still in use.
        try claude(uuid())
        _ = try await read(first)
        disk?.sync()
        let (second, _) = source()
        _ = try await read(second)
        XCTAssertEqual(parses(second), 0)
    }

    /// A file whose own record disagrees with its name is not ours: used by
    /// nobody here, deleted by nobody, summaries kept in memory.
    func testAFileThatSaysAnotherVersionIsLeftAlone() async throws {
        try claude(uuid()); try codex(uuid())
        let (first, disk) = source()
        _ = try await read(first)
        disk?.sync()
        try setMeta("schema", "999")
        let (newer, newerDisk) = source()
        _ = try await read(newer)
        XCTAssertEqual(parses(newer), 2)
        _ = try await read(newer)
        XCTAssertEqual(parses(newer), 2, "kept in memory all the same")
        XCTAssertTrue(newerDisk?.isMemoryOnly ?? false)
        XCTAssertEqual(try meta("schema"), "999", "left exactly as it was")
    }

    /// The connection is closed before the lock is released: while the lock
    /// is held the file is open, never the other way round.
    func testTeardownClosesTheFileBeforeReleasingTheLock() throws {
        let order = TeardownLog()
        var disk: CatalogDiskCache? = CatalogDiskCache(directory: stateDir)
        let loaded = expectation(description: "loaded")
        disk?.load { _ in loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        XCTAssertFalse(disk?.isMemoryOnly ?? true)
        let lock = disk!.lockURL
        disk?.teardownProbe = { step in
            // Each step checks whether another process could now take the
            // file exclusively.
            let probe = Darwin.open(lock.path, O_RDWR)
            let free = flock(probe, LOCK_EX | LOCK_NB) == 0
            close(probe)
            order.append("\(step):\(free ? "free" : "held")")
        }
        disk = nil
        XCTAssertEqual(order.steps, ["database:held", "lock:free"])
    }

    // MARK: Sharing the file

    /// Two Temples at once (the installed app and a dev build) share one
    /// file: each reads what the other wrote, and neither falls back.
    func testTwoUsersShareTheFile() async throws {
        let a = uuid(), b = uuid()
        try claude(a)
        let (one, oneDisk) = source()
        let (two, twoDisk) = source()
        _ = try await read(one)
        oneDisk?.sync()
        try claude(b)
        _ = try await read(two)
        twoDisk?.sync()
        XCTAssertEqual(parses(two), 1, "the second user read the first one's summary")
        XCTAssertFalse(oneDisk?.isMemoryOnly ?? true)
        XCTAssertFalse(twoDisk?.isMemoryOnly ?? true)
        let (three, _) = source()
        let rows = try await read(three).summaries
        XCTAssertEqual(Set(rows.map(\.id)), [a, b])
        XCTAssertEqual(parses(three), 0)
    }

    /// A transaction held elsewhere is contention, not damage: this process
    /// keeps its summaries in memory for the run, and the file — with what
    /// it held — is left as it was.
    func testAHeldTransactionMeansMemoryOnlyAndTheFileStays() async throws {
        try claude(uuid()); try codex(uuid())
        let (first, disk) = source()
        _ = try await read(first)
        disk?.sync()
        var holding = Configuration()
        holding.allowsUnsafeTransactions = true
        let holder = try DatabaseQueue(path: cacheURL.path, configuration: holding)
        try holder.inDatabase { try $0.execute(sql: "BEGIN EXCLUSIVE") }
        let busy = CatalogDiskCache(directory: stateDir, busyTimeout: 0.1)
        let blocked = LocalSessionSource(stores: [ClaudeSessionStore(root: claudeRoot), CodexSessionStore(root: codexRoot)],
                                         monitorChanges: false, catalogDisk: busy)
        _ = try await read(blocked)
        XCTAssertEqual(parses(blocked), 2)
        busy.sync()
        XCTAssertTrue(busy.isMemoryOnly)
        _ = try await read(blocked)
        XCTAssertEqual(parses(blocked), 2, "memory works all the same")
        try holder.inDatabase { try $0.execute(sql: "COMMIT") }
        let (after, _) = source()
        _ = try await read(after)
        XCTAssertEqual(parses(after), 0, "the file still holds every summary")
    }

    /// A corrupt file another process has open is not deleted under it:
    /// memory only. Once nobody else holds it, it is rebuilt.
    func testACorruptFileInUseElsewhereIsLeftAlone() async throws {
        try claude(uuid())
        let garbage = Data("not a database, not even close".utf8)
        try garbage.write(to: cacheURL)
        let lock = CatalogDiskCache(directory: stateDir).lockURL
        let held = Darwin.open(lock.path, O_RDWR | O_CREAT, 0o644)
        XCTAssertEqual(flock(held, LOCK_SH), 0)
        let (inUse, inUseDisk) = source()
        _ = try await read(inUse)
        inUseDisk?.sync()
        XCTAssertTrue(inUseDisk?.isMemoryOnly ?? false)
        XCTAssertEqual(try Data(contentsOf: cacheURL), garbage, "not deleted while another process has it")
        close(held)
        let (sole, soleDisk) = source()
        _ = try await read(sole)
        soleDisk?.sync()
        XCTAssertFalse(soleDisk?.isMemoryOnly ?? true, "rebuilt once nobody else holds it")
        let (next, _) = source()
        _ = try await read(next)
        XCTAssertEqual(parses(next), 0)
    }

    /// A disk load that stalls is waited on once, up to the read's one
    /// deadline, then the read goes on without it; later reads do not wait.
    func testAStalledLoadIsWaitedOnOnceUnderOneDeadline() async throws {
        try claude(uuid()); try codex(uuid())
        let disk = CatalogDiskCache(directory: stateDir)
        let gate = DispatchSemaphore(value: 0)
        disk.stallForTesting(until: gate)
        defer { gate.signal() }
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: claudeRoot), CodexSessionStore(root: codexRoot)],
                                        monitorChanges: false, catalogDisk: disk, catalogLoadDeadline: 0.4)
        var started = Date()
        let rows = try await read(source).summaries
        XCTAssertEqual(rows.count, 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "one deadline for the read, not one per store")
        started = Date()
        _ = try await read(source)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3, "a stalled load is not waited on again")
        XCTAssertEqual(parses(source), 2)
    }

    /// Cancelling a read that waits on the disk ends the wait: the read
    /// stops there and never lists, even once the load lands.
    func testCancellingEndsTheWaitForTheDisk() async throws {
        try claude(uuid())
        let disk = CatalogDiskCache(directory: stateDir)
        let gate = DispatchSemaphore(value: 0)
        disk.stallForTesting(until: gate)
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: claudeRoot)], monitorChanges: false,
                                        catalogDisk: disk, catalogLoadDeadline: 10)
        let listed = Flag()
        source.catalogListedHook = { _ = listed.setOnce() }
        let reader = Task { for try await _ in source.catalog(CatalogQuery()) {} }
        try await Task.sleep(for: .milliseconds(150))
        reader.cancel()
        try await Task.sleep(for: .milliseconds(400))
        gate.signal()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(listed.isSet, "the cancelled read stopped waiting and never listed")
        XCTAssertEqual(parses(source), 0)
    }

    // MARK: Freshness

    /// A file that changes after the read listed it, before its batch, is
    /// read again: the stamp a kept summary answers to is taken at lookup.
    func testAChangeAfterListingIsSeenAtLookup() async throws {
        let id = uuid()
        let file = try claude(id, prompt: "Before change")
        try claude(uuid())
        let (source, _) = source(disk: false)
        _ = try await read(source)
        let base = parses(source)
        let rewrite = Data(try String(contentsOf: file).replacingOccurrences(of: "Before change", with: "After  change").utf8)
        source.catalogListedHook = {
            let modified = try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
            if let handle = try? FileHandle(forWritingTo: file) { try? handle.write(contentsOf: rewrite); try? handle.close() }
            if let modified { try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
        }
        let rows = try await read(source).summaries
        XCTAssertEqual(rows.first { $0.id == id }?.firstPrompt, "After change")
        XCTAssertEqual(parses(source), base + 1)
    }

    /// A transcript that is a symbolic link is read every time: its own
    /// stamp says nothing about its target, so nothing is kept for it.
    func testASymlinkedTranscriptIsNeverServedStale() async throws {
        let id = uuid()
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = try claude(id, prompt: "Target one")
        let moved = elsewhere.appendingPathComponent(target.lastPathComponent)
        try FileManager.default.moveItem(at: target, to: moved)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: moved)
        let (source, _) = source(disk: false)
        func prompt() async throws -> String?? {
            try await read(source).summaries.first { $0.id == id }.map(\.firstPrompt)
        }
        let first = try await prompt()
        XCTAssertEqual(first, "Target one")
        // The target rewritten in place, same size, old mtime back.
        let modified = try FileManager.default.attributesOfItem(atPath: moved.path)[.modificationDate] as? Date
        let handle = try FileHandle(forWritingTo: moved)
        try handle.write(contentsOf: Data(try String(contentsOf: moved).replacingOccurrences(of: "Target one", with: "Target two").utf8))
        try handle.close()
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: moved.path) }
        let rewritten = try await prompt()
        XCTAssertEqual(rewritten, "Target two")
        // The target replaced.
        try Data(try String(contentsOf: moved).replacingOccurrences(of: "Target two", with: "Target new").utf8).write(to: moved, options: .atomic)
        let replaced = try await prompt()
        XCTAssertEqual(replaced, "Target new")
        // The target gone.
        try FileManager.default.removeItem(at: moved)
        let dangling = try await prompt()
        XCTAssertNil(dangling)
        XCTAssertEqual(source.catalogCache.count, 0, "nothing is ever kept for a link")
    }

    // MARK: Read outcomes

    /// A parse whose read failed is never kept, as an exclusion or anything
    /// else: the transcript is read again and shown once it reads. A summary
    /// missing a part it needed is shown and read again next time. A proven
    /// exclusion is kept.
    func testOnlyWholeReadsAreKept() async throws {
        let id = uuid()
        try claude(id)
        let script = OutcomeScript([.failed, .incomplete, .whole, .whole])
        let source = LocalSessionSource(stores: [ScriptedClaudeStore(root: claudeRoot, script: script)], monitorChanges: false)
        let failed = try await read(source).summaries
        XCTAssertEqual(failed, [], "a failed read shows nothing")
        XCTAssertEqual(source.catalogCache.count, 0, "and keeps nothing, not even an exclusion")
        let partial = try await read(source).summaries
        XCTAssertEqual(partial.map(\.id), [id], "a partial summary is shown")
        XCTAssertEqual(source.catalogCache.count, 0, "but not kept")
        _ = try await read(source)
        XCTAssertEqual(parses(source), 3)
        _ = try await read(source)
        XCTAssertEqual(parses(source), 3, "a whole read is kept")
    }

    /// Head, tail, wider-head and stat failures, injected into the catalog's
    /// own parse: a head failure fails, the others leave the summary
    /// incomplete (with the content the old parse gave), and only bytes
    /// read whole can prove an exclusion.
    func testInjectedReadFailuresAreNeverWhole() throws {
        struct Injected: Error {}
        let bigID = uuid()
        let big = project.appendingPathComponent("\(bigID).jsonl")
        let filler = #"{"type":"assistant","sessionId":"\#(bigID)","message":{"content":"\#(String(repeating: "f", count: 1000))"}}"#
        try write(([#"{"type":"user","sessionId":"\#(bigID)","cwd":"/w","message":{"content":"Head prompt"}}"#]
                   + Array(repeating: filler, count: 100) + [#"{"type":"summary","summary":"Tail title"}"#]).joined(separator: "\n"), to: big)
        let wide = rollouts.appendingPathComponent("rollout-2026-10-01T10-00-00-\(uuid()).jsonl")
        let wideID = String(wide.deletingPathExtension().lastPathComponent.dropFirst(28))
        try write([#"{"type":"session_meta","payload":{"id":"\#(wideID)","cwd":"/w"}}"#,
                   #"{"type":"response_item","payload":{"role":"user","content":"\#(String(repeating: "x", count: 80_000))"}}"#,
                   #"{"type":"event_msg","payload":{"type":"user_message","message":"wide prompt"}}"#].joined(separator: "\n"), to: wide)
        let excluded = rollouts.appendingPathComponent("rollout-2026-10-01T10-00-00-\(uuid()).jsonl")
        try write(#"{"type":"session_meta","payload":{"id":"x","cwd":"/w","thread_source":"subagent"}}"#, to: excluded)
        let file = StoreIO.Reads.file
        func reads(head: Bool = true, tail: Bool = true, wider: Bool = true, signature: Bool = true) -> StoreIO.Reads {
            StoreIO.Reads(signature: { signature ? file.signature($0) : nil },
                          head: { url, n in
                              if n == TranscriptBytes.defaultWindow { guard head else { throw Injected() } } else { guard wider else { throw Injected() } }
                              return try file.head(url, n) },
                          tail: { url, n in guard tail else { throw Injected() }; return try file.tail(url, n) })
        }
        let claudeFormat = ClaudeFormat(), codexFormat = CodexFormat()
        let whole = StoreIO.catalogParse(at: big, format: claudeFormat, shared: .empty)
        XCTAssertEqual(whole, StoreIO.summary(at: big, format: claudeFormat, shared: .empty).map { .summary($0) })
        XCTAssertEqual(StoreIO.catalogParse(at: big, format: claudeFormat, shared: .empty, reads: reads(head: false)), .failed)
        guard case .incomplete = StoreIO.catalogParse(at: big, format: claudeFormat, shared: .empty, reads: reads(tail: false)) else {
            return XCTFail("a failed tail is incomplete")
        }
        guard case .incomplete = StoreIO.catalogParse(at: big, format: claudeFormat, shared: .empty, reads: reads(signature: false)) else {
            return XCTFail("a failed stat is incomplete")
        }
        let wideWhole = StoreIO.catalogParse(at: wide, format: codexFormat, shared: .empty)
        guard case .summary(let wideSummary) = wideWhole else { return XCTFail() }
        XCTAssertEqual(wideSummary.firstPrompt, "wide prompt")
        guard case .incomplete(let widePartial) = StoreIO.catalogParse(at: wide, format: codexFormat, shared: .empty, reads: reads(wider: false)) else {
            return XCTFail("a failed wider head is incomplete")
        }
        XCTAssertNil(widePartial.firstPrompt)
        XCTAssertEqual(StoreIO.catalogParse(at: excluded, format: codexFormat, shared: .empty), .excluded)
        XCTAssertEqual(StoreIO.catalogParse(at: excluded, format: codexFormat, shared: .empty, reads: reads(head: false)), .failed)
    }

    /// An inode number means nothing off its own filesystem: the same path
    /// and inode on another device, or another volume, is another root.
    func testARootIsItsFilesystemsToo() {
        let here = CatalogRoot(path: "/r", inode: 7, device: 1, volume: "VOL-A")
        XCTAssertTrue(here.matches(CatalogRoot(path: "/r", inode: 7, device: 1, volume: "VOL-A")))
        XCTAssertFalse(here.matches(CatalogRoot(path: "/r", inode: 7, device: 2, volume: "VOL-A")), "another device")
        XCTAssertFalse(here.matches(CatalogRoot(path: "/r", inode: 7, device: 1, volume: "VOL-B")), "another volume")
        let fromDisk = CatalogRoot(path: "/r", inode: 7, volume: "VOL-A")
        XCTAssertTrue(fromDisk.matches(here), "read back from disk: no device, the volume decides")
        XCTAssertFalse(CatalogRoot(path: "/r", inode: 7, volume: "VOL-B").matches(here))
        XCTAssertNotNil(CatalogRoot(claudeRoot)?.device)
    }

    /// A store root whose filesystem changed during the read — same path,
    /// same inode number, another device — completes nothing.
    func testARootOnAnotherFilesystemByTheEndCompletesNothing() async throws {
        try claude(uuid()); try codex(uuid())
        let calls = IdentityCalls()
        let claudePath = SessionPaths.normalized(claudeRoot.path)
        let catalog = LocalSessionCatalog(stores: [ClaudeSessionStore(root: claudeRoot), CodexSessionStore(root: codexRoot)],
                                          cache: CatalogSummaryCache(), identify: { url in
            guard let real = CatalogRoot(url) else { return nil }
            let call = calls.next(real.path)
            guard real.path == claudePath, call > 1 else { return real }
            return CatalogRoot(path: real.path, inode: real.inode, device: (real.device ?? 0) + 1, volume: real.volume)
        })
        var events: [CatalogBatch] = []
        for await event in catalog.stream() { events.append(event) }
        XCTAssertEqual(events.last?.completedAgents, [.codex])
    }

    /// Kept on disk, a root is its volume: the same path and inode on
    /// another volume reads everything again.
    func testADiskRootOnAnotherVolumeKeepsNothing() async throws {
        try claude(uuid()); try claude(uuid())
        func catalog(volume: String) -> (LocalSessionCatalog, CatalogDiskCache, Counter) {
            let disk = CatalogDiskCache(directory: stateDir)
            let parses = Counter()
            let catalog = LocalSessionCatalog(stores: [ClaudeSessionStore(root: claudeRoot)], cache: CatalogSummaryCache(disk: disk),
                                              onParse: { parses.increment() }, identify: { url in
                guard let real = CatalogRoot(url) else { return nil }
                return CatalogRoot(path: real.path, inode: real.inode, device: real.device, volume: volume)
            })
            return (catalog, disk, parses)
        }
        let (first, firstDisk, firstParses) = catalog(volume: "VOL-A")
        for await _ in first.stream() {}
        firstDisk.sync()
        XCTAssertEqual(firstParses.value, 2)
        let (same, sameDisk, sameParses) = catalog(volume: "VOL-A")
        for await _ in same.stream() {}
        sameDisk.sync()
        XCTAssertEqual(sameParses.value, 0, "the same volume: everything kept")
        let (other, _, otherParses) = catalog(volume: "VOL-B")
        for await _ in other.stream() {}
        XCTAssertEqual(otherParses.value, 2, "another volume: nothing kept applies")
    }

    // MARK: Completed coverage

    /// A store root that is not there completes nothing, for either agent;
    /// an existing empty one completes.
    func testAMissingRootCompletesNothingAndAnEmptyOneCompletes() async throws {
        let (present, _) = source(disk: false)
        let empty = try await read(present)
        XCTAssertEqual(empty.events.last?.completedAgents, [.claude, .codex])
        try FileManager.default.removeItem(at: claudeRoot)
        try FileManager.default.removeItem(at: codexRoot)
        let (absent, _) = source(disk: false)
        let missing = try await read(absent)
        XCTAssertEqual(missing.events.last?.completedAgents, [])
        XCTAssertFalse(missing.events.contains { if case .storeFailed = $0 { return true }; return false })
    }

    /// A root that goes away, or is replaced, while the read goes on
    /// completes nothing for its agent, and nothing kept for it is
    /// forgotten; the other agent completes.
    func testARootLostDuringTheReadCompletesNothing() async throws {
        try claude(uuid()); try claude(uuid()); try codex(uuid())
        let (source, _) = source(disk: false)
        _ = try await read(source)
        XCTAssertEqual(source.catalogCache.count, 3)
        let aside = root.appendingPathComponent("claude-aside")
        let claudeDir = claudeRoot
        source.catalogListedHook = { try? FileManager.default.moveItem(at: claudeDir, to: aside) }
        let lost = try await read(source)
        XCTAssertEqual(lost.events.last?.completedAgents, [.codex])
        XCTAssertEqual(source.catalogCache.count, 3, "nothing forgotten for a root that went away")
        source.catalogListedHook = nil
        try FileManager.default.moveItem(at: aside, to: claudeRoot)
        // Replaced by another directory at the same path.
        let codexSessions = codexRoot.appendingPathComponent("sessions")
        let sessionsAside = root.appendingPathComponent("sessions-aside")
        source.catalogListedHook = {
            try? FileManager.default.moveItem(at: codexSessions, to: sessionsAside)
            try? FileManager.default.createDirectory(at: codexSessions, withIntermediateDirectories: true)
        }
        let replaced = try await read(source)
        XCTAssertEqual(replaced.events.last?.completedAgents, [.claude])
        // And Codex's root simply gone.
        source.catalogListedHook = nil
        try FileManager.default.removeItem(at: codexSessions)
        try FileManager.default.moveItem(at: sessionsAside, to: codexSessions)
        let back = try await read(source)
        XCTAssertEqual(back.events.last?.completedAgents, [.claude, .codex])
        source.catalogListedHook = { try? FileManager.default.moveItem(at: codexSessions, to: sessionsAside) }
        let gone = try await read(source)
        XCTAssertEqual(gone.events.last?.completedAgents, [.claude])
        XCTAssertEqual(source.catalogCache.count, 3)
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
        XCTAssertEqual(failed.events.last?.completedAgents, [.codex])
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
        XCTAssertEqual(whole.events.last?.completedAgents, [.claude])
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
        second.catalogCache.waitUntilLoaded(deadline: Date().addingTimeInterval(5))
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

private final class TeardownLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func append(_ step: String) { lock.lock(); recorded.append(step); lock.unlock() }
    var steps: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
}

private final class IdentityCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func next(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; counts[path, default: 0] += 1; return counts[path]! }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
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
    func rootAvailable() -> Bool { inner.rootAvailable() }
    func loadSummaries() -> [TranscriptSummary] { inner.loadSummaries() }
    func sessionFileURLs() -> [URL] { inner.sessionFileURLs() }
    func enumerateSessionFiles() throws -> [URL] { try inner.enumerateSessionFiles() }
    func loadSummary(at fileURL: URL) -> TranscriptSummary? { inner.loadSummary(at: fileURL) }
    func catalogReader() -> @Sendable (URL) -> CatalogParse {
        let read = inner.catalogReader()
        return { url in Thread.sleep(forTimeInterval: 0.1); return read(url) }
    }
}

/// What each successive catalog parse of `ScriptedClaudeStore` comes to.
private final class OutcomeScript: @unchecked Sendable {
    enum Step { case failed, incomplete, whole }
    private let lock = NSLock()
    private var steps: [Step]
    init(_ steps: [Step]) { self.steps = steps }
    func next() -> Step { lock.lock(); defer { lock.unlock() }; return steps.isEmpty ? .whole : steps.removeFirst() }
}

/// Claude's store whose parses fail, come out partial or read whole, in
/// the order its script says.
private struct ScriptedClaudeStore: IncrementalSessionStore {
    let inner: ClaudeSessionStore
    let script: OutcomeScript
    init(root: URL, script: OutcomeScript) { inner = ClaudeSessionStore(root: root); self.script = script }
    var agent: Agent { .claude }
    var catalogRoot: URL? { inner.catalogRoot }
    func rootAvailable() -> Bool { inner.rootAvailable() }
    func loadSummaries() -> [TranscriptSummary] { inner.loadSummaries() }
    func sessionFileURLs() -> [URL] { inner.sessionFileURLs() }
    func enumerateSessionFiles() throws -> [URL] { try inner.enumerateSessionFiles() }
    func loadSummary(at fileURL: URL) -> TranscriptSummary? { inner.loadSummary(at: fileURL) }
    func catalogReader() -> @Sendable (URL) -> CatalogParse {
        let read = inner.catalogReader(), script = self.script
        return { url in
            switch script.next() {
            case .failed: return .failed
            case .incomplete: if case .summary(let summary) = read(url) { return .incomplete(summary) }; return .failed
            case .whole: return read(url)
            }
        }
    }
}
