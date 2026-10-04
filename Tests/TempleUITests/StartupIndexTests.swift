import XCTest
@testable import TempleUI
import TempleCore

@MainActor
final class StartupIndexTests: XCTestCase {
    func testIndexCacheFileIsRemovedOnTheFirstStartOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("temple-cache-removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("index-cache.json")
        try Data("obsolete".utf8).write(to: cache)
        let sentinel = directory.appendingPathComponent("keep.json")
        try Data("keep".utf8).write(to: sentinel)
        // Housekeeping happens beside the database, so the test's database
        // is a file in the test's own directory.
        let db = try TempleDB(path: directory.appendingPathComponent("temple.sqlite"))
        Fixture.join([Fixture.row("member", project: "/work", title: "Durable")], to: db)
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [FakeEngine()],
            database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        model.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(model.sessions.first?.displayTitle, "Durable")
        XCTAssertTrue(model.isLoading)

        // Once only: an older Temple beside this one rebuilds the file and
        // must not be cold-started on every launch of its own.
        try Data("rebuilt by an older build".utf8).write(to: cache)
        let again = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [FakeEngine()],
            database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        again.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }
    /// A model on an in-memory database has no state directory: start()
    /// must not reach one (before, with no directory injected, it deleted the
    /// real state dir's cache and wrote a marker there).
    func testAnInMemoryDatabaseTouchesNoStateDirectory() throws {
        let marker = TempleState.directory.appendingPathComponent(".index-cache-retired")
        try? FileManager.default.removeItem(at: marker)
        let cache = TempleState.directory.appendingPathComponent("index-cache.json")
        try Data("someone else's".utf8).write(to: cache)
        defer { try? FileManager.default.removeItem(at: cache) }
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [FakeEngine()],
            database: try TempleDB.inMemory(), settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        model.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    func testTranscriptUpdateDoesNotOverwriteADurableTitle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("temple-title-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = CatalogFixtureIndex.grouping([Fixture.session("member", project: "/tmp", title: "Before", updated: 10)])
        let second = CatalogFixtureIndex.grouping([Fixture.session("member", project: "/tmp", title: "After", updated: 10)])
        let db = try TempleDB.inMemory()
        Fixture.join(first, to: db)
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [FakeEngine()], database: db,
                             settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        model.start()
        // Authorized facts for the row's own membership: the persisted
        // title is NULL-only, so a transcript cannot overwrite it.
        model.receiveEngineSnapshot(first.snapshot(authorizedBy: db, generation: 1))
        model.receiveEngineSnapshot(second.snapshot(authorizedBy: db, generation: 2))
        XCTAssertEqual(model.sessions.first?.displayTitle, "Before")
        XCTAssertEqual(try db.sessionState("member")?.title, "Before")
    }

}
