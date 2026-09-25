import XCTest
@testable import TempleUI
import TempleCore
import TempleTerminalAPI

/// Two things every spawned tab must get right: the shell is told it is in
/// Temple (libghostty would otherwise say `ghostty`), and the native surface is
/// released at a known point when the tab goes — not whenever ARC drops it.
@MainActor
final class SpawnEnvironmentAndReleaseTests: XCTestCase {

    func testSpawnedShellsIdentifyAsTemple() throws {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.openSession(Fixture.session("a", project: "/p/a"))

        let env = try XCTUnwrap(factory.created.first?.startedCommand?.env)
        XCTAssertEqual(env["TERM_PROGRAM"], "Temple")
        XCTAssertEqual(env["TERM_PROGRAM_VERSION"], TerminalIdentity.version)
        XCTAssertFalse(TerminalIdentity.version.isEmpty)
    }

    func testACommandsOwnEnvironmentWins() {
        // The production merge: identity filled in, a deliberate per-command
        // value left alone.
        let cmd = TerminalIdentity.apply(to: TerminalCommand(
            argv: ["x"], cwd: "/", env: ["TERM_PROGRAM": "custom", "FOO": "bar"]))
        XCTAssertEqual(cmd.env["TERM_PROGRAM"], "custom")
        XCTAssertEqual(cmd.env["TERM_PROGRAM_VERSION"], TerminalIdentity.version)
        XCTAssertEqual(cmd.env["FOO"], "bar")
        XCTAssertEqual(cmd.argv, ["x"])
    }

    func testClosingARunningTabReleasesItsSurfaceOnceItExits() throws {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.openSession(Fixture.session("a", project: "/p/a"))
        let surface = try XCTUnwrap(factory.created.first)
        let tabID = try XCTUnwrap(model.tabs.first?.id)

        model.closeTab(tabID)   // graceful fake exits synchronously → removeTab

        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(surface.releaseCount, 1)
    }

    func testRemovingAnExitedTabReleasesItsSurface() throws {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.earlyExitGraceSeconds = 0   // an exit is an exit, not a failed launch
        model.openSession(Fixture.session("a", project: "/p/a"))
        let surface = try XCTUnwrap(factory.created.first)

        surface.simulateExit(status: 0)   // agent finished → tab auto-closes

        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(surface.releaseCount, 1)
    }
}
