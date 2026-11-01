import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

/// Another Temple's database, read by the peer script under the local
/// `/bin/sh` stand-in against a temp `HOME` (docs/designs/
/// open-existing-sessions.md sections 2 and 6): real databases made by this
/// build's own migrations, shapes made by hand, the watchdog, the budget,
/// and the parser on its own.
final class PeerTempleTests: XCTestCase {
    /// A stand-in host: a temp HOME whose Temple folder may hold a database.
    final class Box {
        let tree = TempTree("temple-peer")
        var home: String { tree.path + "/home" }
        var path = "/usr/bin:/bin"
        init() { _ = tree.directory("home") }
        var databaseURL: URL { URL(fileURLWithPath: home).appendingPathComponent(PeerTemple.databasePath) }
        var exec: LocalShellExec { LocalShellExec(path: path, environment: hostEnvironment(home: home, path: path)) }

        /// A database as this build makes it, every migration applied.
        func makeCurrent() throws {
            _ = try TempleDB(path: databaseURL)
        }

        /// A database made by hand from `sql`.
        func make(_ sql: String) throws {
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sqlite(sql)
        }

        func sqlite(_ sql: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [databaseURL.path]
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(Data(sql.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, sql)
        }

        func read(budget: Int = PeerTemple.budget, reader: String = "/usr/bin/sqlite3") async throws -> PeerTempleAnswer {
            try await PeerTemple.read(exec: exec, budget: budget, reader: reader)
        }
    }

    static let row = """
        INSERT INTO session_state (id, host, agent, directory, transcript_path, custom_name, title, color, archived, last_active_at, last_opened_at)
        """

    func snapshot(_ answer: PeerTempleAnswer, file: StaticString = #filePath, line: UInt = #line) -> PeerSnapshot? {
        guard case .snapshot(let snapshot) = answer else {
            XCTFail("expected a snapshot, got \(answer)", file: file, line: line)
            return nil
        }
        return snapshot
    }

    // MARK: Real databases

    func testNoDatabaseIsNoTemple() async throws {
        let box = Box()
        let answer = try await box.read()
        XCTAssertEqual(answer, .noTemple)
    }

    func testNoReaderIsItsOwnAnswer() async throws {
        let box = Box()
        try box.makeCurrent()
        box.path = "/bin"  // `sh` is here; `sqlite3` is in /usr/bin
        let answer = try await box.read(reader: box.tree.path + "/no-such-sqlite3")
        XCTAssertEqual(answer, .noReader)
    }

    func testCurrentSchemaReadsTheOtherTemplesOwnSessions() async throws {
        let box = Box()
        try box.makeCurrent()
        try box.sqlite("""
            \(Self.row) VALUES ('c1', '', 'claude', '/work/app', '/home/b/.claude/projects/-work-app/c1.jsonl', 'Fix login', 'login bug', 'blue', 0, '2026-10-30 09:15:00.000', '2026-10-30 09:00:00.000');
            \(Self.row) VALUES ('x1', '', 'codex', '/work/api', NULL, NULL, 'api: "quotes"' || char(9) || 'tab' || char(10) || 'line', NULL, 1, NULL, NULL);
            \(Self.row) VALUES ('e1', '', 'claude', '/work/app', NULL, '', NULL, '', 0, NULL, NULL);
            \(Self.row) VALUES ('r1', 'masterblaster', 'claude', '/srv/x', NULL, NULL, NULL, NULL, 0, NULL, NULL);
            \(Self.row) VALUES ('n1', '', 'claude', NULL, NULL, NULL, NULL, NULL, 0, NULL, NULL);
            \(Self.row) VALUES ('u1', '', 'gemini', '/work/app', NULL, NULL, NULL, NULL, 0, NULL, NULL);
            \(Self.row) VALUES ('b1', '', 'claude', '/work/app', NULL, NULL, CAST(X'FF61' AS TEXT), NULL, 0, NULL, NULL);
            INSERT INTO open_tabs (project_path, session_id, position, agent, title) VALUES ('/work/app', 'c1', 0, 'claude', 'Fix login');
            INSERT INTO project_state (path, archived) VALUES ('/work/old', 1), ('/work/app', 0);
            """)
        let answer = try await box.read()
        guard let snapshot = snapshot(answer) else { return }

        XCTAssertEqual(snapshot.sessions.map(\.id).sorted(), ["c1", "e1", "x1"], "only the other Temple's own, usable rows")
        XCTAssertEqual(snapshot.skipped, 3, "no folder, an unknown agent, a title that isn't text; another host's row isn't counted")
        XCTAssertEqual(snapshot.openTabIDs, ["c1"])
        XCTAssertEqual(snapshot.archivedProjects, ["/work/old"])

        let claude = try XCTUnwrap(snapshot.sessions.first { $0.id == "c1" })
        XCTAssertEqual(claude.agent, .claude)
        XCTAssertEqual(claude.directory, "/work/app")
        XCTAssertEqual(claude.transcriptPath, "/home/b/.claude/projects/-work-app/c1.jsonl")
        XCTAssertEqual(claude.displayTitle, "Fix login", "the name before the title")
        XCTAssertEqual(claude.color, "blue")
        XCTAssertEqual(claude.lastActiveAt, Date(timeIntervalSince1970: 1_793_351_700))
        XCTAssertNotNil(claude.lastOpenedAt)

        let codex = try XCTUnwrap(snapshot.sessions.first { $0.id == "x1" })
        XCTAssertEqual(codex.title, "api: \"quotes\"\ttab\nline", "every byte of a title survives the records")
        XCTAssertNil(codex.customName)
        XCTAssertTrue(codex.archived)

        let empty = try XCTUnwrap(snapshot.sessions.first { $0.id == "e1" })
        XCTAssertEqual(empty.customName, "", "an empty string is not NULL")
        XCTAssertEqual(empty.color, "")
        XCTAssertNil(empty.title)
    }

    func testArchivedProjectArchivesItsSessions() {
        let session = PeerSession(id: "a", agent: .claude, directory: "/work/old")
        XCTAssertTrue(PeerSnapshot(sessions: [session], archivedProjects: ["/work/old"]).isArchived(session))
        XCTAssertFalse(PeerSnapshot(sessions: [session]).isArchived(session))
    }

    func testAdditiveNewerSchemaIsRead() async throws {
        let box = Box()
        try box.makeCurrent()
        try box.sqlite("""
            ALTER TABLE session_state ADD COLUMN future_thing TEXT;
            INSERT INTO grdb_migrations (identifier) VALUES ('v99-from-the-future');
            \(Self.row) VALUES ('c1', '', 'claude', '/work/app', NULL, NULL, NULL, NULL, 0, NULL, NULL);
            """)
        let answer = try await box.read()
        XCTAssertEqual(snapshot(answer)?.sessions.map(\.id), ["c1"])
    }

    static let handMadeTables = """
        CREATE TABLE session_state (id TEXT PRIMARY KEY, host TEXT NOT NULL DEFAULT '', agent TEXT, directory TEXT,
          transcript_path TEXT, custom_name TEXT, title TEXT, color TEXT, archived BOOLEAN NOT NULL DEFAULT 0,
          last_active_at DATETIME, last_opened_at DATETIME);
        CREATE TABLE open_tabs (project_path TEXT, session_id TEXT);
        CREATE TABLE project_state (path TEXT PRIMARY KEY, archived BOOLEAN);
        """

    func testShapeWithoutTheV10MigrationIsIncompatible() async throws {
        let box = Box()
        try box.make(Self.handMadeTables + "CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY); INSERT INTO grdb_migrations VALUES ('v9-session-transcript');")
        let answer = try await box.read()
        XCTAssertEqual(answer, .incompatible)
    }

    func testNoMigrationTableIsIncompatible() async throws {
        let box = Box()
        try box.make(Self.handMadeTables)
        let answer = try await box.read()
        XCTAssertEqual(answer, .incompatible)
    }

    func testMissingRequiredColumnIsIncompatible() async throws {
        let box = Box()
        try box.make("""
            CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY); INSERT INTO grdb_migrations VALUES ('v10-session-core');
            CREATE TABLE session_state (id TEXT PRIMARY KEY, host TEXT, agent TEXT, directory TEXT);
            CREATE TABLE open_tabs (project_path TEXT, session_id TEXT);
            CREATE TABLE project_state (path TEXT PRIMARY KEY, archived BOOLEAN);
            """)
        let answer = try await box.read()
        XCTAssertEqual(answer, .incompatible)
    }

    func testNotADatabaseIsUnreadable() async throws {
        let box = Box()
        try FileManager.default.createDirectory(at: box.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not sqlite, just text long enough to be a header".utf8).write(to: box.databaseURL)
        let answer = try await box.read()
        guard case .unreadable(let line) = answer else { return XCTFail("\(answer)") }
        XCTAssertFalse(line.isEmpty)
    }

    func testOverBudgetIsTooLargeNeverTruncated() async throws {
        let box = Box()
        try box.makeCurrent()
        try box.sqlite("\(Self.row) VALUES ('c1', '', 'claude', '/work/app', NULL, NULL, NULL, NULL, 0, NULL, NULL);")
        let answer = try await box.read(budget: 10)
        XCTAssertEqual(answer, .tooLarge)
    }

    /// Another Temple holds its write lock: the read waits its second for
    /// the lock, then says busy, and holds nothing afterwards.
    func testWriterHoldingTheLockIsBusy() async throws {
        let box = Box()
        try box.makeCurrent()
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        writer.arguments = [box.databaseURL.path]
        let input = Pipe()
        writer.standardInput = input
        writer.standardOutput = Pipe()
        try writer.run()
        defer { writer.terminate(); writer.waitUntilExit() }
        input.fileHandleForWriting.write(Data("BEGIN EXCLUSIVE;\nINSERT INTO ui_state (key, value) VALUES ('k', 'v');\nSELECT 'locked';\n".utf8))
        // Wait for the writer to say it holds the lock.
        let out = (writer.standardOutput as! Pipe).fileHandleForReading
        var seen = Data()
        while !String(decoding: seen, as: UTF8.self).contains("locked") { seen.append(out.availableData) }

        let answer = try await box.read()
        XCTAssertEqual(answer, .busy)

        // The read left no lock behind: the writer commits.
        input.fileHandleForWriting.write(Data("COMMIT;\nSELECT 'committed';\n".utf8))
        while !String(decoding: seen, as: UTF8.self).contains("committed") { seen.append(out.availableData) }
    }

    /// A read that runs too long is killed on the host by the watchdog, well
    /// before the ssh deadline, and says busy.
    func testWatchdogKillsASlowRead() async throws {
        let box = Box()
        try box.makeCurrent()
        let bin = box.tree.directory("slow-bin").path
        box.tree.write("slow-bin/sqlite3", "#!/bin/sh\nexec sleep 30\n", executable: true)
        box.path = "\(bin):/usr/bin:/bin"
        let started = Date()
        let answer = try await box.read()
        XCTAssertEqual(answer, .busy)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6, "the host's watchdog, not the ssh deadline")
    }

    /// A real `sqlite3` that takes the read lock (a read transaction that has
    /// read the table) and then holds it, as a slow read would.
    func installLockHoldingReader(_ box: Box) -> String {
        let bin = box.tree.directory("holding-bin").path
        box.tree.write("holding-bin/sqlite3", """
            #!/bin/sh
            for a; do db=$a; done
            exec /usr/bin/sqlite3 -readonly -cmd 'BEGIN' -cmd 'SELECT count(*) FROM session_state;' -cmd '.shell sleep 30' "$db" < /dev/null
            """, executable: true)
        return bin
    }

    /// Writes one row with a 5 s busy timeout, as the other Temple's next
    /// write would; returns how long it took, or nil if it failed.
    func timedWrite(_ box: Box) -> TimeInterval? {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-cmd", ".timeout 5000", box.databaseURL.path,
                             "INSERT OR REPLACE INTO ui_state (key, value) VALUES ('k', '\(UUID().uuidString)');"]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? Date().timeIntervalSince(started) : nil
    }

    /// The watchdog kills a read holding the lock, and the other Temple's
    /// write then goes through inside its own busy timeout.
    func testWatchdogReleasesARealReadLock() async throws {
        let box = Box()
        try box.makeCurrent()
        box.path = "\(installLockHoldingReader(box)):/usr/bin:/bin"
        let read = Task { try await box.read() }
        try await Task.sleep(nanoseconds: 300_000_000)
        let waited = await Task.detached { self.timedWrite(box) }.value
        let answer = try await read.value
        XCTAssertEqual(answer, .busy)
        let seconds = try XCTUnwrap(waited, "the write never got the lock")
        XCTAssertLessThan(seconds, 4, "released by the 2 s watchdog, well inside the writer's 5 s")
    }

    /// A read cancelled while it holds the lock (the person left the page,
    /// the connection went) lets go of it at once, not at the watchdog.
    func testCancelledReadReleasesTheLockAtOnce() async throws {
        let box = Box()
        try box.makeCurrent()
        box.path = "\(installLockHoldingReader(box)):/usr/bin:/bin"
        let read = Task { try await box.read() }
        try await Task.sleep(nanoseconds: 400_000_000)
        read.cancel()
        _ = try? await read.value
        let waited = await Task.detached { self.timedWrite(box) }.value
        let seconds = try XCTUnwrap(waited, "the write never got the lock")
        XCTAssertLessThan(seconds, 1.5, "the script's cleanup killed sqlite3 with it")
    }

    /// A kill that cuts a record in half sends nothing of it: busy, never a
    /// malformed answer read as an unreachable host.
    func testKillMidOutputIsBusyNotMalformed() async throws {
        let box = Box()
        try box.makeCurrent()
        let bin = box.tree.directory("cut-bin").path
        box.tree.write("cut-bin/sqlite3", "#!/bin/sh\nprintf 'columns\\t1\\t11\\t1\\t2\\nsess'\nexec sleep 30\n", executable: true)
        box.path = "\(bin):/usr/bin:/bin"
        let answer = try await box.read()
        XCTAssertEqual(answer, .busy)
    }

    // MARK: The parser on its own

    func parse(_ text: String) throws -> PeerTempleAnswer { try PeerTemple.parse(Data(text.utf8)) }

    func testParserMapsFailures() throws {
        let error = Array("database is locked".utf8).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try parse("peer\tran\t1\t0\t0\t\(error)\ndone\n"), .busy)
        XCTAssertEqual(try parse("peer\tran\t143\t1\t0\t\ndone\n"), .busy)
        // Measured from a shell: a writer killed after its update spilled,
        // then `sqlite3 -readonly`. (Inside the test process the same steps
        // left a journal the reader did not treat as hot, so this is pinned
        // here from the measured line.)
        let readonly = Array("Parse error near line 2: attempt to write a readonly database (8)".utf8).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try parse("peer\tran\t8\t0\t1\t\(readonly)\ndone\n"), .needsOpen)
        XCTAssertEqual(try parse("peer\tran\t1\t0\t1\t\(error)\ndone\n"), .busy, "a live writer's journal is not a crashed one")
        XCTAssertEqual(try parse("peer\tran\t1\t0\t0\t\ndone\n"), .unreadable("sqlite3 ended with status 1"))
        XCTAssertEqual(try parse("peer\tran\t1\t0\t0\t\ncolumns\t1\t9\t1\t2\ndone\n"), .incompatible,
                       "a shape already known to be wrong decides, whatever failed after it")
        XCTAssertEqual(try parse("peer\tran\t0\t0\t0\t\ncolumns\t1\t11\t1\t2\nmigration\t0\ndone\n"), .incompatible)
        XCTAssertEqual(try parse("peer\tran\t0\t0\t0\t\ncolumns\t1\t11\t1\t2\nmigration\t1\ndone\n"), .snapshot(PeerSnapshot(sessions: [])))
    }

    func testParserRejectsWhatTheScriptNeverSays() {
        for text in ["", "peer\tran\t0\t0\t0\t\n", "peer\tnope\ndone\n", "peer\tran\t0\t0\t0\t\nstray\ndone\n",
                     "peer\tran\t0\t0\t0\tzz\ndone\n", "peer\tran\t0\t0\t0\t\ndone\n"] {
            XCTAssertThrowsError(try parse(text), text.debugDescription)
        }
    }

    func testOneBadRecordLeavesItsNeighbours() throws {
        func hex(_ text: String) -> String { Array(text.utf8).map { String(format: "%02x", $0) }.joined() }
        let good = ["session", hex("a"), hex("claude"), hex("/w"), "-", "-", "-", "-", "0", "-", "-"].joined(separator: "\t")
        let short = ["session", hex("b"), hex("claude")].joined(separator: "\t")
        let notHex = ["session", "zz", hex("claude"), hex("/w"), "-", "-", "-", "-", "0", "-", "-"].joined(separator: "\t")
        let answer = try parse("peer\tran\t0\t0\t0\t\ncolumns\t1\t11\t1\t2\nmigration\t1\n\(good)\n\(short)\n\(notHex)\ndone\n")
        XCTAssertEqual(answer, .snapshot(PeerSnapshot(sessions: [PeerSession(id: "a", agent: .claude, directory: "/w")], skipped: 2)))
    }

    func testCommandThatNeverRanIsTransport() async {
        let exec = RecordingExec { _, _ in RemoteOutput(status: 255, stdout: "", stderr: "ssh: connect to host b: Connection refused", reachedCommand: false) }
        do {
            _ = try await PeerTemple.read(exec: exec)
            XCTFail("expected a transport failure")
        } catch {
            XCTAssertEqual(error as? PeerTempleError, .transport("ssh: connect to host b: Connection refused"))
        }
    }
}
