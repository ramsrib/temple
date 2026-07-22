import XCTest
@testable import TempleUI
import TempleCore

@MainActor
final class PersistenceAdapterTests: XCTestCase {
    func testDBOverlayStoreReloadsPinsAndCustomNames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-overlay-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("temple.sqlite")

        let writer = SessionOverlayStore(db: try TempleDB(path: path))
        writer.togglePin("session")
        writer.rename("session", to: "Custom title")

        let reader = SessionOverlayStore(db: try TempleDB(path: path))
        XCTAssertTrue(reader.isPinned("session"))
        XCTAssertEqual(reader.customName(for: "session"), "Custom title")
    }

    func testDBOverlayStorePublishesAndReloadsColor() throws {
        let db = try TempleDB.inMemory()
        let writer = SessionOverlayStore(db: db)

        writer.setColor("purple", for: "session")
        XCTAssertEqual(writer.colors["session"], "purple")
        XCTAssertEqual(writer.color(for: "session"), "purple")

        let reader = SessionOverlayStore(db: db)
        XCTAssertEqual(reader.color(for: "session"), "purple")

        writer.setColor(nil, for: "session")
        XCTAssertNil(writer.colors["session"])
        XCTAssertNil(SessionOverlayStore(db: db).color(for: "session"))
    }

    func testDBProcessRegistryUnregistersBySession() throws {
        let db = try TempleDB.inMemory()
        let registry = DBProcessRegistry(db: db)
        registry.register(pid: 101, sessionID: "one")
        registry.register(pid: 102, sessionID: "two")
        registry.unregister(sessionID: "one")

        XCTAssertEqual(try db.liveProcesses().map(\.sessionID), ["two"])
    }
}
