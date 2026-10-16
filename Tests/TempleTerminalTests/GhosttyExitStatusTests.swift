import XCTest
import TempleTerminalAPI
@testable import TempleTerminal

/// What a libghostty surface reports when its process ends: the child's own
/// status when libghostty reports one, never a made-up 0 for a close
/// request, and a real status replacing the placeholder a close left.
///
/// Named to sort before `GhosttyRuntimeTests`, whose last test shuts the
/// process-wide runtime down.
@MainActor
final class GhosttyExitStatusTests: XCTestCase {
    private final class Recorder: TerminalSurfaceDelegate {
        var states: [TerminalProcessState] = []
        func surface(_ surface: TerminalSurface, didChangeState state: TerminalProcessState) { states.append(state) }
        func surface(_ surface: TerminalSurface, didUpdateTitle title: String) {}
        func surfaceDidRing(_ surface: TerminalSurface) {}
        func surface(_ surface: TerminalSurface, didPostNotification title: String, body: String) {}
    }

    private func surface() throws -> (GhosttyTerminalSurface, GhosttySurfaceView, Recorder) {
        let surface = GhosttyTerminalSurface(app: GhosttyApp.shared, appearance: .default)
        let view = try XCTUnwrap(surface.view as? GhosttySurfaceView)
        let recorder = Recorder()
        surface.delegate = recorder
        return (surface, view, recorder)
    }

    func testTheChildsStatusIsReportedAndAFollowingCloseChangesNothing() throws {
        let (surface, view, recorder) = try surface()
        view.handleChildExited(code: 255)
        view.handleCloseRequest(processAlive: false)
        XCTAssertEqual(recorder.states, [.exited(status: 255)])
        XCTAssertEqual(surface.processState, .exited(status: 255))
    }

    func testACloseIsNeverReportedAsSuccess() throws {
        let (surface, view, recorder) = try surface()
        view.handleCloseRequest(processAlive: false)
        XCTAssertEqual(recorder.states, [.exited(status: TerminalProcessState.unknownExitStatus)])
        // The child's own status, arriving after the close, replaces it, once.
        view.handleChildExited(code: 1)
        view.handleCloseRequest(processAlive: false)
        XCTAssertEqual(recorder.states, [.exited(status: TerminalProcessState.unknownExitStatus), .exited(status: 1)])
        XCTAssertEqual(surface.processState, .exited(status: 1))
        XCTAssertNotEqual(TerminalProcessState.unknownExitStatus, 0)
    }
}
