import XCTest
import CoreServices
@testable import TempleCore

/// The engine's per-member state machine over this Mac's source: verify,
/// enrich only while the row lacks something, back off, re-verify on a new
/// file. No FSEvents stream runs (every event is injected) and timers never
/// fire on their own: a test advances the clock and runs due work itself.
@MainActor
final class MemberStateMachineTests: XCTestCase {
    private var started: [SessionEngine] = []
    private var tasks: [Task<Void, Never>] = []

    override func tearDown() async throws {
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        for engine in started { await engine.stop() }
        started.removeAll()
        try await super.tearDown()
    }

    private enum Row { case complete, wantsTitle, wantsDirectoryAndTitle, bare }

    private func fixture(agent: Agent = .claude, prompt: String? = nil, row: Row = .bare)
        throws -> (URL, URL, TempleDB, P5Clock, SessionEngine, LocalSessionSource) {
        let root = URL(fileURLWithPath: "/private/tmp/temple-p5-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(agent == .claude ? "project" : "sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: root)
        }
        let file = dir.appendingPathComponent(agent == .claude ? "member.jsonl" : "rollout-member.jsonl")
        try write(file, agent: agent, id: "member", prompt: prompt)
        let db = try TempleDB.inMemory()
        let core: SessionCore? = switch row {
        case .complete: SessionCore(directory: "/work", title: "Complete", lastActiveAt: Date())
        case .wantsTitle: SessionCore(directory: "/work", directorySource: .tab, lastActiveAt: Date())
        case .wantsDirectoryAndTitle: SessionCore(lastActiveAt: Date())
        case .bare: nil
        }
        try db.join(sessionID: "member", via: .imported, agent: agent, locator: TranscriptLocator(localURL: file), core: core)
        let store: any IncrementalSessionStore = agent == .claude ? ClaudeSessionStore(root: root) : CodexSessionStore(root: root)
        let source = LocalSessionSource(stores: [store], debounceInterval: 0.01, monitorChanges: false)
        let clock = P5Clock()
        let watcher = SessionEngine(source: source, database: db, now: { clock.date },
                                    sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        started.append(watcher)
        return (root, file, db, clock, watcher, source)
    }

    private func write(_ file: URL, agent: Agent = .claude, id: String = "member", prompt: String? = nil,
                       atomic: Bool = false) throws {
        let header = agent == .claude
            ? "{\"type\":\"system\",\"sessionId\":\"\(id)\",\"cwd\":\"/work\"}"
            : "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/work\"}}"
        let line = prompt.map { text in agent == .claude
            ? "\n{\"type\":\"user\",\"sessionId\":\"\(id)\",\"message\":{\"content\":\"\(text)\"}}"
            : "\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"\(text)\"}}" } ?? ""
        try (header + line + "\n").write(to: file, atomically: atomic, encoding: .utf8)
    }

    private func append(_ file: URL, _ line: String = "{}\n") throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8))
    }

    /// What FSEvents would deliver for a write to `file`.
    private func touched(_ watcher: SessionEngine, _ file: URL) {
        watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile))
    }

    private func wait(_ message: String = "condition", _ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while await !predicate() {
            guard Date() < deadline else { XCTFail("timed out: \(message)"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func start(_ watcher: SessionEngine) async throws {
        await watcher.start()
        try await wait("settled") {
            guard let snapshot = watcher.latestSnapshot, !snapshot.resolutions.isEmpty else { return false }
            return !snapshot.resolutions.values.contains(.resolving)
        }
    }

    /// A write, delivered, and the pass it causes finished.
    private func written(_ watcher: SessionEngine, _ file: URL) async throws {
        let before = watcher.metrics
        touched(watcher, file)
        try await wait("observed") { watcher.metrics.observations > before.observations }
        try await wait("located") { watcher.metrics.locates > before.locates }
        try await Task.sleep(for: .milliseconds(20))
    }

    /// Persists authorized facts as the app does.
    private func consume(_ watcher: SessionEngine, _ db: TempleDB) {
        let committer = FactCommitter(database: db)
        let stream = watcher.snapshots()
        tasks.append(Task { for await snapshot in stream { committer.receive(snapshot.facts) } })
    }

    func testAMemberWriteWithNothingMissingIsAStatNotAParse() async throws {
        let (_, file, _, _, watcher, _) = try fixture(row: .complete)
        try await start(watcher)
        XCTAssertEqual(watcher.resolution(for: "member"), .loaded(file))
        XCTAssertEqual(watcher.metrics.factReads, 0); XCTAssertEqual(watcher.metrics.reads, 1)
        let before = watcher.metrics
        try append(file)
        try await written(watcher, file)
        XCTAssertEqual(watcher.metrics.factReads, 0); XCTAssertEqual(watcher.metrics.reads, 1)
        XCTAssertEqual(watcher.metrics.parses, 0)
        XCTAssertEqual(watcher.metrics.publications, before.publications)
    }

    /// Once the row has every field, later writes are stats, not parses.
    func testAFilledRowStopsParsing() async throws {
        let (_, file, db, clock, watcher, _) = try fixture(prompt: "A title")
        consume(watcher, db)
        try await start(watcher)
        try await wait("filled") { (try? db.sessionState("member")?.title) == "A title" }
        try await wait("facts dropped") { watcher.latestSnapshot?.facts["member"] == nil }
        let before = watcher.metrics
        clock.advance(61)
        try append(file)
        try await written(watcher, file)
        XCTAssertEqual(watcher.metrics.factReads, before.factReads)
        XCTAssertEqual(watcher.metrics.publications, before.publications)
    }

    func testAPromptArrivingOnWrite12IsFilled() async throws {
        let (_, file, db, clock, watcher, _) = try fixture(row: .wantsTitle)
        consume(watcher, db)
        try await start(watcher)
        for number in 1...12 {
            clock.advance(61)
            if number == 12 {
                try append(file, "{\"type\":\"user\",\"sessionId\":\"member\",\"message\":{\"content\":\"Twelfth prompt\"}}\n")
            } else { try append(file) }
            let before = watcher.metrics.factReads
            touched(watcher, file)
            try await wait("parsed \(number)") { watcher.metrics.factReads > before }
        }
        try await wait("titled") { (try? db.sessionState("member")?.title) == "Twelfth prompt" }
        XCTAssertGreaterThanOrEqual(watcher.metrics.factReads, 13)
    }

    func testBackoffBoundsParsesForAPromptlessFile() async throws {
        let (_, file, _, clock, watcher, _) = try fixture(row: .wantsTitle)
        try await start(watcher)
        for _ in 0..<240 {
            clock.advance(0.25)
            try append(file)
            try await written(watcher, file)
            await watcher.reconcileEnrichment()
        }
        try await Task.sleep(for: .milliseconds(50))
        // t=0,1,3,7,15,31. There is no lifetime attempt limit.
        XCTAssertEqual(watcher.metrics.factReads, 6)
        XCTAssertEqual(watcher.metrics.reads, 6, "appends never re-verify identity")
    }

    func testAnExplicitRequestRunsWithAnUnchangedSignature() async throws {
        let (_, _, _, _, watcher, _) = try fixture(row: .wantsTitle)
        try await start(watcher)
        let before = watcher.metrics.factReads
        await watcher.requestResolution("member")
        try await wait { watcher.metrics.factReads == before + 1 }
    }

    func testAReplacedFileIsReverified() async throws {
        for agent in Agent.allCases {
            let (_, file, _, _, watcher, _) = try fixture(agent: agent, row: .complete)
            try await start(watcher)
            let old = try FileSignature(file)
            try write(file, agent: agent, id: "other", atomic: true)
            XCTAssertNotEqual(try FileSignature(file).fileNumber, old.fileNumber)
            touched(watcher, file)
            try await wait { watcher.resolution(for: "member") == .mismatch }
            XCTAssertEqual(watcher.metrics.factReads, 0); XCTAssertEqual(watcher.metrics.reads, 2)
            await watcher.stop()
        }
    }

    func testTruncationThenRegrowthReverifies() async throws {
        let (_, file, _, _, watcher, _) = try fixture(row: .complete)
        try await start(watcher)
        let inode = try FileSignature(file).fileNumber
        try Data().write(to: file)
        touched(watcher, file)
        try await wait { watcher.resolution(for: "member") == .incomplete }
        XCTAssertEqual(watcher.metrics.reads, 2)
        try write(file, id: "other")
        XCTAssertEqual(try FileSignature(file).fileNumber, inode)
        touched(watcher, file)
        try await wait { watcher.resolution(for: "member") == .mismatch }
        XCTAssertEqual(watcher.metrics.reads, 3)
    }

    func testMismatchAndUnreadableNeverBecomeAbsent() async throws {
        let (root, file, _, _, watcher, _) = try fixture(row: .complete)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        try await start(watcher)
        XCTAssertEqual(watcher.resolution(for: "member"), .unreadable)
        watcher.reconcileEvent(path: root.path, flags: UInt32(kFSEventStreamEventFlagKernelDropped))
        try await wait { watcher.metrics.reads >= 2 }
        XCTAssertEqual(watcher.resolution(for: "member"), .unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try write(file, id: "wrong", atomic: true)
        touched(watcher, file)
        try await wait { watcher.resolution(for: "member") == .mismatch }
        await watcher.requestResolution("member")
        try await wait { watcher.metrics.reads >= 4 }
        XCTAssertEqual(watcher.resolution(for: "member"), .mismatch)
    }

    func testCoverageResetRearmsEnrichment() async throws {
        let (root, file, _, _, watcher, _) = try fixture(row: .wantsTitle)
        try await start(watcher)
        try append(file)
        try await written(watcher, file)
        let before = watcher.metrics.factReads
        watcher.reconcileEvent(path: root.path, flags: UInt32(kFSEventStreamEventFlagKernelDropped))
        try await wait { watcher.metrics.factReads == before + 1 }
        XCTAssertEqual(watcher.metrics.reads, watcher.metrics.factReads,
                       "Coverage resets enrichment without an identity-only re-read of a stable file")
    }

    func testAPartialFillResolvesADeferredSignatureWithoutAnotherWrite() async throws {
        let (_, file, db, clock, watcher, _) = try fixture(row: .wantsDirectoryAndTitle)
        try await start(watcher)
        clock.advance(0.1)
        try append(file, "{\"type\":\"user\",\"sessionId\":\"member\",\"message\":{\"content\":\"Soon\"}}\n")
        try await written(watcher, file)
        XCTAssertEqual(watcher.metrics.factReads, 1, "Changed signature is deferred behind the first deadline")
        _ = try db.fillCoreFields(sessionID: "member", host: .local, directory: "/work")
        // No clock advance, reconciliation or further write: the fill must re-arm work.
        try await wait { watcher.latestSnapshot?.facts["member"]?.summary?.firstPrompt == "Soon" }
        XCTAssertEqual(watcher.metrics.factReads, 2)
    }

    func testRapidReplacementsPreserveTheMembersParseBackoff() async throws {
        let (_, file, _, clock, watcher, _) = try fixture(row: .wantsTitle)
        try await start(watcher)
        for _ in 0..<240 {
            clock.advance(0.25)
            let reads = watcher.metrics.reads
            try write(file, atomic: true)
            touched(watcher, file)
            try await wait { watcher.metrics.reads > reads }
            await watcher.reconcileEnrichment()
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(watcher.metrics.factReads, 6, "Replacements verify immediately but parse only at 0,1,3,7,15,31")
        XCTAssertGreaterThanOrEqual(watcher.metrics.reads, 241)
    }

    func testRepeatedAfterParseRacesStillChargeTheMembersBackoff() async throws {
        let (_, file, _, clock, watcher, source) = try fixture(row: .wantsTitle)
        // The file grows in the middle of every facts read: none settles.
        source.readPhaseHook = { phase, url in
            guard phase == .sharedFactsAcquired, let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("{}\n".utf8))
        }
        let recorded = Recorded()
        let stream = watcher.snapshots()
        tasks.append(Task { for await snapshot in stream { recorded.append(snapshot) } })
        try await start(watcher)
        for _ in 0..<240 {
            clock.advance(0.25)
            try append(file)
            try await written(watcher, file)
            await watcher.reconcileEnrichment()
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(watcher.metrics.factReads, 6, "Every discarded parse consumes a backoff interval")
        XCTAssertFalse(recorded.all.contains { $0.facts["member"]?.summary != nil }, "Racing results must never escape")
    }

    func testAnIdentityReadRacingAReplacementNeverPublishesLoaded() async throws {
        let (_, file, _, _, watcher, source) = try fixture(row: .complete)
        let once = Flag()
        source.readPhaseHook = { phase, url in
            guard phase == .bytesRead, once.setOnce() else { return }
            try? Data("{\"type\":\"system\",\"sessionId\":\"wrong\"}".utf8).write(to: url, options: .atomic)
        }
        let recorded = Recorded()
        let stream = watcher.snapshots()
        tasks.append(Task { for await snapshot in stream { recorded.append(snapshot) } })
        await watcher.start()
        try await wait { watcher.resolution(for: "member") == .mismatch }
        XCTAssertFalse(recorded.all.contains { $0.resolutions["member"] == .loaded(file) })
        XCTAssertEqual(watcher.metrics.factReads, 0)
        XCTAssertGreaterThanOrEqual(watcher.metrics.reads, 1)
    }

    func testCodexSharedHistoryChangesDoNotPublishForACompleteMember() async throws {
        let (root, _, _, _, watcher, _) = try fixture(agent: .codex, row: .complete)
        try await start(watcher)
        let before = watcher.metrics
        let history = root.appendingPathComponent("history.jsonl")
        try Data("{\"session_id\":\"member\",\"text\":\"A late history prompt\"}".utf8).write(to: history)
        watcher.reconcileEvent(path: history.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(watcher.metrics.factReads, 0)
        XCTAssertEqual(watcher.metrics.locates, before.locates)
        XCTAssertEqual(watcher.metrics.publications, before.publications)
    }

    /// A member whose transcript was pruned keeps its hint. Resolving it
    /// again must not walk both stores each time (that was a full
    /// enumeration per pruned member per resolve); and new shared facts do
    /// not resolve it at all — a history line cannot give it a transcript.
    func testAPrunedHintedMemberDoesNotReEnumerateOnEveryResolve() async throws {
        let (root, _, db, _, watcher, _) = try fixture(agent: .codex, row: .complete)
        let gone = root.appendingPathComponent("sessions/rollout-pruned.jsonl")
        try db.join(sessionID: "pruned", via: .imported, agent: .codex, locator: TranscriptLocator(localURL: gone))
        try await start(watcher)
        try await wait { watcher.resolution(for: "pruned") == .confirmedAbsent }
        let before = watcher.metrics
        let history = root.appendingPathComponent("history.jsonl")
        try Data("{\"session_id\":\"other\",\"text\":\"prompt\"}".utf8).write(to: history)
        watcher.reconcileEvent(path: history.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(watcher.metrics.locates, before.locates, "no transcript, nothing shared facts could add")
        for round in 0..<3 {
            // The hinted path itself is reported again (gone): resolved
            // again from the map, without a walk.
            watcher.reconcileEvent(path: gone.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile))
            try await wait { watcher.metrics.locates > before.locates + UInt64(round) }
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(watcher.metrics.enumerations, before.enumerations)
        XCTAssertEqual(watcher.resolution(for: "pruned"), .confirmedAbsent)
    }

    /// The rollout does not change when history.jsonl records the member's
    /// prompt, so the attempt gate on the rollout's signature used to make
    /// the title unreachable until the rollout was written again.
    func testASharedHistoryPromptCompletesACodexTitleWithoutTheRolloutChanging() async throws {
        let (root, file, db, clock, watcher, _) = try fixture(agent: .codex, row: .wantsTitle)
        try db.join(sessionID: "complete", via: .imported, agent: .claude,
            core: SessionCore(directory: "/w", title: "Done", lastActiveAt: Date()))
        try await start(watcher)
        XCTAssertEqual(watcher.resolution(for: "member"), .loaded(file))
        XCTAssertNil(watcher.latestSnapshot?.facts["member"], "nothing the row wants yet")
        let parses = watcher.metrics.factReads
        clock.advance(61)
        let history = root.appendingPathComponent("history.jsonl")
        try Data("{\"session_id\":\"member\",\"ts\":1,\"text\":\"Recorded later\"}".utf8).write(to: history)
        watcher.reconcileEvent(path: history.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await wait { watcher.latestSnapshot?.facts["member"]?.summary?.historyPrompt == "Recorded later" }
        XCTAssertEqual(watcher.metrics.factReads, parses + 1)
        XCTAssertEqual(watcher.resolution(for: "member"), .loaded(file))
    }

    /// Filling one field does not re-read a file that has not changed.
    func testAFieldFillDoesNotReparseAnUnchangedFile() async throws {
        let (_, _, db, _, watcher, _) = try fixture()
        try await start(watcher)
        try await wait { watcher.latestSnapshot?.facts["member"]?.summary != nil }
        let parses = watcher.metrics.factReads
        let locates = watcher.metrics.locates
        _ = try db.fillCoreFields(sessionID: "member", host: .local, directory: "/work")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(watcher.metrics.factReads, parses)
        XCTAssertEqual(watcher.metrics.locates, locates)
    }

    func testClaudeVerifiesTheFirstTypedLineCarryingAnID() async throws {
        let (_, file, _, _, watcher, _) = try fixture(row: .complete)
        try "{\"sessionId\":\"untyped\"}\n{\"type\":\"summary\"}\n{\"type\":\"user\",\"sessionId\":\"member\"}\n{\"type\":\"user\",\"sessionId\":\"other\"}".write(to: file, atomically: false, encoding: .utf8)
        try await start(watcher)
        XCTAssertEqual(watcher.resolution(for: "member"), .loaded(file))
    }
}

private final class P5Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_700_000_000)
    var date: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [EngineSnapshot] = []
    func append(_ snapshot: EngineSnapshot) { lock.lock(); snapshots.append(snapshot); lock.unlock() }
    var all: [EngineSnapshot] { lock.lock(); defer { lock.unlock() }; return snapshots }
}
