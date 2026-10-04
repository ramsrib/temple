import Foundation

/// Codex rollouts: `<codex root>/sessions/**/rollout-<stamp>-<thread>[_<rollout>].jsonl`,
/// titled from the shared `history.jsonl` and `session_index.jsonl`. See
/// SESSION-FORMATS.md.
public struct CodexFormat: TranscriptFormat {
    public let agent: Agent = .codex
    /// One wider head per still-untitled rollout: `codex exec` records its
    /// prompt behind injected instruction blobs, routinely past the head
    /// window but nowhere near this cap.
    public static let promptScanBytes = 1024 * 1024
    public static let headerLineBytes = 64 * 1024
    public static let historyInput = "history.jsonl"
    public static let sessionIndexInput = "session_index.jsonl"
    public init() {}

    /// Mirrors upstream rollout_file_name.rs: timestamp, stable thread ID,
    /// and an optional distinct rollout ID for thread/revert.
    public func name(path: String) -> TranscriptName? {
        let name = TranscriptText.lastComponent(path)
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let core = name.dropFirst(8).dropLast(6)
        guard core.count >= 20 else { return nil }
        let stamp = Array(core.prefix(20).utf8)
        guard stamp.count == 20, stamp[4] == 45, stamp[7] == 45, stamp[10] == 84,
              stamp[13] == 45, stamp[16] == 45, stamp[19] == 45 else { return nil }
        let digitOffsets = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
        guard digitOffsets.allSatisfy({ (48...57).contains(stamp[$0]) }) else { return nil }
        func number(_ range: Range<Int>) -> Int { range.reduce(0) { $0 * 10 + Int(stamp[$1] - 48) } }
        let year = number(0..<4), month = number(5..<7), day = number(8..<10)
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...days[month - 1]).contains(day),
              number(11..<13) < 24, number(14..<16) < 60, number(17..<19) < 60 else { return nil }
        let ids = core.dropFirst(20).split(separator: "_", omittingEmptySubsequences: false)
        guard (1...2).contains(ids.count), let thread = UUID(uuidString: String(ids[0])) else { return nil }
        guard let rollout = ids.count == 2 ? UUID(uuidString: String(ids[1])) : thread else { return nil }
        return TranscriptName(threadID: thread.uuidString.lowercased(),
                              selectionKey: String(core.prefix(19)) + "-" + rollout.uuidString.lowercased())
    }

    /// The thread's active rollout: the highest selection key, ties broken by
    /// the path that sorts last — the CLI's own resume pick, so a revert is
    /// what loads, never the older canonical file it replaced.
    public func select(_ names: [(path: String, name: TranscriptName)]) -> String? {
        var best: (path: String, key: String)?
        for (path, name) in names {
            guard let key = name.selectionKey else { continue }
            if let current = best, key < current.key || (key == current.key && path <= current.path) { continue }
            best = (path, key)
        }
        return best?.path
    }

    public var identityScan: IdentityScan { .firstLine(maxBytes: Self.headerLineBytes) }

    public func identity(lines: some Sequence<Data>, expecting id: String) -> TranscriptVerification {
        guard let line = lines.first(where: { _ in true }),
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let found = Self.threadID(payload) else { return .incomplete }
        return found == id ? .verified : .mismatch
    }

    public func header(firstLine: Data) throws -> AdoptionCandidate? {
        guard let object = try JSONSerialization.jsonObject(with: firstLine) as? [String: Any] else {
            throw TranscriptFormatError.corruptHeader
        }
        guard let type = object["type"] as? String else { throw TranscriptFormatError.corruptHeader }
        guard type == "session_meta" else { return nil }
        guard let payload = object["payload"] as? [String: Any] else { throw TranscriptFormatError.corruptHeader }
        guard !Self.isSubagentThread(payload) else { return nil }
        guard let id = Self.threadID(payload),
              let cwd = payload["cwd"] as? String,
              let date = TranscriptText.parseDate((payload["timestamp"] as? String) ?? (object["timestamp"] as? String))
        else { throw TranscriptFormatError.corruptHeader }
        return AdoptionCandidate(id: id, cwd: cwd, createdAt: date)
    }

    /// The one reading of a rollout header's thread id, shared by parsing,
    /// identity verification and adoption so they cannot disagree. `id` is
    /// the thread's own; `session_id` is the ROOT thread's — equal to `id` for
    /// a thread a person started, but a subagent's names its parent, so it is
    /// only a fallback for headers that carry no `id`.
    static func threadID(_ payload: [String: Any]) -> String? {
        guard let id = (payload["id"] as? String) ?? (payload["session_id"] as? String), !id.isEmpty else { return nil }
        return id
    }

    /// A thread spawned by another agent (`source.subagent.thread_spawn`, with
    /// the parent in `parent_thread_id`) has a rollout of its own, but it is
    /// not a session anyone opens: like Claude's `<session>/subagents/`
    /// transcripts, it belongs to its parent and is left out of the index.
    static func isSubagentThread(_ payload: [String: Any]) -> Bool {
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil { return true }
        return (payload["thread_source"] as? String) == "subagent"
    }

    public func facts(_ bytes: TranscriptBytes, name: TranscriptName?, locator: TranscriptLocator,
                      modifiedAt: Date, shared: SharedFacts) -> TranscriptFacts {
        let head = String(decoding: bytes.head, as: UTF8.self)
        let segments = [head] + (bytes.tail.map { [String(decoding: $0, as: UTF8.self)] } ?? [])
        guard let firstLine = head.split(separator: "\n").first,
              let firstObject = TranscriptText.jsonObject(firstLine),
              (firstObject["type"] as? String) == "session_meta",
              let payload = firstObject["payload"] as? [String: Any],
              !Self.isSubagentThread(payload),
              let id = Self.threadID(payload)
        else { return .unparseable }

        let cwd = payload["cwd"] as? String
        let createdAt = TranscriptText.parseDate(
            (payload["timestamp"] as? String) ?? (firstObject["timestamp"] as? String))
        var count = 0
        var model = payload["model_provider"] as? String
        var preview: String?
        var fallbackTitle: String?
        var tailFallbackTitle: String?
        let git = payload["git"] as? [String: Any]
        let branch = git?["branch"] as? String

        for (segmentIndex, segment) in segments.enumerated() {
            for (lineIndex, line) in segment.split(separator: "\n").enumerated() {
                let obj: [String: Any]?
                if segmentIndex == 0 && lineIndex == 0 {
                    obj = firstObject
                } else {
                    obj = TranscriptText.jsonObject(line)
                }
                guard let obj, let item = obj["payload"] as? [String: Any] else { continue }
                if let value = item["model"] as? String { model = value }
                let type = obj["type"] as? String
                let role = item["role"] as? String
                let payloadType = item["type"] as? String
                let isTurn = role == "user" || role == "assistant" ||
                    payloadType == "user_message" || payloadType == "agent_message"
                if isTurn && type != "session_meta" {
                    count += 1
                    if let text = Self.text(from: item), !text.isEmpty {
                        preview = TranscriptText.cleanTitle(text, cap: 160)
                        // `user_message` events hold the typed prompt; the
                        // role-user response_items also carry injected
                        // AGENTS.md instructions, so they can't title. Only
                        // the head segment can claim the FIRST prompt — a
                        // tail match in a large file may be a later turn, so
                        // it is kept as a last resort behind the deep scan.
                        if payloadType == "user_message" {
                            let cleaned = TranscriptText.cleanTitle(text)
                            if !cleaned.isEmpty {
                                if segmentIndex == 0 {
                                    if fallbackTitle == nil { fallbackTitle = cleaned }
                                } else if tailFallbackTitle == nil {
                                    tailFallbackTitle = cleaned
                                }
                            }
                        }
                    }
                }
            }
        }

        // Nothing in the head stated the prompt: one wider read may find it.
        // A head that is already the whole file is its own wider read.
        if fallbackTitle == nil {
            if let wider = bytes.widerHead { fallbackTitle = Self.firstUserMessage(in: wider) }
            else if bytes.headIsWholeFile { fallbackTitle = Self.firstUserMessage(in: bytes.head) }
            else { return .needsWiderHead(bytes: Self.promptScanBytes) }
        }

        return .summary(TranscriptSummary(
            id: id,
            agent: .codex,
            locator: locator,
            modifiedAt: modifiedAt,
            cwd: cwd,
            firstPrompt: fallbackTitle,
            historyPrompt: shared.prompts[id],
            createdAt: createdAt,
            gitBranch: branch,
            model: model,
            messageCount: count > 0 ? count : nil,
            lastMessagePreview: preview,
            originator: payload["originator"] as? String,
            sharedTitle: shared.titles[id],
            laterPromptHint: tailFallbackTitle,
            selectionKey: name?.selectionKey
        ))
    }

    private static func firstUserMessage(in head: Data) -> String? {
        for line in TranscriptText.lines(head) {
            guard let obj = TranscriptText.jsonObject(line),
                  let item = obj["payload"] as? [String: Any],
                  (item["type"] as? String) == "user_message",
                  let text = Self.text(from: item) else { continue }
            let cleaned = TranscriptText.cleanTitle(text)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    private static func text(from payload: [String: Any]) -> String? {
        if let text = payload["text"] as? String { return text }
        if let message = payload["message"] as? String { return message }
        if let content = payload["content"] as? String { return content }
        if let content = payload["content"] as? [[String: Any]] {
            return content.compactMap { ($0["text"] as? String) ?? ($0["input_text"] as? String) }
                .first(where: { !$0.isEmpty })
        }
        return nil
    }

    // MARK: Shared facts

    public var sharedInputs: [String] { [Self.historyInput, Self.sessionIndexInput] }

    /// The interactive TUI's history.jsonl prompt wins over the app-server's
    /// session_index thread name; `codex exec` sessions appear in neither, so
    /// their title comes from the rollout itself. Entries that clean to
    /// nothing (a lone-space prompt) are dropped so the next source gets its
    /// turn. A file that is not valid UTF-8 contributes nothing.
    public func sharedFacts(_ inputs: [String: Data]) -> SharedFacts {
        let history = Self.historyPrompts(inputs[Self.historyInput])
        let names = Self.threadNames(inputs[Self.sessionIndexInput])
        var titles: [String: String] = [:]
        for source in [names, history] {
            for (id, text) in source {
                let cleaned = TranscriptText.cleanTitle(text)
                if !cleaned.isEmpty { titles[id] = cleaned }
            }
        }
        let prompts = history.compactMapValues { text -> String? in
            let cleaned = TranscriptText.cleanTitle(text)
            return cleaned.isEmpty ? nil : cleaned
        }
        return SharedFacts(titles: titles, prompts: prompts)
    }

    /// `id → thread_name` from session_index.jsonl (written by app-server
    /// clients such as IDE companions; the last entry per id wins).
    private static func threadNames(_ data: Data?) -> [String: String] {
        guard let data, let content = String(data: data, encoding: .utf8) else { return [:] }
        var names: [String: String] = [:]
        for line in content.split(separator: "\n") {
            guard let obj = TranscriptText.jsonObject(line),
                  let id = obj["id"] as? String,
                  let name = obj["thread_name"] as? String else { continue }
            names[id] = name
        }
        return names
    }

    /// `session_id → earliest prompt text` from history.jsonl.
    private static func historyPrompts(_ data: Data?) -> [String: String] {
        guard let data, let content = String(data: data, encoding: .utf8) else { return [:] }
        var earliest: [String: (ts: Double, text: String)] = [:]
        for line in content.split(separator: "\n") {
            guard let obj = TranscriptText.jsonObject(line),
                  let id = obj["session_id"] as? String,
                  let text = obj["text"] as? String else { continue }
            let ts = (obj["ts"] as? Double) ?? .greatestFiniteMagnitude
            if let existing = earliest[id], existing.ts <= ts { continue }
            earliest[id] = (ts, text)
        }
        return earliest.mapValues(\.text)
    }
}
