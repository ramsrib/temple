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
        let db = try TempleDB.inMemory()
        Fixture.join([Fixture.row("member", project: "/work", title: "Durable")], to: db)
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), indexSource: DelayedIndexSource(),
            database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()), stateDirectory: directory)
        model.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(model.sessions.first?.displayTitle, "Durable")
        XCTAssertTrue(model.isLoading)

        // Once only: an older Temple beside this one rebuilds the file and
        // must not be cold-started on every launch of its own.
        try Data("rebuilt by an older build".utf8).write(to: cache)
        let again = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), indexSource: DelayedIndexSource(),
            database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()), stateDirectory: directory)
        again.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }
    func testTranscriptUpdateDoesNotOverwriteADurableTitle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("temple-title-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = CatalogFixtureIndex.grouping([Fixture.session("member", project: "/tmp", title: "Before", updated: 10)])
        let second = CatalogFixtureIndex.grouping([Fixture.session("member", project: "/tmp", title: "After", updated: 10)])
        let db = try TempleDB.inMemory()
        Fixture.join(first, to: db)
        let source = DelayedIndexSource()
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), indexSource: source, database: db,
                             settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                             stateDirectory: directory)
        model.start()
        source.emit(first)
        source.emit(second)
        XCTAssertEqual(model.sessions.first?.displayTitle, "Before")
    }

}

@MainActor
private final class DelayedIndexSource: IndexSource {
    private var onUpdate: ((EngineSnapshot) -> Void)?

    func start(onUpdate: @escaping (EngineSnapshot) -> Void) {
        self.onUpdate = onUpdate
    }

    func stop() {}

    func emit(_ index: CatalogFixtureIndex) {
        onUpdate?(index.snapshot)
    }
}
