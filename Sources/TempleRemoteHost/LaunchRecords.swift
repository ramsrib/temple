import Foundation

/// What the pane recorded once it had entered its folder: the agent is
/// running there, on that server, and nowhere else (section 4).
public struct LaunchEvidence: Sendable, Equatable {
    /// The remote clock when the pane wrote it (seconds since 1970).
    public var epoch: Int
    /// `pwd -P`: the folder as the host spells it.
    public var directory: String
    public var panePID: Int
    /// Field 22 of `/proc/<pid>/stat`; nil where there is no `/proc`.
    public var paneStart: String?
    /// The server the session was created on.
    public var socketPath: String
    public var serverPID: Int?
    public var serverStart: String?
    /// Claude's config root as the agent was started with it; nil when the
    /// record did not say (an older pane).
    public var claudeConfig: RemoteEnvironment.ClaudeConfig?

    public init(epoch: Int, directory: String, panePID: Int, paneStart: String?, socketPath: String,
                serverPID: Int?, serverStart: String?, claudeConfig: RemoteEnvironment.ClaudeConfig? = nil) {
        self.epoch = epoch; self.directory = directory; self.panePID = panePID; self.paneStart = paneStart
        self.socketPath = socketPath; self.serverPID = serverPID; self.serverStart = serverStart
        self.claudeConfig = claudeConfig
    }
}

/// The pane's record (`<marker>`).
public enum PaneRecord: Sendable, Equatable {
    case ok(LaunchEvidence)
    /// The pane could not enter the folder: no agent ran.
    case failedCD(status: Int32)
    /// The pane refused to start the agent (it was not told which Claude
    /// config folder to use): no agent ran. Why, in words.
    case failedLaunch(String)
    /// A record Temple cannot read: proves nothing.
    case unreadable(String)
}

extension PaneRecord {
    static let configRefusal = "the launch didn't say which Claude config folder to use"
}

/// The tmux client's record (`<marker>.client`), kept apart from the pane's
/// (implementation note 3): a client failure means "creation not proven",
/// never "not created".
public struct ClientFailure: Sendable, Equatable {
    public var status: Int32
    public var line: String
}

/// Both records as one fetch found them, and the end of what the pane
/// showed (its diagnostics, for an agent that failed at once).
public struct CollectedRecords: Sendable, Equatable {
    public var pane: PaneRecord?
    public var client: ClientFailure?
    /// The last 4 KiB of the pane's first 64 KiB of output, raw.
    public var output: String?
    public init(pane: PaneRecord? = nil, client: ClientFailure? = nil, output: String? = nil) {
        self.pane = pane; self.client = client; self.output = output
    }
    public var isEmpty: Bool { pane == nil && client == nil }
}

/// Fetching and acknowledging a launch's records by the locator the run row
/// persisted (`~/.temple/launch/<marker>`, the same for every connection),
/// so an `ok` written but never collected (a quit or crash before the first
/// fetch, a dropped connection) is recovered on the next Open. Every
/// operation checks the directory first (`RecordDirectory`). Records live
/// 24 hours on the host (the launch's stale sweep).
public enum LaunchRecords {
    /// Argument: the marker. Prints each record that exists as a header
    /// line (`pane <bytes>`, `client <bytes>`, `output <bytes>`) followed by
    /// exactly that many bytes, then `end`; `unsafe` when the directory is
    /// not a private one of this user's.
    static let fetchScript = RecordDirectory.functions + "\n" + """
    m=$1
    rd=$(temple_record_dir) || { echo unsafe; exit 0; }
    for f in pane client output; do
      case $f in pane) p=$rd/$m ;; client) p=$rd/$m.client ;; *) p=$rd/$m.out ;; esac
      [ -f "$p" ] && [ ! -L "$p" ] || continue
      if [ "$f" = output ]; then
        rm -f "$rd/$m.tail"; ( set -C; tail -c 4096 "$p" > "$rd/$m.tail" ) 2>/dev/null || continue
        p=$rd/$m.tail
      fi
      n=$(wc -c < "$p" | tr -d ' ')
      printf '%s %s\\n' "$f" "$n"
      cat "$p"
    done
    rm -f "$rd/$m.tail"
    printf 'end\\n'
    """

    /// Arguments: the marker, then `all` to drop the pane's diagnostics too.
    /// Deletes the records once their evidence is written on this side, the
    /// creating client's stderr file, which a client hung up while attached
    /// never got to remove, and the creation's staged script if nothing
    /// read it. With `all` (the run's exit has been handled) the
    /// diagnostics go too, and any attach's staged script.
    static let acknowledgeScript = RecordDirectory.functions + "\n" + """
    m=$1
    rd=$(temple_record_dir) || exit 0
    rm -f "$rd/$m" "$rd/$m.client" "$rd/$m.tmp" "$rd/$m.client.tmp" "$rd/$m.err" "$rd/$m".s-c*
    [ "$2" = all ] && rm -f "$rd/$m.out" "$rd/$m".s-*
    exit 0
    """

    /// Argument: the marker. Prints the last 4 KiB of the pane's output,
    /// then deletes that file and nothing else: the pane's and the client's
    /// records are acknowledged only once their evidence is written here.
    static let outputScript = RecordDirectory.functions + "\n" + """
    m=$1
    rd=$(temple_record_dir) || exit 0
    p=$rd/$m.out
    [ -f "$p" ] && [ ! -L "$p" ] && tail -c 4096 "$p"
    rm -f "$p"
    exit 0
    """

    public static let deadline: TimeInterval = 5

    /// The pane's diagnostics, fetched once and removed; nothing else.
    public static func takeOutput(marker: String, using exec: RemoteExec) async -> String? {
        precondition(RemoteQuoting.isSafeToken(marker))
        guard let output = try? await exec.run(script: outputScript, args: [marker], deadline: deadline),
              output.reachedCommand, output.status == 0, !output.stdout.isEmpty else { return nil }
        return output.stdout
    }

    public enum FetchError: Error, Equatable, LocalizedError {
        case transport(String)
        case malformed(String)
        /// The record directory is not a private one of this user's: its
        /// records are not evidence.
        case unsafeDirectory
        public var errorDescription: String? {
            switch self {
            case .transport(let line): line
            case .malformed(let line): "the launch record could not be read: \(line)"
            case .unsafeDirectory: "~/.temple/launch on the host is not a private folder of this account's"
            }
        }
    }

    public static func fetch(marker: String, using exec: RemoteExec) async throws -> CollectedRecords {
        precondition(RemoteQuoting.isSafeToken(marker))
        let output: RemoteOutput
        do {
            output = try await exec.run(script: fetchScript, args: [marker], deadline: deadline)
        } catch {
            throw FetchError.transport(error.localizedDescription)
        }
        guard output.reachedCommand, output.status == 0 else {
            throw FetchError.transport(output.firstErrorLine ?? "ssh exited with status \(output.status)")
        }
        if output.stdout == "unsafe\n" { throw FetchError.unsafeDirectory }
        return try parseFetch(Data(output.stdout.utf8))
    }

    /// `all`: the diagnostics go too (the run's exit has been handled).
    public static func acknowledge(marker: String, all: Bool = false, using exec: RemoteExec) async {
        precondition(RemoteQuoting.isSafeToken(marker))
        _ = try? await exec.run(script: acknowledgeScript, args: [marker, all ? "all" : ""], deadline: deadline)
    }

    static func parseFetch(_ data: Data) throws -> CollectedRecords {
        var records = CollectedRecords()
        var index = data.startIndex
        while index < data.endIndex {
            guard let newline = data[index...].firstIndex(of: 0x0a) else { throw FetchError.malformed("no end") }
            let header = String(decoding: data[index..<newline], as: UTF8.self)
            index = data.index(after: newline)
            if header == "end" { return records }
            let parts = header.split(separator: " ")
            guard parts.count == 2, let count = Int(parts[1]), count >= 0,
                  data.distance(from: index, to: data.endIndex) >= count else { throw FetchError.malformed(header) }
            let body = String(decoding: data[index..<data.index(index, offsetBy: count)], as: UTF8.self)
            index = data.index(index, offsetBy: count)
            switch parts[0] {
            case "pane": records.pane = parsePane(body)
            case "client": records.client = parseClient(body)
            case "output": records.output = body
            default: throw FetchError.malformed(header)
            }
        }
        throw FetchError.malformed("no end")
    }

    /// `ok` then `key<TAB>value` lines, `dir` last and taken whole (a folder
    /// name may hold anything but its trailing newline); or `failed<TAB>cd
    /// <TAB><status>`.
    static func parsePane(_ text: String) -> PaneRecord {
        var body = text
        if body.hasSuffix("\n") { body.removeLast() }
        if body == "failed\tcfg" { return .failedLaunch(PaneRecord.configRefusal) }
        if body.hasPrefix("failed\tcd") {
            let fields = body.split(separator: "\t", omittingEmptySubsequences: false)
            return .failedCD(status: fields.count > 2 ? Int32(fields[2].trimmingCharacters(in: .whitespaces)) ?? 1 : 1)
        }
        guard body.hasPrefix("ok\n") else { return .unreadable(String(body.prefix(80))) }
        guard let dirRange = body.range(of: "\ndir\t") else { return .unreadable("no folder") }
        let directory = String(body[dirRange.upperBound...])
        var values: [String: [String]] = [:]
        for line in body[..<dirRange.lowerBound].split(separator: "\n").dropFirst() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let key = fields.first else { continue }
            values[key] = Array(fields.dropFirst())
        }
        guard let epoch = values["epoch"]?.first.flatMap({ Int($0) }),
              let pane = values["pane"], let pid = pane.first.flatMap({ Int($0) }),
              let socket = values["socket"]?.joined(separator: "\t"), !socket.isEmpty, !directory.isEmpty
        else { return .unreadable(String(body.prefix(80))) }
        let server = values["server"] ?? []
        func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        // Strict: `unset`, or `set` and exactly one field of hex that is
        // valid UTF-8 (empty is a valid, encoded empty value). Anything
        // else is no evidence (nil), never a guess at a root.
        var config: RemoteEnvironment.ClaudeConfig?
        switch values["cfg"] {
        case ["unset"]?: config = .unset
        case let fields? where fields.count == 2 && fields[0] == "set": config = Self.hex(fields[1]).map { .set($0) }
        default: config = nil
        }
        return .ok(LaunchEvidence(epoch: epoch, directory: directory, panePID: pid,
                                  paneStart: nonEmpty(pane.count > 1 ? pane[1] : nil),
                                  socketPath: socket, serverPID: server.first.flatMap { Int($0) },
                                  serverStart: nonEmpty(server.count > 1 ? server[1] : nil), claudeConfig: config))
    }

    /// Hex as `od -An -tx1` prints it, spaces and newlines removed: only
    /// hex digits, in pairs, decoding to valid UTF-8; nil for anything else
    /// (no repair).
    static func hex(_ text: String) -> String? {
        func nibble(_ digit: UInt8) -> UInt8? {
            switch digit {
            case 0x30...0x39: digit - 0x30
            case 0x61...0x66: digit - 0x61 + 10
            case 0x41...0x46: digit - 0x41 + 10
            default: nil
            }
        }
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = 0
        while index < digits.count {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// `failed<TAB>tmux<TAB><status><TAB><tmux's first line>`.
    static func parseClient(_ text: String) -> ClientFailure? {
        var body = text
        if body.hasSuffix("\n") { body.removeLast() }
        let fields = body.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3, fields[0] == "failed", fields[1] == "tmux" else { return nil }
        let line = fields.count > 3 ? fields[3].trimmingCharacters(in: .whitespaces) : ""
        return ClientFailure(status: Int32(fields[2]) ?? 1, line: line)
    }
}

/// The folder sheet's advisory check: `cd -- <path> && pwd -P` with the
/// pane's `~` rule (section 7). What it resolves is intent; the row records
/// a folder only from the pane's `ok`.
public enum FolderCheck: Sendable, Equatable {
    case exists(resolved: String)
    case missing
    case cannotEnter(String)
    case transport(String)

    /// `pwd -P` is captured with a sentinel, so a folder whose name ends in
    /// a newline keeps it.
    static let script = """
    d=$1; NL='
    '
    case $d in "~") d=$HOME;; "~/"*) d=$HOME/${d#"~/"};; esac
    [ -e "$d" ] || { echo missing; exit 0; }
    if e=$(cd -- "$d" 2>&1 >/dev/null); then
      cd -- "$d" || exit 0
      w=$(pwd -P; printf x); w=${w%x}; w=${w%"$NL"}
      printf 'ok\\t%s\\n' "$w"
    else printf 'denied\\t%s\\n' "$e"; fi
    """

    public static let deadline: TimeInterval = 10

    public static func run(_ path: String, using exec: RemoteExec) async -> FolderCheck {
        do {
            let output = try await exec.run(script: script, args: [path], deadline: deadline)
            guard output.reachedCommand, output.status == 0 else {
                return .transport(output.firstErrorLine ?? "ssh exited with status \(output.status)")
            }
            return parse(output.stdout)
        } catch {
            return .transport(error.localizedDescription)
        }
    }

    static func parse(_ stdout: String) -> FolderCheck {
        var text = stdout
        if text.hasSuffix("\n") { text.removeLast() }
        if text == "missing" { return .missing }
        if text.hasPrefix("ok\t") { return .exists(resolved: String(text.dropFirst(3))) }
        if text.hasPrefix("denied\t") { return .cannotEnter(RemoteOutput.firstLine(String(text.dropFirst(7))) ?? "cd failed") }
        return .transport("the folder check printed something Temple didn't expect")
    }
}

/// Whether a Claude session has a transcript on the host: the evidence
/// that its conversation exists (typed input is not: Return at an ssh
/// prompt or Claude's trust screen proves nothing). It inspects exactly the
/// config root the agent was started with (recorded by its pane): set
/// (absolute, or relative to the folder it ran in, as the agent would read
/// it), or unset (`~/.claude`). Absent only when that root was checked to
/// the end and has no transcript for the id; a root Temple doesn't know, an
/// ancestor that can't be searched, or a store that can't be read whole is
/// unknown.
public enum ConversationCheck: Sendable, Equatable {
    case present
    /// The check completed and found no transcript for the id.
    case absent
    case unknown(String)

    /// Arguments `state value base id`: `state` is `set`, `unset` or
    /// anything else (unknown).
    static let script = #"""
    st=$1; v=$2; base=$3; id=$4
    case $st in
      set) case $v in /*) d=$v ;; *) d=$base/$v ;; esac ;;
      unset) d=$HOME/.claude ;;
      *) echo unknown; echo "Temple doesn't know which config folder this session used"; exit 0 ;;
    esac
    p=$d/projects
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then
      a=$p
      while :; do
        a=${a%/*}; [ -n "$a" ] || a=/
        { [ -e "$a" ] || [ "$a" = / ]; } && break
      done
      if [ -d "$a" ] && [ -x "$a" ]; then echo absent; else echo unknown; echo "$a can't be searched"; fi
      exit 0
    fi
    { [ -d "$p" ] && [ -r "$p" ] && [ -x "$p" ]; } || { echo unknown; echo "$p can't be read"; exit 0; }
    if f=$(find "$p" -mindepth 2 -maxdepth 2 -name "$id.jsonl" -print 2>/dev/null); then
      if [ -n "$f" ]; then echo present; else echo absent; fi
    elif [ -n "$f" ]; then echo present
    else echo unknown; echo "part of $p couldn't be read"; fi
    """#

    public static let deadline: TimeInterval = 15

    public static func run(sessionID: String, config: RemoteEnvironment.ClaudeConfig?, base: String,
                           using exec: RemoteExec) async -> ConversationCheck {
        precondition(RemoteQuoting.isSafeToken(sessionID))
        let state: String, value: String
        switch config {
        case .set(let configured)?: (state, value) = ("set", configured)
        case .unset?: (state, value) = ("unset", "")
        case nil: (state, value) = ("unknown", "")
        }
        do {
            let output = try await exec.run(script: script, args: [state, value, base, sessionID], deadline: deadline)
            guard output.reachedCommand, output.status == 0 else {
                return .unknown(output.firstErrorLine ?? "ssh exited with status \(output.status)")
            }
            let lines = output.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            switch lines.first {
            case "present": return .present
            case "absent": return .absent
            default: return .unknown(lines.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 } ?? "the check printed nothing Temple expected")
            }
        } catch {
            return .unknown(error.localizedDescription)
        }
    }
}
