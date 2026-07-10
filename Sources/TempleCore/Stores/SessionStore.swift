import Foundation

/// A source of agent sessions on disk (one per agent).
public protocol SessionStore: Sendable {
    var agent: Agent { get }
    /// Roots whose filesystem changes can affect this store's sessions.
    var watchedURLs: [URL] { get }
    func loadSessions() -> [AgentSession]
}

public extension SessionStore {
    var watchedURLs: [URL] { [] }
}

/// Optional capabilities used by `SessionWatcher` to update a store without
/// reparsing every session after each filesystem event.
public protocol IncrementalSessionStore: SessionStore {
    /// Session files currently owned by this store.
    func sessionFileURLs() -> [URL]
    /// Parses one of the URLs returned by `sessionFileURLs()`.
    func loadSession(at fileURL: URL) -> AgentSession?
    /// Changes when non-session input (for example Codex history) invalidates
    /// cached sessions. `nil` means session files are the only input.
    var cacheInvalidationToken: String? { get }
}

public extension IncrementalSessionStore {
    var cacheInvalidationToken: String? { nil }
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

    static func fileSignature(_ url: URL) -> (modificationDate: Date, fileSize: Int)? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modificationDate = values.contentModificationDate,
              let fileSize = values.fileSize else { return nil }
        return (modificationDate, fileSize)
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

/// A small locked sink keeps concurrent store loading compatible with strict
/// concurrency while preserving the stores' value semantics.
final class SessionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [AgentSession] = []

    func append(_ session: AgentSession) {
        lock.lock()
        sessions.append(session)
        lock.unlock()
    }

    func result() -> [AgentSession] {
        lock.lock()
        defer { lock.unlock() }
        return sessions
    }
}
