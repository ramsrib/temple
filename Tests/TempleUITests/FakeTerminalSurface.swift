import AppKit
import XCTest
@testable import TempleUI
import TempleTerminalAPI
import TempleCore

/// A scriptable `TerminalSurface` for lifecycle (U3) + attention (U7) tests.
@MainActor
final class FakeTerminalSurface: TerminalSurface {
    enum ExitBehavior {
        case graceful          // exits immediately on requestGracefulExit()
        case slow(TimeInterval) // exits after a delay (before a longer timeout)
        case hung              // ignores requestGracefulExit(); only terminate() kills it
    }

    let _view = NSView()
    var view: NSView { _view }
    weak var delegate: TerminalSurfaceDelegate?

    var behavior: ExitBehavior = .graceful
    var startError: Error?
    var onGracefulExit: (() -> Void)?
    private(set) var didRequestGracefulExit = false
    private(set) var didTerminate = false
    private(set) var appliedAppearances: [TerminalAppearance] = []
    private(set) var focusCount = 0
    private(set) var searches: [String] = []
    private(set) var navigations: [TerminalSearchDirection] = []
    private(set) var endSearchCount = 0
    private(set) var startedCommand: TerminalCommand?
    private(set) var releaseCount = 0

    private(set) var processState: TerminalProcessState = .notStarted {
        didSet {
            guard processState != oldValue else { return }
            delegate?.surface(self, didChangeState: processState)
        }
    }

    /// What the local launch wrapper writes to its marker when this fake
    /// "runs" it. By default it does what the shell would for a folder that
    /// exists — `ok` — and writes nothing for one that does not (tests open
    /// made-up paths); set a line to script a launcher failure.
    var wrapperMarkerLine: String?? = nil

    func start(_ command: TerminalCommand) throws {
        startedCommand = command
        if let startError { throw startError }
        processState = .running(pid: 4242)
        if let marker = command.launchMarker, let folder = command.launchFolder {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue
            let line: String? = wrapperMarkerLine ?? (exists ? "ok" : nil)
            if let line { try? Data((line + "\n").utf8).write(to: URL(fileURLWithPath: marker)) }
        }
    }

    func release() { releaseCount += 1 }

    func focus() { focusCount += 1 }

    func search(_ needle: String) { searches.append(needle) }
    func navigateSearch(_ direction: TerminalSearchDirection) { navigations.append(direction) }
    func endSearch() { endSearchCount += 1 }

    func apply(_ appearance: TerminalAppearance) {
        appliedAppearances.append(appearance)
    }

    func requestGracefulExit() {
        didRequestGracefulExit = true
        onGracefulExit?()
        switch behavior {
        case .graceful:
            exitNow(status: 0)
        case .slow(let delay):
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.exitNow(status: 0)
            }
        case .hung:
            break
        }
    }

    func terminate() {
        didTerminate = true
        exitNow(status: 9)
    }

    // Scripted events for U7.
    func simulateBell() { delegate?.surfaceDidRing(self) }
    func simulateNotification(title: String, body: String) {
        delegate?.surface(self, didPostNotification: title, body: body)
    }
    func simulateTitle(_ t: String) { delegate?.surface(self, didUpdateTitle: t) }
    func simulateSubmitInput() { delegate?.surfaceDidSubmitInput(self) }
    func simulateExit(status: Int32 = 0) { exitNow(status: status) }
    func simulateSearchStarted(needle: String?) { delegate?.surface(self, didStartSearch: needle) }
    func simulateSearchEnded() { delegate?.surfaceDidEndSearch(self) }
    func simulateSearchTotal(_ total: Int?) { delegate?.surface(self, didUpdateSearchTotal: total) }
    func simulateSearchSelected(_ selected: Int?) { delegate?.surface(self, didUpdateSearchSelected: selected) }

    private func exitNow(status: Int32) {
        guard case .running = processState else { return }
        processState = .exited(status: status)
    }
}

@MainActor
final class FakeTerminalSurfaceFactory: TerminalSurfaceFactory {
    private(set) var created: [FakeTerminalSurface] = []
    var configure: (FakeTerminalSurface) -> Void = { _ in }
    func makeSurface(appearance: TerminalAppearance) -> TerminalSurface {
        let s = FakeTerminalSurface()
        configure(s)
        created.append(s)
        return s
    }
}

/// A host engine that publishes what a test hands it (no disk, no timer).
/// `start` publishes the fixture index's resolutions; `publish` anything else.
final class FakeEngine: HostEngine, @unchecked Sendable {
    let host: HostID
    private let lock = NSLock()
    private let initial: EngineSnapshot?
    private var current: EngineSnapshot?
    private var continuations: [UUID: AsyncStream<EngineSnapshot>.Continuation] = [:]
    private var requests: [String] = []
    private var reconciles: [String] = []
    /// What `confirmAbsence` answers.
    var absent = false

    init(_ index: CatalogFixtureIndex? = nil, host: HostID = .local, snapshot: EngineSnapshot? = nil) {
        self.host = host
        self.initial = snapshot ?? index?.snapshot
    }

    var latestSnapshot: EngineSnapshot? { lock.lock(); defer { lock.unlock() }; return current }
    var requested: [String] { lock.lock(); defer { lock.unlock() }; return requests }
    var reconciled: [String] { lock.lock(); defer { lock.unlock() }; return reconciles }

    func snapshots() -> AsyncStream<EngineSnapshot> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.continuations.removeValue(forKey: token); self.lock.unlock()
            }
            lock.lock(); continuations[token] = continuation; let latest = current; lock.unlock()
            if let latest { continuation.yield(latest) }
        }
    }

    func publish(_ snapshot: EngineSnapshot) {
        lock.lock(); current = snapshot; let targets = Array(continuations.values); lock.unlock()
        targets.forEach { $0.yield(snapshot) }
    }

    func start() async { if let initial { publish(initial) } }
    func stop() async {}
    func requestResolution(_ id: String, awaitingCreation: Bool) async { lock.lock(); requests.append(id); lock.unlock() }
    func reconcileMembership(_ id: String) async { lock.lock(); reconciles.append(id); lock.unlock() }
    func confirmAbsence(_ id: String) async -> Bool { absent }
}



/// A `UserDefaults` that never touches the disk.
///
/// `UserDefaults(suiteName:)` is not a scratch object: it writes a real plist
/// into ~/Library/Preferences and nothing ever takes it away — one suite per
/// call, several per test, every run. 2,853 of them had accumulated before
/// anyone looked.
///
/// Sweeping them afterwards does not work, and was tried first: the suites are
/// still live when the bundle finishes (a `SettingsStore` under test is holding
/// one), so cfprefsd writes them back out at process exit, contents restored.
/// `removePersistentDomain` also leaves a 42-byte plist behind even when it does
/// take effect. The only reliable fix is to never create one.
///
/// Overriding the documented primitives is enough — the typed accessors are
/// defined in terms of `object(forKey:)` — but `string` and `data` are overridden
/// too, since those are the two this codebase actually reads and an Apple
/// implementation detail must not be able to quietly reopen the hole.
final class InMemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    convenience init() { self.init(suiteName: nil)! }

    override func object(forKey defaultName: String) -> Any? { storage[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { storage[defaultName] = value }
    override func removeObject(forKey defaultName: String) { storage.removeValue(forKey: defaultName) }
    override func string(forKey defaultName: String) -> String? { storage[defaultName] as? String }
    override func data(forKey defaultName: String) -> Data? { storage[defaultName] as? Data }
    override func dictionaryRepresentation() -> [String: Any] { storage }
    override func synchronize() -> Bool { true }
}

// MARK: - Fixtures

@MainActor
enum Fixture {
    static func session(_ id: String, agent: Agent = .claude, project: String,
                        title: String = "Title", updated: TimeInterval = 0) -> TranscriptSummary {
        catalogFixture(id: id, agent: agent, projectPath: project, title: title,
                     createdAt: nil, updatedAt: Date(timeIntervalSince1970: updated),
                     filePath: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
    }

    static func row(_ id: String, agent: Agent? = .claude, project: String? = nil,
                    title: String = "Title", updated: TimeInterval = 0, host: HostID = .local) -> Session {
        Session(state: SessionState(id: id, pinned: false, archived: false, customName: nil,
            color: nil, generatedTitle: nil, lastOpenedAt: nil, joinedVia: .imported,
            joinedAt: nil, agent: agent, host: host, directory: project,
            directorySource: project == nil ? nil : .tab, title: title,
            lastActiveAt: Date(timeIntervalSince1970: updated)))
    }

    static func join(_ rows: [Session], to database: TempleDB) {
        for row in rows {
            try! database.join(sessionID: row.id, via: .imported, agent: row.agent,
                core: SessionCore(host: row.host, directory: row.directory,
                    directorySource: row.state.directorySource, title: row.state.title, lastActiveAt: row.sortDate))
        }
    }

    /// This Mac's real folder check, for tests that use real directories.
    static let localDirectoryEvidence: (ProjectKey) -> DirectoryEvidence = {
        LocalHostLauncher.statEvidence($0.path)
    }

    /// Real folders exist; made-up ones ("/p") are unknown rather than missing,
    /// so a test can record launch directories and still open fake paths.
    static let existingFoldersOnly: (ProjectKey) -> DirectoryEvidence = {
        localDirectoryEvidence($0) == .exists ? .exists : .unknown
    }

    /// A local host whose folder evidence is unknown, so tests may open
    /// sessions in made-up paths ("/p/a") — the real host would refuse to
    /// start an agent in a folder that does not exist.
    static func hostsWithoutFolderEvidence() -> HostRegistry {
        HostRegistry(entries: [.init(source: FolderAgnosticSource(), launcher: LocalHostLauncher(folderEvidence: { _ in .unknown }))])
    }

    /// An isolated defaults object that never reaches the disk.
    static func uniqueDefaults() -> UserDefaults { InMemoryDefaults() }

    /// Complete member rows for tests focused on browsing a supplied index.
    static func join(_ index: CatalogFixtureIndex, to database: TempleDB) {
        for session in index.allSessions {
            try! database.join(sessionID: session.id, via: .imported,
                               agent: session.agent, locator: TranscriptLocator(localURL: session.filePath),
                               core: SessionCore(directory: session.projectPath, directorySource: .transcript,
                                                 title: session.title, lastActiveAt: session.updatedAt))
        }
    }

    /// A fresh OpenSessionsModel wired to a fake factory (isolated persistence).
    static func openModel(factory: FakeTerminalSurfaceFactory,
                          timeout: TimeInterval = 3,
                          reconciler: TempleUI.CodexAdopting? = nil,
                          defaultAgent: Agent = .claude) -> OpenSessionsModel {
        let persistence = UserDefaultsTabPersistence(defaults: uniqueDefaults())
        return OpenSessionsModel(
            surfaceFactory: factory,
            appearanceProvider: { .default },
            runtime: SessionRuntimeController(gracefulTimeout: timeout),
            registry: InMemoryProcessRegistry(),
            reconciler: reconciler,
            persistence: persistence,
            defaultAgent: { defaultAgent })
    }
}

/// A local source with no transcripts, no catalog and no folder evidence.
final class FolderAgnosticSource: HostSessionSource, @unchecked Sendable {
    let host = HostID.local
    let capabilities: Set<HostCapability> = []
    func locate(_ requests: [LocateRequest]) async throws -> LocateResult {
        LocateResult(coverage: 1, candidates: [:], complete: [], sharedRevision: [:])
    }
    func read(_ locator: TranscriptLocator, agent: Agent, expecting id: String, facts: Bool) async throws -> TranscriptRead {
        throw TranscriptReadError.missing
    }
    func directoryEvidence(_ path: String) async -> DirectoryEvidence { .unknown }
    func catalog(_ query: CatalogQuery) -> AsyncThrowingStream<CatalogBatch, Error> { AsyncThrowingStream { $0.finish() } }
    func adopt(_ request: AdoptionRequest) async throws -> AdoptionResult { .none }
    func changes() -> AsyncThrowingStream<SourceChange, Error> { AsyncThrowingStream { _ in } }
}

extension TerminalCommand {
    private var isLocalLaunchWrapper: Bool {
        argv.count > 7 && argv[0] == "/usr/bin/env" && argv[1] == "/bin/sh" && argv[3] == LocalHostLauncher.wrapperScript
    }
    private var isUnreportedWrapper: Bool {
        argv.count > 6 && argv[0] == "/usr/bin/env" && argv[1] == "/bin/sh" && argv[3] == LocalHostLauncher.unreportedWrapperScript
    }
    /// The agent's argv behind the local launch wrapper (the argv itself otherwise).
    var agentArgv: [String] {
        isLocalLaunchWrapper ? Array(argv.dropFirst(7)) : isUnreportedWrapper ? Array(argv.dropFirst(6)) : argv
    }
    var launchFolder: String? { isLocalLaunchWrapper || isUnreportedWrapper ? argv[5] : nil }
    var launchMarker: String? { isLocalLaunchWrapper ? argv[6] : nil }
}
