import XCTest
import GRDB
import TempleCore
@testable import TempleUI

@MainActor
final class AppStartupTests: XCTestCase {
    func testNewerSchemaStopsBeforeModelConstructionAndTabRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("temple-startup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("temple.sqlite")
        let seed = try TempleDB(path: path)
        try seed.replaceOpenTabs([OpenTabRecord(projectPath: "/p", sessionID: "restore-me", position: 0, agent: "claude", title: "Restorable", isActive: true)])
        let raw = try DatabaseQueue(path: path.path)
        try raw.write { try $0.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('future-schema')") }
        try raw.close()
        let factory = FakeTerminalSurfaceFactory()
        var modelConstructions = 0
        let startup = AppStartup(openDatabase: { try AppDatabase.open(path: path) }) { database in
            modelConstructions += 1
            return AppModel(surfaceFactory: factory,
                            engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
                            database: database,
                            settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        }
        XCTAssertTrue(startup.updateRequired)
        XCTAssertEqual(startup.failureMessage, "This Temple is older than the data it found. Update Temple to continue.")
        XCTAssertNil(startup.model)
        XCTAssertEqual(modelConstructions, 0, "settings, overlay and restore must never be constructed")
        XCTAssertTrue(factory.created.isEmpty, "no restored tab may launch an agent")
    }

    func testAnOrdinaryOpenFailureShowsAFailureWindowInsteadOfForgetting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("temple-open-\(UUID().uuidString)")
        // A directory cannot be opened as SQLite, independently of permissions.
        // It sits inside `directory` so its `.migrate-lock` sidecar goes too.
        let path = directory.appendingPathComponent("temple.sqlite")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try AppDatabase.open(path: path)) { error in
            guard case .openFailed(let failedPath, _)? = error as? AppDatabaseError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(failedPath, path.path)
        }
        var modelConstructions = 0
        let startup = AppStartup(openDatabase: { try AppDatabase.open(path: path) }) { database in
            modelConstructions += 1
            return AppModel(database: database, settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        }
        XCTAssertNil(startup.model)
        XCTAssertEqual(modelConstructions, 0)
        XCTAssertFalse(startup.updateRequired)
        XCTAssertTrue(startup.failureMessage?.hasPrefix("Temple couldn't open its data.") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["temple.sqlite", "temple.sqlite.migrate-lock"])
    }
}
