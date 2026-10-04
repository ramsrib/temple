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

    func testRemoteDirectoryEvidenceDoesNotConsultTheMac() throws {
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
        XCTAssertEqual(classified.noise, [local.id])
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
            XCTAssertEqual(recorded, evidence == .exists ? path : nil)
            XCTAssertFalse(model.activeTab?.commandWasSuspect ?? true)
            guard evidence != .missing else {
                // The owning host says the folder is gone: nothing is started.
                XCTAssertTrue(factory.created.isEmpty)
                XCTAssertEqual(model.activeTab?.launchPreparationError, "The folder \(path) no longer exists.")
                continue
            }
            let surface = try XCTUnwrap(factory.created.last)
            surface.simulateExit(status: 1)
            XCTAssertNil(model.activeTab?.missingWorkingDirectory)
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
            .init(source: localSource, launcher: LocalHostLauncher(binaryPath: { _ in "/mac/only/agent" })),
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
        XCTAssertEqual(try db.sessionState(row.id)?.directorySource, .tab)
        XCTAssertEqual(launcher.specs.count, 1)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["remote-transport", "fake-host", "/remote/bin/claude", "--resume", "remote-row"])
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
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["remote-transport", "fake-host", "/remote/bin/codex"])
        for surface in factory.created {
            let command = try XCTUnwrap(surface.startedCommand)
            XCTAssertFalse(command.argv.contains { $0.contains("/mac/") || $0.contains("/missing/local/") })
            XCTAssertEqual(command.cwd, "/transport")
        }
        let localCommand = try XCTUnwrap(hosts.entry(for: .local)).launcher.command(for:
            AgentLaunchSpec(agent: .claude, mode: .resume(sessionID: "local-row"), directory: "/local", host: .local))
        XCTAssertEqual(localCommand.argv.first, "/mac/only/agent")
        // Fills do not replace facts on the next remote observation.
        remoteSource.sendChange()
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
        let failures = SessionOverlayStore(db: db).importPreparedSessions([PreparedSessionImport(
            id: summary.id, agent: summary.agent, locator: summary.locator, core: SessionCore(filling: summary))])
        XCTAssertEqual((failures["shared"] as? TempleDBError), .hostConflict(existing: remote))
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
        let tab = model.newSession(agent: .codex, projectPath: "/tmp")
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
    private func record(_ requests: [ResolutionRequest]) {
        lock.lock(); ids.formUnion(requests.map(\.id)); lock.unlock()
    }
    func resolve(_ requests: [ResolutionRequest]) async throws -> ResolutionBatch {
        record(requests)
        let results = Dictionary(uniqueKeysWithValues: requests.map { request -> (String, ResolutionResult) in
            if host.isLocal { return (request.id, .absent) }
            let locator = TranscriptLocator(host: host, path: "opaque:\(request.id)")
            let summary = TranscriptSummary(id: request.id, agent: .claude, locator: locator,
                modifiedAt: Date(timeIntervalSince1970: 123), cwd: "/remote/project", firstPrompt: "Remote prompt")
            return (request.id, .loaded(locator, summary, []))
        })
        return ResolutionBatch(generation: 1, results: results)
    }
    func directoryEvidence(_ path: String) -> DirectoryEvidence { host.isLocal ? .missing : .exists }
    func release(_ ids: [String]) {}
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
    func sendChange() { lock.lock(); let stream = continuation; let values = Array(ids); lock.unlock(); stream?.yield(.sessions(values)) }
}

@MainActor
private final class RemoteFixtureLauncher: HostLauncher {
    var specs: [AgentLaunchSpec] = []
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
    func canLaunch(_ agent: Agent) -> Bool { true }
}

@MainActor
private final class ThrowingFixtureLauncher: HostLauncher {
    struct PreparationError: LocalizedError {
        var errorDescription: String? { "The host could not prepare this session." }
    }
    var shouldThrow = true
    func command(for spec: AgentLaunchSpec) throws -> TerminalCommand {
        if shouldThrow { throw PreparationError() }
        return TerminalCommand(argv: ["remote-transport"], cwd: "/transport")
    }
    func canLaunch(_ agent: Agent) -> Bool { true }
}
