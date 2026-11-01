import XCTest
@testable import TempleUI
import TempleCore
import TempleTerminalAPI
import TempleTestSupport

/// Open a session by id (docs/designs/open-existing-sessions.md section 5):
/// paste and Open; the agent and the folder asked only when they can't be
/// found; "not found" only after a complete search; every answer leads on.
@MainActor
final class OpenByIDSheetTests: XCTestCase {
    private let box = HostID(rawValue: "mac-b")
    private let id = "3f2a1c7e-0000-4000-8000-000000000001"

    private final class World {
        var lookup: SessionLookup = SessionLookup(agents: [.claude: .notFound, .codex: .notFound])
        var lookupError: Error?
        var folders: [String: OpenByIDFolder] = [:]
        var members: [Session] = []
        var opened: [String] = []
        var resumed: [ResumeRequest] = []
        var lookups = 0
        var closed = false
        var configuration: Int? = 1
    }

    private func sheet(_ world: World, host: HostID? = nil, id: String? = nil) -> OpenByIDSheetModel {
        let dependencies = OpenByIDSheetModel.Dependencies(
            hosts: { [box] in [.local, box] },
            lookup: { _, _ in
                world.lookups += 1
                if let error = world.lookupError { throw error }
                return world.lookup
            },
            checkFolder: { _, path in world.folders[path] ?? .exists(path) },
            member: { id in world.members.first { $0.id == id } },
            hasLiveTab: { _, _ in false },
            openMember: { world.opened.append($0.id) },
            resume: { world.resumed.append($0); return true },
            configuration: { host in host.isLocal ? 0 : world.configuration },
            recentFolders: { _ in [] })
        return OpenByIDSheetModel(request: OpenByIDRequest(host: host ?? box, sessionID: id ?? self.id),
                                  dependencies: dependencies) { world.closed = true }
    }

    private func locator(_ agent: Agent) -> TranscriptLocator {
        TranscriptLocator(host: box, path: "/home/b/.\(agent.rawValue)/\(id).jsonl")
    }

    private func settle(_ sheet: OpenByIDSheetModel) async {
        for _ in 0..<200 {
            if sheet.check != .checking { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("the check never finished")
    }

    func testPasteAndOpenFindsTheAgentAndFolder() async {
        let world = World()
        world.lookup = SessionLookup(agents: [.claude: .found(locator(.claude), directory: "/work/app"), .codex: .notFound])
        let sheet = sheet(world)
        XCTAssertFalse(sheet.showsAgent)
        XCTAssertFalse(sheet.showsFolder)
        sheet.confirm()
        await settle(sheet)
        XCTAssertTrue(world.closed)
        let request = try? XCTUnwrap(world.resumed.first)
        XCTAssertEqual(request?.agent, .claude)
        XCTAssertEqual(request?.host, box)
        XCTAssertEqual(request?.launchDirectory, "/work/app")
        XCTAssertEqual(request?.locator, locator(.claude))
    }

    func testNotFoundOnlyAfterACompleteSearch() async {
        let world = World()
        let complete = sheet(world)
        complete.confirm()
        await settle(complete)
        XCTAssertEqual(complete.check, .problem("No session 3f2a1c7e… on mac-b."))

        world.lookup = SessionLookup(agents: [.claude: .notFound, .codex: .cannotTell(.noStore)])
        let partial = sheet(world)
        partial.confirm()
        await settle(partial)
        guard case .problem(let line) = partial.check else { return XCTFail("\(partial.check)") }
        XCTAssertEqual(line, "Session 3f2a1c7e… isn't among Claude Code's sessions on mac-b. Not checked: Codex's sessions folder isn't there.")
        XCTAssertTrue(world.resumed.isEmpty)
    }

    func testAnUnreachableHostIsNeverNotFound() async {
        let world = World()
        world.lookupError = LocateError.transport("ssh: connect to host mac-b: Operation timed out")
        let sheet = sheet(world)
        sheet.confirm()
        await settle(sheet)
        guard case .unreachable(let line) = sheet.check else { return XCTFail("\(sheet.check)") }
        XCTAssertTrue(line.contains("couldn't reach mac-b"), line)
    }

    func testBothAgentsAskWhichThenOpen() async {
        let world = World()
        world.lookup = SessionLookup(agents: [.claude: .found(locator(.claude), directory: "/a"),
                                              .codex: .found(locator(.codex), directory: "/b")])
        let sheet = sheet(world)
        sheet.confirm()
        await settle(sheet)
        XCTAssertEqual(sheet.check, .chooseAgent)
        XCTAssertTrue(sheet.showsAgent)
        XCTAssertFalse(sheet.canOpen, "an agent must be chosen")
        sheet.agent = .codex
        sheet.confirm()
        await settle(sheet)
        XCTAssertEqual(world.resumed.first?.agent, .codex)
        XCTAssertEqual(world.resumed.first?.launchDirectory, "/b")
    }

    func testNoRecordedFolderAsksForOne() async {
        let world = World()
        world.lookup = SessionLookup(agents: [.claude: .found(locator(.claude), directory: nil), .codex: .notFound])
        let sheet = sheet(world)
        sheet.confirm()
        await settle(sheet)
        XCTAssertEqual(sheet.check, .needsFolder)
        XCTAssertTrue(sheet.showsFolder)
        XCTAssertFalse(sheet.canOpen)
        sheet.folder = "/work/typed"
        sheet.confirm()
        await settle(sheet)
        XCTAssertEqual(world.resumed.first?.launchDirectory, "/work/typed")
    }

    func testAGoneFolderSaysSo() async {
        let world = World()
        world.lookup = SessionLookup(agents: [.claude: .found(locator(.claude), directory: "/gone"), .codex: .notFound])
        world.folders["/gone"] = .missing
        let sheet = sheet(world)
        sheet.confirm()
        await settle(sheet)
        XCTAssertEqual(sheet.check, .problem("This session ran in /gone, which isn't on mac-b any more, so it can't be resumed."))
        XCTAssertTrue(world.resumed.isEmpty)
    }

    func testAMemberHereOpensWithoutLookingAndOneElsewhereOffersItsHost() async {
        let world = World()
        world.members = [Session(state: SessionState(id: id, pinned: false, archived: false, customName: nil, color: nil,
                                                     generatedTitle: nil, lastOpenedAt: nil, joinedVia: .opened, joinedAt: nil,
                                                     agent: .claude, host: box, directory: "/work/app"))]
        let here = sheet(world)
        here.confirm()
        XCTAssertEqual(world.opened, [id])
        XCTAssertEqual(world.lookups, 0)

        world.opened = []
        let elsewhere = sheet(world, host: .local)
        elsewhere.confirm()
        XCTAssertEqual(elsewhere.check, .elsewhere(box))
        elsewhere.openElsewhere()
        XCTAssertEqual(world.opened, [id])
    }

    func testAnAnswerForAChangedHostOrIdOpensNothing() async {
        let world = World()
        world.lookup = SessionLookup(agents: [.claude: .found(locator(.claude), directory: "/w"), .codex: .notFound])
        let sheet = sheet(world)
        sheet.confirm()
        world.configuration = 2
        await settle(sheet)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(world.resumed.isEmpty, "the host's configuration changed while it looked")

        world.configuration = 3
        let edited = self.sheet(world)
        edited.confirm()
        edited.sessionID = "another"
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(world.resumed.isEmpty, "the id changed while it looked")
        XCTAssertEqual(edited.check, .idle)
    }

    func testWholeIDsOnly() {
        XCTAssertTrue(OpenByIDSheetModel.isSessionID(" 3F2A1C7E-0000-4000-8000-000000000001 "))
        XCTAssertFalse(OpenByIDSheetModel.isSessionID("3f2a1c7e"))
        XCTAssertEqual(OpenByIDSheetModel.normalized("3F2A1C7E-0000-4000-8000-000000000001"), id)
    }

    func testSomethingThatIsntAnIdAsksNoHost() {
        let world = World()
        let sheet = sheet(world, id: "fix login")
        sheet.confirm()
        guard case .problem(let line) = sheet.check else { return XCTFail("\(sheet.check)") }
        XCTAssertTrue(line.hasPrefix("That isn't a session id."), line)
        XCTAssertEqual(world.lookups, 0)
    }

    func testAChosenAgentGoneSinceIsSaidNotSwapped() async {
        let world = World()
        world.lookup = SessionLookup(agents: [.claude: .found(locator(.claude), directory: "/a"),
                                              .codex: .found(locator(.codex), directory: "/b")])
        let sheet = sheet(world)
        sheet.confirm()
        await settle(sheet)
        sheet.agent = .codex
        world.lookup = SessionLookup(agents: [.claude: .found(locator(.claude), directory: "/a"), .codex: .notFound])
        sheet.confirm()
        await settle(sheet)
        XCTAssertTrue(world.resumed.isEmpty, "never opens the other agent's session in its place")
        guard case .problem(let line) = sheet.check else { return XCTFail("\(sheet.check)") }
        XCTAssertTrue(line.hasPrefix("The Codex session isn't on mac-b any more"), line)
    }

    func testAChosenAgentThatCouldntBeCheckedIsNotCalledGone() async {
        let world = World()
        world.lookup = SessionLookup(agents: [.claude: .found(locator(.claude), directory: "/a"),
                                              .codex: .found(locator(.codex), directory: "/b")])
        let sheet = sheet(world)
        sheet.confirm()
        await settle(sheet)
        sheet.agent = .codex
        world.lookup = SessionLookup(agents: [.claude: .found(locator(.claude), directory: "/a"),
                                              .codex: .cannotTell(.unreadable("permission denied"))])
        sheet.confirm()
        await settle(sheet)
        XCTAssertTrue(world.resumed.isEmpty)
        guard case .problem(let line) = sheet.check else { return XCTFail("\(sheet.check)") }
        XCTAssertTrue(line.hasPrefix("Temple couldn't check for the Codex session on mac-b this time"), line)
        XCTAssertEqual(sheet.agent, .codex, "the choice stands")
    }

    func testShortcutsOpenNothingOnceTheSheetCantAct() {
        let world = World()
        world.members = [Session(state: SessionState(id: id, pinned: false, archived: false, customName: nil, color: nil,
                                                     generatedTitle: nil, lastOpenedAt: nil, joinedVia: .opened, joinedAt: nil,
                                                     agent: .claude, host: box, directory: "/work/app"))]
        var acting = true
        let dependencies = OpenByIDSheetModel.Dependencies(
            hosts: { [box] in [.local, box] }, lookup: { _, _ in world.lookup },
            checkFolder: { _, path in .exists(path) }, member: { id in world.members.first { $0.id == id } },
            hasLiveTab: { _, _ in false }, openMember: { world.opened.append($0.id) },
            resume: { world.resumed.append($0); return true }, configuration: { _ in 1 },
            canAct: { acting }, recentFolders: { _ in [] })
        let here = OpenByIDSheetModel(request: OpenByIDRequest(host: box, sessionID: id), dependencies: dependencies) {}
        acting = false
        here.confirm()
        XCTAssertTrue(world.opened.isEmpty, "a member's shortcut is gated too")

        acting = true
        let elsewhere = OpenByIDSheetModel(request: OpenByIDRequest(host: .local, sessionID: id), dependencies: dependencies) {}
        elsewhere.confirm()
        XCTAssertEqual(elsewhere.check, .elsewhere(box))
        acting = false
        elsewhere.openElsewhere()
        XCTAssertTrue(world.opened.isEmpty, "Open it is gated too")
    }
}
