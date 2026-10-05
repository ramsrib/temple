import Foundation
@testable import TempleCore
@testable import TempleLocalHost

/// Transcript shapes for the format characterization (`FormatGoldenTests`).
/// Every branch the agent formats take is represented: head/tail windows,
/// the Codex wide-head scan, synthetic Claude prompts, subagent exclusion,
/// identity caps, adoption headers, canonical rollout names, and the shared
/// Codex inputs in each state. Files get fixed modification dates so the
/// recorded facts are reproducible.
enum FormatCorpus {
    struct Fixture {
        let relativePath: String
        let agent: Agent
        /// The root the fixture's store reads (Claude: projects; Codex: base).
        let storeRoot: String
        let expectedID: String
    }

    static let claudeRoot = "claude"
    static let codexRoots = ["codex-plain", "codex-shared", "codex-index-only", "codex-invalid-utf8"]

    static func build(at root: URL) throws -> [Fixture] {
        var fixtures: [Fixture] = []
        var stamp = 1_700_000_000.0
        func write(_ data: Data, _ relative: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            stamp += 1
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: stamp)], ofItemAtPath: url.path)
        }
        func write(_ text: String, _ relative: String) throws { try write(Data(text.utf8), relative) }

        // MARK: Claude
        func claude(_ id: String, dir: String = "-work-project", _ lines: [String], separator: String = "\n", expected: String? = nil) throws {
            let relative = "\(claudeRoot)/\(dir)/\(id).jsonl"
            try write(lines.joined(separator: separator), relative)
            fixtures.append(Fixture(relativePath: relative, agent: .claude, storeRoot: claudeRoot, expectedID: expected ?? id))
        }
        let filler1K = String(repeating: "f", count: 1000)
        let assistantFiller = "{\"type\":\"assistant\",\"sessionId\":\"S\",\"message\":{\"content\":\"\(filler1K)\"}}"
        try claude("minimal", [#"{"type":"system"}"#])
        try claude("untyped", [#"{"note":"no type"}"#, #"{"cwd":"/x"}"#])
        try claude("empty", [])
        try claude("full", [
            #"{"type":"user","sessionId":"full","cwd":"/work/project","timestamp":"2026-01-01T00:00:00.123Z","gitBranch":"main","message":{"content":"  first   prompt ","model":"m1"}}"#,
            #"{"type":"assistant","sessionId":"full","message":{"content":[{"type":"text","text":"answer one"}],"model":"claude-opus"},"gitBranch":"feature"}"#,
            #"{"type":"summary","summary":"  recorded   title "}"#,
            #"{"type":"summary","summary":"second summary"}"#,
        ])
        try claude("synthetic", [
            #"{"type":"user","sessionId":"synthetic","message":{"content":"<command-name>/help</command-name>"}}"#,
            #"{"type":"user","sessionId":"synthetic","message":{"content":"Caveat: the messages below"}}"#,
            #"{"type":"user","sessionId":"synthetic","message":{"content":"[Request interrupted by user]"}}"#,
            #"{"type":"user","sessionId":"synthetic","message":{"content":"   "}}"#,
            #"{"type":"user","sessionId":"synthetic","message":{"content":"real prompt"}}"#,
        ])
        try claude("synthetic-only", [#"{"type":"user","sessionId":"synthetic-only","message":{"content":"<bash-input>ls</bash-input>"}}"#])
        try claude("queued", [
            #"{"type":"queue-operation","operation":"enqueue","content":"  queued   prompt "}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"second queued"}"#,
            #"{"type":"queue-operation","operation":"dequeue","content":"gone"}"#,
        ])
        try claude("content-array", [
            #"{"type":"user","sessionId":"content-array","message":{"content":[{"type":"image"},{"type":"text","text":""},{"type":"text","text":"array prompt"}]}}"#,
        ])
        try claude("top-level-content", [#"{"type":"system","content":"status line"}"#, #"{"content":"untyped content"}"#])
        try claude("top-model", [#"{"type":"system","model":"top-level-model","sessionId":"top-model"}"#, #"{"model":"later-untyped"}"#])
        try claude("malformed", ["{not json", #"{"type":"user","sessionId":"malformed","message":{"content":"after garbage"}}"#, "", "]", #"{"type":5}"#])
        try claude("crlf", [#"{"type":"user","sessionId":"crlf","cwd":"/crlf","message":{"content":"crlf prompt"}}"#, #"{"type":"assistant","message":{"content":"ok"}}"#], separator: "\r\n")
        try claude("dir-hint", dir: "-Users-me-my-project", [#"{"type":"system"}"#])
        try claude("dotted.name", [#"{"type":"user","sessionId":"dotted.name","message":{"content":"dots"}}"#])
        try claude("mismatch", [#"{"type":"user","sessionId":"someone-else","message":{"content":"x"}}"#])
        try claude("untyped-id-first", [#"{"sessionId":"untyped-id-first"}"#, #"{"type":"system"}"#, #"{"type":"user","sessionId":"untyped-id-first"}"#])
        try claude("typed-no-id-first", [#"{"type":"system"}"#, #"{"type":"user","sessionId":"typed-no-id-first"}"#])
        try claude("eof-no-newline", [#"{"note":"x"}"#, #"{"type":"user","sessionId":"eof-no-newline"}"#])
        try claude("bad-utf8-content", ["{\"type\":\"user\",\"sessionId\":\"bad-utf8-content\",\"message\":{\"content\":\"caf\u{e9}\"}}"])
        // Head and tail windows.
        var tailOnly = [#"{"type":"system","sessionId":"tail-only","cwd":"/work"}"#]
        tailOnly += Array(repeating: assistantFiller, count: 200)
        tailOnly.append(#"{"type":"user","sessionId":"tail-only","message":{"content":"A later turn"}}"#)
        try claude("tail-only", tailOnly)
        var tailQueue = [#"{"type":"system","sessionId":"tail-queue"}"#]
        tailQueue += Array(repeating: assistantFiller, count: 150)
        tailQueue.append(#"{"type":"queue-operation","operation":"enqueue","content":"queued late"}"#)
        tailQueue.append(#"{"type":"summary","summary":"late summary"}"#)
        try claude("tail-queue", tailQueue)
        // Between one and two windows: the tail is only the remainder.
        var medium = [#"{"type":"user","sessionId":"medium","message":{"content":"head prompt"}}"#]
        medium += Array(repeating: assistantFiller, count: 90)
        medium.append(#"{"type":"user","sessionId":"medium","message":{"content":"medium tail"}}"#)
        try claude("medium", medium)
        // A multi-byte character straddling the 64 KiB boundary.
        let straddlePrefix = #"{"type":"user","sessionId":"straddle","message":{"content":""#
        let pad = 65_536 - straddlePrefix.utf8.count - 1
        let straddle = straddlePrefix + String(repeating: "a", count: pad) + "\u{1F600}tail\"}}"
        try claude("straddle", [straddle, #"{"type":"assistant","message":{"content":"after straddle"}}"#])
        // Exactly one window.
        let exactPrefix = #"{"type":"user","sessionId":"exact","message":{"content":""#
        let exact = exactPrefix + String(repeating: "e", count: 65_536 - exactPrefix.utf8.count - 4) + "\"}}"
        try claude("exact", [exact])
        // Identity scan past its cap.
        let untyped = String(repeating: "{\"note\":\"\(String(repeating: "y", count: 500))\"}\n", count: 2200)
        try write(untyped + #"{"type":"user","sessionId":"beyond-cap"}"#, "\(claudeRoot)/-work-project/beyond-cap.jsonl")
        fixtures.append(Fixture(relativePath: "\(claudeRoot)/-work-project/beyond-cap.jsonl", agent: .claude, storeRoot: claudeRoot, expectedID: "beyond-cap"))
        try claude("many-turns", (0..<40).map { i in
            i % 2 == 0 ? "{\"type\":\"user\",\"message\":{\"content\":\"turn \(i)\"}}" : "{\"type\":\"assistant\",\"message\":{\"content\":\"reply \(i)\",\"model\":\"m\(i)\"}}"
        })
        // Long messages and whitespace that is not a plain space, around and
        // across the title and preview caps (`TranscriptText.cleanTitle`).
        try claude("long-unicode", [
            json(["type": "user", "sessionId": "long-unicode", "message": ["content": longUnicode(0)]]),
            json(["type": "assistant", "sessionId": "long-unicode", "message": ["content": longUnicode(1)]]),
            json(["type": "queue-operation", "operation": "enqueue", "content": longUnicode(2)]),
            json(["type": "summary", "summary": longUnicode(3)]),
            json(["type": "user", "sessionId": "long-unicode", "message": ["content": [["type": "text", "text": longUnicode(4)]]]]),
        ])
        var longTail = [json(["type": "system", "sessionId": "long-tail", "cwd": "/work"])]
        longTail += Array(repeating: assistantFiller, count: 200)
        longTail.append(json(["type": "user", "sessionId": "long-tail", "message": ["content": longUnicode(5)]]))
        longTail.append(json(["type": "assistant", "sessionId": "long-tail", "message": ["content": "\n\t \u{a0}"]]))
        try claude("long-tail", longTail)

        // MARK: Codex
        func codex(_ root: String, _ name: String, _ lines: [String], expected: String, raw: Data? = nil) throws {
            let relative = "\(root)/sessions/2026/10/01/\(name)"
            if let raw { try write(raw, relative) } else { try write(lines.joined(separator: "\n"), relative) }
            fixtures.append(Fixture(relativePath: relative, agent: .codex, storeRoot: root, expectedID: expected))
        }
        func meta(_ payload: String, top: String = "") -> String {
            #"{"type":"session_meta"\#(top),"payload":\#(payload)}"#
        }
        func userMessage(_ text: String) -> String { #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(text)"}}"# }
        func padding(_ bytes: Int) -> String { #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(String(repeating: "x", count: bytes))"}]}}"# }
        let threadA = "0199a213-81c0-7800-8aa1-bbab2a035a53"
        let threadB = "0199a213-81c0-7800-8aa1-bbab2a035a54"
        let rolloutB2 = "0199a213-81c0-7800-8aa1-bbab2a0aaaaa"
        for root in codexRoots {
            try codex(root, "rollout-minimal.jsonl", [meta(#"{"id":"c-minimal"}"#)], expected: "c-minimal")
            try codex(root, "rollout-session-id.jsonl", [meta(#"{"session_id":"c-sid","cwd":"/w"}"#)], expected: "c-sid")
            try codex(root, "rollout-both.jsonl", [meta(#"{"id":"c-own","session_id":"c-root","cwd":"/w"}"#)], expected: "c-own")
            try codex(root, "rollout-sub-source.jsonl", [meta(#"{"id":"c-sub","cwd":"/w","timestamp":"2026-01-01T00:00:00Z","source":{"subagent":{"thread_spawn":{}}}}"#)], expected: "c-sub")
            try codex(root, "rollout-sub-thread.jsonl", [meta(#"{"id":"c-sub2","cwd":"/w","timestamp":"2026-01-01T00:00:00Z","thread_source":"subagent"}"#)], expected: "c-sub2")
            try codex(root, "rollout-not-meta.jsonl", [#"{"type":"event_msg","payload":{"id":"c-not"}}"#], expected: "c-not")
            try codex(root, "rollout-untyped.jsonl", [#"{"payload":{"id":"c-untyped"}}"#], expected: "c-untyped")
            try codex(root, "rollout-malformed.jsonl", ["{oops", meta(#"{"id":"c-mal"}"#)], expected: "c-mal")
            try codex(root, "rollout-empty.jsonl", [], expected: "c-empty")
            try codex(root, "rollout-leading-newline.jsonl", ["", meta(#"{"id":"c-lead","cwd":"/lead"}"#)], expected: "c-lead")
            try codex(root, "rollout-full.jsonl", [
                meta(#"{"id":"c-full","cwd":"/work/project","timestamp":"2026-01-01T00:00:00Z","model_provider":"openai","originator":"codex-tui","git":{"branch":"dev"}}"#),
                #"{"type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"AGENTS.md instructions"}]}}"#,
                userMessage("   "),
                userMessage("  the   prompt "),
                #"{"type":"turn_context","payload":{"model":"gpt-5"}}"#,
                #"{"type":"event_msg","payload":{"type":"agent_message","message":"done"}}"#,
                #"{"type":"response_item","payload":{"role":"assistant","content":"string content"}}"#,
                #"{"type":"event_msg","payload":"not a dict"}"#,
                #"{"type":"event_msg","payload":{"type":"user_message","text":"via text"}}"#,
            ], expected: "c-full")
            try codex(root, "rollout-top-timestamp.jsonl", [meta(#"{"id":"c-top","cwd":"/w"}"#, top: #","timestamp":"2026-02-03T04:05:06.789Z""#)], expected: "c-top")
            try codex(root, "rollout-wide.jsonl", [meta(#"{"id":"c-wide","cwd":"/w"}"#), padding(80_000), userMessage("wide prompt")], expected: "c-wide")
            try codex(root, "rollout-beyond.jsonl", [meta(#"{"id":"c-beyond","cwd":"/w"}"#), padding(1_100_000), userMessage("tail prompt"), userMessage("last")], expected: "c-beyond")
            try codex(root, "rollout-bare.jsonl", [meta(#"{"id":"c-bare","cwd":"/w"}"#), #"{"type":"response_item","payload":{"role":"user","content":"instructions only"}}"#], expected: "c-bare")
            try codex(root, "rollout-medium.jsonl", [meta(#"{"id":"c-medium","cwd":"/w"}"#), padding(70_000), userMessage("medium prompt")], expected: "c-medium")
            try codex(root, "rollout-crlf.jsonl", [meta(#"{"id":"c-crlf","cwd":"/w"}"#) + "\r", userMessage("crlf prompt") + "\r"], expected: "c-crlf")
            try codex(root, "rollout-no-cwd.jsonl", [meta(#"{"id":"c-nocwd","timestamp":"2026-01-01T00:00:00Z"}"#)], expected: "c-nocwd")
            try codex(root, "rollout-no-time.jsonl", [meta(#"{"id":"c-notime","cwd":"/w"}"#)], expected: "c-notime")
            try codex(root, "rollout-no-type-field.jsonl", [#"{"payload":{"id":"c-ntf","cwd":"/w","timestamp":"2026-01-01T00:00:00Z"}}"#], expected: "c-ntf")
            try codex(root, "rollout-no-payload.jsonl", [#"{"type":"session_meta"}"#], expected: "c-np")
            try codex(root, "rollout-overlong.jsonl", [meta(#"{"id":"c-long","cwd":"/w","timestamp":"2026-01-01T00:00:00Z","junk":"\#(String(repeating: "j", count: 70_000))"}"#)], expected: "c-long")
            try codex(root, "rollout-empty-id.jsonl", [meta(#"{"id":"","session_id":"c-fallback","cwd":"/w"}"#)], expected: "c-fallback")
            // Canonical names: thread only, thread + rollout (revert), a bad date.
            try codex(root, "rollout-2026-10-01T10-00-00-\(threadA).jsonl", [meta(#"{"id":"\#(threadA)","cwd":"/w","timestamp":"2026-10-01T10:00:00Z"}"#), userMessage("canonical")], expected: threadA)
            try codex(root, "rollout-2026-10-01T11-00-00-\(threadB.uppercased())_\(rolloutB2).jsonl", [meta(#"{"id":"\#(threadB)","cwd":"/w","timestamp":"2026-10-01T11:00:00Z"}"#)], expected: threadB)
            try codex(root, "rollout-2026-02-30T10-00-00-\(threadA).jsonl", [meta(#"{"id":"\#(threadA)","cwd":"/w"}"#)], expected: threadA)
            try codex(root, "rollout-2024-02-29T23-59-59-\(threadB).jsonl", [meta(#"{"id":"\#(threadB)","cwd":"/w"}"#)], expected: threadB)
            try codex(root, "rollout-2026-10-01T10-00-00-not-a-uuid.jsonl", [meta(#"{"id":"x","cwd":"/w"}"#)], expected: "x")
            try codex(root, "rollout-hist.jsonl", [meta(#"{"id":"c-hist","cwd":"/w"}"#), userMessage("rollout prompt")], expected: "c-hist")
            try codex(root, "rollout-index.jsonl", [meta(#"{"id":"c-index","cwd":"/w"}"#)], expected: "c-index")
            try codex(root, "rollout-blank-hist.jsonl", [meta(#"{"id":"c-blank","cwd":"/w"}"#)], expected: "c-blank")
            try codex(root, "rollout-content-array.jsonl", [meta(#"{"id":"c-array","cwd":"/w"}"#), #"{"type":"event_msg","payload":{"type":"user_message","content":[{"input_text":""},{"input_text":"array text"}]}}"#], expected: "c-array")
            try codex(root, "rollout-long-unicode.jsonl", [
                meta(#"{"id":"c-long-uni","cwd":"/w"}"#),
                json(["type": "event_msg", "payload": ["type": "user_message", "message": " \n\t "]]),
                json(["type": "event_msg", "payload": ["type": "user_message", "message": longUnicode(6)]]),
                json(["type": "event_msg", "payload": ["type": "agent_message", "message": longUnicode(7)]]),
            ], expected: "c-long-uni")
            try codex(root, "rollout-long-tail.jsonl", [
                meta(#"{"id":"c-long-tail","cwd":"/w"}"#), userMessage("head prompt"), padding(140_000),
                json(["type": "event_msg", "payload": ["type": "user_message", "message": longUnicode(8)]]),
            ], expected: "c-long-tail")
        }
        // Shared inputs per root.
        try write("""
        {"session_id":"c-hist","ts":20,"text":"history later"}
        {"session_id":"c-hist","ts":10,"text":"  history   first "}
        {"session_id":"c-blank","ts":10,"text":"   "}
        {"session_id":"c-full","text":"no timestamp"}
        {"session_id":"c-full","ts":5,"text":"earliest full"}
        {"session_id":"\(threadA)","ts":1,"text":"thread a prompt"}
        \(json(["session_id": "c-long-uni", "ts": 1, "text": longUnicode(9)]))
        not json
        """, "codex-shared/history.jsonl")
        try write("""
        {"id":"c-hist","thread_name":"index loses to history"}
        {"id":"c-index","thread_name":"stale"}
        {"id":"c-index","thread_name":"  companion   thread "}
        {"id":"c-blank","thread_name":"blank falls to index"}
        """, "codex-shared/session_index.jsonl")
        try write(#"{"id":"c-index","thread_name":"only the index"}"#, "codex-index-only/session_index.jsonl")
        var invalid = Data(#"{"session_id":"c-hist","ts":1,"text":"bad "#.utf8)
        invalid.append(contentsOf: [0xff, 0xfe])
        invalid.append(contentsOf: Data("\"}\n".utf8))
        try write(invalid, "codex-invalid-utf8/history.jsonl")
        try write(#"{"id":"c-index","thread_name":"index beside bad history"}"#, "codex-invalid-utf8/session_index.jsonl")
        return fixtures
    }
}

extension FormatCorpus {
    /// One JSONL line, keys sorted so the bytes are reproducible.
    static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    /// A long message whose whitespace is every kind the title cleaner
    /// collapses (runs, tabs, CRLF, NBSP, a paragraph separator) beside
    /// characters a careless cut would split or merge: a combining mark right
    /// after a newline (it joins the space that replaces the newline), an
    /// Arabic prepend before one, ZWJ families and flags. `variant` shifts
    /// where they fall against the 160- and 200-character caps.
    static func longUnicode(_ variant: Int) -> String {
        let pieces = ["word", "\n\u{301}accent", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F1FA}\u{1F1F8}\u{1F1EC}\u{1F1E7}",
                      "tab\t\tbed", "crlf\r\nline", "nbsp\u{a0}\u{a0}gap", "para\u{2029}sep", "\u{600}\nprepend",
                      "e\u{301}", "  ", "\u{65E5}\u{672C}\u{8A9E}"]
        var text = String(repeating: " ", count: variant % 3)
        for index in 0..<(70 + variant * 7) {
            text += pieces[(index + variant) % pieces.count]
            text += index % 5 == 0 ? " \t \n " : " "
        }
        return text
    }
}

/// What the stores report for one fixture, in a form a JSON file can hold.
struct FormatGoldenRecord: Codable, Equatable {
    var file: String
    var summary: [String: String]?
    var identity: String
    var identityOther: String
    var header: String
    var filenameID: String?
    var selectionKey: String?

    static func describe(_ summary: TranscriptSummary?, root: URL) -> [String: String]? {
        guard let s = summary else { return nil }
        var d: [String: String] = [:]
        func put(_ key: String, _ value: String?) { if let value { d[key] = value } }
        put("id", s.id); put("agent", s.agent.rawValue)
        put("path", String(s.locator.path.dropFirst(root.path.count + 1)))
        put("modifiedAt", String(s.modifiedAt.timeIntervalSince1970))
        put("cwd", s.cwd); put("firstPrompt", s.firstPrompt); put("historyPrompt", s.historyPrompt)
        put("createdAt", s.createdAt.map { String($0.timeIntervalSince1970) })
        put("gitBranch", s.gitBranch); put("model", s.model)
        put("messageCount", s.messageCount.map(String.init)); put("lastMessagePreview", s.lastMessagePreview)
        put("originator", s.originator); put("sharedTitle", s.sharedTitle); put("recordedTitle", s.recordedTitle)
        put("directoryHint", s.directoryHint); put("laterPromptHint", s.laterPromptHint)
        put("legacyTitleHint", s.legacyTitleHint)
        return d
    }

    static func capture(_ fixtures: [FormatCorpus.Fixture], root: URL) -> [FormatGoldenRecord] {
        var stores: [String: any IncrementalSessionStore] = [:]
        func store(_ f: FormatCorpus.Fixture) -> any IncrementalSessionStore {
            if let s = stores[f.storeRoot] { return s }
            let url = root.appendingPathComponent(f.storeRoot)
            let s: any IncrementalSessionStore = f.agent == .claude ? ClaudeSessionStore(root: url) : CodexSessionStore(root: url)
            stores[f.storeRoot] = s
            return s
        }
        func verdict(_ body: () throws -> TranscriptVerification) -> String {
            do { return "\(try body())" } catch { return "throws" }
        }
        return fixtures.map { f in
            let s = store(f)
            let url = root.appendingPathComponent(f.relativePath)
            let header: String
            do {
                if let h = try s.adoptionHeader(at: url) {
                    // The header names no file now; the last field is kept for
                    // the golden record's shape (the file read is `url`).
                    header = "\(h.id)|\(h.cwd)|\(h.createdAt.timeIntervalSince1970)|true"
                } else { header = "nil" }
            } catch { header = "throws" }
            return FormatGoldenRecord(
                file: f.relativePath,
                summary: describe(s.loadSummary(at: url), root: root),
                identity: verdict { try s.verifyIdentity(at: url, expectedID: f.expectedID) },
                identityOther: verdict { try s.verifyIdentity(at: url, expectedID: "other-id") },
                header: header,
                filenameID: s.filenameID(at: url),
                selectionKey: s.rolloutSelectionKey(at: url))
        }
    }
}
