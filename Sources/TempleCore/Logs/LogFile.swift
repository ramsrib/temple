import Foundation

/// One line appended to a diagnostic file under `<state dir>/logs/`, the
/// file kept under a cap by dropping its older half (cut at a line). Shared
/// by `UsageLog` and `RemoteLog`; each keeps its own queue and reports its
/// own failures.
enum LogFile {
    static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    /// Call on the log's own serial queue: the formatter is not safe to share.
    static func append(_ line: String, to url: URL, capBytes: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path), !fm.createFile(atPath: url.path, contents: nil) {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try trimIfNeeded(url, capBytes: capBytes)
    }

    /// Past the cap, keep the newer half, cut at a line boundary.
    static func trimIfNeeded(_ url: URL, capBytes: Int) throws {
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > capBytes else { return }
        let data = try Data(contentsOf: url)
        var tail = data.suffix(capBytes / 2)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try Data(tail).write(to: url)
    }

    /// The home directory is the user's name; kept out of a public log line.
    static func redactingHome(_ text: String) -> String {
        text.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
