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
        let wrapper = IdentityFixtureWrapper()
        let hosts = HostRegistry(entries: [
            .init(source: localSource, commandWrapper: LocalCommandWrapper()),
            .init(source: remoteSource, commandWrapper: wrapper)
        ])
        let directory = URL(fileURLWithPath: "/private/tmp/temple-p6-remote-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = FakeTerminalSurfaceFactory()
        let app = AppModel(surfaceFactory: factory, database: db,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()), stateDirectory: directory, hostRegistry: hosts)
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
        XCTAssertEqual(wrapper.calls, 1)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, [app.toolchain.launchPath(for: .claude), "--dangerously-skip-permissions", "--resume", "remote-row"])
        XCTAssertEqual(factory.created.last?.startedCommand?.cwd, "/remote/project")
        XCTAssertEqual(app.openSessions.activeTab?.host, remote)
        let catalog = TranscriptSummary(id: "catalog-only", agent: .claude,
            locator: TranscriptLocator(host: remote, path: "opaque:catalog-only"),
            modifiedAt: Date(), cwd: "/remote/catalog", firstPrompt: "Catalog")
        XCTAssertEqual(HistoryRow(catalog: catalog).project?.host, remote)
        app.openSessions.openSession(catalog)
        XCTAssertEqual(app.openSessions.activeTab?.host, remote)
        XCTAssertEqual(wrapper.calls, 2)
        XCTAssertEqual(try db.sessionState(catalog.id)?.host, remote)
        XCTAssertEqual(factory.created.last?.startedCommand?.cwd, "/remote/catalog")
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
    func catalog(_ query: CatalogQuery) -> AsyncThrowingStream<CatalogBatch, Error> { AsyncThrowingStream { $0.finish() } }
    func adopt(_ request: AdoptionRequest) async throws -> AdoptionResult { .none }
    func changes() -> AsyncThrowingStream<SourceChange, Error> {
        AsyncThrowingStream { lock.lock(); continuation = $0; lock.unlock() }
    }
    func sendChange() { lock.lock(); let stream = continuation; let values = Array(ids); lock.unlock(); stream?.yield(.sessions(values)) }
}

private final class IdentityFixtureWrapper: HostCommandWrapper, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func wrap(_ command: TerminalCommand) -> TerminalCommand {
        lock.lock(); count += 1; lock.unlock(); return command
    }
}
