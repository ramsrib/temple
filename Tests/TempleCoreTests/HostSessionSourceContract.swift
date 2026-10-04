import XCTest
import CoreServices
@testable import TempleCore
import TempleTestSupport

/// A host under test, with the means to change what is on it.
protocol SourceFixture: AnyObject {
    var source: any HostSessionSource { get }
    /// Signatures carry a file identity (an inode).
    var hasInodes: Bool { get }
    var canBreakTransport: Bool { get }
    /// Listings one `locate` costs while the source observes (local: none,
    /// the filename map is current; a remote: one `find` per round trip).
    var listingsPerLocate: Int { get }
    @discardableResult func put(agent: Agent, name: String, data: Data) throws -> TranscriptLocator
    func append(_ locator: TranscriptLocator, _ data: Data) throws
    /// A new file at the same path (a new identity where the host has them).
    func replace(_ locator: TranscriptLocator, _ data: Data) throws
    func truncate(_ locator: TranscriptLocator, to size: Int) throws
    func remove(_ locator: TranscriptLocator) throws
    func makeUnreadable(_ locator: TranscriptLocator) throws
    /// Same bytes count, written in place, with a later modification time.
    func rewriteSameSize(_ locator: TranscriptLocator) throws
    /// A path the agent's store would use for `name`, without creating it.
    func path(agent: Agent, name: String) -> String
    func breakListing(_ agent: Agent) throws
    func breakTransport() throws
    func dropEvents() throws
    func setCodexHistory(_ data: Data) throws
    func existingDirectory() throws -> String
    func missingDirectory() -> String
    func unsearchableDirectory() throws -> String
    var parses: Int { get }
    var listings: Int { get }
    var widerReads: Int { get }
    func cleanup()
}

/// What every `HostSessionSource` must do (Track B plan §6), for any host.
/// Subclasses supply a fixture; this class itself runs nothing.
class HostSessionSourceContract: XCTestCase {
    func makeFixture() throws -> SourceFixture { throw XCTSkip("abstract contract") }

    private var fixture: SourceFixture!
    private var observers: [Task<Void, Never>] = []
    private var events = EventLog()
    var source: any HostSessionSource { fixture.source }

    override func setUpWithError() throws {
        fixture = try makeFixture()
    }

    override func tearDown() {
        observers.forEach { $0.cancel() }
        observers.removeAll()
        fixture?.cleanup()
        fixture = nil
        super.tearDown()
    }

    // MARK: Content

    static let created = Date(timeIntervalSince1970: 1_790_848_800) // 2026-10-01T10:00:00Z
    private static let stamp = "2026-10-01T10-00-00"

    func uuid() -> String { UUID().uuidString.lowercased() }

    func claudeData(_ id: String, cwd: String = "/work/project", prompt: String? = "First prompt", tailPrompt: String? = nil) -> Data {
        var lines = [#"{"type":"system","sessionId":"\#(id)","cwd":"\#(cwd)","timestamp":"2026-10-01T10:00:00Z"}"#]
        if let prompt { lines.append(#"{"type":"user","sessionId":"\#(id)","message":{"content":"\#(prompt)"}}"#) }
        if let tailPrompt {
            let filler = String(repeating: "f", count: 1000)
            lines += Array(repeating: #"{"type":"assistant","sessionId":"\#(id)","message":{"content":"\#(filler)"}}"#, count: 140)
            lines.append(#"{"type":"user","sessionId":"\#(id)","message":{"content":"\#(tailPrompt)"}}"#)
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    func codexData(_ id: String, cwd: String = "/work/project", prompt: String? = "First prompt", tailPrompt: String? = nil,
                   created: Date = HostSessionSourceContract.created, subagent: Bool = false) -> Data {
        let timestamp = ISO8601DateFormatter().string(from: created)
        let extra = subagent ? #","thread_source":"subagent""# : ""
        var lines = [#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","timestamp":"\#(timestamp)"\#(extra)}}"#]
        if let prompt { lines.append(#"{"type":"event_msg","payload":{"type":"user_message","message":"\#(prompt)"}}"#) }
        if let tailPrompt {
            lines.append(#"{"type":"response_item","payload":{"role":"user","content":"\#(String(repeating: "x", count: 1_100_000))"}}"#)
            lines.append(#"{"type":"event_msg","payload":{"type":"user_message","message":"\#(tailPrompt)"}}"#)
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    func rolloutName(_ thread: String, stamp: String = HostSessionSourceContract.stamp, rollout: String? = nil) -> String {
        "rollout-\(stamp)-\(thread)\(rollout.map { "_" + $0 } ?? "").jsonl"
    }

    @discardableResult
    func plantClaude(_ id: String, prompt: String? = "First prompt", tailPrompt: String? = nil) throws -> TranscriptLocator {
        try fixture.put(agent: .claude, name: "\(id).jsonl", data: claudeData(id, prompt: prompt, tailPrompt: tailPrompt))
    }

    @discardableResult
    func plantCodex(_ id: String, name: String? = nil, cwd: String = "/work/project", prompt: String? = "First prompt",
                    tailPrompt: String? = nil, subagent: Bool = false) throws -> TranscriptLocator {
        try fixture.put(agent: .codex, name: name ?? rolloutName(id),
                        data: codexData(id, cwd: cwd, prompt: prompt, tailPrompt: tailPrompt, subagent: subagent))
    }

    // MARK: Observation

    /// Consume `changes()` for the rest of the test, as an engine would.
    func observe() async throws {
        let stream = source.changes()
        let log = events
        observers.append(Task {
            do { for try await change in stream { log.append(change) } } catch {}
        })
        try await waitUntil { (self.source as? any HostSourceDiagnostics)?.isMonitoring ?? true }
    }

    func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForEvent(_ match: @escaping (SourceChange) -> Bool) async throws -> SourceChange? {
        try await waitUntil { self.events.all.contains(where: match) }
        return events.all.first(where: match)
    }

    func locate(_ requests: [LocateRequest]) async throws -> LocateResult { try await source.locate(requests) }

    // MARK: 1–4 locate

    func test01NoTranscriptMeansNoCandidateAndACompleteListing() async throws {
        let result = try await locate([LocateRequest(id: uuid(), agent: .claude), LocateRequest(id: uuid())])
        XCTAssertTrue(result.candidates.values.allSatisfy(\.isEmpty))
        XCTAssertEqual(result.complete, [.claude, .codex])
    }

    func test02AFailedListingLeavesOnlyThatAgentIncompleteAndTransportFailuresThrow() async throws {
        let id = uuid()
        try plantClaude(id)
        try fixture.breakListing(.codex)
        let result = try await locate([LocateRequest(id: id, refresh: true)])
        XCTAssertEqual(result.complete, [.claude])
        XCTAssertEqual(result.candidates[id]?.map(\.agent), [.claude])
        guard fixture.canBreakTransport else { return }
        try fixture.breakTransport()
        do {
            _ = try await locate([LocateRequest(id: id)])
            XCTFail("a transport failure is thrown, not reported as an empty listing")
        } catch let error as LocateError {
            guard case .transport = error else { return XCTFail("\(error)") }
        }
    }

    func test03CodexRolesSelectTheNewestRevertAndKeepOlderRolloutsBehindIt() async throws {
        let thread = uuid(), revertID = uuid(), other = uuid()
        let canonical = try plantCodex(thread, name: rolloutName(thread, stamp: "2026-10-01T09-00-00"))
        let revert = try plantCodex(thread, name: rolloutName(thread, stamp: "2026-10-01T10-00-00", rollout: revertID))
        let foreign = try plantCodex(thread, name: rolloutName(other, stamp: "2026-10-01T08-00-00"))
        func roles(_ hint: TranscriptLocator?) async throws -> [(String, CandidateRole)] {
            let result = try await locate([LocateRequest(id: thread, agent: .codex, hint: hint, refresh: true)])
            return (result.candidates[thread] ?? []).map { ($0.locator.path, $0.role) }
        }
        let plain = try await roles(nil)
        XCTAssertEqual(plain.map(\.0), [revert.path, canonical.path])
        XCTAssertEqual(plain.map(\.1), [.selected, .alternate])
        let hinted = try await roles(foreign)
        XCTAssertEqual(hinted.map(\.0), [revert.path, foreign.path, canonical.path])
        XCTAssertEqual(hinted.map(\.1), [.selected, .hinted, .alternate])
        let olderHint = try await roles(canonical)
        XCTAssertEqual(olderHint.map(\.0), plain.map(\.0), "an older canonical hint is not a separate candidate")
        XCTAssertEqual(olderHint.map(\.1), plain.map(\.1))
    }

    func test04AHintWhoseFileIsGoneIsNoCandidateAndWalksNothing() async throws {
        let id = uuid(), lost = uuid()
        let file = try plantClaude(id)
        try await observe()
        let gone = TranscriptLocator(host: source.host, path: fixture.path(agent: .claude, name: "\(uuid()).jsonl"))
        let before = fixture.listings
        let result = try await locate([LocateRequest(id: id, agent: .claude, hint: gone), LocateRequest(id: lost, agent: .claude, hint: gone)])
        XCTAssertEqual(result.candidates[id]?.map(\.locator), [file])
        XCTAssertEqual(result.candidates[lost]?.count, 0)
        XCTAssertEqual(fixture.listings, before + fixture.listingsPerLocate, "a missing hint never forces a walk (A4)")
    }

    // MARK: 5–7 read

    func test05IdentityReadsCarryNoFactsAndStayBounded() async throws {
        let claudeID = uuid(), codexID = uuid()
        let claude = try plantClaude(claudeID)
        let codex = try plantCodex(codexID)
        for (locator, agent, id) in [(claude, Agent.claude, claudeID), (codex, .codex, codexID)] {
            let verified = try await source.read(locator, agent: agent, expecting: id, facts: false)
            XCTAssertEqual(verified.identity, .verified)
            XCTAssertNil(verified.summary)
            let other = try await source.read(locator, agent: agent, expecting: uuid(), facts: false)
            XCTAssertEqual(other.identity, .mismatch)
        }
        // Ten megabytes with no identity in them: incomplete, and read only as far as the cap.
        let line = Data((#"{"note":"\#(String(repeating: "y", count: 500))"}"# + "\n").utf8)
        let huge = Data((0..<(10 * 1024 * 1024 / line.count)).map { _ in line }.joined())
        let bigClaude = try fixture.put(agent: .claude, name: "\(uuid()).jsonl", data: huge)
        let bigCodex = try fixture.put(agent: .codex, name: rolloutName(uuid()), data: huge)
        let claudeRead = try await source.read(bigClaude, agent: .claude, expecting: claudeID, facts: false)
        XCTAssertEqual(claudeRead.identity, .incomplete)
        XCTAssertLessThanOrEqual(claudeRead.bytesRead, ClaudeFormat.identityScanBytes + 64 * 1024)
        let codexRead = try await source.read(bigCodex, agent: .codex, expecting: codexID, facts: true)
        XCTAssertEqual(codexRead.identity, .incomplete)
        XCTAssertNil(codexRead.summary, "facts only follow a verified identity")
        XCTAssertLessThanOrEqual(codexRead.bytesRead, CodexFormat.headerLineBytes)
    }

    func test06FactsAreWhatTheFileStatesAndATailPromptIsOnlyAHint() async throws {
        let full = uuid(), tail = uuid(), codexTail = uuid(), sub = uuid()
        let a = try plantClaude(full)
        let b = try plantClaude(tail, prompt: nil, tailPrompt: "A later turn")
        let c = try plantCodex(codexTail, prompt: nil, tailPrompt: "Late codex turn")
        let d = try plantCodex(sub, subagent: true)
        let facts = try await source.read(a, agent: .claude, expecting: full, facts: true).summary
        XCTAssertEqual(facts?.firstPrompt, "First prompt")
        XCTAssertEqual(facts?.cwd, "/work/project")
        XCTAssertEqual(facts?.id, full)
        let hinted = try await source.read(b, agent: .claude, expecting: tail, facts: true).summary
        XCTAssertNil(hinted?.firstPrompt)
        XCTAssertEqual(hinted?.laterPromptHint, "A later turn")
        let widerBefore = fixture.widerReads
        let codex = try await source.read(c, agent: .codex, expecting: codexTail, facts: true).summary
        XCTAssertNil(codex?.firstPrompt)
        XCTAssertEqual(codex?.laterPromptHint, "Late codex turn")
        XCTAssertEqual(codex?.selectionKey, rolloutName(codexTail).dropFirst(8).prefix(19) + "-" + codexTail)
        XCTAssertEqual(fixture.widerReads, widerBefore + 1, "exactly one wider read")
        let excluded = try await source.read(d, agent: .codex, expecting: sub, facts: true)
        XCTAssertEqual(excluded.identity, .verified, "identity is reported even when the facts are not a session")
        XCTAssertNil(excluded.summary)
    }

    func test07ReadFailuresAreTyped() async throws {
        let gone = uuid(), locked = uuid(), far = uuid()
        let a = try plantClaude(gone)
        let b = try plantClaude(locked)
        let c = try plantClaude(far)
        try fixture.remove(a)
        try fixture.makeUnreadable(b)
        await assertReadThrows(a, gone, .missing)
        do {
            _ = try await source.read(b, agent: .claude, expecting: locked, facts: false)
            XCTFail("expected unreadable")
        } catch let error as TranscriptReadError {
            guard case .unreadable = error else { return XCTFail("\(error)") }
        }
        guard fixture.canBreakTransport else { return }
        try fixture.breakTransport()
        do {
            _ = try await source.read(c, agent: .claude, expecting: far, facts: false)
            XCTFail("expected transport")
        } catch let error as TranscriptReadError {
            guard case .transport = error else { return XCTFail("\(error)") }
        }
    }

    private func assertReadThrows(_ locator: TranscriptLocator, _ id: String, _ expected: TranscriptReadError,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await source.read(locator, agent: .claude, expecting: id, facts: false)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TranscriptReadError, expected, file: file, line: line)
        }
    }

    // MARK: 8 signatures

    func test08SignaturesMoveTheWayTheFileDid() async throws {
        let id = uuid()
        let file = try plantClaude(id)
        func signature() async throws -> TranscriptSignature {
            let read = try await source.read(file, agent: .claude, expecting: id, facts: false).signature
            let result = try await locate([LocateRequest(id: id, agent: .claude, refresh: true)])
            XCTAssertEqual(result.candidates[id]?.first?.stat, .present(read), "locate and read agree")
            return read
        }
        let first = try await signature()
        let again = try await signature()
        XCTAssertEqual(again, first, "unchanged")
        try fixture.append(file, Data("\n{\"type\":\"assistant\"}".utf8))
        let appended = try await signature()
        XCTAssertGreaterThan(appended.size, first.size)
        try fixture.replace(file, claudeData(id, prompt: "Replaced prompt here"))
        let replaced = try await signature()
        XCTAssertTrue(replaced.identity != appended.identity || replaced.size != appended.size)
        if fixture.hasInodes { XCTAssertNotEqual(replaced.identity, appended.identity) }
        try fixture.truncate(file, to: 40)
        let truncated = try await signature()
        XCTAssertLessThan(truncated.size, replaced.size)
        try fixture.rewriteSameSize(file)
        let rewritten = try await signature()
        XCTAssertEqual(rewritten.size, truncated.size)
        XCTAssertNotEqual(rewritten.modifiedAt, truncated.modifiedAt)
    }

    // MARK: 9–12 changes

    func test09EveryTranscriptWriteIsReportedWithoutParsing() async throws {
        try await observe()
        let parses = fixture.parses
        let id = uuid()
        let file = try plantClaude(id)
        let created = try await waitForEvent { change in
            if case .transcripts(_, let locators) = change { return locators.contains(file) }
            return false
        }
        guard case .transcripts(let ids, _)? = created else { return XCTFail() }
        XCTAssertTrue(ids.contains(id))
        try fixture.append(file, Data("\n{\"type\":\"assistant\"}".utf8))
        try await waitUntil { self.events.all.filter { if case .transcripts(_, let l) = $0 { return l.contains(file) }; return false }.count >= 2 }
        XCTAssertEqual(fixture.parses, parses, "observing never parses")
    }

    /// A primitive-only consumer registers nothing: what it observes must
    /// still reach the listing `locate` trusts, both ways.
    func test09bAnObservedFileIsLocatedWithoutARefreshAndItsRemovalToo() async throws {
        try await observe()
        let claudeID = uuid(), codexID = uuid()
        let claude = try plantClaude(claudeID)
        let codex = try plantCodex(codexID)
        for file in [claude, codex] {
            _ = try await waitForEvent { change in
                if case .transcripts(_, let locators) = change { return locators.contains(file) }
                return false
            }
        }
        let found = try await locate([LocateRequest(id: claudeID), LocateRequest(id: codexID)])
        XCTAssertEqual(found.complete, [.claude, .codex])
        XCTAssertEqual(found.candidates[claudeID]?.map(\.locator), [claude])
        XCTAssertEqual(found.candidates[codexID]?.map(\.locator), [codex])
        XCTAssertEqual(found.candidates[codexID]?.first?.role, .selected)
        guard case .present? = found.candidates[claudeID]?.first?.stat else { return XCTFail("not stat'ed") }
        let before = events.all.count
        try fixture.remove(claude)
        try await waitUntil { self.events.all.dropFirst(before).contains { change in
            if case .transcripts(_, let locators) = change { return locators.contains(claude) }
            return false
        } }
        let gone = try await locate([LocateRequest(id: claudeID)])
        XCTAssertEqual(gone.candidates[claudeID]?.count, 0, "a removed file leaves the listing")
        XCTAssertEqual(gone.complete, [.claude, .codex])
    }

    func test10ADroppedStreamResetsCoverageForward() async throws {
        try await observe()
        let before = try await locate([]).coverage
        try fixture.dropEvents()
        let reset = try await waitForEvent { if case .coverageReset = $0 { return true }; return false }
        guard case .coverageReset(let coverage)? = reset else { return XCTFail() }
        XCTAssertGreaterThan(coverage, before)
        let after = try await locate([]).coverage
        XCTAssertGreaterThanOrEqual(after, coverage)
    }

    func test11SharedInputChangesCarryARevisionAndTheNewTitle() async throws {
        let id = uuid()
        let file = try plantCodex(id)
        try await observe()
        _ = try await locate([LocateRequest(id: id)])
        try fixture.setCodexHistory(Data(#"{"session_id":"\#(id)","ts":1,"text":"Shared title"}"#.utf8))
        let changed = try await waitForEvent { if case .sharedFacts(.codex, _) = $0 { return true }; return false }
        guard case .sharedFacts(_, let revision)? = changed else { return XCTFail() }
        let located = try await locate([LocateRequest(id: id)])
        XCTAssertEqual(located.sharedRevision[.codex], revision)
        let read = try await source.read(file, agent: .codex, expecting: id, facts: true)
        XCTAssertEqual(read.summary?.historyPrompt, "Shared title")
        XCTAssertEqual(read.summary?.titleFact, "Shared title")
        XCTAssertEqual(read.sharedRevision, revision)
    }

    func test12EndingTheConsumerStopsObservationAndANewOneRearms() async throws {
        guard let diagnostics = source as? any HostSourceDiagnostics else { throw XCTSkip("no diagnostics") }
        try await observe()
        XCTAssertTrue(diagnostics.isMonitoring)
        observers.forEach { $0.cancel() }
        observers.removeAll()
        try await waitUntil { !diagnostics.isMonitoring }
        try await observe()
        XCTAssertTrue(diagnostics.isMonitoring)
    }

    // MARK: 13 catalog

    func test13TheCatalogStreamsNewestFirstInBatchesAndReportsFailuresPerAgent() async throws {
        let ids = (0..<3).map { _ in uuid() }
        for id in ids { try plantClaude(id) }
        let codexID = uuid()
        try plantCodex(codexID)
        var events: [CatalogBatch] = []
        for try await batch in source.catalog(CatalogQuery(agents: [.claude], newestFirst: true, batchSize: 2)) { events.append(batch) }
        XCTAssertEqual(events.first, .listed(total: 3))
        let batches = events.compactMap { batch -> [String]? in
            if case .sessions(let summaries, _, _) = batch { return summaries.map(\.id) }
            return nil
        }
        XCTAssertEqual(batches, [[ids[2], ids[1]], [ids[0]]])
        try fixture.breakListing(.codex)
        var mixed: [CatalogBatch] = []
        for try await batch in source.catalog(CatalogQuery()) { mixed.append(batch) }
        XCTAssertTrue(mixed.contains { if case .storeFailed(.codex?, _) = $0 { return true }; return false })
        XCTAssertEqual(Set(mixed.flatMap { batch -> [String] in
            if case .sessions(let summaries, _, _) = batch { return summaries.map(\.id) }
            return []
        }), Set(ids))
    }

    func test13bCatalogSummariesCarryTheirSelectionKey() async throws {
        let codexID = uuid()
        try plantCodex(codexID)
        var keys: [String?] = []
        for try await batch in source.catalog(CatalogQuery(agents: [.codex])) {
            if case .sessions(let summaries, _, _) = batch { keys += summaries.map(\.selectionKey) }
        }
        XCTAssertEqual(keys, ["2026-10-01T10-00-00-\(codexID)"])
    }

    // MARK: 14 adoption

    func test14AdoptionNeedsExactlyOneEligibleHeader() async throws {
        let request = AdoptionRequest(directory: "/adopt", startedAt: Self.created, window: 60)
        let none = try await source.adopt(request)
        XCTAssertEqual(none, AdoptionResult.none)
        let first = uuid()
        let file = try plantCodex(first, cwd: "/adopt")
        try plantCodex(uuid(), cwd: "/elsewhere")
        let adopted = try await source.adopt(request)
        XCTAssertEqual(adopted, .adopted(id: first, locator: file))
        try plantCodex(uuid(), cwd: "/adopt")
        let ambiguous = try await source.adopt(request)
        XCTAssertEqual(ambiguous, .ambiguous)
        try fixture.breakListing(.codex)
        let incomplete = try await source.adopt(AdoptionRequest(directory: "/other", startedAt: Self.created, window: 60))
        XCTAssertEqual(incomplete, .incomplete)
    }

    // MARK: 15 directories

    func test15DirectoryEvidenceIsExistsMissingOrUnknown() async throws {
        let exists = try fixture.existingDirectory()
        let unsearchable = try fixture.unsearchableDirectory()
        let present: DirectoryEvidence = await source.directoryEvidence(exists)
        let missing: DirectoryEvidence = await source.directoryEvidence(fixture.missingDirectory())
        let unknown: DirectoryEvidence = await source.directoryEvidence(unsearchable)
        XCTAssertEqual(present, .exists)
        XCTAssertEqual(missing, .missing)
        XCTAssertEqual(unknown, .unknown, "an unreadable parent proves nothing")
    }

    // MARK: 16–17

    func test16EveryLocatorNamesTheSourcesHost() async throws {
        let claudeID = uuid(), codexID = uuid()
        try plantClaude(claudeID)
        try plantCodex(codexID, cwd: "/adopt")
        try await observe()
        let result = try await locate([LocateRequest(id: claudeID, refresh: true), LocateRequest(id: codexID)])
        let located = result.candidates.values.flatMap { $0.map(\.locator) }
        XCTAssertEqual(located.count, 2)
        var all = located
        for candidate in result.candidates.values.flatMap({ $0 }) {
            let id = candidate.agent == .claude ? claudeID : codexID
            if let summary = try await source.read(candidate.locator, agent: candidate.agent, expecting: id, facts: true).summary {
                all.append(summary.locator)
            }
        }
        for try await batch in source.catalog(CatalogQuery()) {
            if case .sessions(let summaries, _, _) = batch { all += summaries.map(\.locator) }
        }
        if case .adopted(_, let locator) = try await source.adopt(AdoptionRequest(directory: "/adopt", startedAt: Self.created, window: 60)) {
            all.append(locator)
        }
        XCTAssertGreaterThan(all.count, 4)
        XCTAssertTrue(all.allSatisfy { $0.host == source.host })
    }

    func test17ConcurrentLocatesAndReadsComplete() async throws {
        let ids = (0..<8).map { _ in uuid() }
        var files: [TranscriptLocator] = []
        for id in ids { files.append(try plantClaude(id)) }
        let source = self.source
        let verdicts = try await withThrowingTaskGroup(of: TranscriptVerification?.self) { group in
            for _ in 0..<2 { group.addTask { _ = try await source.locate(ids.map { LocateRequest(id: $0, refresh: true) }); return nil } }
            for (id, file) in zip(ids, files) {
                group.addTask { try await source.read(file, agent: .claude, expecting: id, facts: true).identity }
            }
            var results: [TranscriptVerification] = []
            for try await verdict in group { if let verdict { results.append(verdict) } }
            return results
        }
        XCTAssertEqual(verdicts, Array(repeating: .verified, count: 8))
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [SourceChange] = []
    func append(_ change: SourceChange) { lock.lock(); changes.append(change); lock.unlock() }
    var all: [SourceChange] { lock.lock(); defer { lock.unlock() }; return changes }
}

// MARK: - The local host

final class LocalSourceContractTests: HostSessionSourceContract {
    override func makeFixture() throws -> SourceFixture { try LocalFixture() }

    // Local-only behaviour that predates the contract.

    func testLocalAdoptionCancellationReleasesItsObservationWindow() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/temple-p6-adopt-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.01)
        let task = Task { try await source.adopt(AdoptionRequest(directory: "/project", startedAt: Date(), window: 60)) }
        let deadline = Date().addingTimeInterval(2)
        while !source.isMonitoring, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        _ = try? await task.value
        let stopped = Date().addingTimeInterval(2)
        while source.isMonitoring, Date() < stopped { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(source.isMonitoring)
    }

    func testChangesNameOnlyTheAffectedRegisteredSession() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/temple-p6-changes-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["one", "two"] {
            try "{\"type\":\"user\",\"sessionId\":\"\(id)\"}".write(to: project.appendingPathComponent("\(id).jsonl"), atomically: false, encoding: .utf8)
        }
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.01)
        let changes = source.changes()
        defer { source.release(["one", "two"]) }
        let changed = expectation(description: "semantic invalidation")
        let reader = Task { () throws -> [String] in
            for try await change in changes {
                if case .sessions(let ids) = change { changed.fulfill(); return ids }
            }
            return []
        }
        _ = try await source.resolve([ResolutionRequest(id: "one"), ResolutionRequest(id: "two")])
        let file = project.appendingPathComponent("one.jsonl")
        try FileManager.default.removeItem(at: file)
        source.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved))
        await fulfillment(of: [changed], timeout: 3)
        reader.cancel()
        let ids = try await reader.value
        XCTAssertEqual(ids, ["one"])
    }
}

private final class LocalFixture: SourceFixture {
    let root = URL(fileURLWithPath: "/private/tmp/temple-contract-\(UUID().uuidString)")
    private let local: LocalSessionSource
    var source: any HostSessionSource { local }
    let hasInodes = true
    let canBreakTransport = false
    let listingsPerLocate = 0
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var locked: [URL] = []
    private var claudeRoot: URL { root.appendingPathComponent("claude") }
    private var codexRoot: URL { root.appendingPathComponent("codex") }

    init() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("claude/-work-project"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("codex/sessions/2026/10/01"), withIntermediateDirectories: true)
        local = LocalSessionSource(stores: [ClaudeSessionStore(root: root.appendingPathComponent("claude")),
                                            CodexSessionStore(root: root.appendingPathComponent("codex"))],
                                   debounceInterval: 0.01)
    }

    func path(agent: Agent, name: String) -> String {
        agent == .claude ? claudeRoot.appendingPathComponent("-work-project/\(name)").path
            : codexRoot.appendingPathComponent("sessions/2026/10/01/\(name)").path
    }

    private func touched(_ path: String, removed: Bool = false) throws {
        if !removed {
            clock = clock.addingTimeInterval(1)
            try FileManager.default.setAttributes([.modificationDate: clock], ofItemAtPath: path)
        }
        let flags = removed ? kFSEventStreamEventFlagItemRemoved : (kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemCreated)
        local.reconcileEvent(path: path, flags: UInt32(flags | kFSEventStreamEventFlagItemIsFile))
    }

    func put(agent: Agent, name: String, data: Data) throws -> TranscriptLocator {
        let path = path(agent: agent, name: name)
        try data.write(to: URL(fileURLWithPath: path))
        try touched(path)
        return TranscriptLocator(host: .local, path: path)
    }
    func append(_ locator: TranscriptLocator, _ data: Data) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: locator.path))
        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
        try touched(locator.path)
    }
    func replace(_ locator: TranscriptLocator, _ data: Data) throws {
        try data.write(to: URL(fileURLWithPath: locator.path), options: .atomic)
        try touched(locator.path)
    }
    func truncate(_ locator: TranscriptLocator, to size: Int) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: locator.path))
        try handle.truncate(atOffset: UInt64(size)); try handle.close()
        try touched(locator.path)
    }
    func remove(_ locator: TranscriptLocator) throws {
        try FileManager.default.removeItem(atPath: locator.path)
        try touched(locator.path, removed: true)
    }
    func makeUnreadable(_ locator: TranscriptLocator) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locator.path)
        locked.append(URL(fileURLWithPath: locator.path))
    }
    func rewriteSameSize(_ locator: TranscriptLocator) throws {
        let url = URL(fileURLWithPath: locator.path)
        let data = try Data(contentsOf: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: data); try handle.close()
        clock = clock.addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: clock], ofItemAtPath: locator.path)
        local.reconcileEvent(path: locator.path, flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile))
    }
    func breakListing(_ agent: Agent) throws {
        let directory = agent == .claude ? claudeRoot : codexRoot.appendingPathComponent("sessions")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        locked.append(directory)
    }
    func breakTransport() throws { throw XCTSkip("a local host has no transport") }
    func dropEvents() throws { local.reconcileEvent(path: root.path, flags: UInt32(kFSEventStreamEventFlagKernelDropped)) }
    func setCodexHistory(_ data: Data) throws {
        let path = codexRoot.appendingPathComponent("history.jsonl").path
        try data.write(to: URL(fileURLWithPath: path))
        clock = clock.addingTimeInterval(1)
        try FileManager.default.setAttributes([.modificationDate: clock], ofItemAtPath: path)
        local.reconcileEvent(path: path, flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile))
    }
    func existingDirectory() throws -> String {
        let url = root.appendingPathComponent("project-here")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
    func missingDirectory() -> String { root.appendingPathComponent("project-gone").path }
    func unsearchableDirectory() throws -> String {
        let parent = root.appendingPathComponent("sealed")
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("child"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        locked.append(parent)
        return parent.appendingPathComponent("child").path
    }
    var parses: Int { Int(local.metrics.parses) }
    var listings: Int { Int(local.metrics.enumerations) }
    var widerReads: Int { Int(local.metrics.widerReads) }
    func cleanup() {
        for url in locked { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - A remote-shaped host (TempleTestSupport.FakeHostSource)

final class FakeRemoteSourceContractTests: HostSessionSourceContract {
    override func makeFixture() throws -> SourceFixture { FakeFixture() }
}

private final class FakeFixture: SourceFixture {
    let fake = FakeHostSource(host: HostID(rawValue: "build-box"))
    var source: any HostSessionSource { fake }
    var hasInodes: Bool { fake.hasInodes }
    let canBreakTransport = true
    let listingsPerLocate = 1
    func path(agent: Agent, name: String) -> String {
        agent == .claude ? "/home/me/.agent-a/projects/-work-project/\(name)" : "/home/me/.agent-b/sessions/2026/10/01/\(name)"
    }
    func put(agent: Agent, name: String, data: Data) throws -> TranscriptLocator {
        fake.write(path(agent: agent, name: name), agent: agent, data: data)
    }
    func append(_ locator: TranscriptLocator, _ data: Data) throws { fake.append(locator.path, data) }
    func replace(_ locator: TranscriptLocator, _ data: Data) throws {
        let agent: Agent = locator.path.contains("/.agent-a/") ? .claude : .codex
        fake.write(locator.path, agent: agent, data: data)
    }
    func truncate(_ locator: TranscriptLocator, to size: Int) throws { fake.truncate(locator.path, to: size) }
    func remove(_ locator: TranscriptLocator) throws { fake.remove(locator.path) }
    func makeUnreadable(_ locator: TranscriptLocator) throws { fake.setUnreadable(locator.path) }
    func rewriteSameSize(_ locator: TranscriptLocator) throws { fake.append(locator.path, Data()) }
    func breakListing(_ agent: Agent) throws { fake.breakListing(agent) }
    func breakTransport() throws { fake.breakTransport() }
    func dropEvents() throws { fake.dropEvents() }
    func setCodexHistory(_ data: Data) throws { fake.setShared(.codex, CodexFormat.historyInput, data) }
    func existingDirectory() throws -> String { fake.addDirectory("/home/me/project"); return "/home/me/project" }
    func missingDirectory() -> String { "/home/me/gone" }
    func unsearchableDirectory() throws -> String { fake.makeUnsearchable("/home/sealed"); return "/home/sealed/child" }
    var parses: Int { fake.counters.parses }
    var listings: Int { fake.counters.listings }
    var widerReads: Int { fake.counters.widerReads }
    func cleanup() {}
}
