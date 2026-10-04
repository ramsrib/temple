import XCTest
import Foundation
@testable import TempleCore
@testable import TempleUI
import TempleTerminalAPI

@MainActor
final class RemoteHostSeamTests: XCTestCase {
    func testThrowingLauncherRetainsFailureWithoutSurfaceAndCanReopen() throws {
        let remote = HostID(rawValue: "throwing-host")
        let launcher = ThrowingFixtureLauncher()
        let factory = FakeTerminalSurfaceFactory()
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            launcherForHost: { $0 == remote ? launcher : nil })
        let summary = TranscriptSummary(id: "unjoined", agent: .claude,
            locator: TranscriptLocator(host: remote, path: "opaque:unjoined"),
            modifiedAt: Date(), cwd: "/remote/project")
        model.openSession(summary)
        let tab = try XCTUnwrap(model.activeTab)
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(tab.activity, .exited(status: -1))
        XCTAssertEqual(tab.launchPreparationError, "The host could not prepare this session.")
        XCTAssertNil(tab.surface)
        XCTAssertTrue(factory.created.isEmpty)
        model.closeActiveTab()
        XCTAssertTrue(model.tabs.isEmpty)
        model.reopenLastClosedTab()
        let reopened = try XCTUnwrap(model.activeTab)
        XCTAssertNotEqual(reopened.id, tab.id)
        XCTAssertEqual(reopened.host, remote)
        XCTAssertEqual(reopened.activity, .exited(status: -1))
        XCTAssertEqual(reopened.launchPreparationError, tab.launchPreparationError)
        XCTAssertNil(reopened.surface)
        XCTAssertTrue(factory.created.isEmpty)
        launcher.shouldThrow = false
        model.activate(reopened)
        XCTAssertNil(reopened.launchPreparationError)
        XCTAssertFalse(reopened.commandWasSuspect)
        XCTAssertTrue(reopened.hasSurface)
        XCTAssertEqual(reopened.activity, .running)
        model.closeActiveTab()
        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testRemoteDirectoryEvidenceDoesNotConsultTheMac() async throws {
        let remote = HostID(rawValue: "remote-directory")
        let path = "/not-on-this-mac/project"
        let summary = TranscriptSummary(id: "remote-dir", agent: .claude,
            locator: TranscriptLocator(host: remote, path: "opaque:dir"), modifiedAt: Date(), cwd: path)
        let local = TranscriptSummary(id: "local-dir", agent: .claude,
            locator: TranscriptLocator(host: .local, path: "opaque:dir"), modifiedAt: Date(), cwd: path)
        let classified = HistoryModel.classify([local, summary], exists: [:]) { key in
            key.host.isLocal ? .missing : .unknown
        }
        XCTAssertEqual(classified.kept.map(\.id), [summary.id])
        XCTAssertEqual(classified.noise, [HistoryKey(local)])
        XCTAssertEqual(classified.exists.count, 2)
        for evidence in [DirectoryEvidence.exists, .unknown, .missing] {
            let factory = FakeTerminalSurfaceFactory()
            let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
                runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
                launcherForHost: { _ in RemoteFixtureLauncher() }, directoryEvidence: { _ in evidence })
            var recorded: String?
            model.launchDirectoryHandler = { _, _, directory in recorded = directory }
            model.openSession(summary)
            model.drainLaunchResults()
            // A host that cannot report where its launch ran records nothing,
            // whatever its folder evidence says (D4: unknown stays unknown).
            XCTAssertNil(recorded)
            XCTAssertFalse(model.activeTab?.commandWasSuspect ?? true)
            // Folder evidence never gates a spawn: the launcher's `prepare`
            // proves a folder gone, or its command must `cd` or exit.
            let surface = try XCTUnwrap(factory.created.last)
            surface.simulateExit(status: 1)
            // After an exit, the owning host's evidence (never this Mac's)
            // names a deleted folder.
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(model.activeTab?.missingWorkingDirectory, evidence == .missing ? path : nil, "\(evidence)")
            XCTAssertFalse(model.activeTab?.commandWasSuspect ?? true)
        }
    }

    func testAFakeRemoteSourceDrivesRowsEndToEnd() async throws {
        let remote = HostID(rawValue: "fake-host")
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "remote-row", via: .imported, core: SessionCore(host: remote))
        try db.join(sessionID: "local-row", via: .imported,
                    core: SessionCore(directory: "/local", title: "Local facts"))
        let remoteSource = RemoteFixtureSource(host: remote)
        let localSource = RemoteFixtureSource(host: .local)
        let launcher = RemoteFixtureLauncher()
        let hosts = HostRegistry(entries: [
            .init(source: localSource, launcher: LocalHostLauncher(binaryPath: { _ in "/mac/only/agent" }, folderEvidence: { _ in .unknown })),
            .init(source: remoteSource, launcher: launcher)
        ])
        let directory = URL(fileURLWithPath: "/private/tmp/temple-p6-remote-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = FakeTerminalSurfaceFactory()
        let settings = SettingsStore(defaults: Fixture.uniqueDefaults())
        settings.claudePath = "/missing/local/claude"
        settings.codexPath = "/missing/local/codex"
        let app = AppModel(surfaceFactory: factory, database: db,
            settings: settings, hostRegistry: hosts)
        app.start()
        let deadline = Date().addingTimeInterval(3)
        while app.sessions.first(where: { $0.id == "remote-row" })?.state.title == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let row = try XCTUnwrap(app.sessions.first { $0.id == "remote-row" })
        XCTAssertEqual(row.host, remote)
        XCTAssertEqual(row.agent, .claude)
        XCTAssertEqual(row.directory, "/remote/project")
        XCTAssertEqual(row.displayTitle, "Remote prompt")
        XCTAssertEqual(row.transcript, TranscriptLocator(host: remote, path: "opaque:remote-row"))
        XCTAssertNil(row.transcript?.localURL)
        XCTAssertEqual(try db.sessionState(row.id)?.directorySource, .transcript)
        XCTAssertEqual(try db.sessionState(row.id)?.title, "Remote prompt")
        XCTAssertEqual(try db.sessionState(row.id)?.transcriptPath, "opaque:remote-row")
        XCTAssertEqual(remoteSource.requested, ["remote-row"])
        XCTAssertEqual(localSource.requested, ["local-row"])
        XCTAssertEqual(app.sessions.first { $0.id == "local-row" }?.displayTitle, "Local facts")
        app.openSessions.openSession(row)
        app.openSessions.drainLaunchResults()
        // This host's launcher cannot report where it ran, so the folder stays
        // the transcript's: a remote spawn never claims one (D4).
        XCTAssertEqual(try db.sessionState(row.id)?.directorySource, .transcript)
        XCTAssertEqual(launcher.specs.count, 1)
        XCTAssertEqual(factory.created.last?.startedCommand?.agentArgv, ["remote-transport", "fake-host", "/remote/bin/claude", "--resume", "remote-row"])
        XCTAssertEqual(factory.created.last?.startedCommand?.cwd, "/transport")
        XCTAssertEqual(app.openSessions.activeTab?.host, remote)
        var catalogRows: [TranscriptSummary] = []
        for try await batch in remoteSource.catalog(CatalogQuery()) {
            if case .sessions(let rows, _, _) = batch { catalogRows += rows }
        }
        let catalog = try XCTUnwrap(catalogRows.first)
        XCTAssertEqual(HistoryRow(catalog: catalog).project?.host, remote)
        app.openSessions.openSession(catalog)
        XCTAssertEqual(app.openSessions.activeTab?.host, remote)
        XCTAssertEqual(launcher.specs.count, 2)
        XCTAssertEqual(try db.sessionState(catalog.id)?.host, remote)
        XCTAssertEqual(launcher.specs.last?.directory, "/remote/catalog")
        let codex = app.openSessions.newSession(agent: .codex,
            project: ProjectKey(host: remote, path: "/remote/new"))
        let adoptionDeadline = Date().addingTimeInterval(3)
        while codex.sessionID == nil, Date() < adoptionDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(codex.sessionID, "remote-adopted")
        XCTAssertEqual(try db.sessionState("remote-adopted")?.host, remote)
        XCTAssertEqual(launcher.specs.last?.mode, .new(sessionID: nil))
        XCTAssertEqual(factory.created.last?.startedCommand?.agentArgv, ["remote-transport", "fake-host", "/remote/bin/codex"])
        for surface in factory.created {
            let command = try XCTUnwrap(surface.startedCommand)
            XCTAssertFalse(command.argv.contains { $0.contains("/mac/") || $0.contains("/missing/local/") })
            XCTAssertEqual(command.cwd, "/transport")
        }
        let localLaunch = try XCTUnwrap(hosts.entry(for: .local)).launcher.prepare(
            AgentLaunchSpec(agent: .claude, mode: .resume(sessionID: "local-row"), directory: "/local", host: .local))
        XCTAssertEqual(localLaunch.displayArgv.first, "/mac/only/agent")
        localLaunch.result?.cancel()
        // Fills do not replace facts on the next remote observation.
        remoteSource.sendChange(TranscriptLocator(host: remote, path: "opaque:remote-row"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try db.sessionState(row.id)?.title, "Remote prompt")
        await withCheckedContinuation { continuation in app.drainForQuit { continuation.resume() } }
    }

    // MARK: Duplicate ids across hosts (0b)

    func testTheOverlayRefusesAJoinForAnotherHostsRowAndAnImportReportsIt() throws {
        let db = try TempleDB.inMemory()
        let remote = HostID(rawValue: "box")
        try db.join(sessionID: "shared", via: .imported, agent: .codex, core: SessionCore(host: remote, title: "Remote row"))
        let overlay = SessionOverlayStore(db: db)
        XCTAssertEqual(overlay.join("shared", via: .opened, agent: .codex).conflict, .host(remote))
        XCTAssertEqual(overlay.join("shared", via: .opened, agent: .claude, core: SessionCore(host: remote)).conflict, .agent(.codex))
        XCTAssertTrue(overlay.join("shared", via: .opened, core: SessionCore(host: remote)).isJoined)
        let summary = TranscriptSummary(id: "shared", agent: .codex, locator: TranscriptLocator(host: .local, path: "/l/x.jsonl"),
                                        modifiedAt: Date(), cwd: "/l", firstPrompt: "Local copy")
        let outcomes = SessionOverlayStore(db: db).import([summary])
        guard case .failed(let error) = outcomes.first, outcomes.count == 1 else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(error as? TempleDBError, .hostConflict(existing: remote))
        XCTAssertEqual(try db.sessionState("shared")?.title, "Remote row")
        XCTAssertEqual(try db.sessionState("shared")?.host, remote)
    }

    func testATabRefusedAtJoinStartsNothingAndSaysWhere() throws {
        let remote = HostID(rawValue: "box")
        let factory = FakeTerminalSurfaceFactory()
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            launcherForHost: { _ in RemoteFixtureLauncher() }, directoryEvidence: { _ in .exists })
        var opens: [SessionOpen] = []
        model.openedHandler = { open in opens.append(open); return .refused(.host(remote)) }
        var touched: [String] = []
        model.touchHandler = { id, _, _ in touched.append(id) }
        model.openSession(TranscriptSummary(id: "dup", agent: .claude, locator: TranscriptLocator(host: .local, path: "/l/dup.jsonl"),
                                            modifiedAt: Date(), cwd: "/l"))
        let tab = try XCTUnwrap(model.activeTab)
        XCTAssertEqual(opens.map(\.id), ["dup"])
        XCTAssertEqual(opens.first?.host, .local)
        XCTAssertEqual(opens.first?.locator, TranscriptLocator(host: .local, path: "/l/dup.jsonl"))
        XCTAssertTrue(factory.created.isEmpty, "no spawn for a session another host owns")
        XCTAssertEqual(tab.launchPreparationError, "Already in Temple on box.")
        XCTAssertEqual(tab.activity, .exited(status: -1))
        XCTAssertTrue(touched.isEmpty)
    }

    func testARefusedAdoptionKeepsTheTabProvisional() throws {
        let remote = HostID(rawValue: "box")
        let model = OpenSessionsModel(surfaceFactory: FakeTerminalSurfaceFactory(), appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            directoryEvidence: { _ in .exists })
        var result: JoinResult = .refused(.host(remote))
        model.openedHandler = { _ in result }
        var directories: [String] = []
        model.launchDirectoryHandler = { id, _, _ in directories.append(id) }
        let tab = model.newSession(agent: .codex, project: Fixture.key("/tmp"))
        XCTAssertTrue(tab.isProvisional)
        model.adopt(sessionID: "codex-dup", for: tab.id)
        XCTAssertNil(tab.sessionID)
        XCTAssertTrue(tab.isProvisional)
        XCTAssertTrue(directories.isEmpty)
        result = .joined
        model.adopt(sessionID: "codex-own", for: tab.id)
        XCTAssertEqual(tab.sessionID, "codex-own")
        XCTAssertFalse(tab.isProvisional)
    }

    func testTabWritesCarryTheTabsHostSoAnotherHostsRowIsLeftAlone() async throws {
        let db = try TempleDB.inMemory()
        let remote = HostID(rawValue: "box")
        try db.join(sessionID: "r", via: .imported, core: SessionCore(host: remote, title: "Remote"))
        let overlay = SessionOverlayStore(db: db)
        overlay.titleFlushDelay = 0
        overlay.touch("r", host: .local, at: Date(timeIntervalSince1970: 2_000_000_000))
        overlay.observeLaunchDirectory("r", host: .local, "/local")
        overlay.recordGeneratedTitle("Local tab title", for: "r", host: .local)
        overlay.flushPendingTitles()
        overlay.flushPendingTouches()
        overlay.recordOpened("r", host: .local)
        let row = try XCTUnwrap(db.sessionState("r"))
        XCTAssertEqual(row.title, "Remote")
        XCTAssertNil(row.lastActiveAt)
        XCTAssertNil(row.directory)
        XCTAssertNil(row.lastOpenedAt)
        XCTAssertNil(overlay.rows["r"]?.lastActiveAt)
        XCTAssertEqual(overlay.leave([SessionKey(id: "r", host: .local)]), [])
        XCTAssertEqual(overlay.leave([SessionKey(id: "r", host: remote)]), ["r"])
    }
}

private final class RemoteFixtureSource: HostSessionSource, @unchecked Sendable {
    let host: HostID
    let capabilities: Set<HostCapability> = [.liveChanges, .catalog]
    private let lock = NSLock()
    private var ids: Set<String> = []
    private var continuation: AsyncThrowingStream<SourceChange, Error>.Continuation?
    init(host: HostID) { self.host = host }
    var requested: Set<String> { lock.lock(); defer { lock.unlock() }; return ids }
    private static let signature = TranscriptSignature(modifiedAt: Date(timeIntervalSince1970: 123), size: 10, identity: 0)
    func locate(_ requests: [LocateRequest]) async throws -> LocateResult {
        lock.lock(); ids.formUnion(requests.map(\.id)); lock.unlock()
        var candidates: [String: [TranscriptCandidate]] = [:]
        for request in requests {
            candidates[request.id] = host.isLocal ? [] : [TranscriptCandidate(
                locator: TranscriptLocator(host: host, path: "opaque:\(request.id)"), agent: .claude,
                role: .selected, stat: .present(Self.signature))]
        }
        return LocateResult(coverage: 1, candidates: candidates, complete: Set(Agent.allCases), sharedRevision: [:])
    }
    func read(_ locator: TranscriptLocator, agent: Agent, expecting id: String, facts: Bool) async throws -> TranscriptRead {
        guard !host.isLocal else { throw TranscriptReadError.missing }
        let summary = facts ? TranscriptSummary(id: id, agent: .claude, locator: locator,
            modifiedAt: Date(timeIntervalSince1970: 123), cwd: "/remote/project", firstPrompt: "Remote prompt") : nil
        return TranscriptRead(identity: .verified, summary: summary, signature: Self.signature, bytesRead: 10, sharedRevision: nil)
    }
    func directoryEvidence(_ path: String) async -> DirectoryEvidence { host.isLocal ? .missing : .exists }
    func catalog(_ query: CatalogQuery) -> AsyncThrowingStream<CatalogBatch, Error> {
        AsyncThrowingStream { stream in
            if !host.isLocal {
                let summary = TranscriptSummary(id: "catalog-only", agent: .claude,
                    locator: TranscriptLocator(host: host, path: "opaque:catalog-only"),
                    modifiedAt: Date(), cwd: "/remote/catalog", firstPrompt: "Catalog")
                stream.yield(.sessions([summary], read: 1, total: 1))
            }
            stream.finish()
        }
    }
    func adopt(_ request: AdoptionRequest) async throws -> AdoptionResult {
        .adopted(id: "remote-adopted", locator: TranscriptLocator(host: host, path: "opaque:remote-adopted"))
    }
    func changes() -> AsyncThrowingStream<SourceChange, Error> {
        AsyncThrowingStream { lock.lock(); continuation = $0; lock.unlock() }
    }
    func sendChange(_ locator: TranscriptLocator) {
        lock.lock(); let stream = continuation; lock.unlock()
        stream?.yield(.transcripts(ids: [], locators: [locator]))
    }
}

@MainActor
private final class RemoteFixtureLauncher: HostLauncher {
    var specs: [AgentLaunchSpec] = []
    func prepare(_ spec: AgentLaunchSpec) throws -> AgentLaunch {
        let command = try command(for: spec)
        return AgentLaunch(command: command, displayArgv: command.argv, result: nil)
    }
    func command(for spec: AgentLaunchSpec) throws -> TerminalCommand {
        specs.append(spec)
        let args: [String]
        switch spec.mode {
        case .resume(let id): args = Array(spec.agent.resumeArgv(sessionID: id).dropFirst())
        case .new(let id): args = id.map { ["--session-id", $0] } ?? []
        }
        return TerminalCommand(argv: ["remote-transport", spec.host.rawValue, "/remote/bin/" + spec.agent.binaryName] + args,
            cwd: "/transport")
    }
    func availability(_ agent: Agent) -> LaunchAvailability { .available }
}

@MainActor
private final class ThrowingFixtureLauncher: HostLauncher {
    struct PreparationError: LocalizedError {
        var errorDescription: String? { "The host could not prepare this session." }
    }
    var shouldThrow = true
    func prepare(_ spec: AgentLaunchSpec) throws -> AgentLaunch {
        if shouldThrow { throw PreparationError() }
        return AgentLaunch(command: TerminalCommand(argv: ["remote-transport"], cwd: "/transport"),
                           displayArgv: ["remote-transport"], result: nil)
    }
    func availability(_ agent: Agent) -> LaunchAvailability { .available }
}
