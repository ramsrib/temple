import Foundation
import TempleCore
import TempleUI

/// One History row as the command line prints it.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var id: String
    public var cli: Agent?
    public var project: String?
    public var title: String
    public var updatedAt: Date?
    /// History's status column: in-temple, archived, outside or conflict.
    public var status: String
    public var resumeCommand: [String]?
    public var transcript: String?
    public var transcriptMissing: Bool?
    public var folderMissing: Bool?

    init(_ row: HistoryRow, detail: Bool = false) {
        id = row.sessionID
        cli = row.agent
        project = row.project?.path
        title = row.title
        updatedAt = row.updatedAt == .distantPast ? nil : row.updatedAt
        status = row.standingName
        if detail {
            resumeCommand = row.resumeArgv.isEmpty ? nil : row.resumeArgv
            transcript = row.localURL?.path
            transcriptMissing = row.transcriptMissing
            folderMissing = row.folderMissing
        }
    }
}

enum Output {
    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Left-aligned columns, the last one unpadded. With `markers`, each row
    /// starts with one ("* " for the one on screen).
    static func table(_ header: [String], _ rows: [(marker: Bool, cells: [String])], markers: Bool = true) -> String {
        var widths = header.map(\.count)
        for row in rows {
            for (index, cell) in row.cells.enumerated() where index < widths.count - 1 {
                widths[index] = max(widths[index], cell.count)
            }
        }
        func line(_ marker: String, _ cells: [String]) -> String {
            let padded = cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }
            let line = marker + padded.joined(separator: "  ")
            return String(line.reversed().drop { $0 == " " }.reversed())
        }
        let blank = markers ? "  " : ""
        return ([line(blank, header)] + rows.map { line($0.marker ? "* " : blank, $0.cells) }).joined(separator: "\n")
    }

    static func fields(_ pairs: [(String, String?)]) -> String {
        let present = pairs.compactMap { key, value in value.map { (key, $0) } }
        let width = (present.map(\.0.count).max() ?? 0) + 1
        return present.map { key, value in "\(key):".padding(toLength: width, withPad: " ", startingAt: 0) + " " + value }
            .joined(separator: "\n")
    }

    static func projectName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "-" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// A shell-ready command line from argv.
    static func command(_ argv: [String]?) -> String? {
        guard let argv, !argv.isEmpty else { return nil }
        return argv.map(ShellQuote.quote).joined(separator: " ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func date(_ date: Date?) -> String { date.map(dateFormatter.string(from:)) ?? "-" }

    // MARK: Projects and sessions

    static func projects(_ projects: [ControlProject]) -> String {
        table(["NAME", "SESSIONS", "PATH"], projects.map { (marker: $0.focused, cells: [$0.name, "\($0.sessions)", $0.path]) })
    }

    static func sessions(_ sessions: [ControlSession]) -> String {
        table(["ID", "CLI", "STATE", "PROJECT", "TITLE"], sessions.map { session in
            (marker: session.focused,
             cells: [session.id ?? "pending", session.cli.rawValue, session.state.rawValue,
                     projectName(session.project), session.title])
        })
    }

    static func session(_ session: ControlSession) -> String {
        fields([
            ("id", session.id ?? "pending (Codex has not written it yet)"),
            ("cli", session.cli.rawValue),
            ("project", session.project),
            ("title", session.title),
            ("state", session.state.rawValue + (session.focused ? ", on screen" : "")),
            ("resume", command(session.resumeCommand)),
            ("transcript", session.transcript),
        ])
    }

    // MARK: History

    static func history(_ entries: [HistoryEntry]) -> String {
        table(["ID", "CLI", "UPDATED", "STATUS", "PROJECT", "TITLE"], entries.map { entry in
            (marker: false, cells: [entry.id, entry.cli?.rawValue ?? "-", date(entry.updatedAt), entry.status,
                                    projectName(entry.project), entry.title])
        }, markers: false)
    }

    static func historyEntry(_ entry: HistoryEntry) -> String {
        var conditions: [String] = []
        if entry.transcriptMissing == true { conditions.append("no transcript") }
        if entry.folderMissing == true { conditions.append("no folder") }
        return fields([
            ("id", entry.id),
            ("cli", entry.cli?.rawValue),
            ("project", entry.project),
            ("title", entry.title),
            ("updated", date(entry.updatedAt)),
            ("status", entry.status + (conditions.isEmpty ? "" : " (\(conditions.joined(separator: ", ")))")),
            ("resume", command(entry.resumeCommand)),
            ("transcript", entry.transcript),
        ])
    }
}

enum ShellQuote {
    /// Bare when safe, single-quoted otherwise.
    static func quote(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
