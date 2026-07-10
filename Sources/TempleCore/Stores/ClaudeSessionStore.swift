import Dispatch
import Foundation

/// Reads Claude Code sessions from `~/.claude/projects/<encoded-cwd>/<id>.jsonl`.
/// See SESSION-FORMATS.md.
public struct ClaudeSessionStore: IncrementalSessionStore {
    public let agent: Agent = .claude
    private let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public var watchedURLs: [URL] { [root] }

    public func loadSessions() -> [AgentSession] {
        let files = sessionFileURLs()
        let collector = SessionCollector()
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            if let session = loadSession(at: files[index]) {
                collector.append(session)
            }
        }
        return collector.result()
    }

    public func sessionFileURLs() -> [URL] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        var files: [URL] = []
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let directoryFiles = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }

            files.append(contentsOf: directoryFiles.filter { $0.pathExtension == "jsonl" })
        }
        return files
    }

    public func loadSession(at fileURL: URL) -> AgentSession? {
        parse(file: fileURL, encodedDirName: fileURL.deletingLastPathComponent().lastPathComponent)
    }

    private func parse(file: URL, encodedDirName: String) -> AgentSession? {
        let id = file.deletingPathExtension().lastPathComponent
        let signature = StoreIO.fileSignature(file)
        guard let segments = StoreIO.boundedSegments(file, fileSize: signature?.fileSize),
              let head = segments.first, !head.isEmpty else { return nil }

        var cwd: String?
        var createdAt: Date?
        var humanTitle: String?   // first real human prompt
        var anyUserTitle: String? // first user text of any kind (fallback)
        var queuedTitle: String?
        var validTypedLine = false
        var count = 0
        var model: String?
        var preview: String?
        var branch: String?
        var summary: String?

        for segment in segments {
            for line in segment.split(separator: "\n") {
                guard let obj = StoreIO.jsonObject(line) else { continue }
                let type = obj["type"] as? String
                if type != nil { validTypedLine = true }
                if cwd == nil, let value = obj["cwd"] as? String { cwd = value }
                if createdAt == nil, let value = obj["timestamp"] as? String {
                    createdAt = StoreIO.parseDate(value)
                }
                if queuedTitle == nil, let value = obj["content"] as? String, !value.isEmpty {
                    queuedTitle = value
                }
                if type == "user" || type == "assistant" {
                    count += 1
                    if let message = obj["message"] as? [String: Any] {
                        if let value = message["model"] as? String { model = value }
                        if let text = Self.text(from: message["content"]), !text.isEmpty {
                            preview = StoreIO.cleanTitle(text, cap: 160)
                            if type == "user" {
                                if anyUserTitle == nil { anyUserTitle = text }
                                if humanTitle == nil, Self.isLikelyHumanPrompt(text) {
                                    humanTitle = text
                                }
                            }
                        }
                    }
                }
                if let value = obj["model"] as? String { model = value }
                if let value = obj["gitBranch"] as? String { branch = value }
                if let value = obj["summary"] as? String, !value.isEmpty {
                    summary = StoreIO.cleanTitle(value)
                }
            }
        }
        guard validTypedLine else { return nil }

        // Fallbacks: any user text, then a queued prompt; lossy dir-name for cwd.
        let title = humanTitle ?? anyUserTitle ?? queuedTitle
        let projectPath = cwd ?? Self.decodeDirName(encodedDirName)

        return AgentSession(
            id: id,
            agent: .claude,
            projectPath: projectPath,
            title: summary ?? title.map { StoreIO.cleanTitle($0) } ?? "(untitled)",
            createdAt: createdAt,
            updatedAt: signature?.modificationDate ?? StoreIO.modificationDate(file),
            filePath: file,
            messageCount: count > 0 ? count : nil,
            model: model,
            lastMessagePreview: preview,
            gitBranch: branch
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
