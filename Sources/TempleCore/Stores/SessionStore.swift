import Foundation

/// A source of agent sessions on disk (one per agent).
public protocol SessionStore: Sendable {
    var agent: Agent { get }
    /// Roots whose filesystem changes can affect this store's sessions.
    var watchedURLs: [URL] { get }
    func loadSummaries() -> [TranscriptSummary]
}

public extension SessionStore {
    var watchedURLs: [URL] { [] }
}

/// Path-level capabilities required by the live engine. Full-disk catalogs
/// continue to accept any SessionStore.
public protocol IncrementalSessionStore: SessionStore {
    /// Session files currently owned by this store.
    func sessionFileURLs() -> [URL]
    /// Parses one of the URLs returned by `sessionFileURLs()`.
    func loadSummary(at fileURL: URL) -> TranscriptSummary?
    /// Changes when non-session input (for example Codex history) invalidates
    /// cached sessions. `nil` means session files are the only input.
    var cacheInvalidationToken: String? { get }
    var sharedTitleURLs: [URL] { get }
    func loadSharedTitles() -> [String: String]
    /// Unlike the catalog's tolerant listing, resolution must distinguish errors
    /// from a completed empty scan.
    func enumerateSessionFiles() throws -> [URL]
    func enumerateSessionFiles(in subtree: URL) throws -> [URL]
    func filenameID(at url: URL) -> String?
    /// Codex resume priority from the canonical filename (timestamp + rollout ID).
    func rolloutSelectionKey(at url: URL) -> String?
    func acceptsTranscript(_ url: URL) -> Bool
    func adoptionHeader(at url: URL) throws -> CodexRolloutCandidate?
    func metadataHeader(at url: URL) -> CodexRolloutCandidate?
    /// A parser for many files in one read (`SessionCatalog.stream`): any
    /// input shared by every file is read once, here, not once per file.
    func catalogParser() -> @Sendable (URL) -> TranscriptSummary?

}

public extension IncrementalSessionStore {
    var cacheInvalidationToken: String? { nil }
    var sharedTitleURLs: [URL] { [] }
    func loadSharedTitles() -> [String: String] { [:] }
    func enumerateSessionFiles() throws -> [URL] { sessionFileURLs() }
    func enumerateSessionFiles(in subtree: URL) throws -> [URL] {
        let prefix = SessionPaths.normalized(subtree.path)
        return try enumerateSessionFiles().filter { SessionPaths.normalized($0.path).hasPrefix(prefix + "/") }
    }
    func filenameID(at url: URL) -> String? { url.deletingPathExtension().lastPathComponent }
    func rolloutSelectionKey(at url: URL) -> String? { nil }
    func acceptsTranscript(_ url: URL) -> Bool {
        url.pathExtension == "jsonl" && !url.pathComponents.contains("subagents")
    }
    func adoptionHeader(at url: URL) throws -> CodexRolloutCandidate? {
        metadataHeader(at: url)
    }
    func metadataHeader(at url: URL) -> CodexRolloutCandidate? { nil }
    func catalogParser() -> @Sendable (URL) -> TranscriptSummary? {
        let store = self
        return { store.loadSummary(at: $0) }
    }

}

/// Fact-producing stores used by catalog and member enrichment.
public protocol TranscriptSummaryStore: IncrementalSessionStore {
    func catalogSummaryParser() -> @Sendable (URL) -> TranscriptSummary?
    func loadSharedPrompts() -> [String: String]
}
public extension TranscriptSummaryStore {
    func loadSharedPrompts() -> [String: String] { [:] }
    func catalogSummaryParser() -> @Sendable (URL) -> TranscriptSummary? { catalogParser() }
}

/// Lexical aliases, preserving case and requiring no access to an event leaf.
enum SessionPaths {
    static func normalized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(component)
        }
        let p = "/" + components.joined(separator: "/")
        for prefix in ["/tmp", "/var"] where p == prefix || p.hasPrefix(prefix + "/") {
            return "/private" + p
        }
        return p
    }
}

// MARK: - Shared file/JSON helpers

enum StoreIO {
    static let readWindowBytes = 64 * 1024

    /// Read only the first `maxBytes` of a file — enough for metadata + the
    /// first prompt, without loading multi-MB session logs into memory.
    static func readHead(_ url: URL, maxBytes: Int = readWindowBytes) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: maxBytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Read one JSONL header, never decoding the rest of the prefix or file.
    /// A missing newline at EOF is valid; hitting the cap is incomplete input.
    static func readFirstLine(_ url: URL, maxBytes: Int = readWindowBytes) throws -> Data {
        guard maxBytes > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var line = Data()
        while line.count < maxBytes {
            let chunk = try handle.read(upToCount: min(4096, maxBytes - line.count)) ?? Data()
            if chunk.isEmpty { return line }
            if let newline = chunk.firstIndex(of: 0x0a) {
                line.append(chunk.prefix(upTo: newline))
                return line
            }
            line.append(chunk)
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    /// Read at most the last `maxBytes`, keeping large logs memory-bounded.
    static func readTail(_ url: URL, maxBytes: Int = readWindowBytes) -> String? {
        guard maxBytes > 0, let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        do {
            try fh.seek(toOffset: start)
            let data = try fh.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    /// Bounded JSONL lines from the head and tail, avoiding double-counting
    /// when the whole file fits inside one read window.
    static func boundedLines(_ url: URL) -> [Substring] {
        (boundedSegments(url) ?? []).flatMap { $0.split(separator: "\n") }
    }

    /// Returns a head and, only for files larger than the head window, a
    /// non-overlapping tail. Keeping the segments separate avoids reparsing or
    /// double-counting overlapping lines in medium-sized files.
    static func boundedSegments(
        _ url: URL,
        fileSize: Int? = nil,
        maxBytes: Int = readWindowBytes
    ) -> [String]? {
        guard maxBytes > 0, let head = readHead(url, maxBytes: maxBytes) else { return nil }
        let size = fileSize ?? ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? head.utf8.count)
        guard size > maxBytes else { return [head] }

        // Never overlap the bytes already represented by the head. For files
        // between one and two windows this reads only the remaining bytes.
        let remaining = max(0, size - maxBytes)
        let tailBytes = min(maxBytes, remaining)
        guard tailBytes > 0, let tail = readTail(url, maxBytes: tailBytes) else { return [head] }
        return [head, tail]
    }

    static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
    }

    /// Optional store-root override from the environment (testing / demos).
    static func envRoot(_ key: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func fileSignature(_ url: URL) -> (modificationDate: Date, fileSize: Int)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return nil }
        return (date, size)
    }

    /// Parse one JSONL line into a dictionary; nil on malformed input.
    static func jsonObject(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return obj as? [String: Any]
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return (try? isoWithFraction.parse(s)) ?? (try? isoPlain.parse(s))
    }

    /// Collapse whitespace and cap length for a one-line title.
    static func cleanTitle(_ s: String, cap: Int = 200) -> String {
        let collapsed = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > cap ? String(collapsed.prefix(cap)) + "…" : collapsed
    }

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
}

/// Locked sink for parallel transcript parsing.
final class TranscriptSummaryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var summaries: [TranscriptSummary] = []

    func append(_ summary: TranscriptSummary) {
        lock.lock()
        summaries.append(summary)
        lock.unlock()
    }

    func result() -> [TranscriptSummary] {
        lock.lock()
        defer { lock.unlock() }
        return summaries
    }
}
