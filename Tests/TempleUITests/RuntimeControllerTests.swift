import XCTest
@testable import TempleUI
import TempleTerminalAPI

@MainActor
final class RuntimeControllerTests: XCTestCase {
    private func started(_ behavior: FakeTerminalSurface.ExitBehavior) throws -> FakeTerminalSurface {
        let s = FakeTerminalSurface()
        s.behavior = behavior
        try s.start(TerminalCommand(argv: ["claude"], cwd: "/tmp"))
        return s
    }

    func testGracefulExitNeverForceTerminates() throws {
        let s = try started(.graceful)
        SessionRuntimeController(gracefulTimeout: 0.2).close(s)
        XCTAssertEqual(s.processState, .exited(status: 0))
        XCTAssertTrue(s.didRequestGracefulExit)
        XCTAssertFalse(s.didTerminate)
    }

    func testSlowExitBeatsTimeout() async throws {
        let s = try started(.slow(0.05))
        SessionRuntimeController(gracefulTimeout: 0.5).close(s)
        XCTAssertEqual(s.processState, .running(pid: 4242))  // not yet
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(s.processState, .exited(status: 0))
        XCTAssertFalse(s.didTerminate)
    }

    func testHungExitIsForceTerminatedAfterTimeout() async throws {
        let s = try started(.hung)
        SessionRuntimeController(gracefulTimeout: 0.05).close(s)
        XCTAssertTrue(s.didRequestGracefulExit)
        XCTAssertEqual(s.processState, .running(pid: 4242))  // graceful ignored
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(s.didTerminate)
        XCTAssertEqual(s.processState, .exited(status: 9))
    }

    func testDrainAllForcesStragglersThenCompletes() async throws {
        let a = try started(.hung)
        let b = try started(.graceful)
        let done = expectation(description: "drained")
        SessionRuntimeController(gracefulTimeout: 0.05).drainAll([a, b]) { done.fulfill() }
        await fulfillment(of: [done], timeout: 1.0)
        XCTAssertTrue(a.didTerminate)          // hung → forced
        XCTAssertFalse(b.didTerminate)         // graceful → exited politely
        XCTAssertEqual(a.processState, .exited(status: 9))
        XCTAssertEqual(b.processState, .exited(status: 0))
    }

    func testDrainAllWithNoLiveSurfacesCompletesImmediately() {
        let done = expectation(description: "drained")
        SessionRuntimeController().drainAll([]) { done.fulfill() }
        wait(for: [done], timeout: 0.1)
    }
}
