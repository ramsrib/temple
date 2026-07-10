import Foundation

/// A source of agent sessions on disk (one per agent).
public protocol SessionStore: Sendable {
    var agent: Agent { get }
    func loadSessions() -> [AgentSession]
}

// MARK: - Shared file/JSON helpers

enum StoreIO {
    /// Read only the first `maxBytes` of a file — enough for metadata + the
    /// first prompt, without loading multi-MB session logs into memory.
    static func readHead(_ url: URL, maxBytes: Int = 64 * 1024) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: maxBytes)) ?? Data()
        return String(data: data, encoding: .utf8)
    }

    static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
    }

    /// Parse one JSONL line into a dictionary; nil on malformed input.
    static func jsonObject(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return obj as? [String: Any]
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoWithFraction.date(from: s) ?? isoPlain.date(from: s)
    }

    /// Collapse whitespace and cap length for a one-line title.
    static func cleanTitle(_ s: String, cap: Int = 200) -> String {
        let collapsed = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > cap ? String(collapsed.prefix(cap)) + "…" : collapsed
    }
}
