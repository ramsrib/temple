import XCTest
@testable import TempleUI
import TempleCore

@MainActor
final class StartupIndexTests: XCTestCase {
    func testCachedIndexPublishesBeforeFirstLiveEmission() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-ui-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("index-cache.json")
        let cachedIndex = SessionIndex(projects: [
            Project(path: "/cached", sessions: [
                Fixture.session("cached", project: "/cached", title: "Cached"),
            ]),
        ])
        let liveIndex = SessionIndex(projects: [
            Project(path: "/live", sessions: [
                Fixture.session("live", project: "/live", title: "Live"),
            ]),
        ])
        try CachedIndexStore.save(cachedIndex, to: cacheURL)
        let source = DelayedIndexSource()
        let database = try TempleDB.inMemory()
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            indexSource: source,
            noiseFilter: NoNoiseFilter(),
            database: database,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: SessionOverlayStore(db: database),
            cacheURL: cacheURL
        )

        model.start()

        XCTAssertEqual(model.index, cachedIndex)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.isIndexStale)

        source.emit(liveIndex)
        XCTAssertEqual(model.index, liveIndex)
        XCTAssertFalse(model.isIndexStale)
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
