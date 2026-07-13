import XCTest
@testable import TempleCore

final class RobustnessTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    private func directory(_ name: String = "root") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-robust-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    func testMissingAndEmptyStoresReturnEmpty() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(ClaudeSessionStore(root: missing).loadSessions().isEmpty)
        XCTAssertTrue(CodexSessionStore(root: missing).loadSessions().isEmpty)

        let empty = try directory("empty")
        XCTAssertTrue(SessionIndex.build(stores: [ClaudeSessionStore(root: empty), CodexSessionStore(root: empty)]).allSessions.isEmpty)
    }

    func testZeroByteAndMalformedSessionsAreSkipped() throws {
        let claude = try directory("malformed")
        let project = claude.appendingPathComponent("-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("empty.jsonl"))
        try "not json\n[]\n{\"cwd\": 42}".write(
            to: project.appendingPathComponent("bad.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertTrue(ClaudeSessionStore(root: claude).loadSessions().isEmpty)

        let codex = try directory("codex-malformed")
        let sessions = codex.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try #"{"type":"session_meta","payload":{"cwd":"/tmp"}}"#.write(
            to: sessions.appendingPathComponent("rollout-no-id.jsonl"), atomically: true, encoding: .utf8)
        try "{truncated".write(
            to: sessions.appendingPathComponent("rollout-truncated.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertTrue(CodexSessionStore(root: codex).loadSessions().isEmpty)
    }

    func testCodexAcceptsPayloadIDVariant() throws {
        let root = try directory("codex-id")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try #"{"type":"session_meta","payload":{"id":"new-schema-id","cwd":"/work"}}"#.write(
            to: sessions.appendingPathComponent("rollout-id.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexSessionStore(root: root).loadSessions().first?.id, "new-schema-id")
    }

    func testHugeFileUsesBoundedReadsAndRetainsHeadAndTailMetadata() throws {
        let root = try directory("huge")
        let project = root.appendingPathComponent("-work-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("huge.jsonl")
        let first = #"{"type":"user","cwd":"/work/project","message":{"content":"first"}}"# + "\n"
        let junkLine = String(repeating: "x", count: 1023) + "\n"
        var data = Data(first.utf8)
        let junk = Data(junkLine.utf8)
        for _ in 0..<10_240 { data.append(junk) }
        data.append(Data(#"{"type":"assistant","message":{"content":"tail answer","model":"latest-model"}}"#.utf8))
        try data.write(to: file)

        XCTAssertLessThanOrEqual(StoreIO.readHead(file, maxBytes: 1024)?.utf8.count ?? .max, 1024)
        XCTAssertLessThanOrEqual(StoreIO.readTail(file, maxBytes: 1024)?.utf8.count ?? .max, 1024)
        let session = try XCTUnwrap(ClaudeSessionStore(root: root).loadSessions().first)
        XCTAssertEqual(session.title, "first")
        XCTAssertEqual(session.model, "latest-model")
        XCTAssertEqual(session.lastMessagePreview, "tail answer")
    }

    func testUnreadableFileDoesNotPreventPartialResults() throws {
        let root = try directory("permissions")
        let project = root.appendingPathComponent("-work-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let readable = project.appendingPathComponent("readable.jsonl")
        let denied = project.appendingPathComponent("denied.jsonl")
        let json = #"{"type":"user","cwd":"/work/project","message":{"content":"ok"}}"#
        try json.write(to: readable, atomically: true, encoding: .utf8)
        try json.write(to: denied, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied.path) }

        let sessions = ClaudeSessionStore(root: root).loadSessions()
        XCTAssertTrue(sessions.contains(where: { $0.id == "readable" }))
    }
}

@MainActor
final class LoginShellEnvironmentTests: XCTestCase {
    func testResolveLoginShellPATHReturnsUsablePath() {
        let path = LoginShellEnvironment.resolveLoginShellPATH()
        XCTAssertNotNil(path)
        XCTAssertTrue(path?.contains("/usr/bin") ?? false)
        // A real login shell PATH has more than launchd's four entries.
        XCTAssertGreaterThan(path?.split(separator: ":").count ?? 0, 4)
    }

    /// The rc file is free to print a banner before we ever get a word in — an
    /// instant prompt, a version-manager notice, an MOTD. Only the marker tells
    /// us where the noise stops.
    func testParseIgnoresRcFileChatter() {
        let output = """
        p10k instant prompt junk
        nvm: using v22.11.0
        __temple_path__
        /usr/local/bin:/usr/bin
        """
        XCTAssertEqual(LoginShellEnvironment.parse(output), "/usr/local/bin:/usr/bin")
    }

    func testParseReturnsNilWhenShellPrintedNothingUseful() {
        XCTAssertNil(LoginShellEnvironment.parse("command not found: printenv\n"))
        XCTAssertNil(LoginShellEnvironment.parse("__temple_path__\n"))
    }

    /// Resolution follows PATH order, exactly as `command -v` would — this is the
    /// whole point: a stale binary earlier in a *hardcoded* list must not win over
    /// the one the user's own shell would pick.
    func testLocateHonorsPATHOrder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        for dir in [first, second] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = second.appendingPathComponent("claude")
        try Data().write(to: stale)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stale.path)

        // Only the later directory has it → that's the answer.
        XCTAssertEqual(LoginShellEnvironment.locate("claude", on: "\(first.path):\(second.path)"),
                       stale.path)

        // Now both do → the earlier one wins.
        let current = first.appendingPathComponent("claude")
        try Data().write(to: current)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: current.path)
        XCTAssertEqual(LoginShellEnvironment.locate("claude", on: "\(first.path):\(second.path)"),
                       current.path)
    }

    func testLocateSkipsNonExecutablesAndRelativeEntries() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Present, but not executable — not a command.
        try Data().write(to: dir.appendingPathComponent("claude"))

        XCTAssertNil(LoginShellEnvironment.locate("claude", on: dir.path))
        XCTAssertNil(LoginShellEnvironment.locate("claude", on: "relative/bin"))
        XCTAssertNil(LoginShellEnvironment.locate("claude", on: nil))
    }
}
