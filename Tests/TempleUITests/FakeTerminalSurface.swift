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
    private(set) var didRequestGracefulExit = false
    private(set) var didTerminate = false
    private(set) var appliedAppearances: [TerminalAppearance] = []

    private(set) var processState: TerminalProcessState = .notStarted {
        didSet {
            guard processState != oldValue else { return }
            delegate?.surface(self, didChangeState: processState)
        }
    }

    func start(_ command: TerminalCommand) throws {
        processState = .running(pid: 4242)
    }

    func focus() {}

    func apply(_ appearance: TerminalAppearance) {
        appliedAppearances.append(appearance)
    }

    func requestGracefulExit() {
        didRequestGracefulExit = true
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

    private func exitNow(status: Int32) {
        guard case .running = processState else { return }
        processState = .exited(status: status)
    }
}

@MainActor
final class FakeTerminalSurfaceFactory: TerminalSurfaceFactory {
    private(set) var created: [FakeTerminalSurface] = []
    func makeSurface(appearance: TerminalAppearance) -> TerminalSurface {
        let s = FakeTerminalSurface()
        created.append(s)
        return s
    }
}

/// An `IndexSource` that emits a fixed index on demand (no disk / no timer).
@MainActor
final class FakeIndexSource: IndexSource {
    var index: SessionIndex
    private var onUpdate: ((SessionIndex) -> Void)?
    init(_ index: SessionIndex) { self.index = index }
    func start(onUpdate: @escaping (SessionIndex) -> Void) {
        self.onUpdate = onUpdate
        onUpdate(index)
    }
    func stop() {}
    func emit(_ new: SessionIndex) { index = new; onUpdate?(new) }
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
                        title: String = "Title", updated: TimeInterval = 0) -> AgentSession {
        AgentSession(id: id, agent: agent, projectPath: project, title: title,
                     createdAt: nil, updatedAt: Date(timeIntervalSince1970: updated),
                     filePath: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
    }

    /// An isolated defaults object that never reaches the disk.
    static func uniqueDefaults() -> UserDefaults { InMemoryDefaults() }

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
