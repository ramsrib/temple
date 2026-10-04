import XCTest
import Foundation
@testable import TempleCore
@testable import TempleUI
import TempleTerminalAPI

@MainActor
final class RemoteHostSeamTests: XCTestCase {
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
            settings: settings, stateDirectory: directory, hostRegistry: hosts)
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
