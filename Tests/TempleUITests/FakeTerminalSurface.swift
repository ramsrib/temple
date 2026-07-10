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

// MARK: - Fixtures

@MainActor
enum Fixture {
    static func session(_ id: String, agent: Agent = .claude, project: String,
                        title: String = "Title", updated: TimeInterval = 0) -> AgentSession {
        AgentSession(id: id, agent: agent, projectPath: project, title: title,
                     createdAt: nil, updatedAt: Date(timeIntervalSince1970: updated),
                     filePath: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
    }

    static func uniqueDefaults() -> UserDefaults {
        UserDefaults(suiteName: "temple.tests.\(UUID().uuidString)")!
    }

    /// A fresh OpenSessionsModel wired to a fake factory (isolated persistence).
    static func openModel(factory: FakeTerminalSurfaceFactory,
                          timeout: TimeInterval = 3,
                          reconciler: CodexReconciler? = nil,
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
