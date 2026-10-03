import XCTest
@testable import TempleCore

final class StoreTests: XCTestCase {

    private func temporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("temple-store-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeTranscript(_ content: String, at file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    func testParsersReturnNilForMissingCwdAndPrompt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeFile = root.appendingPathComponent("claude/-work-project/claude-id.jsonl")
        let codexFile = root.appendingPathComponent("sessions/rollout-codex.jsonl")
        try writeTranscript(#"{"type":"system"}"#, at: claudeFile)
        try writeTranscript(#"{"type":"session_meta","payload":{"id":"codex-id"}}"#, at: codexFile)

        let stores: [any TranscriptSummaryStore] = [
            ClaudeSessionStore(root: root.appendingPathComponent("claude")), CodexSessionStore(root: root),
        ]
        for (store, file) in zip(stores, [claudeFile, codexFile]) {
            let summary = try XCTUnwrap(store.loadSummary(at: file))
            XCTAssertNil(summary.cwd)
            XCTAssertNil(summary.firstPrompt)
            XCTAssertNil(summary.createdAt)
            XCTAssertNil(summary.gitBranch)
            XCTAssertNil(summary.model)
            XCTAssertNil(summary.messageCount)
            XCTAssertNil(summary.lastMessagePreview)
            XCTAssertNil(summary.originator)
            XCTAssertNil(summary.recordedTitle)
            XCTAssertNil(summary.laterPromptHint)
            XCTAssertEqual(summary.locator, TranscriptLocator(host: .local, path: file.path))
            XCTAssertEqual(summary.locator.localURL, file)
            XCTAssertEqual(store.loadSummaries(), [summary])
            XCTAssertEqual(store.catalogSummaryParser()(file), summary)
        }
    }

    func testLossyDirectoryDecodeIsAHintNotACwd() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("claude/-work-my-project/claude-id.jsonl")
        let store = ClaudeSessionStore(root: root.appendingPathComponent("claude"))
        try writeTranscript(#"{"type":"system"}"#, at: file)
        let missingCwd = try XCTUnwrap(store.loadSummary(at: file))
        XCTAssertNil(missingCwd.cwd)
        XCTAssertEqual(missingCwd.directoryHint, "/work/my/project")

        try writeTranscript(#"{"type":"system","cwd":"/work/my-project"}"#, at: file)
        let recordedCwd = try XCTUnwrap(store.loadSummary(at: file))
        XCTAssertEqual(recordedCwd.cwd, "/work/my-project")
        XCTAssertNil(recordedCwd.directoryHint)
    }

    func testTranscriptSummarySummaryPreservesLegacyFallbacks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeFile = root.appendingPathComponent("claude/-work-my-project/claude-id.jsonl")
        let codexFile = root.appendingPathComponent("sessions/rollout-codex.jsonl")
        try writeTranscript(#"{"type":"system"}"#, at: claudeFile)
        try writeTranscript(#"{"type":"session_meta","payload":{"id":"codex-id"}}"#, at: codexFile)

        let stores: [any TranscriptSummaryStore] = [
            ClaudeSessionStore(root: root.appendingPathComponent("claude")), CodexSessionStore(root: root),
        ]
        for (store, file) in zip(stores, [claudeFile, codexFile]) {
            let summary = try XCTUnwrap(store.loadSummary(at: file))
            XCTAssertNil(summary.cwd)
            XCTAssertNil(summary.firstPrompt)
            XCTAssertEqual(summary.directoryHint, store.agent == .claude ? "/work/my/project" : nil)
            XCTAssertEqual(store.loadSummary(at: file), summary)
            XCTAssertEqual(store.loadSummaries(), [summary])
            XCTAssertEqual(store.catalogParser()(file), summary)
        }
    }

    func testClaudeRecordedTitleIsSeparateFromPrompt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("claude/-work-project/claude-id.jsonl")
        try writeTranscript("""
        {"type":"user","cwd":"/work/project","message":{"content":"first prompt"}}
        {"type":"summary","summary":"  recorded   title "}
        """, at: file)
        let store = ClaudeSessionStore(root: root.appendingPathComponent("claude"))
        let summary = try XCTUnwrap(store.loadSummary(at: file))
        XCTAssertEqual(summary.firstPrompt, "first prompt")
        XCTAssertEqual(summary.recordedTitle, "recorded title")
        XCTAssertEqual(summary.title, "recorded title")
        XCTAssertEqual(store.loadSummary(at: file)?.title, "recorded title")
    }

    func testCodexTailPromptIsAHintNotAFirstPrompt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sessions/rollout-codex.jsonl")
        let filler = String(repeating: "x", count: 1_100_000)
        try writeTranscript("""
        {"type":"session_meta","payload":{"id":"codex-id","cwd":"/work/project"}}
        {"type":"response_item","payload":{"role":"user","content":"\(filler)"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"later prompt"}}
        """, at: file)
        let store = CodexSessionStore(root: root)
        let summary = try XCTUnwrap(store.loadSummary(at: file))
        XCTAssertNil(summary.firstPrompt)
        XCTAssertEqual(summary.laterPromptHint, "later prompt")
        XCTAssertEqual(summary.title, "later prompt")
        XCTAssertEqual(store.loadSummary(at: file), summary)
    }

    func testCodexHistoryPromptIsSeparateFromRolloutAndLegacyTitles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sessions/rollout-codex.jsonl")
        let filler = String(repeating: "x", count: 80_000)
        try writeTranscript("""
        {"type":"session_meta","payload":{"id":"codex-id","cwd":"/work/project"}}
        {"type":"response_item","payload":{"role":"user","content":"\(filler)"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"rollout prompt"}}
        """, at: file)
        try writeTranscript(#"{"session_id":"codex-id","ts":10,"text":"shared title"}"#,
                            at: root.appendingPathComponent("history.jsonl"))
        let store = CodexSessionStore(root: root)
        let summary = try XCTUnwrap(store.loadSummary(at: file))
        XCTAssertEqual(summary.firstPrompt, "rollout prompt")
        XCTAssertEqual(summary.historyPrompt, "shared title")
        XCTAssertNil(summary.recordedTitle)
        XCTAssertEqual(summary.title, "shared title")
        XCTAssertEqual(store.loadSummary(at: file)?.title, "shared title")
        XCTAssertEqual(store.loadSummaries().first?.title, "shared title")
        XCTAssertEqual(store.catalogParser()(file)?.title, "shared title")
    }

    func testCodexSummaryIncludesOnlyRecordedHistoryPromptsAsFacts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sessions/rollout-codex.jsonl")
        try writeTranscript(#"{"type":"session_meta","payload":{"id":"codex-id","cwd":"/work"}}"#, at: file)
        try writeTranscript(#"{"id":"codex-id","thread_name":"Display name"}"#,
                            at: root.appendingPathComponent("session_index.jsonl"))
        let store = CodexSessionStore(root: root)
        XCTAssertNil(store.loadSummary(at: file)?.historyPrompt, "A thread name is not a human prompt")
        try writeTranscript("""
        {"session_id":"codex-id","ts":20,"text":"Later prompt"}
        {"session_id":"codex-id","ts":10,"text":"First recorded prompt"}
        """, at: root.appendingPathComponent("history.jsonl"))
        for summary in [store.loadSummary(at: file), store.loadSummaries().first, store.catalogSummaryParser()(file)] {
            let summary = try XCTUnwrap(summary)
            XCTAssertNil(summary.firstPrompt)
            XCTAssertEqual(summary.historyPrompt, "First recorded prompt")
            XCTAssertNil(summary.firstPrompt, "History prompts remain separate from rollout facts")
        }
        XCTAssertEqual(store.loadSummary(at: file)?.title, "First recorded prompt")
        try writeTranscript(#"{"session_id":"codex-id","ts":10,"text":"   "}"#,
                            at: root.appendingPathComponent("history.jsonl"))
        XCTAssertNil(store.loadSummary(at: file)?.historyPrompt)
        XCTAssertEqual(store.loadSummary(at: file)?.title, "Display name")
    }

    private func assertLegacyValue(
        _ actual: TranscriptSummary?, equals expected: TranscriptSummary,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let actual = try XCTUnwrap(actual, file: file, line: line)
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.agent, expected.agent, file: file, line: line)
        XCTAssertEqual(actual.projectPath, expected.projectPath, file: file, line: line)
        XCTAssertEqual(actual.title, expected.title, file: file, line: line)
        XCTAssertEqual(actual.createdAt, expected.createdAt, file: file, line: line)
        XCTAssertEqual(actual.modifiedAt, expected.modifiedAt, file: file, line: line)
        XCTAssertEqual(actual.locator.localURL, expected.locator.localURL, file: file, line: line)
        XCTAssertEqual(actual.messageCount, expected.messageCount, file: file, line: line)
        XCTAssertEqual(actual.model, expected.model, file: file, line: line)
        XCTAssertEqual(actual.gitBranch, expected.gitBranch, file: file, line: line)
        XCTAssertEqual(actual.lastMessagePreview, expected.lastMessagePreview, file: file, line: line)
        XCTAssertEqual(actual.originator, expected.originator, file: file, line: line)
    }

    func testClaudeSystemContentIsOnlyALegacyTitleHint() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("claude/-work-project/system.jsonl")
        try writeTranscript(#"{"type":"system","content":"status"}"#, at: file)
        let store = ClaudeSessionStore(root: root.appendingPathComponent("claude"))
        let summary = try XCTUnwrap(store.loadSummary(at: file))
        XCTAssertNil(summary.firstPrompt)
        XCTAssertEqual(summary.legacyTitleHint, "status")
        let expected = catalogFixture(id: "system", agent: .claude, projectPath: "/work/project",
                                    title: "status", createdAt: nil,
                                    updatedAt: StoreIO.modificationDate(file), filePath: file)
        try assertLegacyValue(summary, equals: expected)
        try assertLegacyValue(store.loadSummary(at: file), equals: expected)
        try assertLegacyValue(store.loadSummaries().first, equals: expected)
        try assertLegacyValue(store.catalogParser()(file), equals: expected)
    }

    func testClaudeTitlePrecedencePreservesCompleteLegacyValues() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClaudeSessionStore(root: root.appendingPathComponent("claude"))
        let system = #"{"type":"system","content":"status"}"#
        let queued = #"{"type":"queue-operation","operation":"enqueue","content":"  queued   prompt "}"#
        let synthetic = #"{"type":"user","message":{"content":"<command-name>/help</command-name>"}}"#
        let human = #"{"type":"user","message":{"content":"  human   prompt "}}"#
        let laterHuman = #"{"type":"user","message":{"content":"later human prompt"}}"#
        let firstSummary = #"{"type":"summary","summary":"first summary"}"#
        let lastSummary = #"{"type":"summary","summary":"  last   summary "}"#
        let cases: [(id: String, lines: [String], prompt: String?, title: String, count: Int, recorded: String?)] = [
            ("human", [system, queued, synthetic, human, laterHuman], "human prompt", "human prompt", 4, nil),
            ("synthetic", [system, queued, synthetic], "queued prompt", "<command-name>/help</command-name>", 2, nil),
            ("synthetic-only", [synthetic], nil, "<command-name>/help</command-name>", 2, nil),
            ("queued", [queued], "queued prompt", "queued prompt", 1, nil),
            ("system-before-queue", [system, queued], "queued prompt", "status", 1, nil),
            ("dequeue", [#"{"type":"queue-operation","operation":"dequeue","content":"removed"}"#], nil, "removed", 1, nil),
            ("summaries", [queued, synthetic, human, firstSummary, lastSummary], "human prompt", "last summary", 3, "last summary"),
            ("summary-only", [firstSummary, lastSummary], nil, "last summary", 1, "last summary"),
            ("empty-summary", [human, firstSummary, #"{"type":"summary","summary":""}"#], "human prompt", "first summary", 2, "first summary"),
            ("blank-summary", [human, firstSummary, #"{"type":"summary","summary":"   "}"#], "human prompt", "", 2, ""),
        ]
        let created = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
        let modified = Date(timeIntervalSince1970: 1_767_225_700)
        var files: [String: URL] = [:]
        for item in cases {
            let file = root.appendingPathComponent("claude/-work-project/\(item.id).jsonl")
            let header = #"{"type":"system","cwd":"/actual/my-project","timestamp":"2026-01-01T00:00:00Z","model":"initial","gitBranch":"main"}"#
            let answer = #"{"type":"assistant","message":{"content":" final   answer ","model":"latest"},"gitBranch":"feature"}"#
            try writeTranscript(([header] + item.lines + [answer]).joined(separator: "\n"), at: file)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            files[item.id] = file
        }
        let bulk = Dictionary(uniqueKeysWithValues: store.loadSummaries().map { ($0.id, $0) })
        let catalog = store.catalogParser()
        XCTAssertEqual(bulk.count, cases.count)
        for item in cases {
            let file = try XCTUnwrap(files[item.id])
            let summary = try XCTUnwrap(store.loadSummary(at: file))
            XCTAssertEqual(summary.firstPrompt, item.prompt, item.id)
            XCTAssertEqual(summary.recordedTitle, item.recorded, item.id)
            let expected = catalogFixture(id: item.id, agent: .claude, projectPath: "/actual/my-project",
                                        title: item.title, createdAt: created, updatedAt: modified, filePath: file,
                                        messageCount: item.count, model: "latest", lastMessagePreview: "final answer",
                                        gitBranch: "feature", originator: nil)
            try assertLegacyValue(summary, equals: expected)
            try assertLegacyValue(store.loadSummary(at: file), equals: expected)
            try assertLegacyValue(bulk[item.id], equals: expected)
            try assertLegacyValue(catalog(file), equals: expected)
        }
    }

    func testCodexDistinctHeadWideAndTailPrecedencePreservesCompleteLegacyValues() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CodexSessionStore(root: root)
        let cases: [(id: String, head: Bool, wide: Bool, shared: String?, prompt: String?, title: String)] = [
            ("head", true, true, nil, "head prompt", "head prompt"),
            ("wide", false, true, nil, "wide prompt", "wide prompt"),
            ("tail", false, false, nil, nil, "tail prompt"),
            ("shared-head", true, true, "history first", "head prompt", "history first"),
            ("shared-wide", false, true, "history first", "wide prompt", "history first"),
            ("index-wide", false, true, "index title", "wide prompt", "index title"),
        ]
        func prompt(_ text: String) -> String {
            #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(text)"}}"#
        }
        func padding(_ bytes: Int) -> String {
            #"{"type":"padding","payload":{"text":"\#(String(repeating: "x", count: bytes))"}}"#
        }
        let created = Date(timeIntervalSince1970: 1_767_225_600)
        let modified = Date(timeIntervalSince1970: 1_767_225_700)
        var files: [String: URL] = [:]
        var history: [String] = []
        var index: [String] = []
        for item in cases {
            let file = root.appendingPathComponent("sessions/rollout-\(item.id).jsonl")
            let header = #"{"type":"session_meta","payload":{"id":"\#(item.id)","cwd":"/actual/my-project","timestamp":"2026-01-01T00:00:00Z","model_provider":"openai","originator":"codex_exec","git":{"branch":"main"}}}"#
            var lines = [header]
            if item.head { lines.append(prompt("head prompt")) }
            lines.append(padding(80_000))
            if item.wide { lines.append(prompt("wide prompt")) }
            // Keep the wide prompt outside the tail and the tail outside the
            // 1 MiB scan. Each source has a different value and can win alone.
            lines += [padding(1_100_000), prompt("tail prompt"), prompt("later tail prompt"),
                      #"{"type":"event_msg","payload":{"type":"agent_message","message":" final   answer ","model":"latest"}}"#]
            try writeTranscript(lines.joined(separator: "\n"), at: file)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            files[item.id] = file
            if item.shared != nil {
                index.append(#"{"id":"\#(item.id)","thread_name":"index title"}"#)
            }
            if item.shared == "history first" {
                history += [#"{"session_id":"\#(item.id)","ts":20,"text":"history later"}"#,
                            #"{"session_id":"\#(item.id)","ts":10,"text":"history first"}"#]
            }
        }
        try writeTranscript(history.joined(separator: "\n"), at: root.appendingPathComponent("history.jsonl"))
        try writeTranscript(index.joined(separator: "\n"), at: root.appendingPathComponent("session_index.jsonl"))
        let bulk = Dictionary(uniqueKeysWithValues: store.loadSummaries().map { ($0.id, $0) })
        let catalog = store.catalogParser()
        XCTAssertEqual(bulk.count, cases.count)
        for item in cases {
            let file = try XCTUnwrap(files[item.id])
            let summary = try XCTUnwrap(store.loadSummary(at: file))
            XCTAssertEqual(summary.firstPrompt, item.prompt, item.id)
            XCTAssertEqual(summary.laterPromptHint, "tail prompt", item.id)
            func expected(title: String) -> TranscriptSummary {
                catalogFixture(id: item.id, agent: .codex, projectPath: "/actual/my-project",
                             title: title, createdAt: created, updatedAt: modified, filePath: file,
                             messageCount: item.head ? 4 : 3, model: "latest", lastMessagePreview: "final answer",
                             gitBranch: "main", originator: "codex_exec")
            }
            let legacy = expected(title: item.title)
            let transcript = expected(title: item.prompt ?? "tail prompt")
            try assertLegacyValue(store.loadSummary(at: file), equals: legacy)
            try assertLegacyValue(bulk[item.id], equals: legacy)
            try assertLegacyValue(catalog(file), equals: legacy)
            try assertLegacyValue(summary, equals: legacy)
            try assertLegacyValue(store.loadSummary(at: file), equals: legacy)
        }
    }

    func testBaseRelativeTranscriptURLsPreserveLegacyRepresentation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures: [(store: any TranscriptSummaryStore, relativePath: String, id: String, content: String)] = [
            (ClaudeSessionStore(root: root.appendingPathComponent("claude")), "claude/-work-project/claude.jsonl", "claude",
             #"{"type":"user","cwd":"/work/project","message":{"content":"prompt"}}"#),
            (CodexSessionStore(root: root), "sessions/rollout-codex.jsonl", "codex",
             """
             {"type":"session_meta","payload":{"id":"codex","cwd":"/work/project"}}
             {"type":"event_msg","payload":{"type":"user_message","message":"prompt"}}
             """),
        ]
        for item in fixtures {
            let relative = try XCTUnwrap(URL(string: item.relativePath, relativeTo: root))
            let absolute = root.appendingPathComponent(item.relativePath)
            try writeTranscript(item.content, at: absolute)
            let summary = try XCTUnwrap(item.store.loadSummary(at: relative))
            XCTAssertNotNil(relative.baseURL)
            XCTAssertEqual(summary.locator.localURL?.baseURL, relative.baseURL)
            XCTAssertEqual(summary.locator.localURL?.relativeString, item.relativePath)
            func expected(file: URL) -> TranscriptSummary {
                catalogFixture(id: item.id, agent: item.store.agent, projectPath: "/work/project",
                             title: "prompt", createdAt: nil, updatedAt: StoreIO.modificationDate(absolute),
                             filePath: file, messageCount: 1, lastMessagePreview: "prompt")
            }
            let legacy = expected(file: relative)
            try assertLegacyValue(summary, equals: legacy)
            try assertLegacyValue(item.store.loadSummary(at: relative), equals: legacy)
            try assertLegacyValue(item.store.catalogParser()(relative), equals: legacy)
            try assertLegacyValue(item.store.loadSummaries().first, equals: expected(file: absolute))
            if let codex = item.store as? CodexSessionStore {
                try assertLegacyValue(codex.loadSummary(at: relative), equals: legacy)
            }
        }
    }

    func testHostAndProjectIdentityKeepHostsDistinct() throws {
        let remote = HostID(rawValue: "build-host")
        let localProject = ProjectKey(host: .local, path: "/work/project")
        let remoteProject = ProjectKey(host: remote, path: "/work/project")
        XCTAssertTrue(HostID.local.isLocal)
        XCTAssertFalse(remote.isLocal)
        XCTAssertNotEqual(localProject, remoteProject)
        XCTAssertEqual(localProject.name, "project")
        XCTAssertEqual(localProject.displayName, "project")
        XCTAssertEqual(remoteProject.displayName, "project @build-host")
        XCTAssertNil(TranscriptLocator(host: remote, path: "/work/rollout.jsonl").localURL)
        XCTAssertEqual(try JSONDecoder().decode(ProjectKey.self,
                                               from: JSONEncoder().encode(remoteProject)), remoteProject)
        XCTAssertEqual(DirectorySource.tab.rawValue, "tab")
        XCTAssertEqual(DirectorySource.transcript.rawValue, "transcript")
    }

    func testClaudeTextExtractionFromString() {
        XCTAssertEqual(ClaudeSessionStore.text(from: "hello"), "hello")
    }

    func testClaudeTextExtractionFromContentArray() {
        let content: [[String: Any]] = [["type": "text", "text": "build me a thing"]]
        XCTAssertEqual(ClaudeSessionStore.text(from: content), "build me a thing")
    }

    func testDecodeDirNameIsBestEffort() {
        XCTAssertEqual(
            ClaudeSessionStore.decodeDirName("-Users-sriram-Projects-active-raven"),
            "/Users/sriram/Projects/active/raven")
    }

    func testCleanTitleCollapsesAndCaps() {
        XCTAssertEqual(StoreIO.cleanTitle("  a\n  b\tc "), "a b c")
        XCTAssertEqual(StoreIO.cleanTitle(String(repeating: "x", count: 300)).count, 201)
    }

    func testIndexGroupsByProjectPath() {
        let base = URL(fileURLWithPath: "/tmp/x.jsonl")
        let s1 = catalogFixture(id: "1", agent: .claude, projectPath: "/p/a",
                              title: "t1", createdAt: nil, updatedAt: Date(timeIntervalSince1970: 10),
                              filePath: base)
        let s2 = catalogFixture(id: "2", agent: .codex, projectPath: "/p/a",
                              title: "t2", createdAt: nil, updatedAt: Date(timeIntervalSince1970: 20),
                              filePath: base)
        let s3 = catalogFixture(id: "3", agent: .claude, projectPath: "/p/b",
                              title: "t3", createdAt: nil, updatedAt: Date(timeIntervalSince1970: 5),
                              filePath: base)

        let store = StubStore(sessions: [s1, s2, s3])
        let sessions = LocalSessionCatalog(stores: [store]).load()
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(Set(sessions.compactMap(\.cwd)), ["/p/a", "/p/b"])
        XCTAssertEqual(sessions.first?.id, "2")
    }
}

private struct StubStore: SessionStore {
    let agent: Agent = .claude
    let sessions: [TranscriptSummary]
    func loadSummaries() -> [TranscriptSummary] { sessions }
}
