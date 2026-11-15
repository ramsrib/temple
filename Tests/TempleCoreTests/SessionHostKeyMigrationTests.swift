import XCTest
import GRDB
@testable import TempleCore
import TempleTestSupport

/// ADR-041: a session is its id on a host. `v14-session-host-key` rebuilds
/// `session_state` keyed by `(id, host)` and `open_tabs` with a host, and
/// runs only when no other Temple has the file open.
final class SessionHostKeyMigrationTests: XCTestCase {
    private var directories: [URL] = []
    private let box = HostID(rawValue: "box")

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    private func path() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-v14-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory.appendingPathComponent("temple.sqlite")
    }

    /// A file as v0.8 left it: v12, one session on this Mac, one on a host,
    /// a saved tab of each and one whose row is gone, a process of the host's.
    private func writeV12(at path: URL) throws {
        let queue = try DatabaseQueue(path: path.path)
        try DBTests.legacyMigrator(through: "v12-archive-provenance").migrate(queue)
        try queue.write { database in
            try database.execute(sql: """
                INSERT INTO session_state (id, pinned, archived, custom_name, last_opened_at, generated_title, color,
                    joined_via, joined_at, agent, transcript_path, host, directory, directory_source, title,
                    last_active_at, incarnation, archive_reason, kept_at, archived_at)
                VALUES ('local', 1, 0, 'Mine', '2024-01-02 03:04:05.000', 'Gen', 'blue', 'opened', '2024-01-02 03:04:05.000',
                        'claude', '/t/local.jsonl', '', '/work', 'tab', 'Title', '2024-01-03 03:04:05.000', 'inc-local',
                        NULL, NULL, NULL),
                       ('remote', 0, 1, NULL, NULL, NULL, NULL, 'created', '2024-01-02 03:04:05.000', 'codex',
                        NULL, 'box', '/home/u/p', 'transcript', NULL, NULL, 'inc-remote',
                        'folder_missing', '2024-01-04 03:04:05.000', '2024-01-05 03:04:05.000');
                INSERT INTO open_tabs (project_path, session_id, position, agent, title, active)
                VALUES ('/home/u/p', 'remote', 0, 'codex', 'On the box', 0),
                       ('/work', 'local', 0, 'claude', 'Here', 1),
                       ('/orphan', 'gone', 2, 'claude', 'No row', 0);
                INSERT INTO process_registry (pid, session_id, started_at) VALUES (77, 'remote', '2024-01-02 03:04:05.000');
                """)
        }
        try queue.close()
    }

    func testV12MigratesWithEveryColumnIncarnationAndTabOrderKept() throws {
        let path = try path()
        try writeV12(at: path)
        let db = try TempleDB(path: path, onMigrationLockContention: nil, holders: { _ in [] })

        let local = try XCTUnwrap(db.sessionState("local"))
        XCTAssertEqual(local.incarnation, "inc-local")
        XCTAssertTrue(local.pinned)
        XCTAssertEqual(local.customName, "Mine")
        XCTAssertEqual(local.generatedTitle, "Gen")
        XCTAssertEqual(local.color, "blue")
        XCTAssertEqual(local.joinedVia, .opened)
        XCTAssertEqual(local.agent, .claude)
        XCTAssertEqual(local.transcriptPath, "/t/local.jsonl")
        XCTAssertEqual(local.directory, "/work")
        XCTAssertEqual(local.directorySource, .tab)
        XCTAssertEqual(local.title, "Gen", "the open-time title reconcile still runs")
        XCTAssertNil(local.lastActiveAt, "the v0.5 activity repair runs once on a file it has not seen, as before")
        let remote = try XCTUnwrap(db.sessionState("remote", host: box))
        XCTAssertNil(try db.sessionState("remote"), "the host's session is the host's only")
        XCTAssertEqual(remote.incarnation, "inc-remote")
        XCTAssertTrue(remote.archived)
        XCTAssertEqual(remote.archiveReason, .folderMissing)
        XCTAssertNotNil(remote.keptAt)
        XCTAssertNotNil(remote.archivedAt)

        // Each saved tab names its row's host; one whose row is gone stays
        // this Mac's. The restore order (rowid) is the order they were saved.
        let tabs = try db.openTabRecords()
        XCTAssertEqual(tabs.map(\.sessionID), ["remote", "local", "gone"])
        XCTAssertEqual(tabs.map(\.host), [box, .local, .local])
        XCTAssertEqual(tabs.map(\.isActive), [false, true, false])
        XCTAssertEqual(try db.liveProcesses().map(\.host), [box])

        // Now the same id joins on another host as a second session, and the
        // trigger still stamps a new row's incarnation.
        try db.join(sessionID: "local", via: .imported, agent: .claude, core: SessionCore(host: box, directory: "/home/u/work"))
        let copy = try XCTUnwrap(db.sessionState("local", host: box))
        XCTAssertEqual(copy.incarnation?.count, 32)
        XCTAssertEqual(try db.sessionState("local"), local, "this Mac's row is untouched")
        // Both sessions' tabs can be saved, even in folders with the same path.
        try db.replaceOpenTabs([
            OpenTabRecord(projectPath: "/work", sessionID: "local", host: .local, position: 0, agent: "claude", title: "Here"),
            OpenTabRecord(projectPath: "/work", sessionID: "local", host: box, position: 0, agent: "claude", title: "There"),
        ])
        XCTAssertEqual(try db.openTabRecords().map(\.host), [.local, box])

        // An older build sees a migration it does not know and refuses the
        // file ("Update Temple") rather than writing the old way into it.
        let queue = try DatabaseQueue(path: path.path, configuration: { var c = Configuration(); c.readonly = true; return c }())
        XCTAssertTrue(try queue.read { try DBTests.legacyMigrator().hasBeenSuperseded($0) })
        try queue.close()
    }

    /// Two Temples on one file across this migration would leave the older
    /// one writing by id alone into rows keyed by host: it waits for the
    /// other to quit, and changes nothing meanwhile.
    func testTheMigrationWaitsForEveryOtherTempleToQuit() throws {
        let path = try path()
        try writeV12(at: path)
        let other = FileHolder(pid: 4321, executable: "/Applications/Temple.app/Contents/MacOS/Temple")
        XCTAssertThrowsError(try TempleDB(path: path, onMigrationLockContention: nil, holders: { _ in [other] })) {
            XCTAssertEqual($0 as? TempleDBError, .openElsewhere([other]))
            XCTAssertEqual(($0 as? TempleDBError)?.errorDescription,
                           "Another copy of Temple is using its data (/Applications/Temple.app (pid 4321)), "
                           + "and this version updates that data the first time it opens. Quit the other copy, then try again.")
        }
        let queue = try DatabaseQueue(path: path.path)
        XCTAssertFalse(try queue.read { try $0.tableExists("activity_before_repair") }, "nothing was written")
        XCTAssertEqual(try queue.read { try DBTests.legacyMigrator().appliedIdentifiers($0) }.count, 12)
        try queue.close()

        // A process list that can't be read is no proof nobody holds it.
        XCTAssertThrowsError(try TempleDB(path: path, onMigrationLockContention: nil,
                                          holders: { _ in throw FileHoldersUnreadable(reason: "test") })) {
            XCTAssertEqual($0 as? TempleDBError, .cannotCheckOthers("test"))
        }
        // Once migrated, others having the file open is ordinary.
        _ = try TempleDB(path: path, onMigrationLockContention: nil, holders: { _ in [] })
        XCTAssertNoThrow(try TempleDB(path: path, onMigrationLockContention: nil, holders: { _ in [other] }))
    }

    /// The real probe: this test's own process holds the file, so another
    /// process opening it sees it; only Temple processes are counted.
    func testFileHoldersSeesAnotherProcessByDeviceAndInode() throws {
        let path = try path()
        FileManager.default.createFile(atPath: path.path, contents: Data())
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "exec 3<\"$1\"; sleep 5", "sh", path.path]
        try child.run()
        defer { child.terminate() }
        var seen: [FileHolder] = []
        let deadline = Date().addingTimeInterval(3)
        while seen.isEmpty, Date() < deadline {
            seen = try FileHolders.others(holding: path)
            if seen.isEmpty { usleep(20_000) }
        }
        XCTAssertTrue(seen.contains { $0.pid == child.processIdentifier })
        XCTAssertFalse(try TempleDB.templeHolders(path).contains { $0.pid == child.processIdentifier },
                       "a shell is not a Temple: it can't write the old way")
    }
}
