import Foundation

/// Claude Code transcripts: `<projects root>/<encoded cwd>/<session id>.jsonl`.
/// See SESSION-FORMATS.md. Every file named for a session is an alternate:
/// Claude has no selection among files.
public struct ClaudeFormat: TranscriptFormat {
    public let agent: Agent = .claude
    /// How far identity verification reads before calling a file unverified.
    public static let identityScanBytes = 1024 * 1024
    public init() {}

    public func name(path: String) -> TranscriptName? {
        let last = TranscriptText.lastComponent(path)
        guard last.hasSuffix(".jsonl"), last.count > 6 else { return nil }
        return TranscriptName(threadID: String(last.dropLast(6)))
    }

    public var identityScan: IdentityScan { .lines(maxBytes: Self.identityScanBytes) }

    /// Claude can write untyped records before the first typed `sessionId`;
    /// the first typed record that carries one decides.
    public func identity(lines: some Sequence<Data>, expecting id: String) -> TranscriptVerification {
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] is String, let found = obj["sessionId"] as? String else { continue }
            return found == id ? .verified : .mismatch
        }
        return .incomplete
    }

    public func facts(_ bytes: TranscriptBytes, name: TranscriptName?, locator: TranscriptLocator,
                      modifiedAt: Date, shared: SharedFacts) -> TranscriptFacts {
        let last = TranscriptText.lastComponent(locator.path)
        let id = name?.threadID ?? (String(last) as NSString).deletingPathExtension
        let encodedDirName = ((locator.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let head = String(decoding: bytes.head, as: UTF8.self)
        guard !head.isEmpty else { return .unparseable }
        let segments = [head] + (bytes.tail.map { [String(decoding: $0, as: UTF8.self)] } ?? [])

        var cwd: String?
        var createdAt: Date?
        var humanTitle: String?   // first real human prompt
        var anyUserTitle: String? // first user text of any kind (fallback)
        var topLevelTitle: String? // legacy fallback from any record
        var queuedPrompt: String?
        // A prompt found only in the tail may be any later turn: the bytes
        // between head and tail were never read. It is a display hint.
        var tailPrompt: String?
        var validTypedLine = false
        var count = 0
        var model: String?
        var preview: String?
        var branch: String?
        var summary: String?

        for (segmentIndex, segment) in segments.enumerated() {
            let inHead = segmentIndex == 0
            for line in segment.split(separator: "\n") {
                guard let obj = TranscriptText.jsonObject(line) else { continue }
                let type = obj["type"] as? String
                if type != nil { validTypedLine = true }
                if cwd == nil, let value = obj["cwd"] as? String { cwd = value }
                if createdAt == nil, let value = obj["timestamp"] as? String {
                    createdAt = TranscriptText.parseDate(value)
                }
                if let value = obj["content"] as? String, !value.isEmpty {
                    if topLevelTitle == nil { topLevelTitle = value }
                    if type == "queue-operation", (obj["operation"] as? String) == "enqueue" {
                        if inHead { if queuedPrompt == nil { queuedPrompt = value } }
                        else if tailPrompt == nil { tailPrompt = value }
                    }
                }
                if type == "user" || type == "assistant" {
                    count += 1
                    if let message = obj["message"] as? [String: Any] {
                        if let value = message["model"] as? String { model = value }
                        if let text = Self.text(from: message["content"]), !text.isEmpty {
                            preview = TranscriptText.cleanTitle(text, cap: 160)
                            if type == "user" {
                                if anyUserTitle == nil { anyUserTitle = text }
                                if Self.isLikelyHumanPrompt(text) {
                                    if inHead { if humanTitle == nil { humanTitle = text } }
                                    else if tailPrompt == nil { tailPrompt = text }
                                }
                            }
                        }
                    }
                }
                if let value = obj["model"] as? String { model = value }
                if let value = obj["gitBranch"] as? String { branch = value }
                if let value = obj["summary"] as? String, !value.isEmpty {
                    summary = TranscriptText.cleanTitle(value)
                }
            }
        }
        guard validTypedLine else { return .unparseable }

        // Synthetic user messages and arbitrary top-level content can title the
        // legacy index, but only human messages and enqueues state a prompt.
        let firstPrompt = humanTitle ?? queuedPrompt
        let legacyTitle = humanTitle ?? tailPrompt ?? anyUserTitle ?? topLevelTitle

        return .summary(TranscriptSummary(
            id: id,
            agent: .claude,
            locator: locator,
            modifiedAt: modifiedAt,
            cwd: cwd,
            firstPrompt: firstPrompt.map { TranscriptText.cleanTitle($0) },
            createdAt: createdAt,
            gitBranch: branch,
            model: model,
            messageCount: count > 0 ? count : nil,
            lastMessagePreview: preview,
            recordedTitle: summary,
            directoryHint: cwd == nil ? Self.decodeDirName(encodedDirName) : nil,
            laterPromptHint: firstPrompt == nil ? tailPrompt.map { TranscriptText.cleanTitle($0) } : nil,
            legacyTitleHint: legacyTitle.map { TranscriptText.cleanTitle($0) },
            selectionKey: name?.selectionKey
        ))
    }

    /// Extract text from a Claude message `content`, which is either a string or
    /// an array of `{type:"text", text:"…"}` blocks.
    public static func text(from content: Any?) -> String? {
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
    public static func isLikelyHumanPrompt(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.hasPrefix("<") { return false } // <local-command-caveat>, <bash-input>, <command-name>, …
        if t.hasPrefix("Caveat:") { return false }
        if t.hasPrefix("[Request interrupted") { return false }
        return true
    }

    /// Best-effort reverse of the `/`→`-` dir encoding. Lossy — only a hint
    /// when the file carries no `cwd`.
    public static func decodeDirName(_ name: String) -> String {
        "/" + name.drop(while: { $0 == "-" }).replacingOccurrences(of: "-", with: "/")
    }
}
