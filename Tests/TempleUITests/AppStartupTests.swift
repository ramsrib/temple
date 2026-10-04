import XCTest
import AppKit
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
        XCTAssertEqual(startup.failure, .updateRequired)
        XCTAssertEqual(startup.failure?.title, "Update Temple to continue")
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
        guard case .openFailed(let failedPath?, let reason)? = startup.failure else {
            return XCTFail("unexpected \(String(describing: startup.failure))")
        }
        XCTAssertEqual(failedPath, path.path)
        XCTAssertEqual(startup.failure?.title, "Temple couldn't open its data")
        XCTAssertEqual(startup.failure?.details(version: "1.0", bundlePath: "/x"), "\(path.path)\n\(reason)",
                       "the path, then the raw error as it came")
        XCTAssertEqual(startup.failure?.revealURL()?.path, path.path, "it exists (as a directory), so it is what Finder shows")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["temple.sqlite", "temple.sqlite.migrate-lock"])
    }

    /// The update window names the copy that is running; Reveal in Finder is
    /// offered only for a file whose folder exists, and shows the folder when
    /// the file itself is gone.
    func testFailureDetailsAndRevealTarget() {
        XCTAssertEqual(StartupFailure.updateRequired.details(version: "0.4.0", bundlePath: "~/Downloads/Temple.app"),
                       "Temple 0.4.0\n~/Downloads/Temple.app")
        XCTAssertNil(StartupFailure.updateRequired.revealURL(fileExists: { _ in true }))
        let failure = StartupFailure.openFailed(path: "/data/temple.sqlite", reason: "SQLite error 26: file is not a database")
        XCTAssertEqual(failure.revealURL(fileExists: { _ in true })?.path, "/data/temple.sqlite")
        XCTAssertEqual(failure.revealURL(fileExists: { $0 == "/data" })?.path, "/data")
        XCTAssertNil(failure.revealURL(fileExists: { _ in false }), "no folder, no button")
        XCTAssertNil(StartupFailure.openFailed(path: nil, reason: "x").revealURL(fileExists: { _ in true }))
    }

    /// A failure window has no model, so nothing drains and nothing asks: its
    /// close button closes the last window, which quits — it must never leave
    /// a windowless app with a menu bar and no New Window to get back.
    func testWithoutAModelClosingTheWindowQuitsWithoutAsking() {
        let delegate = TempleAppDelegate()
        delegate.confirmQuitWhileWorking = { _ in XCTFail("nothing to ask about"); return false }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 560, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        XCTAssertTrue(delegate.approveCloseForQuit(window))
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }
}
