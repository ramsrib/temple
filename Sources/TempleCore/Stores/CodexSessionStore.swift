import Dispatch
import Foundation

/// Reads Codex sessions from `~/.codex/sessions/**/rollout-*.jsonl`, titling them
/// from `~/.codex/history.jsonl`. See SESSION-FORMATS.md.
public struct CodexSessionStore: IncrementalSessionStore {
    public let agent: Agent = .codex
    private let sessionsRoot: URL
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

    public var watchedURLs: [URL] { [sessionsRoot, historyFile, sessionIndexFile] }

    public var cacheInvalidationToken: String? {
        [historyFile, sessionIndexFile].map { url in
            guard let signature = StoreIO.fileSignature(url) else { return "missing" }
            return "\(signature.modificationDate.timeIntervalSinceReferenceDate):\(signature.fileSize)"
        }.joined(separator: "|")
    }

    public func loadSessions() -> [AgentSession] {
        let titles = loadTitles()
        let files = sessionFileURLs()
        let collector = SessionCollector()
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            if let session = parse(file: files[index], titles: titles) {
                collector.append(session)
            }
        }
        return collector.result()
    }

    public func sessionFileURLs() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-") else { continue }
            files.append(url)
        }
        return files
    }

    public func loadSession(at fileURL: URL) -> AgentSession? {
        parse(file: fileURL, titles: loadTitles())
    }

    private func parse(file: URL, titles: [String: String]) -> AgentSession? {
        let signature = StoreIO.fileSignature(file)
        guard let segments = StoreIO.boundedSegments(file, fileSize: signature?.fileSize),
              let head = segments.first,
              let firstLine = head.split(separator: "\n").first,
              let firstObject = StoreIO.jsonObject(firstLine),
              (firstObject["type"] as? String) == "session_meta",
              let payload = firstObject["payload"] as? [String: Any],
              let id = (payload["session_id"] as? String) ?? (payload["id"] as? String),
              !id.isEmpty
        else { return nil }

        let cwd = (payload["cwd"] as? String) ?? "(unknown)"
        let createdAt = StoreIO.parseDate(
            (payload["timestamp"] as? String) ?? (firstObject["timestamp"] as? String))
        var count = 0
        var model = payload["model_provider"] as? String
        var preview: String?
        var fallbackTitle: String?
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
                        // tail match in a large file may be a later turn.
                        if fallbackTitle == nil, segmentIndex == 0,
                           payloadType == "user_message" {
                            let cleaned = StoreIO.cleanTitle(text)
                            if !cleaned.isEmpty { fallbackTitle = cleaned }
                        }
                    }
                }
            }
        }

        // `codex exec` sessions record their prompt behind the injected
        // instruction blobs — routinely past the 64 KB head window — so when
        // nothing recorded a title, pay for one wider read to find it.
        if titles[id] == nil, fallbackTitle == nil {
            fallbackTitle = Self.firstUserMessage(in: file)
        }

        return AgentSession(
            id: id,
            agent: .codex,
            projectPath: cwd,
            title: titles[id] ?? fallbackTitle ?? "(no prompt)",
            createdAt: createdAt,
            updatedAt: signature?.modificationDate ?? StoreIO.modificationDate(file),
            filePath: file,
            messageCount: count > 0 ? count : nil,
            model: model,
            lastMessagePreview: preview,
            gitBranch: branch,
            originator: payload["originator"] as? String
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
    private func loadTitles() -> [String: String] {
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
