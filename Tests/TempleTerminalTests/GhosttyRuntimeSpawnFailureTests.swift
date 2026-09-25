import XCTest
import GhosttyKit
import TempleTerminalAPI
@testable import TempleTerminal

/// A `ghostty_surface_new` that returns nil must surface as a failure in both
/// creation modes: thrown to the caller when creation ran at once, reported
/// through the child-exited path when it was deferred to the end of a drain
/// (the caller is long gone by then, and had already been told "running").
///
/// Named to sort before `GhosttyRuntimeTests`, whose last test shuts the
/// process-wide runtime down: these need a live app handle.
@MainActor
final class GhosttyRuntimeSpawnFailureTests: XCTestCase {
    private final class StateRecorder: TerminalSurfaceDelegate {
        var states: [TerminalProcessState] = []
        func surface(_ surface: TerminalSurface, didChangeState state: TerminalProcessState) { states.append(state) }
        func surface(_ surface: TerminalSurface, didUpdateTitle title: String) {}
        func surfaceDidRing(_ surface: TerminalSurface) {}
        func surface(_ surface: TerminalSurface, didPostNotification title: String, body: String) {}
        func surfaceDidSubmitInput(_ surface: TerminalSurface) {}
        func surface(_ surface: TerminalSurface, didStartSearch needle: String?) {}
        func surfaceDidEndSearch(_ surface: TerminalSurface) {}
        func surface(_ surface: TerminalSurface, didUpdateSearchTotal total: Int?) {}
        func surface(_ surface: TerminalSurface, didUpdateSearchSelected selected: Int?) {}
    }

    private var app: GhosttyApp { GhosttyApp.shared }
    private var creations = 0

    override func setUp() {
        super.setUp()
        creations = 0
        app.newSurface = { [weak self] _, _ in self?.creations += 1; return nil }
        app.drainMailbox = {}   // nothing real to drain; keep the runtime out of it
    }

    override func tearDown() {
        app.newSurface = { app, cfg in
            var cfg = cfg
            return ghostty_surface_new(app, &cfg)
        }
        app.drainMailbox = { [weak app = GhosttyApp.shared] in
            guard let app, let handle = app.app else { return }
            ghostty_app_tick(handle)
        }
        super.tearDown()
    }

    func testImmediateCreationFailureThrowsAndLeavesTheSurfaceNotStarted() throws {
        // Asserted, not skipped: a reordering that ran these after the runtime
        // shutdown would otherwise remove this coverage without a word.
        XCTAssertNotNil(app.app, "runtime must be live; this class sorts before GhosttyRuntimeTests")
        let surface = GhosttyTerminalSurface(app: app, appearance: .default)
        let recorder = StateRecorder()
        surface.delegate = recorder

        XCTAssertThrowsError(try surface.start(TerminalCommand(argv: ["x"], cwd: "/"))) { error in
            XCTAssertEqual(error as? GhosttyError, .surfaceCreationFailed)
        }
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(surface.processState, .notStarted)
        XCTAssertEqual(recorder.states, [])
    }

    func testDeferredCreationFailureIsReportedAsAnExit() throws {
        // Asserted, not skipped: a reordering that ran these after the runtime
        // shutdown would otherwise remove this coverage without a word.
        XCTAssertNotNil(app.app, "runtime must be live; this class sorts before GhosttyRuntimeTests")
        let surface = GhosttyTerminalSurface(app: app, appearance: .default)
        let recorder = StateRecorder()
        surface.delegate = recorder

        var stateInsideTick: TerminalProcessState?
        app.runTick {
            do { try surface.start(TerminalCommand(argv: ["x"], cwd: "/")) } catch { XCTFail("deferred start threw: \(error)") }
            stateInsideTick = surface.processState
            XCTAssertEqual(self.creations, 0, "creation waits for the drain to end")
        }
        // Told "running" while the creation was queued (the pid was always a
        // placeholder); the failure lands once the queued creation runs.
        XCTAssertEqual(stateInsideTick, .running(pid: 0))
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(surface.processState, .exited(status: -1))
        XCTAssertEqual(recorder.states, [.running(pid: 0), .exited(status: -1)])
    }
}
