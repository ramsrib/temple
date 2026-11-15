import XCTest
@testable import TempleUI
import TempleCore
import TempleTerminalAPI

/// The handoff both new doors use (docs/designs/open-existing-sessions.md
/// section 4): a member's folder wins, anything else launches in the
/// request's, the other Temple's marks ride into the launch's join, and
/// nothing runs that Temple could not record.
@MainActor
final class ResumeRequestTests: XCTestCase {
    private func member(_ id: String, host: HostID = .local, agent: Agent = .claude, directory: String?) -> Session {
        Session(state: SessionState(id: id, pinned: false, archived: false, customName: nil, color: nil,
                                    generatedTitle: nil, lastOpenedAt: nil, joinedVia: .imported, joinedAt: nil,
                                    agent: agent, host: host, directory: directory))
    }

    private func request(_ id: String, host: HostID = .local, directory: String = "/work/peer",
                         carried: CarriedMarks? = CarriedMarks(name: "Fix login", color: "blue"),
                         note: String? = nil) -> ResumeRequest {
        ResumeRequest(host: host, agent: .claude, id: id, locator: nil, title: "Claude Code session",
                      launchDirectory: directory, carried: carried, peerTabNote: note)
    }

    func testAnOutsideSessionLaunchesInTheRequestsFolderAndCarriesItsMarks() throws {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        var opens: [SessionOpen] = []
        model.openedHandler = { opens.append($0); return .joined }
        XCTAssertTrue(model.resume(request("s1", note: "mac-b's Temple also has a tab for this session.")))
        XCTAssertEqual(factory.created.first?.startedCommand?.cwd, "/work/peer")
        XCTAssertEqual(factory.created.first?.startedCommand?.agentArgv, ["claude", "--resume", "s1"])
        XCTAssertEqual(opens.first?.via, .opened)
        XCTAssertEqual(opens.first?.carried, CarriedMarks(name: "Fix login", color: "blue"))
        XCTAssertEqual(model.activeTab?.peerTabNote, "mac-b's Temple also has a tab for this session.")
    }

    func testAMembersOwnFolderWins() throws {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.openedHandler = { _ in .joined }
        model.sessionRow = { [self] key in member(key.id, host: key.host, directory: "/work/recorded") }
        XCTAssertTrue(model.resume(request("s1", directory: "/work/peer")))
        XCTAssertEqual(factory.created.first?.startedCommand?.cwd, "/work/recorded")
    }

    func testAMemberWithNoFolderLaunchesInTheRequestsFolder() throws {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.openedHandler = { _ in .joined }
        model.sessionRow = { [self] key in member(key.id, host: key.host, directory: nil) }
        XCTAssertTrue(model.resume(request("s1", directory: "/work/peer")))
        XCTAssertEqual(factory.created.first?.startedCommand?.cwd, "/work/peer")
    }

    /// ADR-041: the same id on another host is another session. A row for
    /// it elsewhere neither refuses this launch nor lends it its folder.
    func testAnotherHostsRowWithTheSameIDIsAnotherSession() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        let elsewhere = HostID(rawValue: "elsewhere")
        model.openedHandler = { _ in .joined }
        model.sessionRow = { [self] key in key.host == elsewhere ? member(key.id, host: elsewhere, directory: "/w") : nil }
        XCTAssertTrue(model.resume(request("s1")))
        XCTAssertEqual(model.activeTab?.host, .local)
        XCTAssertEqual(factory.created.first?.startedCommand?.cwd, "/work/peer", "the request's folder, not the other host's row's")
    }

    /// This host's row for the id as the other agent's: not this session.
    func testThisHostsRowAsAnotherAgentIsRefused() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.sessionRow = { [self] key in member(key.id, host: key.host, agent: .codex, directory: "/w") }
        XCTAssertFalse(model.resume(request("s1")))
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertTrue(factory.created.isEmpty)
    }

    func testNothingRunsWhenTheJoinFailsToWrite() throws {
        struct DiskFull: Error, LocalizedError { var errorDescription: String? { "disk full" } }
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.openedHandler = { _ in .failed(DiskFull()) }
        model.resume(request("s1"))
        XCTAssertNil(factory.created.first?.startedCommand, "a session Temple couldn't record is not run")
        XCTAssertEqual(model.activeTab?.launchPreparationError, "Temple couldn't record this session: disk full")
    }

    /// A restored chip of a member with no folder recorded launches in the
    /// request's folder, not wherever it was saved.
    func testARestoredChipTakesTheRequestsFolder() throws {
        let factory = FakeTerminalSurfaceFactory()
        let persistence = UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults())
        persistence.save([PersistedTab(sessionID: "s1", agent: .claude, projectPath: "/saved/stale", title: "Saved")])
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(), persistence: persistence)
        model.openedHandler = { _ in .joined }
        model.sessionRow = { [self] key in member(key.id, host: key.host, directory: nil) }
        model.restore()
        XCTAssertTrue(factory.created.isEmpty, "inert")
        XCTAssertTrue(model.resume(request("s1", directory: "/work/peer", note: "noted")))
        XCTAssertEqual(factory.created.first?.startedCommand?.cwd, "/work/peer")
        XCTAssertEqual(model.tabs.count, 1, "the chip, not a second tab")
        XCTAssertEqual(model.activeTab?.peerTabNote, "noted")
    }

    func testNothingOpensOnceQuittingHasBegun() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.prepareForQuit()
        XCTAssertFalse(model.resume(request("s1")))
        XCTAssertTrue(model.tabs.isEmpty)
    }
}
