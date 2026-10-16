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

    public init(epoch: Int, directory: String, panePID: Int, paneStart: String?, socketPath: String,
                serverPID: Int?, serverStart: String?) {
        self.epoch = epoch; self.directory = directory; self.panePID = panePID; self.paneStart = paneStart
        self.socketPath = socketPath; self.serverPID = serverPID; self.serverStart = serverStart
    }
}

/// The pane's record (`<marker>`).
public enum PaneRecord: Sendable, Equatable {
    case ok(LaunchEvidence)
    /// The pane could not enter the folder: no agent ran.
    case failedCD(status: Int32)
    /// A record Temple cannot read: proves nothing.
    case unreadable(String)
}

/// The tmux client's record (`<marker>.client`), kept apart from the pane's
/// (implementation note 3): a client failure means "creation not proven",
/// never "not created".
public struct ClientFailure: Sendable, Equatable {
    public var status: Int32
    public var line: String
}

/// Both records as one fetch found them.
public struct CollectedRecords: Sendable, Equatable {
    public var pane: PaneRecord?
    public var client: ClientFailure?
    public init(pane: PaneRecord? = nil, client: ClientFailure? = nil) { self.pane = pane; self.client = client }
    public var isEmpty: Bool { pane == nil && client == nil }
}

/// Fetching and acknowledging a launch's records by the name the run row
/// persisted, so an `ok` written but never collected (a quit or crash before
/// the first fetch, a dropped connection) is recovered on the next Open.
/// Records live 24 hours on the host (the launch's stale sweep).
public enum LaunchRecords {
    static let directoryLine = #"mdir=${TMPDIR:-/tmp}/temple-launch-$(id -u)"#

    /// Argument: the marker. Prints each record that exists as a header
    /// line (`pane <bytes>` or `client <bytes>`) followed by exactly that
    /// many bytes, then `end`.
    static let fetchScript = """
    m=$1; \(directoryLine)
    for f in pane client; do
      p=$mdir/$m; [ "$f" = client ] && p=$mdir/$m.client
      [ -f "$p" ] || continue
      n=$(wc -c < "$p" | tr -d ' ')
      printf '%s %s\\n' "$f" "$n"
      cat "$p"
    done
    printf 'end\\n'
    """

    /// Argument: the marker. Deletes both records, after their evidence has
    /// been written on this side, and the creating client's stderr file,
    /// which a client hung up while attached never got to remove.
    static let acknowledgeScript = """
    m=$1; \(directoryLine)
    rm -f "$mdir/$m" "$mdir/$m.client" "$mdir/$m.tmp" "$mdir/$m.client.tmp" "$mdir/$m.err"
    """

    public static let deadline: TimeInterval = 5

    public enum FetchError: Error, Equatable, LocalizedError {
        case transport(String)
        case malformed(String)
        public var errorDescription: String? {
            switch self {
            case .transport(let line): line
            case .malformed(let line): "the launch record could not be read: \(line)"
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
        return try parseFetch(Data(output.stdout.utf8))
    }

    public static func acknowledge(marker: String, using exec: RemoteExec) async {
        precondition(RemoteQuoting.isSafeToken(marker))
        _ = try? await exec.run(script: acknowledgeScript, args: [marker], deadline: deadline)
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
        return .ok(LaunchEvidence(epoch: epoch, directory: directory, panePID: pid,
                                  paneStart: nonEmpty(pane.count > 1 ? pane[1] : nil),
                                  socketPath: socket, serverPID: server.first.flatMap { Int($0) },
                                  serverStart: nonEmpty(server.count > 1 ? server[1] : nil)))
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

    static let script = """
    d=$1
    case $d in "~") d=$HOME;; "~/"*) d=$HOME/${d#"~/"};; esac
    [ -e "$d" ] || { echo missing; exit 0; }
    if e=$(cd -- "$d" 2>&1 >/dev/null); then cd -- "$d" && printf 'ok\\t%s\\n' "$(pwd -P)"; else printf 'denied\\t%s\\n' "$e"; fi
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
