import XCTest
@testable import TempleCore

final class ReconcilerTests: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 100)

    private func candidate(_ id: String, cwd: String = "/work", offset: TimeInterval = 0) -> CodexRolloutCandidate {
        CodexRolloutCandidate(sessionID: id, cwd: cwd, createdAt: launch.addingTimeInterval(offset),
                              filePath: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
    }

    func testUniqueMatch() {
        let match = CodexReconciler.reconcile(launchedCwd: "/work", launchedAt: launch, window: 3,
                                              candidates: [candidate("yes"), candidate("other", cwd: "/else")])
        XCTAssertEqual(match?.sessionID, "yes")
    }

    func testNoMatchForWrongCwdOrOutsideWindow() {
        XCTAssertNil(CodexReconciler.reconcile(launchedCwd: "/work", launchedAt: launch, window: 3,
                                               candidates: [candidate("wrong", cwd: "/else"), candidate("late", offset: 4)]))
    }

    func testAmbiguousCandidatesReturnNil() {
        XCTAssertNil(CodexReconciler.reconcile(launchedCwd: "/work", launchedAt: launch, window: 3,
                                               candidates: [candidate("one"), candidate("two", offset: 1)]))
    }
}
