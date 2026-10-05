import Foundation

// Agent transcript formats as pure functions over bytes. Nothing in this
// directory opens a file, lists a directory or knows where a store lives: a
// host's source reads the bytes (a local file, an ssh exec) and hands them
// here, so every host parses, verifies, selects and adopts the same way.

/// What a transcript's file name says. Only the last path component counts.
public struct TranscriptName: Hashable, Sendable {
    public let threadID: String
    /// Codex: "<stamp>-<rolloutID>", the CLI's own resume priority. Nil for an
    /// agent whose files have no selection among them (Claude).
    public let selectionKey: String?
    public init(threadID: String, selectionKey: String? = nil) {
        self.threadID = threadID; self.selectionKey = selectionKey
    }
}

/// How a candidate file relates to the member it might hold.
public enum CandidateRole: Hashable, Sendable {
    /// The agent's own pick among the thread's files (Codex: the newest revert).
    case selected
    /// The row's recorded transcript path, consulted when it is not the
    /// selected file and is not an older file of the same thread.
    case hinted
    /// Any other file named for the thread: tried only when there is no
    /// selected file, or the selected one is proven missing.
    case alternate
}

/// Bytes a transport read from one transcript, with their provenance: a
/// prompt found only in `tail` may be any later turn (the middle was never
/// read), so it is a hint, never a first prompt.
public struct TranscriptBytes: Sendable {
    /// The first `window` bytes (fewer for a shorter file).
    public let head: Data
    /// The last bytes after `head`, at most `window`; nil when the file fits
    /// in the head. Never overlaps it.
    public let tail: Data?
    public let fileSize: Int
    public let window: Int
    /// A wider head, read only when a format asked for one (`needsWiderHead`).
    public let widerHead: Data?

    public static let defaultWindow = 64 * 1024

    public init(head: Data, tail: Data?, fileSize: Int, window: Int = TranscriptBytes.defaultWindow, widerHead: Data? = nil) {
        self.head = head; self.tail = tail; self.fileSize = fileSize; self.window = window; self.widerHead = widerHead
    }

    /// The same read with a wider head supplied.
    public func with(widerHead: Data) -> TranscriptBytes {
        TranscriptBytes(head: head, tail: tail, fileSize: fileSize, window: window, widerHead: widerHead)
    }

    /// Does `head` hold the whole file?
    var headIsWholeFile: Bool { head.count < window || head.count >= fileSize }
}

/// Facts recorded outside any one transcript that every summary of the agent
/// draws on (Codex: history.jsonl and session_index.jsonl). Already cleaned.
public struct SharedFacts: Sendable, Equatable {
    /// The thread's shared title: its earliest history prompt, else its
    /// session_index thread name.
    public let titles: [String: String]
    /// The earliest history prompt per thread.
    public let prompts: [String: String]
    public init(titles: [String: String] = [:], prompts: [String: String] = [:]) {
        self.titles = titles; self.prompts = prompts
    }
    public static let empty = SharedFacts()
}

/// A rollout header that could be the session a Temple tab just launched.
public struct AdoptionCandidate: Sendable, Equatable {
    public let id: String
    public let cwd: String
    public let createdAt: Date
    public init(id: String, cwd: String, createdAt: Date) {
        self.id = id; self.cwd = cwd; self.createdAt = createdAt
    }
}

/// How much of a file identity verification may read, and how.
public enum IdentityScan: Sendable, Equatable {
    /// One JSONL header line, at most this long; longer is corrupt input.
    case firstLine(maxBytes: Int)
    /// Lines from the start, at most this many bytes. A transport yields every
    /// complete line inside the cap and, only when it reached the end of the
    /// file first, the final unterminated line.
    case lines(maxBytes: Int)
}

public enum TranscriptFacts: Sendable, Equatable {
    case summary(TranscriptSummary)
    /// The head stated no prompt and the file goes on past it; read a head
    /// of this many bytes into `TranscriptBytes.widerHead` and ask again. At
    /// most once per read.
    case needsWiderHead(bytes: Int)
    /// Not a session this agent opens: no recognizable record, or a header
    /// that excludes it (a Codex subagent thread).
    case unparseable
}

public enum TranscriptFormatError: Error, Equatable {
    /// An adoption header that is partial or corrupt. Unlike a nil result,
    /// this proves nothing about whether the file competes.
    case corruptHeader
}

public protocol TranscriptFormat: Sendable {
    var agent: Agent { get }
    /// Identity from a file's name (its last path component), or nil when the
    /// name is not one this agent writes.
    func name(path: String) -> TranscriptName?
    /// The agent's pick among one thread's files, or nil when it has no
    /// selection (every file is an alternate).
    func select(_ names: [(path: String, name: TranscriptName)]) -> String?
    var identityScan: IdentityScan { get }
    /// Identity from the lines a transport read under `identityScan`. An
    /// exhausted sequence with no identity is `.incomplete`, never a mismatch.
    func identity(lines: some Sequence<Data>, expecting id: String) -> TranscriptVerification
    /// The one adoption reading of a header line. Nil proves the file is not
    /// a competing session (another record type, a subagent thread); a
    /// partial or corrupt header throws.
    func header(firstLine: Data) throws -> AdoptionCandidate?
    /// Facts from bounded bytes. Nil fields are facts the bytes do not state.
    func facts(_ bytes: TranscriptBytes, name: TranscriptName?, locator: TranscriptLocator,
               modifiedAt: Date, shared: SharedFacts) -> TranscriptFacts
    /// Inputs outside the transcripts, by path relative to the agent's root.
    var sharedInputs: [String] { get }
    /// Shared facts from those inputs' bytes; a missing input is absent.
    func sharedFacts(_ inputs: [String: Data]) -> SharedFacts
    /// `summary` with every field that comes from shared inputs replaced by
    /// what `shared` states (nil where it states nothing). `facts` applies
    /// shared facts through this and nothing else, so for any bytes
    /// `facts(…, shared: s)` is `withShared(facts(…, shared: x), s)` for every
    /// `x`: a summary kept across a change to the shared inputs is brought up
    /// to date by this alone, with no transcript read (ADR-032).
    func withShared(_ summary: TranscriptSummary, _ shared: SharedFacts) -> TranscriptSummary
}

public extension TranscriptFormat {
    func select(_ names: [(path: String, name: TranscriptName)]) -> String? { nil }
    var sharedInputs: [String] { [] }
    func sharedFacts(_ inputs: [String: Data]) -> SharedFacts { .empty }
    func header(firstLine: Data) throws -> AdoptionCandidate? { nil }
    func withShared(_ summary: TranscriptSummary, _ shared: SharedFacts) -> TranscriptSummary { summary }
}

public enum TranscriptFormats {
    public static func format(for agent: Agent) -> any TranscriptFormat {
        switch agent {
        case .claude: ClaudeFormat()
        case .codex: CodexFormat()
        }
    }

    /// The version of what `facts` produces from given bytes. A summary kept
    /// across launches (ADR-032) records it and is discarded when it moves,
    /// so **bump it with any change to a format's facts** — a field read
    /// differently, a new field, a different title rule. `FormatGoldenTests`
    /// fails on such a change; this is the number that must move with it.
    public static let factsVersion = 1
}

public enum TranscriptVerification: Equatable, Sendable {
    case verified, incomplete, mismatch
}

/// JSONL and text helpers shared by the formats.
enum TranscriptText {
    static func lines(_ data: Data) -> [Substring] {
        String(decoding: data, as: UTF8.self).split(separator: "\n")
    }

    /// Parse one JSONL line into a dictionary; nil on malformed input.
    static func jsonObject(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return jsonObject(data)
    }

    static func jsonObject(_ line: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) else { return nil }
        return obj as? [String: Any]
    }

    /// A transcript's lines, each as the UTF-8 bytes `jsonObject` parses:
    /// exactly what `lines(_:)` and `Substring.data(using: .utf8)` gave,
    /// without walking the text's grapheme clusters to find the breaks.
    ///
    /// The bytes are decoded first (ill-formed sequences become U+FFFD, as
    /// before), then split on the decoded bytes. A "\n" is a character of
    /// its own except right after "\r", where the two are one "\r\n"
    /// character that `split(separator: "\n")` does not split at: a line
    /// break is therefore every 0x0A byte not preceded by 0x0D, and no other
    /// byte (a line feed never belongs to a multi-byte sequence, nor to a
    /// repaired one). Empty lines are dropped, as `split` drops them.
    static func lineData(_ data: Data) -> [Data] {
        var text = String(decoding: data, as: UTF8.self)
        var lines: [Data] = []
        text.withUTF8 { bytes in
            var start = 0
            for index in bytes.indices where bytes[index] == 0x0a {
                if index > 0 && bytes[index - 1] == 0x0d { continue }
                if index > start { lines.append(Data(UnsafeBufferPointer(rebasing: bytes[start..<index]))) }
                start = index + 1
            }
            if bytes.count > start { lines.append(Data(UnsafeBufferPointer(rebasing: bytes[start...]))) }
        }
        return lines
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return (try? isoWithFraction.parse(s)) ?? (try? isoPlain.parse(s))
    }

    /// Collapse whitespace and cap length for a one-line title: every run of
    /// whitespace characters becomes one space, leading and trailing runs go,
    /// and a result longer than `cap` characters keeps `cap` and gains "…".
    ///
    /// Exactly `s.split(whereSeparator: \.isWhitespace).joined(separator: " ")`
    /// capped, without collapsing all of a long message: it stops as soon as
    /// the outcome is decided. Appending to a string can change only its last
    /// character (a grapheme break depends on what precedes it and on the
    /// one scalar after it, so only the break at the join is new — a space
    /// can absorb a combining mark that followed a newline, say). So once the
    /// collapsed prefix holds `cap + 2` characters, its first `cap + 1` are
    /// final: the whole result is longer than `cap`, and those are its first.
    /// `appended` counts characters added, an upper bound on the prefix's
    /// count (joins can only merge); the real count is taken only when that
    /// bound says it may be enough. `TranscriptTextTests` pins the parity.
    static func cleanTitle(_ s: String, cap: Int = 200) -> String {
        var collapsed = ""
        var pendingSpace = false
        var appended = 0
        for character in s {
            if character.isWhitespace {
                if !collapsed.isEmpty { pendingSpace = true }
                continue
            }
            if pendingSpace { collapsed.append(" "); appended += 1; pendingSpace = false }
            collapsed.append(character)
            appended += 1
            if appended >= cap + 2 {
                appended = collapsed.count
                if appended >= cap + 2 { return String(collapsed.prefix(cap)) + "…" }
            }
        }
        return collapsed.count > cap ? String(collapsed.prefix(cap)) + "…" : collapsed
    }

    static func lastComponent(_ path: String) -> Substring {
        path.split(separator: "/", omittingEmptySubsequences: true).last ?? Substring(path)
    }

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
}
