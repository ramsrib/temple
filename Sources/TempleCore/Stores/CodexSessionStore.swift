import Dispatch
import Foundation

/// Reads Codex sessions from `~/.codex/sessions/**/rollout-*.jsonl`, titling them
/// from `~/.codex/history.jsonl`. See SESSION-FORMATS.md.
public struct CodexSessionStore: IncrementalSessionStore {
    public let agent: Agent = .codex
    private let sessionsRoot: URL
    private let historyFile: URL

    public init(root: URL? = nil) {
        let base = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        self.sessionsRoot = base.appendingPathComponent("sessions", isDirectory: true)
        self.historyFile = base.appendingPathComponent("history.jsonl")
    }

    public var watchedURLs: [URL] { [sessionsRoot, historyFile] }

    public var cacheInvalidationToken: String? {
        guard let signature = StoreIO.fileSignature(historyFile) else { return "missing" }
        return "\(signature.modificationDate.timeIntervalSinceReferenceDate):\(signature.fileSize)"
    }

    public func loadSessions() -> [AgentSession] {
        let titles = loadHistoryTitles()
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
        parse(file: fileURL, titles: loadHistoryTitles())
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
        let title = titles[id].map { StoreIO.cleanTitle($0) } ?? "(no prompt)"
        var count = 0
        var model = payload["model_provider"] as? String
        var preview: String?
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
                    }
                }
            }
        }

        return AgentSession(
            id: id,
            agent: .codex,
            projectPath: cwd,
            title: title,
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
