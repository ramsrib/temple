import Dispatch
import Foundation

/// Reads Codex sessions from `~/.codex/sessions/**/rollout-*.jsonl`, titling them
/// from `~/.codex/history.jsonl`. See SESSION-FORMATS.md.
public struct CodexSessionStore: TranscriptSummaryStore {
    public let agent: Agent = .codex
    let sessionsRoot: URL
    private let historyFile: URL
    private let sessionIndexFile: URL

    public init(root: URL? = nil) {
        // TEMPLE_CODEX_ROOT: see ClaudeSessionStore.
        let base = root
            ?? StoreIO.envRoot("TEMPLE_CODEX_ROOT")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        self.sessionsRoot = base.appendingPathComponent("sessions", isDirectory: true)
        self.historyFile = base.appendingPathComponent("history.jsonl")
        self.sessionIndexFile = base.appendingPathComponent("session_index.jsonl")
    }

    public var watchedURLs: [URL] { [sessionsRoot.deletingLastPathComponent(), sessionsRoot] }
    public var sharedTitleURLs: [URL] { titleURLs }
    public func loadSharedTitles() -> [String: String] { loadTitles() }
    public var titleURLs: [URL] { [historyFile, sessionIndexFile] }

    public var cacheInvalidationToken: String? {
        [historyFile, sessionIndexFile].map { url in
            guard let signature = StoreIO.fileSignature(url) else { return "missing" }
            return "\(signature.modificationDate.timeIntervalSinceReferenceDate):\(signature.fileSize)"
        }.joined(separator: "|")
    }

    public func loadSummaries() -> [TranscriptSummary] {
        let titles = loadTitles()
        let historyPrompts = loadSharedPrompts()
        let files = sessionFileURLs()
        let collector = TranscriptSummaryCollector()
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            if let summary = parse(file: files[index], sharedTitles: titles, historyPrompts: historyPrompts) {
                collector.append(summary)
            }
        }
        return collector.result()
    }

    public func loadSummary(at fileURL: URL) -> TranscriptSummary? {
        parse(file: fileURL, sharedTitles: loadTitles(), historyPrompts: loadSharedPrompts())
    }

    public func catalogParser() -> @Sendable (URL) -> TranscriptSummary? { catalogSummaryParser() }

    public func catalogSummaryParser() -> @Sendable (URL) -> TranscriptSummary? {
        let titles = loadTitles()
        let historyPrompts = loadSharedPrompts()
        let store = self
        return { store.parse(file: $0, sharedTitles: titles, historyPrompts: historyPrompts) }
    }

    public func loadSharedPrompts() -> [String: String] {
        loadHistoryTitles().compactMapValues { text in
            let cleaned = StoreIO.cleanTitle(text)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    public func sessionFileURLs() -> [URL] { (try? enumerateSessionFiles()) ?? [] }

    public func enumerateSessionFiles() throws -> [URL] { try enumerateRollouts(in: sessionsRoot) }

    public func enumerateSessionFiles(in subtree: URL) throws -> [URL] {
        let path = SessionPaths.normalized(subtree.path)
        let prefix = SessionPaths.normalized(sessionsRoot.path)
        if path == prefix || prefix.hasPrefix(path + "/") { return try enumerateSessionFiles() }
        guard path.hasPrefix(prefix + "/") else { return [] }
        return try enumerateRollouts(in: subtree)
    }

    private func enumerateRollouts(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        let physicalRoot = directory.resolvingSymlinksInPath()
        do { _ = try fm.contentsOfDirectory(atPath: physicalRoot.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        var failure: Error?
        guard let enumerator = fm.enumerator(at: physicalRoot, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false })
        else { throw CocoaError(.fileReadUnknown) }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") { files.append(url) }
        if let failure { throw failure }
        return files
    }

    public func acceptsTranscript(_ url: URL) -> Bool {
        url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") &&
            SessionPaths.normalized(url.path).hasPrefix(SessionPaths.normalized(sessionsRoot.path) + "/")
    }

    public func filenameID(at url: URL) -> String? { Self.rolloutName(at: url)?.threadID }
    public func rolloutSelectionKey(at url: URL) -> String? { Self.rolloutName(at: url)?.selectionKey }

    private static func rolloutName(at url: URL) -> (threadID: String, selectionKey: String)? {
        // Mirrors upstream rollout_file_name.rs: timestamp, stable thread ID,
        // and an optional distinct rollout ID for thread/revert.
        let name = url.lastPathComponent
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
        return (thread.uuidString.lowercased(), String(core.prefix(19)) + "-" + rollout.uuidString.lowercased())
    }

    private func metadataObject(at url: URL) throws -> [String: Any] {
        let data = try StoreIO.readFirstLine(url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    public func metadataHeader(at url: URL) -> CodexRolloutCandidate? { try? adoptionHeader(at: url) }

    /// Nil proves an exclusion. Invalid/partial eligible metadata throws, so
    /// adoption cannot mistake a failed read for a noncompeting rollout.
    public func adoptionHeader(at url: URL) throws -> CodexRolloutCandidate? {
        let object = try metadataObject(at: url)
        guard let type = object["type"] as? String else { throw CocoaError(.fileReadCorruptFile) }
        guard type == "session_meta" else { return nil }
        guard let payload = object["payload"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        guard !Self.isSubagentThread(payload) else { return nil }
        guard let id = (payload["id"] as? String) ?? (payload["session_id"] as? String), !id.isEmpty,
              let cwd = payload["cwd"] as? String,
              let date = StoreIO.parseDate((payload["timestamp"] as? String) ?? (object["timestamp"] as? String))
        else { throw CocoaError(.fileReadCorruptFile) }
        return CodexRolloutCandidate(sessionID: id, cwd: cwd, createdAt: date, filePath: url)
    }

    /// A thread spawned by another agent (`source.subagent.thread_spawn`, with
    /// the parent in `parent_thread_id`) has a rollout of its own, but it is
    /// not a session anyone opens: like Claude's `<session>/subagents/`
    /// transcripts, it belongs to its parent and is left out of the index.
    static func isSubagentThread(_ payload: [String: Any]) -> Bool {
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil { return true }
        return (payload["thread_source"] as? String) == "subagent"
    }

    private func parse(file: URL, sharedTitles: [String: String] = [:],
                       historyPrompts: [String: String] = [:]) -> TranscriptSummary? {
        let signature = StoreIO.fileSignature(file)
        guard let segments = StoreIO.boundedSegments(file, fileSize: signature?.fileSize),
              let head = segments.first,
              let firstLine = head.split(separator: "\n").first,
              let firstObject = StoreIO.jsonObject(firstLine),
              (firstObject["type"] as? String) == "session_meta",
              let payload = firstObject["payload"] as? [String: Any],
              !Self.isSubagentThread(payload),
              // The thread's own id. `session_id` is the ROOT thread's: equal to
              // `id` for a thread a person started, but a subagent's names its
              // parent — reading it first filed every subagent under its parent.
              let id = (payload["id"] as? String) ?? (payload["session_id"] as? String),
              !id.isEmpty
        else { return nil }

        let cwd = payload["cwd"] as? String
        let createdAt = StoreIO.parseDate(
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
                    obj = StoreIO.jsonObject(line)
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
                        preview = StoreIO.cleanTitle(text, cap: 160)
                        // `user_message` events hold the typed prompt; the
                        // role-user response_items also carry injected
                        // AGENTS.md instructions, so they can't title. Only
                        // the head segment can claim the FIRST prompt — a
                        // tail match in a large file may be a later turn, so
                        // it is kept as a last resort behind the deep scan.
                        if payloadType == "user_message" {
                            let cleaned = StoreIO.cleanTitle(text)
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

        // `codex exec` sessions record their prompt behind the injected
        // instruction blobs — routinely past the 64 KB head window — so when
        // nothing recorded a title, pay for one wider read to find it. Past
        // even that cap, a later prompt from the tail beats "(no prompt)".
        if fallbackTitle == nil {
            fallbackTitle = Self.firstUserMessage(in: file)
        }

        return TranscriptSummary(
            id: id,
            agent: .codex,
            locator: TranscriptLocator(localURL: file),
            modifiedAt: signature?.modificationDate ?? StoreIO.modificationDate(file),
            cwd: cwd,
            firstPrompt: fallbackTitle,
            historyPrompt: historyPrompts[id],
            createdAt: createdAt,
            gitBranch: branch,
            model: model,
            messageCount: count > 0 ? count : nil,
            lastMessagePreview: preview,
            originator: payload["originator"] as? String,
            sharedTitleHint: sharedTitles[id],
            laterPromptHint: tailFallbackTitle
        )
    }

    /// One deep read per still-untitled session (bounded; the instruction
    /// blobs preceding a prompt are large but nowhere near this cap).
    private static let promptScanBytes = 1024 * 1024

    private static func firstUserMessage(in file: URL) -> String? {
        guard let head = StoreIO.readHead(file, maxBytes: promptScanBytes) else { return nil }
        for line in head.split(separator: "\n") {
            guard let obj = StoreIO.jsonObject(line),
                  let item = obj["payload"] as? [String: Any],
                  (item["type"] as? String) == "user_message",
                  let text = Self.text(from: item) else { continue }
            let cleaned = StoreIO.cleanTitle(text)
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

    /// Best recorded title per session, already cleaned. The interactive
    /// TUI's history.jsonl prompt wins over the app-server's session_index
    /// thread name; `codex exec` sessions appear in neither file, so parse()
    /// falls back to the prompt inside the rollout itself. Entries that clean
    /// to nothing (e.g. a lone-space prompt) are dropped so the next source
    /// gets its turn.
    public func loadTitles() -> [String: String] {
        var titles: [String: String] = [:]
        for source in [loadIndexThreadNames(), loadHistoryTitles()] {
            for (id, text) in source {
                let cleaned = StoreIO.cleanTitle(text)
                if !cleaned.isEmpty { titles[id] = cleaned }
            }
        }
        return titles
    }

    /// Map `id → thread_name` from session_index.jsonl (written by app-server
    /// clients such as IDE companions; last entry per id wins).
    private func loadIndexThreadNames() -> [String: String] {
        guard let content = try? String(contentsOf: sessionIndexFile, encoding: .utf8) else {
            return [:]
        }
        var names: [String: String] = [:]
        for line in content.split(separator: "\n") {
            guard let obj = StoreIO.jsonObject(line),
                  let id = obj["id"] as? String,
                  let name = obj["thread_name"] as? String else { continue }
            names[id] = name
        }
        return names
    }

    /// Map `session_id → earliest prompt text` from history.jsonl.
    private func loadHistoryTitles() -> [String: String] {
        guard let content = try? String(contentsOf: historyFile, encoding: .utf8) else {
            return [:]
        }
        var earliest: [String: (ts: Double, text: String)] = [:]
        for line in content.split(separator: "\n") {
            guard let obj = StoreIO.jsonObject(line),
                  let id = obj["session_id"] as? String,
                  let text = obj["text"] as? String else { continue }
            let ts = (obj["ts"] as? Double) ?? .greatestFiniteMagnitude
            if let existing = earliest[id], existing.ts <= ts { continue }
            earliest[id] = (ts, text)
        }
        return earliest.mapValues(\.text)
    }
}
