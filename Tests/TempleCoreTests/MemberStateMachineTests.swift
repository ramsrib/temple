import XCTest
import CoreServices
@testable import TempleCore

@MainActor
final class MemberStateMachineTests: XCTestCase {
    private func fixture(agent: Agent = .claude, prompt: String? = nil, complete: Bool = false)
        throws -> (URL, URL, TempleDB, P5SpyStore, P5Clock, SessionEngine) {
        let root = URL(fileURLWithPath: "/private/tmp/temple-p5-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(agent == .claude ? "project" : "sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = dir.appendingPathComponent(agent == .claude ? "member.jsonl" : "rollout-member.jsonl")
        try write(file, agent: agent, id: "member", prompt: prompt)
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "member", via: .imported, agent: agent, transcriptPath: file,
            core: complete ? SessionCore(directory: "/work", title: "Complete", lastActiveAt: Date()) : nil)
        let store = P5SpyStore(agent == .claude ? ClaudeSessionStore(root: root) : CodexSessionStore(root: root))
        let clock = P5Clock()
        let watcher = SessionEngine(source: LocalSessionSource(stores: [store], debounceInterval: 0.01, now: { clock.date }), database: db)
        return (root, file, db, store, clock, watcher)
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

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    private func start(_ watcher: SessionEngine) async throws -> Task<Void, Never> {
        let stream = watcher.start()
        let task = Task { for await _ in stream {} }
        try await wait { watcher.publishedSnapshot != nil }
        return task
    }

    func testAMemberWriteWithNothingMissingIsAStatNotAParse() async throws {
        let (_, file, _, spy, _, watcher) = try fixture(complete: true)
        let task = try await start(watcher); defer { task.cancel(); watcher.stop() }
        XCTAssertEqual(watcher.resolution(for: "member"), .loaded(file))
        XCTAssertEqual(spy.parses, 0); XCTAssertEqual(spy.verifications, 1)
        let before = watcher.metrics
        try append(file)
        watcher.reconcileEnrichment()
        try await wait { watcher.metrics.observations > before.observations }
        XCTAssertEqual(spy.parses, 0); XCTAssertEqual(spy.verifications, 1)
        XCTAssertEqual(watcher.metrics.publications, before.publications)
    }

    func testAPromptArrivingOnWrite12IsFilled() async throws {
        let (_, file, db, spy, clock, watcher) = try fixture()
        let task = try await start(watcher); defer { task.cancel(); watcher.stop() }
        watcher.setEnrichmentWanted(["member": [.title]])
        for number in 1...12 {
            clock.advance(61)
            if number == 12 {
                try append(file, "{\"type\":\"user\",\"sessionId\":\"member\",\"message\":{\"content\":\"Twelfth prompt\"}}\n")
            } else { try append(file) }
            let before = spy.parses
            watcher.reconcileEnrichment()
            try await wait { spy.parses > before }
        }
        let summary = try XCTUnwrap(watcher.publishedSnapshot?.summaries["member"])
        _ = try db.fillCoreFields(sessionID: "member", agent: summary.agent, directory: summary.cwd,
            title: summary.firstPrompt, lastActiveAt: summary.modifiedAt)
        watcher.setEnrichmentWanted([:])
        XCTAssertEqual(try db.sessionState("member")?.title, "Twelfth prompt")
        XCTAssertGreaterThanOrEqual(spy.parses, 13)
    }

    func testBackoffBoundsParsesForAPromptlessFile() async throws {
        let (_, file, _, spy, clock, watcher) = try fixture()
        watcher.setEnrichmentWanted(["member": [.title]])
        let task = try await start(watcher); defer { task.cancel(); watcher.stop() }
        for _ in 0..<240 {
            clock.advance(0.25)
            try append(file)
            let observations = watcher.metrics.observations
            watcher.reconcileEnrichment()
            try await wait { watcher.metrics.observations > observations }
        }
        // t=0,1,3,7,15,31. There is no lifetime attempt limit.
        XCTAssertEqual(spy.parses, 6)
        XCTAssertEqual(spy.verifications, 1)
    }

    func testAnExplicitRequestRunsWithAnUnchangedSignature() async throws {
        let (_, _, _, spy, _, watcher) = try fixture()
        watcher.setEnrichmentWanted(["member": [.title]])
        let task = try await start(watcher); defer { task.cancel(); watcher.stop() }
        let before = spy.parses
        watcher.requestResolution("member")
        try await wait { spy.parses == before + 1 }
    }

    func testAReplacedFileIsReverified() async throws {
        for agent in Agent.allCases {
            let (_, file, _, spy, _, watcher) = try fixture(agent: agent, complete: true)
            let task = try await start(watcher)
            let old = try FileSignature(file)
            try write(file, agent: agent, id: "other", atomic: true)
            XCTAssertNotEqual(try FileSignature(file).fileNumber, old.fileNumber)
            watcher.reconcileEnrichment()
            try await wait { watcher.resolution(for: "member") == .mismatch }
            XCTAssertEqual(spy.parses, 0); XCTAssertEqual(spy.verifications, 2)
            task.cancel(); watcher.stop()
        }
    }

    func testTruncationThenRegrowthReverifies() async throws {
        let (_, file, _, spy, _, watcher) = try fixture(complete: true)
        let task = try await start(watcher); defer { task.cancel(); watcher.stop() }
        let inode = try FileSignature(file).fileNumber
        try Data().write(to: file)
        watcher.reconcileEnrichment()
        try await wait { watcher.resolution(for: "member") == .incomplete }
        XCTAssertEqual(spy.verifications, 2)
        try write(file, id: "other")
        XCTAssertEqual(try FileSignature(file).fileNumber, inode)
        watcher.reconcileEnrichment()
        try await wait { watcher.resolution(for: "member") == .mismatch }
        XCTAssertEqual(spy.verifications, 3)
    }

    func testMismatchAndUnreadableNeverBecomeAbsent() async throws {
        let (root, file, _, spy, _, watcher) = try fixture(complete: true)
        spy.failVerification = true
        let task = try await start(watcher); defer { task.cancel(); watcher.stop() }
        XCTAssertEqual(watcher.resolution(for: "member"), .unreadable)
        watcher.reconcileEvent(path: root.path, flags: UInt32(kFSEventStreamEventFlagKernelDropped))
        try await wait { spy.verifications >= 2 }
        XCTAssertEqual(watcher.resolution(for: "member"), .unreadable)
        spy.failVerification = false
        try write(file, id: "wrong", atomic: true)
        watcher.reconcileEnrichment()
        try await wait { watcher.resolution(for: "member") == .mismatch }
        watcher.requestResolution("member")
        try await wait { spy.verifications >= 4 }
        XCTAssertEqual(watcher.resolution(for: "member"), .mismatch)
    }

    func testCoverageResetRearmsEnrichment() async throws {
        let (root, file, _, spy, _, watcher) = try fixture()
        watcher.setEnrichmentWanted(["member": [.title]])
        let task = try await start(watcher); defer { task.cancel(); watcher.stop() }
        try append(file)
        watcher.reconcileEnrichment()
        let before = spy.parses
        watcher.reconcileEvent(path: root.path, flags: UInt32(kFSEventStreamEventFlagKernelDropped))
        try await wait { spy.parses == before + 1 }
        XCTAssertEqual(spy.verifications, 1, "Coverage resets enrichment without invalidating a stable identity")
    }

    func testAPartialFillResolvesADeferredSignatureWithoutAnotherWrite() async throws {
        let (_, file, db, spy, clock, watcher) = try fixture()
        watcher.setEnrichmentWanted(["member": [.directory, .title]])
        let task = try await start(watcher); defer { task.cancel(); watcher.stop() }
        clock.advance(0.1)
        try append(file, "{\"type\":\"user\",\"sessionId\":\"member\",\"message\":{\"content\":\"Soon\"}}\n")
        let observations = watcher.metrics.observations
        watcher.reconcileEnrichment()
        try await wait { watcher.metrics.observations > observations }
        XCTAssertEqual(spy.parses, 1, "Changed signature is deferred behind the first deadline")
        _ = try db.fillCoreFields(sessionID: "member", directory: "/work")
        watcher.setEnrichmentWanted(["member": [.title]])
        // No clock advance, reconciliation or further write: the fill must re-arm work.
        try await wait { watcher.publishedSnapshot?.summaries["member"]?.firstPrompt == "Soon" }
        XCTAssertEqual(spy.parses, 2)
        let summary = try XCTUnwrap(watcher.publishedSnapshot?.summaries["member"])
        _ = try db.fillCoreFields(sessionID: "member", title: summary.firstPrompt)
        XCTAssertEqual(try db.sessionState("member")?.title, "Soon")
    }

    func testRapidReplacementsPreserveTheMembersParseBackoff() async throws {
        let (_, file, _, spy, clock, watcher) = try fixture()
        watcher.setEnrichmentWanted(["member": [.title]])
        let task = try await start(watcher); defer { task.cancel(); watcher.stop() }
        for _ in 0..<240 {
            clock.advance(0.25)
            let verifications = spy.verifications
            try write(file, atomic: true)
            watcher.reconcileEnrichment()
            try await wait { spy.verifications > verifications }
        }
        XCTAssertEqual(spy.parses, 6, "Replacements verify immediately but parse only at 0,1,3,7,15,31")
        XCTAssertGreaterThanOrEqual(spy.verifications, 241)
    }

    func testRepeatedAfterParseRacesStillChargeTheMembersBackoff() async throws {
        let (_, file, _, spy, clock, watcher) = try fixture()
        spy.afterParse = {
            let handle = try! FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try! handle.seekToEnd()
            try! handle.write(contentsOf: Data("{}\n".utf8))
        }
        watcher.setEnrichmentWanted(["member": [.title]])
        let task = try await start(watcher); defer { task.cancel(); watcher.stop() }
        for _ in 0..<240 {
            clock.advance(0.25)
            try append(file)
            let observations = watcher.metrics.observations
            watcher.reconcileEnrichment()
            try await wait { watcher.metrics.observations > observations }
        }
        XCTAssertEqual(spy.parses, 6, "Every discarded parse consumes a backoff interval")
        XCTAssertNil(watcher.publishedSnapshot?.summaries["member"], "Racing results must never escape")
    }

    func testAnIdentityReadRacingAReplacementNeverPublishesLoaded() async throws {
        let (_, file, _, spy, _, watcher) = try fixture(complete: true)
        spy.afterVerification = {
            try? Data("{\"type\":\"system\",\"sessionId\":\"wrong\"}".utf8).write(to: file, options: .atomic)
        }
        let stream = watcher.start()
        var states: [MemberResolution] = []
        let task = Task { for await snapshot in stream { if let state = snapshot.resolutions["member"] { states.append(state) } } }
        defer { task.cancel(); watcher.stop() }
        try await wait { watcher.resolution(for: "member") == .mismatch }
        XCTAssertFalse(states.contains(.loaded(file)))
        XCTAssertEqual(spy.parses, 0)
        XCTAssertGreaterThanOrEqual(spy.verifications, 2)
    }

    func testCodexSharedHistoryChangesDoNotPublishForACompleteMember() async throws {
        let (root, _, _, spy, _, watcher) = try fixture(agent: .codex, complete: true)
        let task = try await start(watcher); defer { task.cancel(); watcher.stop() }
        let before = watcher.metrics.publications
        let history = root.appendingPathComponent("history.jsonl")
        try Data("{\"session_id\":\"member\",\"text\":\"A late history prompt\"}".utf8).write(to: history)
        watcher.reconcileEvent(path: history.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        watcher.reconcileEnrichment()
        try await wait { watcher.metrics.observations >= 2 }
        XCTAssertEqual(spy.parses, 0)
        XCTAssertEqual(watcher.metrics.publications, before)
    }

    func testClaudeVerifiesTheFirstTypedLineCarryingAnID() async throws {
        let (_, file, _, _, _, watcher) = try fixture(complete: true)
        try "{\"sessionId\":\"untyped\"}\n{\"type\":\"summary\"}\n{\"type\":\"user\",\"sessionId\":\"member\"}\n{\"type\":\"user\",\"sessionId\":\"other\"}".write(to: file, atomically: false, encoding: .utf8)
        let task = try await start(watcher); defer { task.cancel(); watcher.stop() }
        XCTAssertEqual(watcher.resolution(for: "member"), .loaded(file))
    }
}

private final class P5Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_700_000_000)
    var date: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private final class P5SpyStore: IncrementalSessionStore, @unchecked Sendable {
    private let inner: any IncrementalSessionStore
    private let lock = NSLock()
    private var parseCount = 0
    private var verifyCount = 0
    private var failure = false
    var afterParse: (@Sendable () -> Void)?
    var afterVerification: (@Sendable () -> Void)?
    init(_ inner: any IncrementalSessionStore) { self.inner = inner }
    var parses: Int { lock.lock(); defer { lock.unlock() }; return parseCount }
    var verifications: Int { lock.lock(); defer { lock.unlock() }; return verifyCount }
    var failVerification: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failure }
        set { lock.lock(); failure = newValue; lock.unlock() }
    }
    var agent: Agent { inner.agent }
    var watchedURLs: [URL] { inner.watchedURLs }
    func loadSummaries() -> [TranscriptSummary] { XCTFail("No full-store parse"); return [] }
    func loadSummary(at fileURL: URL) -> TranscriptSummary? {
        lock.lock(); parseCount += 1; lock.unlock()
        let summary = inner.loadSummary(at: fileURL)
        afterParse?()
        return summary
    }
    func verifyIdentity(at url: URL, expectedID: String) throws -> TranscriptVerification {
        lock.lock(); verifyCount += 1; lock.unlock()
        if failVerification { throw CocoaError(.fileReadNoPermission) }
        let verdict = try inner.verifyIdentity(at: url, expectedID: expectedID)
        let callback = afterVerification; afterVerification = nil; callback?()
        return verdict
    }
    func sessionFileURLs() -> [URL] { inner.sessionFileURLs() }
    func enumerateSessionFiles() throws -> [URL] { try inner.enumerateSessionFiles() }
    func enumerateSessionFiles(in subtree: URL) throws -> [URL] { try inner.enumerateSessionFiles(in: subtree) }
    func filenameID(at url: URL) -> String? { inner.filenameID(at: url) }
    func rolloutSelectionKey(at url: URL) -> String? { inner.rolloutSelectionKey(at: url) }
    func acceptsTranscript(_ url: URL) -> Bool { inner.acceptsTranscript(url) }
}
