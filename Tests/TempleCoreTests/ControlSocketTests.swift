import XCTest
import Darwin
@testable import TempleCore

/// The command line's socket (ADR-034): one request, one answer, one
/// process serving a state directory, and nothing left behind or stolen.
final class ControlSocketTests: XCTestCase {
    private var directory: URL!
    private var socket: URL { directory.appendingPathComponent("c.sock") }

    override func setUpWithError() throws {
        // `sun_path` is 104 bytes: keep the path short.
        directory = URL(fileURLWithPath: "/private/tmp/tc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private struct StartFailed: Error { let failure: ControlServer.StartFailure }

    private func serve(deadline: TimeInterval = ControlServer.handlerDeadline,
                       _ answer: @escaping @Sendable (ControlRequest) async -> ControlResponse) throws -> ControlServer {
        switch ControlServer.start(at: socket, deadline: deadline, handler: { request, _ in await answer(request) }) {
        case .success(let server): return server
        case .failure(let failure): throw StartFailed(failure: failure)
        }
    }

    func testARequestGetsItsAnswer() throws {
        let server = try serve { request in
            ControlResponse(session: ControlSession(id: request.id, cli: .codex, project: "/p", title: request.term ?? "",
                                                    state: .idle, focused: true))
        }
        defer { server.stop() }
        let response = try ControlClient.send(ControlRequest(.sessionsGet, id: "abc", term: "hello"), socket: socket, timeout: 5)
        XCTAssertEqual(response.session?.id, "abc")
        XCTAssertEqual(response.session?.title, "hello")
        var info = stat()
        XCTAssertEqual(lstat(socket.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600, "only this user may connect")
    }

    func testNothingListeningIsNotRunning() {
        XCTAssertThrowsError(try ControlClient.send(ControlRequest(.projectsList), socket: socket, timeout: 1)) {
            XCTAssertEqual($0 as? ControlClientError, .notRunning)
        }
    }

    /// The installed Temple and a dev build can share a state directory:
    /// the second never takes the first one's socket.
    func testASecondServerLeavesTheFirstAlone() throws {
        let first = try serve { _ in ControlResponse(projects: []) }
        defer { first.stop() }
        guard case .failure(.alreadyServed) = ControlServer.start(at: socket, handler: { _, _ in ControlResponse() }) else {
            return XCTFail("a second server must not listen")
        }
        XCTAssertNotNil(try ControlClient.send(ControlRequest(.projectsList), socket: socket, timeout: 5).projects)
    }

    /// A Temple that crashed leaves its socket file; the next one replaces it.
    func testAStaleSocketIsReplaced() throws {
        let stale = try XCTUnwrap(ControlSocket.address(socket.path))
        let fd = ControlSocket.newSocket()
        var address = stale
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        close(fd)  // gone without unlinking: nothing answers
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        let server = try serve { _ in ControlResponse(projects: []) }
        defer { server.stop() }
        XCTAssertNotNil(try ControlClient.send(ControlRequest(.projectsList), socket: socket, timeout: 5).projects)
    }

    func testSomethingElseAtThePathIsNeverRemoved() throws {
        try Data("keep".utf8).write(to: socket)
        guard case .failure(.failed) = ControlServer.start(at: socket, handler: { _, _ in ControlResponse() }) else {
            return XCTFail("a regular file is not a stale socket")
        }
        XCTAssertEqual(try Data(contentsOf: socket), Data("keep".utf8))
    }

    /// Ownership is the lock, not whether a connect works: with the socket
    /// file gone (or a full accept queue), the holder is still the owner.
    func testTheLockDecidesWhoServesNotAConnect() throws {
        let first = try serve { _ in ControlResponse() }
        unlink(socket.path)
        guard case .failure(.alreadyServed) = ControlServer.start(at: socket, handler: { _, _ in ControlResponse() }) else {
            return XCTFail("the lock is held: nobody else may take the socket")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path), "and nobody else made one")
        first.stop()
        let next = try serve { _ in ControlResponse(projects: []) }
        defer { next.stop() }
        XCTAssertNotNil(try ControlClient.send(ControlRequest(.projectsList), socket: socket, timeout: 5).projects)
    }

    func testEveryStopReturnsOnlyOnceCleanupIsDone() throws {
        let server = try serve { _ in ControlResponse() }
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            server.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: self.socket.path))
        }
        guard case .success(let next) = ControlServer.start(at: socket, handler: { _, _ in ControlResponse() }) else {
            return XCTFail("ownership was released")
        }
        next.stop()
    }

    func testStoppingRemovesTheSocketAndAnswersNothingMore() throws {
        let server = try serve { _ in ControlResponse() }
        server.stop()
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertThrowsError(try ControlClient.send(ControlRequest(.projectsList), socket: socket, timeout: 1)) {
            XCTAssertEqual($0 as? ControlClientError, .notRunning)
        }
    }

    /// An agent Temple launches must not inherit the socket.
    func testSocketsAreCloseOnExec() {
        let fd = ControlSocket.newSocket()
        defer { close(fd) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        let flags = fcntl(fd, F_GETFD)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertNotEqual(flags & FD_CLOEXEC, 0)
    }

    func testAStalledRequestIsAnsweredAtItsDeadline() throws {
        let server = try serve(deadline: 0.2) { _ in
            try? await Task.sleep(for: .seconds(5))
            return ControlResponse(projects: [])
        }
        defer { server.stop() }
        let started = Date()
        let response = try ControlClient.send(ControlRequest(.projectsList), socket: socket, timeout: 5)
        XCTAssertEqual(response.error?.code, .refused)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// A request that committed to a change is answered by its handler,
    /// however late; one whose deadline passed first may not commit.
    func testTheDeadlineAndACommitAreExclusive() throws {
        let late = ControlServer.start(at: socket, deadline: 0.2, handler: { _, commit in
            XCTAssertTrue(commit.commit())
            try? await Task.sleep(for: .seconds(0.6))
            return ControlResponse(projects: [])
        })
        guard case .success(let server) = late else { return XCTFail("\(late)") }
        XCTAssertNotNil(try ControlClient.send(ControlRequest(.projectsList), socket: socket, timeout: 5).projects,
                        "committed: the handler's answer, not a timeout")
        server.stop()

        let committed = Expectation()
        let expired = ControlServer.start(at: socket, deadline: 0.2, handler: { _, commit in
            try? await Task.sleep(for: .seconds(0.6))
            committed.value = commit.commit()
            return ControlResponse(projects: [])
        })
        guard case .success(let second) = expired else { return XCTFail("\(expired)") }
        defer { second.stop() }
        let answer = try ControlClient.send(ControlRequest(.projectsList), socket: socket, timeout: 5)
        XCTAssertEqual(answer.error?.code, .refused)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(committed.value, false, "too late to change anything")
    }

    private final class Expectation: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        var value: Bool? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    func testStoppingClosesARequestStillWaiting() throws {
        let server = try serve { _ in
            try? await Task.sleep(for: .seconds(5))
            return ControlResponse()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { server.stop() }
        XCTAssertThrowsError(try ControlClient.send(ControlRequest(.projectsList), socket: socket, timeout: 3)) {
            XCTAssertEqual($0 as? ControlClientError, .transport("Temple did not answer"))
        }
    }

    /// The other direction: an answer in another version is not read as ours.
    func testAnAnswerFromAnotherProtocolIsRefused() throws {
        let server = try serve { _ in
            var response = ControlResponse(projects: [])
            response.version = ControlProtocol.version + 1
            return response
        }
        defer { server.stop() }
        XCTAssertThrowsError(try ControlClient.send(ControlRequest(.projectsList), socket: socket, timeout: 5)) {
            guard case .transport(let message) = $0 as? ControlClientError else { return XCTFail("\($0)") }
            XCTAssertTrue(message.contains("command speaks protocol \(ControlProtocol.version) and Temple speaks \(ControlProtocol.version + 1)"), message)
            XCTAssertTrue(message.hasSuffix("Use the temple command that ships with this Temple."), message)
        }
    }

    func testAnotherProtocolIsRefusedNotGuessedAt() throws {
        let server = try serve { _ in XCTFail("another version must not reach the handler"); return ControlResponse() }
        defer { server.stop() }
        for version in [ControlProtocol.version + 1, ControlProtocol.version - 1] {
            var request = ControlRequest(.projectsList)
            request.version = version
            let response = try ControlClient.send(request, socket: socket, timeout: 5)
            XCTAssertEqual(response.error?.code, .invalid)
        }
    }

    /// A pending Codex session has no id yet, and says so.
    func testAPendingSessionEncodesANullID() throws {
        let pending = ControlSession(id: nil, cli: .codex, project: "/p", title: "New Codex session", state: .running,
                                     focused: false)
        let json = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
        XCTAssertTrue(json.contains("\"id\":null"), json)
        XCTAssertEqual(try JSONDecoder().decode(ControlSession.self, from: Data(json.utf8)), pending)
    }

    func testFoldersCompareResolved() throws {
        XCTAssertTrue(ControlPaths.sameFolder("/tmp", "/private/tmp"))
        XCTAssertEqual(ControlPaths.canonical("x/../y", relativeTo: "/a"), "/a/y")
        XCTAssertEqual(ControlPaths.canonical(".", relativeTo: directory.path), directory.path)
    }
}
