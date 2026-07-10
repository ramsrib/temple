import Foundation

/// Reads Claude Code sessions from `~/.claude/projects/<encoded-cwd>/<id>.jsonl`.
/// See SESSION-FORMATS.md.
public struct ClaudeSessionStore: SessionStore {
    public let agent: Agent = .claude
    private let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public func loadSessions() -> [AgentSession] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        var sessions: [AgentSession] = []
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }

            for file in files where file.pathExtension == "jsonl" {
                if let session = parse(file: file, encodedDirName: dir.lastPathComponent) {
                    sessions.append(session)
                }
            }
        }
        return sessions
    }

    private func parse(file: URL, encodedDirName: String) -> AgentSession? {
        let id = file.deletingPathExtension().lastPathComponent
        guard let head = StoreIO.readHead(file) else { return nil }
        let lines = head.split(separator: "\n")

        var cwd: String?
        var createdAt: Date?
        var humanTitle: String?   // first real human prompt
        var anyUserTitle: String? // first user text of any kind (fallback)

        for line in lines {
            guard let obj = StoreIO.jsonObject(line) else { continue }
            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
            if createdAt == nil, let ts = obj["timestamp"] as? String {
                createdAt = StoreIO.parseDate(ts)
            }
            if humanTitle == nil, (obj["type"] as? String) == "user",
               let msg = obj["message"] as? [String: Any],
               let text = Self.text(from: msg["content"]), !text.isEmpty {
                if anyUserTitle == nil { anyUserTitle = text }
                if Self.isLikelyHumanPrompt(text) { humanTitle = text }
            }
            if cwd != nil, createdAt != nil, humanTitle != nil { break }
        }

        // Fallbacks: any user text, then a queued prompt; lossy dir-name for cwd.
        var title = humanTitle ?? anyUserTitle
        if title == nil {
            for line in lines {
                if let obj = StoreIO.jsonObject(line),
                   let c = obj["content"] as? String, !c.isEmpty {
                    title = c
                    break
                }
            }
        }
        let projectPath = cwd ?? Self.decodeDirName(encodedDirName)

        return AgentSession(
            id: id,
            agent: .claude,
            projectPath: projectPath,
            title: title.map { StoreIO.cleanTitle($0) } ?? "(untitled)",
            createdAt: createdAt,
            updatedAt: StoreIO.modificationDate(file),
            filePath: file
        )
    }

    /// Extract text from a Claude message `content`, which is either a string or
    /// an array of `{type:"text", text:"…"}` blocks.
    static func text(from content: Any?) -> String? {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            for item in arr {
                if let t = item["text"] as? String, !t.isEmpty { return t }
            }
        }
        return nil
    }

    /// Whether a user message looks like something the human actually typed,
    /// versus Claude Code's synthetic wrappers (slash-command echoes, caveats,
    /// hook output, bash-input blocks). Those start with an XML-ish `<…>` tag or
    /// the command caveat preamble.
    static func isLikelyHumanPrompt(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.hasPrefix("<") { return false } // <local-command-caveat>, <bash-input>, <command-name>, …
        if t.hasPrefix("Caveat:") { return false }
        if t.hasPrefix("[Request interrupted") { return false }
        return true
    }

    /// Best-effort reverse of the `/`→`-` dir encoding. Lossy — only a fallback
    /// when the file carries no `cwd`.
    static func decodeDirName(_ name: String) -> String {
        "/" + name.drop(while: { $0 == "-" }).replacingOccurrences(of: "-", with: "/")
    }
}
