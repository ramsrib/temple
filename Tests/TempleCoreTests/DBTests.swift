import XCTest
@testable import TempleCore

final class DBTests: XCTestCase {
    private var paths: [URL] = []

    override func tearDown() {
        for path in paths { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        paths.removeAll()
        super.tearDown()
    }

    private func database() throws -> (TempleDB, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-db-\(UUID().uuidString)", isDirectory: true)
        let path = directory.appendingPathComponent("temple.sqlite")
        paths.append(path)
        return (try TempleDB(path: path), path)
    }

    func testSessionStateRoundTrip() throws {
        let (db, _) = try database()
        try db.setPinned(true, sessionID: "s")
        try db.setArchived(true, sessionID: "s")
        try db.setCustomName("My session", sessionID: "s")
        try db.recordOpened(sessionID: "s", at: Date(timeIntervalSince1970: 123))
        let state = try XCTUnwrap(db.sessionState("s"))
        XCTAssertTrue(state.pinned)
        XCTAssertTrue(state.archived)
        XCTAssertEqual(state.customName, "My session")
        try db.setPinned(false, sessionID: "s")
        XCTAssertFalse(try XCTUnwrap(db.sessionState("s")).pinned)
    }

    func testOpenTabsPreserveOrder() throws {
        let (db, _) = try database()
        try db.setOpenTabs(projectPath: "/project", sessionIDs: ["a", "b", "c"])
        XCTAssertEqual(try db.openTabs(projectPath: "/project"), ["a", "b", "c"])
    }

    func testProcessRegistrationAndRemoval() throws {
        let (db, _) = try database()
        try db.registerProcess(pid: 42, sessionID: "s", startedAt: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(try db.liveProcesses().map(\.pid), [42])
        try db.unregisterProcess(pid: 42)
        XCTAssertTrue(try db.liveProcesses().isEmpty)
    }

    func testReopeningDatabasePreservesState() throws {
        let (db, path) = try database()
        try db.setCustomName("persisted", sessionID: "s")
        let reopened = try TempleDB(path: path)
        XCTAssertEqual(try reopened.sessionState("s")?.customName, "persisted")
    }

    func testDefaultPathShape() {
        XCTAssertTrue(TempleDB.defaultPath().path.hasSuffix("Library/Application Support/Temple/temple.sqlite"))
    }
}
