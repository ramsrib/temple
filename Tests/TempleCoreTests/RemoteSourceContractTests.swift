import XCTest
@testable import TempleCore
import TempleRemoteHost

/// The host seam's contract for a remote host (docs/designs/remote-ssh.md
/// section 11), run on `RemoteSessionSource` over `LocalShellExec`: the
/// locate and read scripts under this Mac's `/bin/sh` against a temp
/// `HOME`, with a stub `head` on the PATH for changes mid-read. Locate and
/// read meet the contract as any host does. Where v1 answers differently
/// on purpose (no live changes, no catalog, no adoption window, folder
/// evidence unknown, absence never proven, `complete` always empty), the
/// test is overridden here to assert the v1 answer.
final class RemoteSourceContractTests: HostSessionSourceContract {
    override func makeFixture() throws -> SourceFixture { try RemoteFixture() }

    private var remote: RemoteFixture { fixture as! RemoteFixture }

    // MARK: Listings are never complete

    override func test01NoTranscriptMeansNoCandidateAndACompleteListing() async throws {
        let result = try await locate([LocateRequest(id: uuid(), agent: .claude), LocateRequest(id: uuid())])
        XCTAssertTrue(result.candidates.values.allSatisfy(\.isEmpty))
        XCTAssertEqual(result.complete, [], "a find over ssh is never an audited listing")
    }

    override func test02AFailedListingLeavesOnlyThatAgentIncompleteAndTransportFailuresThrow() async throws {
        let id = uuid()
        try plantClaude(id)
        try fixture.breakListing(.codex)
        let result = try await locate([LocateRequest(id: id, refresh: true)])
        XCTAssertEqual(result.complete, [])
        XCTAssertEqual(result.candidates[id]?.map(\.agent), [.claude])
        try fixture.breakTransport()
        do {
            _ = try await locate([LocateRequest(id: id)])
            XCTFail("a transport failure is thrown, not reported as an empty listing")
        } catch let error as LocateError {
            guard case .transport = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: No live changes

    private func assertNoChanges(after write: () throws -> Void) async throws {
        let stream = source.changes()
        let log = EventLog()
        let reader = Task { do { for try await change in stream { log.append(change) } } catch {} }
        defer { reader.cancel() }
        try write()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(log.all, [], "a remote host reports no changes")
    }

    override func test09EveryTranscriptWriteIsReportedWithoutParsing() async throws {
        let parses = fixture.parses
        try await assertNoChanges { try plantClaude(uuid()) }
        XCTAssertEqual(fixture.parses, parses)
    }

    /// Every locate lists (there is no map to keep current), so a file is
    /// found, and its removal seen, without a refresh.
    override func test09bAnObservedFileIsLocatedWithoutARefreshAndItsRemovalToo() async throws {
        let claudeID = uuid(), codexID = uuid()
        let claude = try plantClaude(claudeID)
        let codex = try plantCodex(codexID)
        let found = try await locate([LocateRequest(id: claudeID), LocateRequest(id: codexID)])
        XCTAssertEqual(found.complete, [])
        XCTAssertEqual(found.candidates[claudeID]?.map(\.locator), [claude])
        XCTAssertEqual(found.candidates[codexID]?.map(\.locator), [codex])
        XCTAssertEqual(found.candidates[codexID]?.first?.role, .selected)
        guard case .present? = found.candidates[claudeID]?.first?.stat else { return XCTFail("not stat'ed") }
        try fixture.remove(claude)
        let gone = try await locate([LocateRequest(id: claudeID)])
        XCTAssertEqual(gone.candidates[claudeID]?.count, 0, "a removed file leaves the listing")
    }

    override func test10ADroppedStreamResetsCoverageForward() async throws {
        let before = try await locate([]).coverage
        try fixture.breakTransport()
        _ = try? await locate([])
        remote.mendTransport()
        let after = try await locate([]).coverage
        XCTAssertGreaterThan(after, before, "the first listing after a transport failure moves coverage")
    }

    /// No revision: every read takes the session's shared lines fresh.
    override func test11SharedInputChangesCarryARevisionAndTheNewTitle() async throws {
        let id = uuid()
        let file = try plantCodex(id)
        try await assertNoChanges {
            try fixture.setCodexHistory(Data(#"{"session_id":"\#(id)","ts":1,"text":"Shared title"}"#.utf8))
        }
        let located = try await locate([LocateRequest(id: id)])
        XCTAssertEqual(located.sharedRevision, [:])
        let read = try await source.read(file, agent: .codex, expecting: id, facts: true)
        XCTAssertEqual(read.summary?.historyPrompt, "Shared title")
        XCTAssertEqual(read.summary?.titleFact, "Shared title")
        XCTAssertNil(read.sharedRevision)
    }

    override func test12EndingTheConsumerStopsObservationAndANewOneRearms() async throws {
        XCTAssertNil(source as? any HostSourceDiagnostics, "nothing to monitor")
    }

    // MARK: No catalog

    private func assertNoCatalog() async throws {
        try plantClaude(uuid())
        var batches: [CatalogBatch] = []
        for try await batch in source.catalog(CatalogQuery()) { batches.append(batch) }
        XCTAssertEqual(batches.count, 1)
        guard case .storeFailed(nil, _)? = batches.first else { return XCTFail("\(batches)") }
        XCTAssertEqual(fixture.catalogParses, 0)
    }

    override func test13TheCatalogStreamsNewestFirstInBatchesAndReportsFailuresPerAgent() async throws { try await assertNoCatalog() }
    override func test13bCatalogSummariesCarryTheirSelectionKey() async throws { try await assertNoCatalog() }
    override func test13cTheCatalogShowsTheSelectedRolloutOrNothing() async throws { try await assertNoCatalog() }
    override func test13dTheCatalogListsAThreadOnlyFromAFileThatRecordsIt() async throws { try await assertNoCatalog() }
    override func test13eACompletedReadNamesTheAgentsItCovered() async throws { try await assertNoCatalog() }
    override func test13fAnUnchangedCatalogParsesNothingAndAChangeOnlyItsFile() async throws { try await assertNoCatalog() }
    override func test13gAKeptSummaryNeverOutlivesTheFileItWasReadFrom() async throws { try await assertNoCatalog() }
    override func test13hSharedTitlesAreAppliedFreshWithoutReparsing() async throws { try await assertNoCatalog() }
    override func test13iTheThreadsFileIsPickedBeforeAnythingKeptIsUsed() async throws { try await assertNoCatalog() }
    override func test13jCompletionNamesEveryCandidateWhateverItRead() async throws { try await assertNoCatalog() }
    override func test13kCandidatesAreComparedInTheAgentsOwnSpelling() async throws { try await assertNoCatalog() }

    // MARK: Absence is never proven

    private func assertUnproven() async throws {
        let id = uuid()
        for agent in Agent.allCases {
            let proof = await source.proveAbsent(ids: [id], agent: agent)
            XCTAssertEqual(proof, .unproven)
        }
        let listed = fixture.listings
        XCTAssertEqual(fixture.listings, listed, "and nothing is listed to try")
    }

    override func test18aAnExhaustiveQuiescentListingProvesWhatHasNoFile() async throws { try await assertUnproven() }
    override func test18bANonExhaustiveOrFailedListingProvesNothing() async throws { try await assertUnproven() }
    override func test18cOnlyAChangeThatCouldMatterDisturbsAProof() async throws { try await assertUnproven() }
    override func test18dACancelledProofProvesNothing() async throws { try await assertUnproven() }
    override func test18eATransportLostDuringAProofProvesNothing() async throws { try await assertUnproven() }

    // MARK: Adoption, folders, hosts

    /// Identity on a host is `RemoteSessions`' (its process tree, or the
    /// user's yes); the seam's window proves nothing.
    override func test14AdoptionNeedsExactlyOneEligibleHeader() async throws {
        try plantCodex(uuid(), cwd: "/adopt")
        let result = try await source.adopt(AdoptionRequest(directory: "/adopt", startedAt: Self.created, window: 60))
        XCTAssertEqual(result, .incomplete)
    }

    override func test15DirectoryEvidenceIsExistsMissingOrUnknown() async throws {
        let present = await source.directoryEvidence(try fixture.existingDirectory())
        let missing = await source.directoryEvidence(fixture.missingDirectory())
        XCTAssertEqual(present, .unknown)
        XCTAssertEqual(missing, .unknown, "never missing: a remote folder is never proven gone")
    }

    override func test16EveryLocatorNamesTheSourcesHost() async throws {
        let claudeID = uuid(), codexID = uuid()
        try plantClaude(claudeID)
        try plantCodex(codexID)
        let result = try await locate([LocateRequest(id: claudeID, refresh: true), LocateRequest(id: codexID)])
        var all = result.candidates.values.flatMap { $0.map(\.locator) }
        XCTAssertEqual(all.count, 2)
        for candidate in result.candidates.values.flatMap({ $0 }) {
            let id = candidate.agent == .claude ? claudeID : codexID
            if let summary = try await source.read(candidate.locator, agent: candidate.agent, expecting: id, facts: true).summary {
                all.append(summary.locator)
            }
        }
        XCTAssertEqual(all.count, 4)
        XCTAssertTrue(all.allSatisfy { $0.host == source.host })
    }
}

/// A stand-in host: a temp `HOME` with both stores, the scripts run by this
/// Mac's `/bin/sh`.
private final class RemoteFixture: SourceFixture {
    let root = URL(fileURLWithPath: "/private/tmp/temple-remote-contract-\(UUID().uuidString)")
    private let exec: BreakableExec
    private let remote: RemoteSessionSource
    var source: any HostSessionSource { remote }
    let hasInodes = true
    let canBreakTransport = true
    let listingsPerLocate = 1
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var locked: [String] = []
    private var home: String { root.path + "/home" }
    private var hook: String { root.path + "/hook" }

    init() throws {
        for directory in ["home/.claude/projects/-work-project", "home/.codex/sessions/2026/10/01", "home/tmp", "stubs"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        // `head` that runs the test's hook after reading, when one is set:
        // a change after the bytes and before the closing stat.
        let stub = root.appendingPathComponent("stubs/head")
        try "#!/bin/sh\n/usr/bin/head \"$@\"; s=$?\n[ -x \"$TEMPLE_CONTRACT_HOOK\" ] && \"$TEMPLE_CONTRACT_HOOK\" \"$@\"\nexit $s\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)
        let environment = ["HOME": root.path + "/home", "PATH": root.path + "/stubs:/usr/bin:/bin", "TMPDIR": root.path + "/home/tmp",
                           "SHELL": "/bin/sh", "LANG": "C", "TEMPLE_CONTRACT_HOOK": root.path + "/hook"]
        exec = BreakableExec(LocalShellExec(path: root.path + "/stubs:/usr/bin:/bin", environment: environment))
        let roots: [Agent: RemoteTranscriptRoot] = [.claude: RemoteTranscriptRoot(.unset, base: nil)!,
                                                     .codex: RemoteTranscriptRoot(.unset, base: nil)!]
        remote = RemoteSessionSource(host: HostID(rawValue: "contract-box"), provider: Provider(exec: exec, roots: roots))
    }

    func path(agent: Agent, name: String) -> String {
        agent == .claude ? home + "/.claude/projects/-work-project/\(name)" : home + "/.codex/sessions/2026/10/01/\(name)"
    }

    private func touched(_ path: String, by seconds: TimeInterval = 1) throws {
        clock = clock.addingTimeInterval(seconds)
        try FileManager.default.setAttributes([.modificationDate: clock], ofItemAtPath: path)
    }

    func put(agent: Agent, name: String, data: Data) throws -> TranscriptLocator {
        let path = path(agent: agent, name: name)
        try data.write(to: URL(fileURLWithPath: path))
        try touched(path)
        return TranscriptLocator(host: remote.host, path: path)
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
    func remove(_ locator: TranscriptLocator) throws { try FileManager.default.removeItem(atPath: locator.path) }
    func makeUnreadable(_ locator: TranscriptLocator) throws {
        chmod(locator.path, 0o000)
        locked.append(locator.path)
    }
    func rewriteSameSize(_ locator: TranscriptLocator) throws {
        let url = URL(fileURLWithPath: locator.path)
        let data = try Data(contentsOf: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: data); try handle.close()
        try touched(locator.path, by: 60)
    }
    func rewriteKeepingModificationTime(_ locator: TranscriptLocator, _ data: Data) throws {
        let modified = try FileManager.default.attributesOfItem(atPath: locator.path)[.modificationDate] as? Date
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: locator.path))
        try handle.write(contentsOf: data); try handle.truncate(atOffset: UInt64(data.count)); try handle.close()
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: locator.path) }
    }
    func breakListing(_ agent: Agent) throws {
        let directory = agent == .claude ? home + "/.claude/projects" : home + "/.codex/sessions"
        chmod(directory, 0o000)
        locked.append(directory)
    }
    func makeListingNotExhaustive(_ agent: Agent) throws {
        let directory = agent == .claude ? home + "/.claude/projects/.stash" : home + "/.codex/sessions/.stash"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
    func makeFolderInScope(_ agent: Agent) throws {
        let folder = agent == .claude ? home + "/.claude/projects/-new-\(UUID().uuidString)"
            : home + "/.codex/sessions/2026/10/\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }
    func holdNextProofListing() -> (reached: @Sendable () -> Bool, release: @Sendable () -> Void) { ({ true }, {}) }
    func duringNextProof(_ body: @escaping @Sendable () throws -> Void) {}

    /// The hook runs after `head` reads the file named last on its line.
    private func setHook(_ body: String) throws {
        try ("#!/bin/sh\nfor a; do f=$a; done\n" + body).write(toFile: hook, atomically: true, encoding: .utf8)
        chmod(hook, 0o755)
    }
    func replaceDuringNextRead(_ locator: TranscriptLocator, with data: Data) throws {
        let prepared = root.path + "/prepared"
        try data.write(to: URL(fileURLWithPath: prepared))
        try setHook("""
        [ "$f" = \(quote(locator.path)) ] && [ -e \(quote(prepared)) ] || exit 0
        mv -f \(quote(prepared)) "$f"; rm -f \(quote(hook))
        """)
    }
    func appendDuringEveryRead(_ locator: TranscriptLocator) throws {
        try setHook("""
        [ "$f" = \(quote(locator.path)) ] || exit 0
        printf '\\n{"type":"assistant"}' >> "$f"
        """)
    }
    private func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func breakTransport() throws { exec.broken = true }
    func mendTransport() { exec.broken = false }
    func dropEvents() throws { throw XCTSkip("a remote host reports no events") }
    func setCodexHistory(_ data: Data) throws {
        try data.write(to: URL(fileURLWithPath: home + "/.codex/history.jsonl"))
    }
    func existingDirectory() throws -> String {
        try FileManager.default.createDirectory(atPath: home + "/project-here", withIntermediateDirectories: true)
        return home + "/project-here"
    }
    func missingDirectory() -> String { home + "/project-gone" }
    func unsearchableDirectory() throws -> String { home + "/sealed/child" }
    var parses: Int { remote.counters.parses }
    var catalogParses: Int { 0 }
    var listings: Int { remote.counters.listings }
    var widerReads: Int { remote.counters.widerReads }
    func cleanup() {
        for path in locked { chmod(path, 0o700) }
        try? FileManager.default.removeItem(at: root)
    }

    final class BreakableExec: RemoteExec, @unchecked Sendable {
        private let lock = NSLock()
        private var _broken = false
        let inner: RemoteExec
        init(_ inner: RemoteExec) { self.inner = inner }
        var broken: Bool {
            get { lock.withLock { _broken } }
            set { lock.withLock { _broken = newValue } }
        }
        func run(script: String, args: [String], input: Data?, deadline: TimeInterval) async throws -> RemoteOutput {
            if broken {
                return RemoteOutput(status: 255, stdout: "", stderr: "ssh: connect to host contract-box port 22: Connection refused\n",
                                    reachedCommand: false)
            }
            return try await inner.run(script: script, args: args, input: input, deadline: deadline)
        }
    }

    struct Provider: RemoteTranscriptProvider {
        let exec: RemoteExec
        let roots: [Agent: RemoteTranscriptRoot]
        func transcriptContext(sessionIDs: [String], refresh: Bool) async throws -> RemoteTranscriptContext {
            RemoteTranscriptContext(exec: exec, roots: Dictionary(uniqueKeysWithValues: sessionIDs.map { ($0, roots) }))
        }
        func transportFailed() async {}
    }
}
