import XCTest
@testable import TempleCore

final class MetadataTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testClaudeMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-work-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("claude-id.jsonl")
        let content = """
        {"type":"user","cwd":"/work/project","message":{"content":"first prompt"},"gitBranch":"main","timestamp":"2026-01-01T00:00:00Z"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"latest answer"}],"model":"claude-opus-4-6"},"gitBranch":"feature"}
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(ClaudeSessionStore(root: root).loadSessions().first)
        XCTAssertEqual(session.messageCount, 2)
        XCTAssertEqual(session.model, "claude-opus-4-6")
        XCTAssertEqual(session.lastMessagePreview, "latest answer")
        XCTAssertEqual(session.gitBranch, "feature")
    }

    func testCodexMetadataAndAbsentFields() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-test.jsonl")
        let content = """
        {"type":"session_meta","payload":{"session_id":"codex-id","cwd":"/work/project","originator":"codex-tui","model_provider":"openai","git":{"branch":"dev"}}}
        {"type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"hello"}]}}
        {"type":"event_msg","payload":{"type":"agent_message","message":"done"}}
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(CodexSessionStore(root: root).loadSessions().first)
        XCTAssertEqual(session.messageCount, 2)
        XCTAssertEqual(session.model, "openai")
        XCTAssertEqual(session.lastMessagePreview, "done")
        XCTAssertEqual(session.gitBranch, "dev")
        XCTAssertEqual(session.originator, "codex-tui")

        let plainFile = sessions.appendingPathComponent("rollout-plain.jsonl")
        try #"{"type":"session_meta","payload":{"session_id":"plain","cwd":"/work/project"}}"#
            .write(to: plainFile, atomically: true, encoding: .utf8)
        let plain = try XCTUnwrap(CodexSessionStore(root: root).loadSessions().first { $0.id == "plain" })
        XCTAssertNil(plain.model)
        XCTAssertNil(plain.gitBranch)
        XCTAssertNil(plain.lastMessagePreview)
    }

    func testCodexTitleFallbackChain() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        try """
        {"session_id":"hist-id","ts":10,"text":"typed prompt"}
        {"session_id":"blank-id","ts":10,"text":"   "}
        """.write(to: root.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)

        try """
        {"id":"hist-id","thread_name":"index name loses to history"}
        {"id":"index-id","thread_name":"stale name"}
        {"id":"index-id","thread_name":"companion thread"}
        """.write(to: root.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        func writeRollout(_ id: String, lines: [String]) throws {
            let meta = #"{"type":"session_meta","payload":{"session_id":"\#(id)","cwd":"/work/project"}}"#
            try ([meta] + lines).joined(separator: "\n")
                .write(to: sessions.appendingPathComponent("rollout-\(id).jsonl"),
                       atomically: true, encoding: .utf8)
        }
        let instructions = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"AGENTS.md instructions blob"}]}}"#
        let prompt = #"{"type":"event_msg","payload":{"type":"user_message","message":"prompt from rollout"}}"#
        try writeRollout("hist-id", lines: [prompt])
        try writeRollout("index-id", lines: [prompt])
        try writeRollout("exec-id", lines: [instructions, prompt])
        try writeRollout("blank-id", lines: [prompt])
        try writeRollout("bare-id", lines: [instructions])
        // codex exec buries the prompt behind instruction blobs, routinely
        // past the parser's 64 KB head window; the deep-scan must find it.
        let filler = String(repeating: "x", count: 80_000)
        let bigInstructions = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(filler)"}]}}"#
        try writeRollout("deep-id", lines: [bigInstructions, prompt])

        let byID = Dictionary(uniqueKeysWithValues:
            CodexSessionStore(root: root).loadSessions().map { ($0.id, $0.title) })
        XCTAssertEqual(byID["hist-id"], "typed prompt")
        XCTAssertEqual(byID["index-id"], "companion thread")
        XCTAssertEqual(byID["exec-id"], "prompt from rollout")
        XCTAssertEqual(byID["blank-id"], "prompt from rollout")
        XCTAssertEqual(byID["bare-id"], "(no prompt)")
        XCTAssertEqual(byID["deep-id"], "prompt from rollout")
    }

    func testAutomationOriginatorIsNoise() {
        let session = AgentSession(id: "id", agent: .codex, projectPath: "/work", title: "x",
                                   createdAt: nil, updatedAt: Date(), filePath: URL(fileURLWithPath: "/tmp/x"),
                                   originator: "codex_exec")
        XCTAssertTrue(SessionFilter.isNoise(session, pathExists: { _ in true }))
    }

    func testMessageTypeLiteralInsideContentDoesNotInflateCounts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-work-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("adversarial.jsonl")
        let content = #"{"type":"user","cwd":"/work/project","message":{"content":"the text contains \"type\":\"assistant\" but is one message"}}"#
        try content.write(to: file, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(ClaudeSessionStore(root: root).loadSessions().first)
        XCTAssertEqual(session.messageCount, 1)
        XCTAssertEqual(session.title, #"the text contains "type":"assistant" but is one message"#)
    }
}
