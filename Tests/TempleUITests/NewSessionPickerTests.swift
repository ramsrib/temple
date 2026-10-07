import XCTest
@testable import TempleUI
import TempleCore



@MainActor
final class NewSessionPickerTests: XCTestCase {
    private func makeModel(_ rows: [Session]) -> AppModel {
        let database = try! TempleDB.inMemory()
        Fixture.join(rows, to: database)
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
            database: database,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: SessionOverlayStore(db: database)
        )
        return model
    }

    func testPickerListsProjectsByRecencyAndFiltersByPath() {
        let model = makeModel( [

                Fixture.row("a", project: "/work/api", updated: 10),

                Fixture.row("b", project: "/home/temple", updated: 30),

                Fixture.row("c", project: "/work/site", updated: 20),
        ])

        XCTAssertEqual(model.projectPickerResults("").map(\.path),
                       ["/home/temple", "/work/site", "/work/api"])
        // Any path component matches, not just the folder name.
        XCTAssertEqual(model.projectPickerResults("work").map(\.path),
                       ["/work/site", "/work/api"])
        XCTAssertEqual(model.projectPickerResults("TEMPLE").map(\.path),
                       ["/home/temple"])
    }

    func testPickerKeepsNoisyMembers() {
        let model = makeModel( [

                Fixture.row("noise", project: "/p/junk", updated: 20),

                Fixture.row("kept", project: "/p/kept", updated: 10),
        ])

        XCTAssertEqual(model.projectPickerResults("").map(\.path), ["/p/junk", "/p/kept"])
    }

    func testPickerToggleAgentTargetingAndExclusion() {
        let model = makeModel( [])
        let defaultAgent = model.settings.defaultAgent
        let other = Agent.allCases.first { $0 != defaultAgent }!

        model.commandPalettePresented = true
        model.toggleNewSessionPicker()
        XCTAssertTrue(model.newSessionPickerPresented)
        XCTAssertEqual(model.newSessionPickerAgent, defaultAgent)
        XCTAssertFalse(model.commandPalettePresented)

        // The other shortcut while open RETARGETS the panel, not dismisses it…
        model.toggleNewSessionPicker(alternateAgent: true)
        XCTAssertTrue(model.newSessionPickerPresented)
        XCTAssertEqual(model.newSessionPickerAgent, other)

        // …and the same shortcut again is a plain toggle.
        model.toggleNewSessionPicker(alternateAgent: true)
        XCTAssertFalse(model.newSessionPickerPresented)

        // Presenting any sibling panel — or the History tab — puts the picker away.
        model.toggleNewSessionPicker()
        model.showHistory()
        XCTAssertFalse(model.newSessionPickerPresented)
        XCTAssertTrue(model.historyActive)
    }
}
