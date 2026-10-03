import Dispatch
import Foundation

/// Reads Claude Code sessions from `~/.claude/projects/<encoded-cwd>/<id>.jsonl`.
/// See SESSION-FORMATS.md.
public struct ClaudeSessionStore: TranscriptSummaryStore {
    public let agent: Agent = .claude
    private let root: URL

    public init(root: URL? = nil) {
        // TEMPLE_CLAUDE_ROOT points the index at an alternate store (testing,
        // demos, screenshots). Defaults to the real one.
        self.root = root
            ?? StoreIO.envRoot("TEMPLE_CLAUDE_ROOT")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public var watchedURLs: [URL] { [root] }

    public func loadSummaries() -> [TranscriptSummary] {
        let files = sessionFileURLs()
        let collector = TranscriptSummaryCollector()
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            if let session = loadSummary(at: files[index]) {
                collector.append(session)
            }
        }
        return collector.result()
    }

    public func sessionFileURLs() -> [URL] { (try? enumerateSessionFiles()) ?? [] }

    public func enumerateSessionFiles() throws -> [URL] {
        let fm = FileManager.default
        let dirs: [URL]
        do { dirs = try fm.contentsOfDirectory(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        var files: [URL] = []
        for dir in dirs {
            guard try dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            files += try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }
        }
        return files
    }

    public func enumerateSessionFiles(in subtree: URL) throws -> [URL] {
        let prefix = SessionPaths.normalized(root.path)
        let path = SessionPaths.normalized(subtree.path)
        if path == prefix || prefix.hasPrefix(path + "/") { return try enumerateSessionFiles() }
        guard path.hasPrefix(prefix + "/") else { return [] }
        let relative = path.dropFirst(prefix.count + 1).split(separator: "/")
        guard relative.count == 1 else { return [] } // no Claude subagent trees
        do {
            return try FileManager.default.contentsOfDirectory(at: subtree.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    public func acceptsTranscript(_ url: URL) -> Bool {
        let path = SessionPaths.normalized(url.path)
        let prefix = SessionPaths.normalized(root.path)
        return url.pathExtension == "jsonl" && path.hasPrefix(prefix + "/") &&
            path.split(separator: "/").count == prefix.split(separator: "/").count + 2
    }

    public func loadSummary(at fileURL: URL) -> TranscriptSummary? {
        parse(file: fileURL, encodedDirName: fileURL.deletingLastPathComponent().lastPathComponent)
    }

    private func parse(file: URL, encodedDirName: String) -> TranscriptSummary? {
        let id = file.deletingPathExtension().lastPathComponent
        let signature = StoreIO.fileSignature(file)
        guard let segments = StoreIO.boundedSegments(file, fileSize: signature?.fileSize),
              let head = segments.first, !head.isEmpty else { return nil }

        var cwd: String?
        var createdAt: Date?
        var humanTitle: String?   // first real human prompt
        var anyUserTitle: String? // first user text of any kind (fallback)
        var topLevelTitle: String? // legacy fallback from any record
        var queuedPrompt: String?
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
                if let value = obj["content"] as? String, !value.isEmpty {
                    if topLevelTitle == nil { topLevelTitle = value }
                    if queuedPrompt == nil, type == "queue-operation",
                       (obj["operation"] as? String) == "enqueue" {
                        queuedPrompt = value
                    }
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

        // Synthetic user messages and arbitrary top-level content can title the
        // legacy index, but only human messages and enqueues state a prompt.
        let firstPrompt = humanTitle ?? queuedPrompt
        let legacyTitle = humanTitle ?? anyUserTitle ?? topLevelTitle

        return TranscriptSummary(
            id: id,
            agent: .claude,
            locator: TranscriptLocator(localURL: file),
            modifiedAt: signature?.modificationDate ?? StoreIO.modificationDate(file),
            cwd: cwd,
            firstPrompt: firstPrompt.map { StoreIO.cleanTitle($0) },
            createdAt: createdAt,
            gitBranch: branch,
            model: model,
            messageCount: count > 0 ? count : nil,
            lastMessagePreview: preview,
            recordedTitle: summary,
            directoryHint: cwd == nil ? Self.decodeDirName(encodedDirName) : nil,
            legacyTitleHint: legacyTitle.map { StoreIO.cleanTitle($0) }
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
