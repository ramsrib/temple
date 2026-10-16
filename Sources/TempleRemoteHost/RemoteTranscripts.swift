import Foundation
import TempleCore

// Enrichment's two queries (docs/designs/remote-ssh.md sections 6 and 12,
// phase 2): `locate` finds the transcript files named for ids Temple already
// has rows for, and `read` takes one file's bytes. Both are fixed scripts
// with positional arguments, run like every query (the short bootstrap on
// the command line, the program on stdin). Nothing here lists a session
// Temple has no row for: every `find` is narrowed to the requested ids.
//
// Paths come back hex-encoded, file bytes length-framed, and every answer
// ends with `done` and nothing after it; anything else is not an answer.

/// Where one agent keeps its transcripts on a host, as Temple knows it: the
/// agent's root variable (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) set (absolute,
/// or relative to `base`, the folder the agent ran in) or unset (the
/// agent's default under `$HOME`). The host resolves and canonicalizes it
/// (`pwd -P`, with a sentinel, so a name ending in a newline keeps it).
public struct RemoteTranscriptRoot: Sendable, Hashable {
    public let state: String
    public let value: String
    public let base: String

    /// Nil when Temple doesn't know the root: the variable couldn't be read,
    /// it is set to the empty string (how the agent reads that is not
    /// established), or it is relative with no folder to resolve it
    /// against. Never a guess.
    public init?(_ variable: RemoteEnvironment.Variable?, base: String?) {
        switch variable {
        case .unset?: (state, value, self.base) = ("unset", "", "")
        case .set(let configured)? where configured.isEmpty: return nil
        case .set(let configured)? where configured.hasPrefix("/"): (state, value, self.base) = ("set", configured, "")
        case .set(let configured)?:
            guard let base, base.hasPrefix("/") else { return nil }
            (state, value, self.base) = ("set", configured, base)
        case nil: return nil
        }
    }
}

enum RemoteTranscripts {
    /// Shell shared by both scripts: `gnu` (whether `find -printf` works),
    /// `temple_hex` (stdin as hex, as `od -An -tx1` prints it, spaces and
    /// newlines removed) and `temple_stat <path>` (size, modification time
    /// with its fraction, and inode, tab-separated, no newline; the same
    /// spelling in the listing and in a read, so the two agree exactly).
    /// GNU `find` on Linux; BSD `stat -f` elsewhere (tested here, not an
    /// acceptance target).
    static let common = #"""
    NL='
    '
    TAB=$(printf '\t')
    set -f
    if find / -maxdepth 0 -printf '' >/dev/null 2>&1; then gnu=1; else gnu=; fi
    temple_hex() { od -An -v -tx1 | tr -d ' \n'; }
    temple_stat() {
      if [ -n "$gnu" ]; then find "$1" -maxdepth 0 -printf '%s\t%T@\t%i' 2>/dev/null
      else _s=$(stat -f '%z%t%Fm%t%i' -- "$1" 2>/dev/null) || return 1; printf '%s' "$_s"; fi
    }
    temple_gone() {
      [ -e "$1" ] || [ -L "$1" ] && return 1
      _d=${1%/*}; [ -n "$_d" ] || _d=/
      [ -d "$_d" ] && [ -x "$_d" ]
    }
    """#

    /// Arguments: groups of five (`agent state value base ids`, `ids` the
    /// requested ids separated by spaces), then `--`, then hint paths.
    /// Per group, in order: `root<TAB><i><TAB>ok<TAB><hex canonical root>`
    /// and `list<TAB><i><TAB><hex>` (the matching files as NUL-terminated
    /// `size<TAB>mtime<TAB>inode<TAB>path` records, then `S<find's
    /// status>`), or `root<TAB><i><TAB>none` (nothing there) or `failed`
    /// or `unknown`. Per hint: `hint<TAB><hex path><TAB>ok<TAB><stat>`,
    /// `missing` or `unreadable`. Then `done`.
    static let locateScript = common + "\n" + #"""
    temple_find() {
      _ag=$1; _p=$2; _ids=$3; set --
      for _n in $_ids; do
        if [ "$_ag" = claude ]; then set -- "$@" -o -name "$_n.jsonl"
        else set -- "$@" -o -name "rollout-*-$_n.jsonl" -o -name "rollout-*-${_n}_*.jsonl"; fi
      done
      [ $# -gt 0 ] || return 0
      shift
      if [ "$_ag" = claude ]; then set -- "$_p" -mindepth 2 -maxdepth 2 \( "$@" \)
      else set -- "$_p" \( "$@" \); fi
      if [ -n "$gnu" ]; then find "$@" -printf '%s\t%T@\t%i\t%p\0' 2>/dev/null
      else find "$@" -exec sh -c 'for f; do s=$(stat -f "%z%t%Fm%t%i" -- "$f") || exit 1; printf "%s\t%s\0" "$s" "$f"; done' temple-stat {} + 2>/dev/null
      fi
    }
    i=0
    while [ $# -ge 5 ] && [ "$1" != -- ]; do
      ag=$1; st=$2; v=$3; b=$4; ids=$5; shift 5
      if [ "$ag" = claude ]; then def=.claude; sub=projects; else def=.codex; sub=sessions; fi
      d=
      case $st in
        set) case $v in /*) d=$v ;; *) [ -n "$b" ] && d=$b/$v ;; esac ;;
        unset) d=$HOME/$def ;;
      esac
      if [ -z "$d" ]; then printf 'root\t%s\tunknown\n' "$i"
      elif [ ! -e "$d" ] && [ ! -L "$d" ]; then printf 'root\t%s\tnone\n' "$i"
      elif h=$(cd -- "$d" 2>/dev/null && pwd -P && printf x); then
        h=${h%x}; h=${h%"$NL"}
        printf 'root\t%s\tok\t%s\n' "$i" "$(printf '%s' "$h" | temple_hex)"
        p=$h/$sub
        if [ ! -e "$p" ] && [ ! -L "$p" ]; then
          printf 'list\t%s\t%s\n' "$i" "$(printf 'S0' | temple_hex)"
        else
          printf 'list\t%s\t%s\n' "$i" "$( (temple_find "$ag" "$p" "$ids"; printf 'S%s' "$?") | temple_hex)"
        fi
      else printf 'root\t%s\tfailed\n' "$i"
      fi
      i=$((i+1))
    done
    [ "$1" = -- ] && shift
    for f; do
      x=$(printf '%s' "$f" | temple_hex)
      if s=$(temple_stat "$f"); then printf 'hint\t%s\tok\t%s\n' "$x" "$s"
      elif temple_gone "$f"; then printf 'hint\t%s\tmissing\n' "$x"
      else printf 'hint\t%s\tunreadable\n' "$x"; fi
    done
    printf 'done\n'
    """#

    /// Arguments `path head tailFrom facts home id`. Prints the opening
    /// `stat<TAB>…` line, the first `head` bytes (`head<TAB><n>`, the
    /// bytes, `\nend`), when `facts` is 1 and the file is longer than
    /// `tailFrom` the last `min(tailFrom, size - tailFrom)` bytes (`tail`,
    /// framed the same way), when `home` is set every line of the agent's
    /// shared inputs there that contains `id` (`shared<TAB><name><TAB><n>`,
    /// framed; `shared<TAB><name><TAB>absent` for a file that isn't
    /// there), the closing stat, then `done`. Or `missing`, or
    /// `unreadable<TAB><why>`, at any point instead (then nothing more).
    /// Bytes go through a private temp file, so each frame's length is the
    /// length of exactly what follows it.
    static let readScript = common + "\n" + #"""
    f=$1; hb=$2; w=$3; facts=$4; home=$5; id=$6
    t=$(umask 077; mktemp "${TMPDIR:-/tmp}/temple-read.XXXXXX" 2>/dev/null) || { printf 'unreadable\tno temporary file on the host\n'; exit 0; }
    trap 'rm -f "$t"' EXIT
    trap 'exit 1' HUP INT TERM
    frame() { _n=$(wc -c < "$t" | tr -d ' '); printf '%s\t%s\n' "$1" "$_n"; cat "$t"; printf '\nend\n'; }
    stamp() {
      if s=$(temple_stat "$f"); then printf 'stat\t%s\n' "$s"; size=${s%%"$TAB"*}
      elif temple_gone "$f"; then printf 'missing\n'; exit 0
      else printf 'unreadable\tthe file cannot be examined\n'; exit 0; fi
    }
    stamp
    head -c "$hb" -- "$f" > "$t" 2>/dev/null || { printf 'unreadable\tthe file cannot be read\n'; exit 0; }
    frame head
    if [ "$facts" = 1 ] && [ "$size" -gt "$w" ]; then
      tb=$((size - w)); [ "$tb" -gt "$w" ] && tb=$w
      tail -c "$tb" -- "$f" > "$t" 2>/dev/null || { printf 'unreadable\tthe file cannot be read\n'; exit 0; }
      frame tail
    fi
    if [ "$facts" = 1 ] && [ -n "$home" ]; then
      for n in history.jsonl session_index.jsonl; do
        g=$home/$n
        if [ ! -e "$g" ] && [ ! -L "$g" ]; then printf 'shared\t%s\tabsent\n' "$n"; continue; fi
        grep -F -e "$id" -- "$g" > "$t" 2>/dev/null
        [ $? -le 1 ] || { printf 'unreadable\t%s cannot be read\n' "$n"; exit 0; }
        frame "shared$TAB$n"
      done
    fi
    stamp
    printf 'done\n'
    """#

    static let locateDeadline: TimeInterval = 20
    static let readDeadline: TimeInterval = 20

    // MARK: Parsing

    enum RootOutcome: Equatable {
        case ok(String)
        case none, failed, unknown
    }

    struct Listed: Equatable {
        let path: String
        let signature: TranscriptSignature
    }

    struct LocateAnswer: Equatable {
        var roots: [Int: RootOutcome] = [:]
        /// Per group with a root: its files, or nil when the listing failed.
        var lists: [Int: [Listed]?] = [:]
        var hints: [String: CandidateStat] = [:]
    }

    /// Strict: every line known, every group answered once, `done` last
    /// with nothing after it. Nil for anything else.
    static func parseLocate(_ data: Data, groups: Int) -> LocateAnswer? {
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("done\n") else { return nil }
        var answer = LocateAnswer()
        var lines = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.last == "done" else { return nil }
        lines.removeLast()
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "root":
                guard fields.count >= 3, let index = Int(fields[1]), (0..<groups).contains(index),
                      answer.roots[index] == nil else { return nil }
                switch (fields[2], fields.count) {
                case ("ok", 4):
                    guard let root = LaunchRecords.hex(fields[3]), root.hasPrefix("/") else { return nil }
                    answer.roots[index] = .ok(root)
                case ("none", 3): answer.roots[index] = RootOutcome.none
                case ("failed", 3): answer.roots[index] = .failed
                case ("unknown", 3): answer.roots[index] = .unknown
                default: return nil
                }
            case "list":
                guard fields.count == 3, let index = Int(fields[1]), case .ok? = answer.roots[index],
                      answer.lists[index] == nil, let bytes = hexBytes(fields[2]) else { return nil }
                answer.lists[index] = .some(listing(bytes))
            case "hint":
                guard fields.count >= 3, let path = LaunchRecords.hex(fields[1]) else { return nil }
                switch (fields[2], fields.count) {
                case ("ok", 6):
                    guard let signature = signature(fields[3...5].joined(separator: "\t")) else { return nil }
                    answer.hints[path] = .present(signature)
                case ("missing", 3): answer.hints[path] = .missing
                case ("unreadable", 3): answer.hints[path] = .unreadable
                default: return nil
                }
            default:
                return nil
            }
        }
        // Every group answered, and every root that was found listed.
        guard answer.roots.count == groups else { return nil }
        for (index, root) in answer.roots {
            if case .ok = root, answer.lists[index] == nil { return nil }
        }
        return answer
    }

    /// The NUL-terminated records and the trailing `S<status>`: the files,
    /// or nil when `find` failed (a partial listing is not used) or the
    /// bytes are not that shape.
    static func listing(_ bytes: Data) -> [Listed]? {
        let parts = bytes.split(separator: 0, omittingEmptySubsequences: false)
        guard let status = parts.last.map({ String(decoding: $0, as: UTF8.self) }), status == "S0" else { return nil }
        var files: [Listed] = []
        for record in parts.dropLast() {
            let fields = record.split(separator: 0x09, maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, let path = String(data: Data(fields[3]), encoding: .utf8), path.hasPrefix("/"),
                  let stat = signature(String(decoding: Data(fields[0..<3].joined(separator: [0x09])), as: UTF8.self))
            else { return nil }
            files.append(Listed(path: path, signature: stat))
        }
        return files
    }

    /// `size<TAB>mtime<TAB>inode`, as `temple_stat` prints it.
    static func signature(_ text: String) -> TranscriptSignature? {
        let fields = text.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 3, let size = Int(fields[0]), size >= 0,
              let seconds = Double(fields[1]), seconds.isFinite, let inode = UInt64(fields[2]) else { return nil }
        return TranscriptSignature(modifiedAt: Date(timeIntervalSince1970: seconds), size: size, identity: inode)
    }

    static func hexBytes(_ text: String) -> Data? {
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
        var bytes = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    enum ReadAnswer: Equatable {
        case missing
        case unreadable(String)
        case bytes(ReadBytes)
    }

    struct ReadBytes: Equatable {
        var opening: TranscriptSignature
        var head: Data
        var tail: Data?
        /// Present inputs only (an absent one is not a key).
        var shared: [String: Data]
        var closing: TranscriptSignature
    }

    /// Strict: the shape `readScript` prints and nothing else, `done` last.
    static func parseRead(_ data: Data) -> ReadAnswer? {
        var index = data.startIndex
        func line() -> String? {
            guard let newline = data[index...].firstIndex(of: 0x0a),
                  let text = String(data: data[index..<newline], encoding: .utf8) else { return nil }
            index = data.index(after: newline)
            return text
        }
        let end = Data("\nend\n".utf8)
        func body(_ count: Int) -> Data? {
            // By subtraction: a length near Int.max must not overflow.
            let remaining = data.distance(from: index, to: data.endIndex)
            guard count >= 0, remaining >= end.count, count <= remaining - end.count else { return nil }
            let bodyEnd = data.index(index, offsetBy: count)
            guard data[bodyEnd..<data.index(bodyEnd, offsetBy: end.count)].elementsEqual(end) else { return nil }
            defer { index = data.index(bodyEnd, offsetBy: end.count) }
            return Data(data[index..<bodyEnd])
        }
        func terminal(_ text: String) -> ReadAnswer? {
            guard index == data.endIndex else { return nil }
            if text == "missing" { return .missing }
            if text.hasPrefix("unreadable\t") { return .unreadable(String(text.dropFirst("unreadable\t".count))) }
            return nil
        }
        guard let first = line() else { return nil }
        guard first.hasPrefix("stat\t") else { return terminal(first) }
        guard let opening = signature(String(first.dropFirst(5))) else { return nil }
        var head: Data?, tail: Data?, shared: [String: Data] = [:], absent: Set<String> = []
        while let next = line() {
            let fields = next.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "head" where fields.count == 2 && head == nil:
                guard let count = Int(fields[1]), let bytes = body(count) else { return nil }
                head = bytes
            case "tail" where fields.count == 2 && head != nil && tail == nil && shared.isEmpty && absent.isEmpty:
                guard let count = Int(fields[1]), let bytes = body(count) else { return nil }
                tail = bytes
            case "shared" where fields.count == 3 && head != nil:
                let name = fields[1]
                guard CodexFormat().sharedInputs.contains(name), shared[name] == nil, !absent.contains(name) else { return nil }
                if fields[2] == "absent" { absent.insert(name); continue }
                guard let count = Int(fields[2]), let bytes = body(count) else { return nil }
                shared[name] = bytes
            case "stat" where fields.count == 4 && head != nil:
                guard let closing = signature(fields[1...3].joined(separator: "\t")), line() == "done",
                      index == data.endIndex, let head else { return nil }
                return .bytes(ReadBytes(opening: opening, head: head, tail: tail, shared: shared, closing: closing))
            default:
                return terminal(next)
            }
        }
        return nil
    }

    // MARK: Identity, as the local store reads it

    /// The identity verdict from the first `head.count` bytes of a file of
    /// `size` bytes, read under `scan` exactly as the local store reads it
    /// (`StoreIO.identity`), and how many of those bytes it used. Nil when
    /// the head is too short to decide what a full scan would (read more).
    /// Throws `.unreadable` for a header line longer than its cap.
    static func identity(_ format: any TranscriptFormat, head: Data, size: Int, expecting id: String) throws
        -> (verdict: TranscriptVerification, bytesRead: Int)? {
        let whole = head.count >= size
        switch format.identityScan {
        case .firstLine(let maxBytes):
            let window = head.prefix(maxBytes)
            if let newline = window.firstIndex(of: 0x0a) {
                let line = Data(window[..<newline])
                return (format.identity(lines: [line], expecting: id), line.count + 1)
            }
            // No newline inside the cap: the whole file when it ended first,
            // corrupt when the cap came first.
            if window.count < maxBytes {
                guard whole else { return nil }
                return (format.identity(lines: [Data(window)], expecting: id), window.count + 1)
            }
            throw TranscriptReadError.unreadable("the transcript's header line is longer than \(maxBytes) bytes")
        case .lines(let maxBytes):
            let window = head.prefix(maxBytes)
            let reachedEnd = whole && head.count <= maxBytes
            var lines: [Data] = []
            var start = window.startIndex
            while let newline = window[start...].firstIndex(of: 0x0a) {
                lines.append(Data(window[start..<newline]))
                start = window.index(after: newline)
            }
            if reachedEnd, start < window.endIndex { lines.append(Data(window[start...])) }
            let verdict = format.identity(lines: lines, expecting: id)
            // Undecided on a head shorter than the scan: a full scan may decide.
            if verdict == .incomplete, !whole, window.count < maxBytes { return nil }
            return (verdict, window.count)
        }
    }
}
