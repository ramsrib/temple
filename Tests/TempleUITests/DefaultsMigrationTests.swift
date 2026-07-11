import Foundation
import XCTest
@testable import TempleUI

final class DefaultsMigrationTests: XCTestCase {
    private func scratchDefaults() -> (name: String, defaults: UserDefaults) {
        let name = "temple-migration-test-\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    func testMigratesValuesAndSetsSentinel() {
        let scratch = scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: scratch.name) }

        DefaultsMigration.migrateIfNeeded(
            source: ["font": "SF Mono", "fontSize": 14.0],
            target: scratch.defaults
        )

        XCTAssertEqual(scratch.defaults.string(forKey: "font"), "SF Mono")
        XCTAssertEqual(scratch.defaults.double(forKey: "fontSize"), 14.0)
        XCTAssertEqual(scratch.defaults.bool(forKey: DefaultsMigration.sentinelKey), true)
    }

    func testSecondMigrationIsNoOp() {
        let scratch = scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: scratch.name) }

        DefaultsMigration.migrateIfNeeded(source: ["theme": "dark"], target: scratch.defaults)
        DefaultsMigration.migrateIfNeeded(source: ["theme": "light"], target: scratch.defaults)

        XCTAssertEqual(scratch.defaults.string(forKey: "theme"), "dark")
    }

    func testEmptySourceStillSetsSentinel() {
        let scratch = scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: scratch.name) }

        DefaultsMigration.migrateIfNeeded(source: [:], target: scratch.defaults)

        XCTAssertNil(scratch.defaults.object(forKey: "migrated-value"))
        XCTAssertEqual(scratch.defaults.bool(forKey: DefaultsMigration.sentinelKey), true)
    }
}
