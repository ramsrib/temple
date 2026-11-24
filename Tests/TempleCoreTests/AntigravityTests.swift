import XCTest
import SQLite3
@testable import TempleCore
@testable import TempleLocalHost

/// The Antigravity CLI's store (ADR-043, SESSION-FORMATS.md "Antigravity
/// CLI"): the pure format over the records a store builds, the store over
/// real SQLite files, and which conversation a process has loaded.
final class AntigravityFormatTests: XCTestCase {
    private let id = "502dbaf1-4ae5-4f7c-ab0f-53dfb69d6efd"
    private let format = AntigravityFormat()

    private func facts(_ record: AntigravityFormat.Record, path: String? = nil, modifiedAt: Date = Date(timeIntervalSince1970: 2_000_000_000)) -> TranscriptFacts {
        let data = record.encoded()
        let path = path ?? "/s/conversations/\(id).db"
        return format.facts(TranscriptBytes(head: data, tail: nil, fileSize: data.count, window: data.count + 1),
                            name: format.name(path: path), locator: TranscriptLocator(localURL: URL(fileURLWithPath: path)),
                            modifiedAt: modifiedAt, shared: .empty)
    }

    private func summary(title: String = "Replying With Only Ok", folders: [String] = ["file:///work/app"],
                         parent: String = "", steps: Int = 2,
                         modified: String = "2026-11-24 20:55:47.538592+00:00") -> AntigravityFormat.Record.Summary {
        let uris = String(data: try! JSONSerialization.data(withJSONObject: folders), encoding: .utf8)!
        return .init(title: title, workspaceURIs: uris, parent: parent, stepCount: steps, lastModified: modified)
    }

    func testTheNameIsTheDatabasesUUIDAndNothingElse() {
        XCTAssertEqual(format.name(path: "/x/conversations/\(id.uppercased()).db")?.threadID, id)
        XCTAssertNil(format.name(path: "/x/conversations/\(id).db-wal"))
        XCTAssertNil(format.name(path: "/x/conversations/notes.db"))
        XCTAssertNil(format.name(path: "/x/conversation_summaries.db"))
    }

    func testIdentityIsWhatTheConversationsOwnDatabaseRecords() {
        func verdict(_ ids: [String]) -> TranscriptVerification {
            format.identity(lines: [AntigravityFormat.Record(ids: ids, summary: nil, firstUserStep: nil).encoded()], expecting: id)
        }
        XCTAssertEqual(verdict([id.uppercased()]), .verified)
        XCTAssertEqual(verdict(["other", id]), .verified)
        XCTAssertEqual(verdict(["0d8063b7-4be9-440a-80ca-5ea1d4ba5e98"]), .mismatch)
        XCTAssertEqual(verdict([]), .incomplete, "a database still being made says nothing yet")
        XCTAssertEqual(format.identity(lines: [Data("not json".utf8)], expecting: id), .incomplete)
    }

    func testFactsComeFromTheSummaryRowAndTheFirstUserStep() throws {
        let when = Date(timeIntervalSince1970: 1_795_553_744.5)
        let record = AntigravityFormat.Record(ids: [id], summary: summary(folders: ["file:///work/my%20app"]),
                                              firstUserStep: Self.userStep("Reply with only the word ok", at: when))
        guard case .summary(let s) = facts(record) else { return XCTFail() }
        XCTAssertEqual(s.id, id)
        XCTAssertEqual(s.agent, .antigravity)
        XCTAssertEqual(s.cwd, "/work/my app", "the URL's text, decoded")
        XCTAssertEqual(s.recordedTitle, "Replying With Only Ok", "agy's own title, as ADR-011 prefers")
        XCTAssertEqual(s.firstPrompt, "Reply with only the word ok")
        XCTAssertEqual(s.titleFact, "Replying With Only Ok")
        XCTAssertEqual(try XCTUnwrap(s.createdAt).timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(s.lastEntryAt).timeIntervalSince1970, 1_795_553_747.538, accuracy: 0.001)
    }

    func testAConversationWithNoTitleIsTitledByItsFirstPrompt() {
        let record = AntigravityFormat.Record(ids: [id], summary: summary(title: ""), firstUserStep: Self.userStep("  hi\n there ", at: nil))
        guard case .summary(let s) = facts(record) else { return XCTFail() }
        XCTAssertNil(s.recordedTitle)
        XCTAssertEqual(s.titleFact, "hi there")
    }

    func testOnlyAConversationWithOneFolderHasOne() {
        for folders in [[], ["file:///a", "file:///b"], ["https://example.com/a"]] {
            let record = AntigravityFormat.Record(ids: [id], summary: summary(folders: folders), firstUserStep: Self.userStep("x", at: nil))
            guard case .summary(let s) = facts(record) else { return XCTFail() }
            XCTAssertNil(s.cwd, "\(folders)")
        }
    }

    func testSubagentsAndConversationsNobodyAskedAnythingAreNotSessions() {
        let child = AntigravityFormat.Record(ids: [id], summary: summary(parent: "0d8063b7-4be9-440a-80ca-5ea1d4ba5e98"),
                                             firstUserStep: Self.userStep("task", at: nil))
        XCTAssertEqual(facts(child), .unparseable, "a subagent runs inside its parent (ADR-024)")
        let cleared = AntigravityFormat.Record(ids: [id], summary: summary(title: "", steps: 0, modified: "0001-01-01 00:00:00+00:00"), firstUserStep: nil)
        XCTAssertEqual(facts(cleared), .unparseable, "left by /clear: nothing to resume")
        // Steps but no user step read (yet): a session whose prompt is unknown.
        guard case .summary(let s) = facts(AntigravityFormat.Record(ids: [id], summary: summary(steps: 3), firstUserStep: nil)) else { return XCTFail() }
        XCTAssertNil(s.firstPrompt)
        // No summary row yet: still a session, with nothing it does not state.
        guard case .summary(let bare) = facts(AntigravityFormat.Record(ids: [id], summary: nil, firstUserStep: Self.userStep("go", at: nil))) else { return XCTFail() }
        XCTAssertNil(bare.cwd)
        XCTAssertNil(bare.recordedTitle)
        XCTAssertNil(bare.titleFact, "agy names it as the prompt is sent: no title until its row says")
        XCTAssertEqual(bare.catalogTitle, "go", "the prompt is shown meanwhile")
    }

    func testTimesAreAgysColumnTextAndTheZeroTimeIsNever() throws {
        XCTAssertNil(AntigravityFormat.date("0001-01-01 00:00:00+00:00"))
        XCTAssertEqual(try XCTUnwrap(AntigravityFormat.date("2026-11-24 20:55:44.515956+00:00")).timeIntervalSince1970, 1_795_553_744.515, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(AntigravityFormat.date("2026-11-24 20:55:44+00:00")).timeIntervalSince1970, 1_795_553_744, accuracy: 0.001)
        XCTAssertNil(AntigravityFormat.date("yesterday"))
    }

    func testAPayloadThatIsNotAWholeMessageStatesNoPrompt() {
        let truncated = Data(base64Encoded: Self.userStep("hello there", at: nil))!.dropLast(3)
        let record = AntigravityFormat.Record(ids: [id], summary: summary(), firstUserStep: Data(truncated).base64EncodedString())
        guard case .summary(let s) = facts(record) else { return XCTFail() }
        XCTAssertNil(s.firstPrompt)
        XCTAssertEqual(s.recordedTitle, "Replying With Only Ok")
    }

    /// A user-input step's payload as `agy` writes it: field 1 the step
    /// type, 5.1 the time, 19.2 the text (19.3.1 repeats it).
    static func userStep(_ text: String, at: Date?) -> String {
        Data(userStepPayload(text, at: at)).base64EncodedString()
    }

    static func userStepPayload(_ text: String, at: Date?) -> [UInt8] {
        func varint(_ value: UInt64) -> [UInt8] {
            var v = value, out: [UInt8] = []
            repeat { var byte = UInt8(v & 0x7f); v >>= 7; if v != 0 { byte |= 0x80 }; out.append(byte) } while v != 0
            return out
        }
        func bytes(_ number: UInt64, _ payload: [UInt8]) -> [UInt8] { varint(number << 3 | 2) + varint(UInt64(payload.count)) + payload }
        func int(_ number: UInt64, _ value: UInt64) -> [UInt8] { varint(number << 3) + varint(value) }
        var meta: [UInt8] = []
        if let at {
            let seconds = UInt64(at.timeIntervalSince1970)
            let nanos = UInt64(((at.timeIntervalSince1970 - Double(seconds)) * 1_000_000_000).rounded())
            meta = bytes(1, int(1, seconds) + int(2, nanos))
        }
        let text = Array(text.utf8)
        return int(1, 14) + int(4, 3) + bytes(5, meta) + bytes(19, bytes(2, text) + bytes(3, bytes(1, text)))
    }
}

/// The store over real SQLite files shaped like `agy`'s.
final class AntigravityStoreTests: XCTestCase {
    private var root: URL!
    private let id = "502dbaf1-4ae5-4f7c-ab0f-53dfb69d6efd"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/temple-agy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("conversations"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var store: AntigravitySessionStore { AntigravitySessionStore(root: root) }
    private func database(_ id: String) -> URL { root.appendingPathComponent("conversations/\(id).db") }

    /// One conversation database; `wal` leaves it in WAL mode, checkpointed
    /// and closed with no `-wal` or `-shm` (how `agy` leaves it on exit).
    @discardableResult
    func writeConversation(_ id: String, prompt: String?, wal: Bool = false) throws -> URL {
        let url = database(id)
        try SQLiteFixture.exec(url, [
            wal ? "PRAGMA journal_mode=WAL" : "PRAGMA journal_mode=DELETE",
            "CREATE TABLE trajectory_meta (trajectory_id text PRIMARY KEY, cascade_id text)",
            "CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer NOT NULL DEFAULT 0, step_payload blob)",
            "INSERT INTO trajectory_meta VALUES ('t-\(id)', '\(id)')",
            "INSERT INTO steps VALUES (0, 15, x'00')",
        ] + (prompt.map { ["INSERT INTO steps VALUES (1, 14, x'\(Self.hex(AntigravityFormatTests.userStepPayload($0, at: Date(timeIntervalSince1970: 1_795_553_744))))')"] } ?? [])
          + (wal ? ["PRAGMA wal_checkpoint(TRUNCATE)"] : []))
        if wal {
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        return url
    }

    func writeSummaries(_ rows: [(id: String, title: String, folder: String, parent: String, steps: Int)]) throws {
        try SQLiteFixture.exec(store.summariesFile, [
            """
            CREATE TABLE IF NOT EXISTS conversation_summaries (conversation_id text PRIMARY KEY, title text NOT NULL DEFAULT '',
              preview text NOT NULL DEFAULT '', step_count integer NOT NULL DEFAULT 0, last_modified_time datetime NOT NULL,
              workspace_uris text NOT NULL, parent_conversation_id text NOT NULL DEFAULT '')
            """,
        ] + rows.map { row in
            "INSERT INTO conversation_summaries VALUES ('\(row.id)', '\(row.title)', '\(row.title)', \(row.steps), '2026-11-24 20:55:47.538592+00:00', '[\"file://\(row.folder)\"]', '\(row.parent)')"
        })
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    func testItListsConversationsAndReadsFactsFromBothDatabases() throws {
        let child = "8c8e8b9b-721a-4e3a-adda-6389fb94f724"
        try writeConversation(id, prompt: "Reply with only the word ok")
        try writeConversation(child, prompt: "a subagent's task")
        try Data().write(to: root.appendingPathComponent("conversations/notes.txt"))
        try writeSummaries([(id, "Replying With Only Ok", "/work/app", "", 2), (child, "", "/work/app", id, 4)])

        XCTAssertEqual(try store.enumerateSessionFiles().map(\.lastPathComponent).sorted(), ["\(id).db", "\(child).db"].sorted())
        guard case .summary(let s) = store.parse(database(id)) else { return XCTFail() }
        XCTAssertEqual(s.cwd, "/work/app")
        XCTAssertEqual(s.titleFact, "Replying With Only Ok")
        XCTAssertEqual(s.firstPrompt, "Reply with only the word ok")
        XCTAssertEqual(store.parse(database(child)), .excluded, "a subagent: read whole, and no session")
        XCTAssertEqual(try store.verifyIdentity(at: database(id), expectedID: id), .verified)
        XCTAssertEqual(try store.verifyIdentity(at: database(id), expectedID: child), .mismatch)
    }

    func testAQuiescentWALDatabaseIsReadAsACheckedSnapshotAndLeftUntouched() throws {
        try writeConversation(id, prompt: "hello", wal: true)
        try writeSummaries([(id, "Hello", "/w", "", 2)])
        let before = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("conversations").path).sorted()
        let read = try store.readTranscript(at: database(id), expecting: id, facts: true, shared: { .empty })
        XCTAssertEqual(read.verdict, .verified)
        XCTAssertEqual(read.summary?.firstPrompt, "hello")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("conversations").path).sorted(), before,
                       "no -wal or -shm made in a store that is not Temple's")
    }

    /// A writer's log left behind with no shared memory (a crash): its
    /// commits are in the log and not in the main file. The read-only open
    /// reads them (SQLite builds the index in memory); it is never the
    /// immutable read, which would miss them.
    func testALogLeftByACrashedWriterIsReadThroughNotIgnored() throws {
        let scratch = root.appendingPathComponent("scratch.db")
        try SQLiteFixture.exec(scratch, [
            "PRAGMA journal_mode=WAL",
            "CREATE TABLE trajectory_meta (trajectory_id text PRIMARY KEY, cascade_id text)",
            "CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer NOT NULL DEFAULT 0, step_payload blob)",
            "INSERT INTO trajectory_meta VALUES ('t', '\(id)')",
            "PRAGMA wal_checkpoint(TRUNCATE)",
        ])
        try? FileManager.default.removeItem(atPath: scratch.path + "-wal")
        try? FileManager.default.removeItem(atPath: scratch.path + "-shm")
        let url = database(id)
        try SQLiteFixture.exec(scratch, [
            "PRAGMA wal_autocheckpoint=0",
            "INSERT INTO steps VALUES (0, 14, x'\(Self.hex(AntigravityFormatTests.userStepPayload("only in the log", at: nil)))')",
        ], whileOpen: {
            try FileManager.default.copyItem(at: scratch, to: url)
            try FileManager.default.copyItem(atPath: scratch.path + "-wal", toPath: url.path + "-wal")
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
        try writeSummaries([(id, "", "/w", "", 1)])
        let read = try store.readTranscript(at: url, expecting: id, facts: true, shared: { .empty })
        XCTAssertEqual(read.summary?.firstPrompt, "only in the log")
    }

    func testTheSummariesFileAloneMovesTheSharedRevision() throws {
        try writeSummaries([(id, "", "/w", "", 0)])
        let store = self.store
        let before = try XCTUnwrap(store.sharedRevision())
        XCTAssertEqual(store.sharedRevision(), before, "nothing changed")
        try SQLiteFixture.exec(store.summariesFile, ["UPDATE conversation_summaries SET title = 'Named'"])
        XCTAssertGreaterThan(try XCTUnwrap(store.sharedRevision()), before)
        XCTAssertEqual(store.sharedFactURLs.map(\.lastPathComponent), ["conversation_summaries.db", "conversation_summaries.db-wal"])
    }

    func testAMissingDatabaseIsMissing() {
        XCTAssertThrowsError(try store.readTranscript(at: database(id), expecting: id, facts: false, shared: { .empty })) {
            XCTAssertTrue(LocalSessionSource.isMissing($0), "\($0)")
        }
    }

    func testAWriteToTheLogIsAWriteToTheConversation() throws {
        let url = try writeConversation(id, prompt: "x")
        let wal = URL(fileURLWithPath: url.path + "-wal")
        XCTAssertEqual(store.transcriptURL(forEvent: wal)?.path, url.path)
        XCTAssertEqual(store.transcriptURL(forEvent: url)?.path, url.path)
        XCTAssertNil(store.transcriptURL(forEvent: URL(fileURLWithPath: url.path + "-shm")), "readers write -shm too")
        XCTAssertNil(store.transcriptURL(forEvent: store.summariesFile))
        XCTAssertNil(store.transcriptURL(forEvent: root.appendingPathComponent("presence/\(id).lock")))

        let before = try store.signature(at: url)
        try Data(repeating: 1, count: 32).write(to: wal)
        XCTAssertNotEqual(try store.signature(at: url), before, "a commit to the log is a new version")
    }

    func testTheSourceReadsAConversationThroughItsStore() async throws {
        try writeConversation(id, prompt: "Reply with only the word ok")
        try writeSummaries([(id, "Replying With Only Ok", "/work/app", "", 2)])
        let source = LocalSessionSource(stores: [store], monitorChanges: false)
        let located = try await source.locate([LocateRequest(id: id, agent: .antigravity)])
        let candidate = try XCTUnwrap(located.candidates[id]?.first)
        XCTAssertTrue(located.complete.contains(.antigravity))
        let read = try await source.read(candidate.locator, agent: .antigravity, expecting: id, facts: true)
        XCTAssertEqual(read.identity, .verified)
        XCTAssertEqual(read.summary?.titleFact, "Replying With Only Ok")
        XCTAssertEqual(read.summary?.cwd, "/work/app")
    }
}

/// Which conversation a process has loaded: the one `presence/<id>.lock`
/// the process itself holds open.
final class ProcessLocksTests: XCTestCase {
    private let id = "502dbaf1-4ae5-4f7c-ab0f-53dfb69d6efd"
    private let store = AntigravitySessionStore(root: URL(fileURLWithPath: "/s/agy"))
    private let start = ProcessStart(seconds: 100, microseconds: 5)

    func testOnlyALockDirectlyInThePresenceFolderNamesAConversation() {
        let presence = URL(fileURLWithPath: "/s/agy/presence")
        XCTAssertEqual(ProcessLocks.lockedIDs(["/s/agy/presence/\(id.uppercased()).lock", "/s/agy/conversations/\(id).db",
                                               "/s/agy/presence/x/\(id).lock", "/s/agy/presence/notes.lock",
                                               "/s/agy/presence/\(id).lock-journal"], presence: presence), [id])
    }

    private func identify(_ paths: [String], started: ProcessStart? = nil,
                          starts: [ProcessStart?]? = nil) -> ProcessIdentity {
        var remaining = starts ?? [start, start]
        return ProcessLocks.identify(ProcessIdentityRequest(agent: .antigravity, pid: 42, started: started), store: store,
                                     start: { _ in remaining.isEmpty ? nil : remaining.removeFirst() },
                                     openPaths: { _ in paths })
    }

    func testTheAnswers() {
        guard case .session(let found, let locator, _, let started) = identify(["/s/agy/presence/\(id).lock"]) else { return XCTFail() }
        XCTAssertEqual(found, id)
        XCTAssertEqual(locator.path, "/s/agy/conversations/\(id).db")
        XCTAssertEqual(started, start)
        XCTAssertEqual(identify(["/s/agy/conversations/\(id).db"]), .none(started: start), "a database open is not a lock held")
        guard case .inconclusive(_, started: start) = identify(["/s/agy/presence/\(id).lock", "/s/agy/presence/0d8063b7-4be9-440a-80ca-5ea1d4ba5e98.lock"]) else {
            return XCTFail("two locks: which is loaded can't be told")
        }
        XCTAssertEqual(identify([], starts: [nil]), .ended)
        XCTAssertEqual(identify([], started: ProcessStart(seconds: 99, microseconds: 0)), .ended, "the pid is another process's now")
        XCTAssertEqual(identify(["/s/agy/presence/\(id).lock"], starts: [start, ProcessStart(seconds: 101, microseconds: 0)]), .ended,
                       "replaced while its files were read")
    }

    /// A real process holding a lock open, read with the real system calls.
    func testARealProcessHoldingALockIsIdentified() throws {
        let root = URL(fileURLWithPath: "/private/tmp/temple-locks-\(UUID().uuidString)")
        let presence = root.appendingPathComponent("presence")
        try FileManager.default.createDirectory(at: presence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = presence.appendingPathComponent("\(id).lock")
        let store = AntigravitySessionStore(root: root)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The shell opens the lock and `exec`s: the lock stays open in the same process.
        process.arguments = ["-c", "exec 3>>\"$1\"; exec /bin/sleep 30", "sh", lock.path]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        var answer = ProcessIdentity.unsupported
        for _ in 0..<50 {
            answer = ProcessLocks.identify(ProcessIdentityRequest(agent: .antigravity, pid: process.processIdentifier, started: nil), store: store)
            if case .session = answer { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard case .session(let found, _, _, _) = answer else { return XCTFail("\(answer)") }
        XCTAssertEqual(found, id)
    }
}

/// Builds SQLite fixtures with the system library.
enum SQLiteFixture {
    struct Failure: Error { let message: String }
    /// Runs `statements`, then `whileOpen` before the connection closes.
    static func exec(_ url: URL, _ statements: [String], whileOpen: () throws -> Void = {}) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Failure(message: "open \(url.path)") }
        defer { sqlite3_close(db) }
        for sql in statements {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                defer { sqlite3_free(error) }
                throw Failure(message: error.map { String(cString: $0) } ?? sql)
            }
        }
        try whileOpen()
    }
}
