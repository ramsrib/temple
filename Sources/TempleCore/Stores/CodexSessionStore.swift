import Foundation

/// Reads Codex sessions from `~/.codex/sessions/**/rollout-*.jsonl`, titling them
/// from `~/.codex/history.jsonl`. See SESSION-FORMATS.md.
public struct CodexSessionStore: SessionStore {
    public let agent: Agent = .codex
    private let sessionsRoot: URL
    private let historyFile: URL

    public init(root: URL? = nil) {
        let base = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        self.sessionsRoot = base.appendingPathComponent("sessions", isDirectory: true)
        self.historyFile = base.appendingPathComponent("history.jsonl")
    }

    public func loadSessions() -> [AgentSession] {
        let titles = loadHistoryTitles()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var sessions: [AgentSession] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-") else { continue }
            if let session = parse(file: url, titles: titles) {
                sessions.append(session)
            }
        }
        return sessions
    }

    private func parse(file: URL, titles: [String: String]) -> AgentSession? {
        guard let head = StoreIO.readHead(file),
              let firstLine = head.split(separator: "\n").first,
              let obj = StoreIO.jsonObject(firstLine),
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let id = payload["session_id"] as? String
        else { return nil }

        let cwd = (payload["cwd"] as? String) ?? "(unknown)"
        let createdAt = StoreIO.parseDate(
            (payload["timestamp"] as? String) ?? (obj["timestamp"] as? String))
        let title = titles[id].map { StoreIO.cleanTitle($0) } ?? "(no prompt)"

        return AgentSession(
            id: id,
            agent: .codex,
            projectPath: cwd,
            title: title,
            createdAt: createdAt,
            updatedAt: StoreIO.modificationDate(file),
            filePath: file
        )
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
