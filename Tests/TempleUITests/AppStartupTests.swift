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
                            indexSource: FakeIndexSource(SessionIndex(projects: [])),
                            database: database,
                            settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        }
        XCTAssertTrue(startup.updateRequired)
        XCTAssertEqual(startup.failureMessage, "This Temple is older than the data it found. Update Temple to continue.")
        XCTAssertNil(startup.model)
        XCTAssertEqual(modelConstructions, 0, "settings, overlay and restore must never be constructed")
        XCTAssertTrue(factory.created.isEmpty, "no restored tab may launch an agent")
    }

    func testOrdinaryOpenFailureStillUsesTheExistingInMemoryFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("temple-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A directory cannot be opened as SQLite, independently of permissions.
        let db = try AppDatabase.open(path: directory)
        try db.join(sessionID: "ephemeral", via: .created)
        XCTAssertEqual(try db.sessionStates().map(\.id), ["ephemeral"])
    }
}
