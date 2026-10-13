import XCTest
import TempleCore
import TempleUI
@testable import TempleCLIKit

final class ArgumentParserTests: XCTestCase {
    private func parse(_ line: String) -> ParseResult {
        ArgumentParser.parse(line.split(separator: " ").map(String.init))
    }

    func testTheShapesADR034Names() {
        XCTAssertEqual(parse("projects ls"), .run(Invocation(noun: .projects, verb: .ls)))
        XCTAssertEqual(parse("projects get /p"), .run(Invocation(noun: .projects, verb: .get, argument: "/p")))
        XCTAssertEqual(parse("sessions ls --project . --cli codex --json"),
                       .run(Invocation(noun: .sessions, verb: .ls, project: ".", cli: .codex, json: true)))
        XCTAssertEqual(parse("sessions new"), .run(Invocation(noun: .sessions, verb: .new)))
        XCTAssertEqual(parse("sessions new ~/repo --cli CLAUDE"),
                       .run(Invocation(noun: .sessions, verb: .new, argument: "~/repo", cli: .claude)))
        XCTAssertEqual(parse("sessions close abc --force"),
                       .run(Invocation(noun: .sessions, verb: .close, argument: "abc", force: true)))
        XCTAssertEqual(parse("history search keychain --cli claude"),
                       .run(Invocation(noun: .history, verb: .search, argument: "keychain", cli: .claude)))
        XCTAssertEqual(ArgumentParser.parse(["history", "search", "--", "-x"]),
                       .run(Invocation(noun: .history, verb: .search, argument: "-x")))
    }

    func testHelp() {
        XCTAssertEqual(parse("--help"), .help(nil))
        XCTAssertEqual(parse("sessions -h"), .help(.sessions))
        XCTAssertEqual(parse("history ls --help"), .help(.history))
    }

    func testMistakesAreUsageErrorsNotGuesses() {
        let usage: [String] = [
            "", "tabs ls", "sessions", "sessions list", "history new", "history open abc",
            "sessions get", "sessions get a b", "projects ls extra", "sessions new a b",
            "sessions ls --cli gemini", "sessions ls --cli", "sessions ls --bogus",
            "history ls --force", "sessions close abc --project /p", "projects get /p --cli codex",
        ]
        for line in usage {
            guard case .usageError = parse(line) else { return XCTFail("\"\(line)\" should be a usage error") }
        }
    }
}

@MainActor
final class TempleCLITests: XCTestCase {
    private var out: [String] = []
    private var err: [String] = []
    private var sent: [ControlRequest] = []
    private var launches = 0
    private var directory: URL!

    override func setUpWithError() throws {
        out = []; err = []; sent = []; launches = 0
        directory = URL(fileURLWithPath: "/private/tmp/temple-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func run(_ arguments: [String], answer: ControlResponse = ControlResponse(),
                     failure: ControlClientError? = nil, history: [HistoryRow] = []) async -> TempleCLI.Exit {
        let console = TempleCLI.Console(out: { self.out.append($0) }, err: { self.err.append($0) })
        let transport = TempleCLI.Transport(
            send: { request, _ in
                self.sent.append(request)
                if let failure { throw failure }
                return answer
            },
            ensureRunning: { self.launches += 1 })
        return await TempleCLI.main(["temple"] + arguments, console: console, transport: transport,
                                    history: { HistoryReader.Result(rows: history, failures: []) },
                                    workingDirectory: directory.path)
    }

    func testReadsNeverStartTemple() async {
        _ = await run(["sessions", "ls"])
        _ = await run(["projects", "ls"])
        _ = await run(["sessions", "close", "abc"])
        XCTAssertEqual(launches, 0)
        _ = await run(["sessions", "open", "abc"])
        XCTAssertEqual(launches, 1, "an action starts it")
    }

    func testANotRunningTempleSaysSo() async {
        let exit = await run(["sessions", "ls"], failure: .notRunning)
        XCTAssertEqual(exit, .failure)
        XCTAssertEqual(err, ["temple: Temple isn't running"])
        XCTAssertTrue(out.isEmpty)
    }

    func testTheAppsRefusalIsTheMessageAndAFailure() async {
        let exit = await run(["sessions", "close", "abc"],
                             answer: .failure(.refused, "Its agent is working. Pass --force to close it anyway."))
        XCTAssertEqual(exit, .failure)
        XCTAssertEqual(err.first, "temple: Its agent is working. Pass --force to close it anyway.")
        XCTAssertEqual(sent.first?.force, false)
    }

    func testNewSendsAResolvedFolderAndRefusesOneThatIsNot() async throws {
        let sub = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = await run(["sessions", "new", "repo", "--cli", "codex"],
                      answer: ControlResponse(session: ControlSession(id: nil, cli: .codex, project: sub.path,
                                                                      title: "New Codex session", state: .running, focused: true)))
        XCTAssertEqual(sent.last?.directory, sub.path)
        XCTAssertEqual(sent.last?.cli, .codex)
        XCTAssertEqual(out.last, "Started a pending Codex session (New Codex session)")

        _ = await run(["sessions", "new"])
        XCTAssertEqual(sent.last?.directory, directory.path, "no folder: here")

        let count = sent.count
        let exit = await run(["sessions", "new", "missing"])
        XCTAssertEqual(exit, .failure)
        XCTAssertEqual(sent.count, count, "nothing sent for a folder that is not one")
    }

    func testJSONSaysAPendingIDIsNull() async {
        let pending = ControlSession(id: nil, cli: .codex, project: "/p", title: "t", state: .running, focused: false)
        _ = await run(["sessions", "ls", "--json"], answer: ControlResponse(sessions: [pending]))
        XCTAssertTrue(out.joined().contains("\"id\" : null"), out.joined())
    }

    func testTheTableMarksTheSessionOnScreen() async {
        let sessions = [
            ControlSession(id: "a", cli: .claude, project: "/p/one", title: "first", state: .idle, focused: false),
            ControlSession(id: nil, cli: .codex, project: "/p/two", title: "second", state: .running, focused: true),
        ]
        _ = await run(["sessions", "ls"], answer: ControlResponse(sessions: sessions))
        XCTAssertEqual(out.joined(separator: "\n"), """
              ID       CLI     STATE    PROJECT  TITLE
              a        claude  idle     one      first
            * pending  codex   running  two      second
            """)
    }

    // MARK: History

    private func row(_ id: String, agent: Agent = .claude, project: String?, title: String,
                     host: HostID = .local) -> HistoryRow {
        HistoryRow(member: Session(state: SessionState(
            id: id, pinned: false, archived: false, customName: nil, color: nil, generatedTitle: nil,
            lastOpenedAt: nil, joinedVia: .imported, joinedAt: nil, agent: agent, host: host,
            directory: project, directorySource: project == nil ? nil : .tab, title: title,
            lastActiveAt: Date(timeIntervalSince1970: 1_700_000_000))))
    }

    func testHistoryFiltersAndSearches() async throws {
        // Ids and terms no temp folder's random name can contain.
        let rows = [row("first-id", project: directory.path, title: "fix keychain"),
                    row("second-id", agent: .codex, project: "/elsewhere", title: "keychain too"),
                    row("third-id", project: "/elsewhere", title: "unrelated")]
        _ = await run(["history", "ls", "--project", ".", "--json"], history: rows)
        XCTAssertEqual(try ids(), ["first-id"])
        _ = await run(["history", "search", "KEYCHAIN", "--cli", "codex", "--json"], history: rows)
        XCTAssertEqual(try ids(), ["second-id"])
        _ = await run(["history", "search", "third-i", "--json"], history: rows)
        XCTAssertEqual(try ids(), ["third-id"], "an id prefix finds its session")
        XCTAssertEqual(launches + sent.count, 0, "history never asks the app")
    }

    func testHistoryGet() async {
        let rows = [row("c1", project: "/p", title: "one"), row("dup", project: "/p", title: "here"),
                    row("dup", project: "/p", title: "there", host: HostID(rawValue: "box"))]
        let exit = await run(["history", "get", "c1"], history: rows)
        XCTAssertEqual(exit, .ok)
        XCTAssertTrue(out.last?.contains("resume:  claude --resume c1") == true, out.last ?? "")
        let duplicate = await run(["history", "get", "dup"], history: rows)
        XCTAssertEqual(duplicate, .failure)
        XCTAssertEqual(err.last, "temple: 2 sessions have the id dup.")
        let missing = await run(["history", "get", "nope"], history: rows)
        XCTAssertEqual(missing, .failure)
    }

    private func ids() throws -> [String] {
        let data = Data(try XCTUnwrap(out.last).utf8)
        let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        return entries?.compactMap { $0["id"] as? String } ?? []
    }

    func testOnlyTheEnclosingAppIsStartedAndOnlyWhenNoTempleRuns() {
        let app = URL(fileURLWithPath: "/Applications/Temple.app")
        XCTAssertEqual(AppLauncher.plan(serving: true, redirected: false, app: app, running: [.init(pid: 1, path: nil)]), .ready)
        XCTAssertEqual(AppLauncher.plan(serving: false, redirected: false, app: app, running: []), .launch(app))
        guard case .refuse = AppLauncher.plan(serving: false, redirected: false, app: app,
                                              running: [.init(pid: 7, path: "/Users/x/Temple.app")]) else {
            return XCTFail("a Temple that runs but does not answer is reported, never joined by a second")
        }
        guard case .refuse = AppLauncher.plan(serving: false, redirected: true, app: app, running: []),
              case .refuse = AppLauncher.plan(serving: false, redirected: false, app: nil, running: []) else {
            return XCTFail("a redirected state directory or a dev build starts nothing")
        }
    }

    func testTheShippedAppIsTheOneStarted() {
        XCTAssertEqual(AppLauncher.enclosingApp(executable: "/Applications/Temple.app/Contents/Helpers/temple")?.path,
                       "/Applications/Temple.app")
        XCTAssertNil(AppLauncher.enclosingApp(executable: "/repo/.build/debug/temple"), "a dev build starts nothing")
        XCTAssertNil(AppLauncher.enclosingApp(executable: "/Applications/Temple.app/Contents/MacOS/temple"))
    }
}
