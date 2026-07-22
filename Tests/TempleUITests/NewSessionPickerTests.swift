import XCTest
@testable import TempleUI
import TempleCore

private struct PickerNoiseFilter: NoiseFilter {
    func isNoise(_ session: AgentSession) -> Bool { session.id == "noise" }
}

private struct PickerNoNoiseFilter: NoiseFilter {
    func isNoise(_ session: AgentSession) -> Bool { false }
}

@MainActor
final class NewSessionPickerTests: XCTestCase {
    private func makeModel(_ index: SessionIndex,
                           noise: NoiseFilter = PickerNoNoiseFilter()) -> AppModel {
        let database = try! TempleDB.inMemory()
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            indexSource: FakeIndexSource(index),
            noiseFilter: noise,
            database: database,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: SessionOverlayStore(db: database)
        )
        model.index = index
        return model
    }

    func testPickerListsProjectsByRecencyAndFiltersByPath() {
        let model = makeModel(SessionIndex(projects: [
            Project(path: "/work/api", sessions: [
                Fixture.session("a", project: "/work/api", updated: 10)]),
            Project(path: "/home/temple", sessions: [
                Fixture.session("b", project: "/home/temple", updated: 30)]),
            Project(path: "/work/site", sessions: [
                Fixture.session("c", project: "/work/site", updated: 20)]),
        ]))

        XCTAssertEqual(model.projectPickerResults("").map(\.path),
                       ["/home/temple", "/work/site", "/work/api"])
        // Any path component matches, not just the folder name.
        XCTAssertEqual(model.projectPickerResults("work").map(\.path),
                       ["/work/site", "/work/api"])
        XCTAssertEqual(model.projectPickerResults("TEMPLE").map(\.path),
                       ["/home/temple"])
    }

    func testPickerRespectsNoiseFilter() {
        let model = makeModel(SessionIndex(projects: [
            Project(path: "/p/junk", sessions: [
                Fixture.session("noise", project: "/p/junk", updated: 20)]),
            Project(path: "/p/kept", sessions: [
                Fixture.session("kept", project: "/p/kept", updated: 10)]),
        ]), noise: PickerNoiseFilter())

        XCTAssertEqual(model.projectPickerResults("").map(\.path), ["/p/kept"])
    }

    func testPickerToggleAgentTargetingAndExclusion() {
        let model = makeModel(SessionIndex(projects: []))
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

        // Presenting any sibling panel puts the picker away.
        model.toggleNewSessionPicker()
        model.toggleHistory()
        XCTAssertFalse(model.newSessionPickerPresented)
        XCTAssertTrue(model.historyPresented)
    }
}
