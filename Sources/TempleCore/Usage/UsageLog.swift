import Foundation
import os

/// The usage meter's diagnostic trail: every credential lookup and every
/// fetch outcome, one timestamped line each, to the unified log AND to a
/// file the user can hand over — `<state dir>/logs/usage.log`.
///
/// The file exists because the unified log is the wrong shape for "it
/// happened last week on my other Mac": info-level lines are gone within
/// hours, and even the persisted ones take a predicate to find. The meter's
/// whole failure mode is silence — a dead reader and a healthy one look the
/// same on screen — so the record of what it did has to be somewhere a
/// person can open, days later, and read top to bottom.
///
/// Never the token, never the Keychain account. The file lives under
/// `TempleState.directory`, so a `make demo` run writes its own copy.
public enum UsageLog {
    /// Where the file goes — nil until the APP sets it at launch
    /// (`TempleApp.init`). Nothing else that logs through here writes a
    /// file: the test suite drives the same model. Tests that want the
    /// file set this themselves.
    public nonisolated(unsafe) static var fileURL: URL?
    /// The app's location: beside the SQLite store, so a demo run writes its own.
    public static var defaultFileURL: URL {
        TempleState.directory.appendingPathComponent("logs/usage.log")
    }
    /// The file is trimmed to its newer half once it passes this.
    static let capBytes = 512 * 1024

    private static let logger = Logger(subsystem: "com.sriramb.temple.core", category: "usage")
    private static let queue = DispatchQueue(label: "com.sriramb.temple.usage-log", qos: .utility)
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    /// A transition worth keeping: persisted by the unified log too.
    public static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        append("notice", message)
    }

    /// Per-poll detail: the unified log keeps it in memory only; the file
    /// keeps it.
    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("info", message)
    }

    /// Waits for every line queued so far to be written (or to have failed).
    /// Tests use it instead of polling; nothing in the app needs it.
    @discardableResult
    static func flush(timeout: TimeInterval = 5) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    private static func append(_ level: String, _ message: String) {
        // The time is taken here, the formatting happens on the queue: the
        // ISO 8601 formatter is not safe to share across threads.
        // The destination too: a line belongs to the file that was current
        // when it was logged, not to whatever the path is by the time the
        // queue gets to it.
        let at = Date()
        guard let url = fileURL else { return }
        queue.async { write(to: url, at: at, level: level, message: message) }
    }

    /// A file that cannot be written must not fail silently — that is the
    /// failure this file exists to end. Reported once per distinct reason
    /// through the underlying logger (never through `UsageLog`, which would
    /// loop back here), then quiet until the reason changes.
    private static var reportedFailure: String?

    private static func write(to url: URL, at: Date, level: String, message: String) {
        let line = "\(stamp.string(from: at)) \(level) \(message)\n"
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path), !fm.createFile(atPath: url.path, contents: nil) {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try trimIfNeeded(url)
            reportedFailure = nil
        } catch {
            // The home directory is the user's name; keep it out of a
            // public log line.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let reason = "\(url.path): \(error)".replacingOccurrences(of: home, with: "~")
            if reportedFailure != reason {
                reportedFailure = reason
                logger.error("usage log file cannot be written — \(reason, privacy: .public)")
            }
        }
    }

    /// Past the cap, keep the newer half, cut at a line boundary.
    private static func trimIfNeeded(_ url: URL) throws {
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > capBytes else { return }
        let data = try Data(contentsOf: url)
        var tail = data.suffix(capBytes / 2)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try Data(tail).write(to: url)
    }
}
