import XCTest
@testable import TempleUI
import TempleCore

@MainActor
final class StartupIndexTests: XCTestCase {
    func testIndexCacheFileIsRemovedOnStart() throws {
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
    }
    func testTitleOnlyLiveUpdateReachesAppModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("temple-title-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SessionIndex.grouping([Fixture.session("member", project: "/tmp", title: "Before", updated: 10)])
        let second = SessionIndex.grouping([Fixture.session("member", project: "/tmp", title: "After", updated: 10)])
        let db = try TempleDB.inMemory()
        Fixture.join(first, to: db)
        let source = DelayedIndexSource()
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), indexSource: source,
                             noiseFilter: NoNoiseFilter(), database: db,
                             settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                             stateDirectory: directory)
        model.start()
        source.emit(first)
        source.emit(second)
        XCTAssertEqual(model.index.allSessions.first?.title, "After")
    }

}

@MainActor
private final class DelayedIndexSource: IndexSource {
    private var onUpdate: ((SessionIndex) -> Void)?

    func start(onUpdate: @escaping (SessionIndex) -> Void) {
        self.onUpdate = onUpdate
    }

    func stop() {}

    func emit(_ index: SessionIndex) {
        onUpdate?(index)
    }
}
