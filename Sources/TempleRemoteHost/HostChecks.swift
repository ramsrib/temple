import Foundation
import TempleCore

// The Test connection's checks, by execution: each runs the thing Temple
// will rely on and keeps that tool's own words. Only a failure can be
// proven; nothing here is a promise that a launch will work.

/// One agent CLI on the host: is it on the resolved PATH, and does
/// `--version` run.
public enum ToolCheck: Sendable, Equatable {
    case runs(path: String, version: String, output: String)
    case missing
    case fails(path: String, status: Int32, firstLine: String, output: String)
    /// The check itself could not run (transport, deadline): proves nothing.
    case notChecked(reason: String)

    /// Deadline for one tool's check (section 2's probe).
    public static let deadline: TimeInterval = 10

    static let script = """
    t=$1
    p=$(command -v "$t" 2>/dev/null) || { echo missing; exit 0; }
    out=$("$p" --version </dev/null 2>&1); st=$?
    printf 'found\\t%s\\t%s\\n' "$st" "$p"
    printf '%s\\n' "$out" | head -n 40
    """

    public static func run(_ binary: String, using exec: RemoteExec) async -> ToolCheck {
        do {
            return parse(try await exec.run(script: script, args: [binary], deadline: deadline))
        } catch {
            return .notChecked(reason: error.localizedDescription)
        }
    }

    static func parse(_ output: RemoteOutput) -> ToolCheck {
        let lines = output.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard output.status == 0, let head = lines.first else {
            return .notChecked(reason: output.firstErrorLine ?? "ssh exited with status \(output.status)")
        }
        if head == "missing" { return .missing }
        let fields = head.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3, fields[0] == "found", let status = Int32(fields[1]) else {
            return .notChecked(reason: "the check printed something Temple didn't expect: \(head)")
        }
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let first = RemoteOutput.firstLine(body) ?? ""
        if status == 0 { return .runs(path: fields[2], version: first, output: body) }
        return .fails(path: fields[2], status: status, firstLine: first.isEmpty ? "exit status \(status)" : first, output: body)
    }

    /// Whether the check connected and the CLI did not run.
    public var provesUnavailable: Bool {
        switch self {
        case .missing, .fails: true
        case .runs, .notChecked: false
        }
    }
}

/// The launch chain's configuration, in the order the launcher sends it
/// (docs/designs/remote-ssh.md section 4). The Test connection executes
/// exactly this, on a throwaway server; the launcher builds its script from
/// the same list.
public enum TmuxChain {
    /// The oldest tmux Temple runs sessions under (`new-session -e`,
    /// `prefix None`).
    public static let floor = TmuxVersion(major: 3, minor: 2)
    /// `allow-passthrough` arrived in 3.3; set with `-q` before that.
    public static let passthroughSince = TmuxVersion(major: 3, minor: 3)

    /// Each command as sh words, with the name the test reports it by.
    public static let configure: [(name: String, words: String)] = [
        ("default-shell", "set -g default-shell /bin/sh"),
        ("default-terminal", "set -g default-terminal tmux-256color"),
        ("status off", "set -g status off"),
        ("prefix None", "set -g prefix None"),
        ("prefix2 None", "set -g prefix2 None"),
        ("set-titles", "set -g set-titles on"),
        ("set-titles-string", "set -g set-titles-string '#T'"),
        ("mouse", "set -g mouse on"),
        ("history-limit", "set -g history-limit 50000"),
        ("set-clipboard", "set -g set-clipboard on"),
        ("allow-passthrough", "set -gq allow-passthrough on"),
        ("detach-on-destroy", "set -g detach-on-destroy on"),
        ("destroy-unattached", "set -g destroy-unattached off"),
        ("copy-mode Any", "bind -T copy-mode Any send-keys -X cancel"),
    ]

    /// `start-server ';' <configure…> ';'`: the chain's head, ready for a
    /// `new-session`. tmux takes a `;` argument as its command separator.
    static var head: String {
        (["start-server"] + configure.map(\.words)).joined(separator: " ';' ") + " ';'"
    }
}

public struct TmuxVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let suffix: String
    public init(major: Int, minor: Int, suffix: String = "") {
        self.major = major; self.minor = minor; self.suffix = suffix
    }

    /// `tmux 3.2a` → 3.2a; `tmux next-3.5` → 3.5. Nil for builds that carry
    /// no number (`tmux master`).
    public init?(_ line: String) {
        guard let range = line.range(of: #"(\d+)\.(\d+)([a-z]?)"#, options: .regularExpression) else { return nil }
        let text = line[range]
        let digits = text.split(separator: ".")
        guard digits.count == 2, let major = Int(digits[0]) else { return nil }
        let minorText = digits[1].prefix { $0.isNumber }
        guard let minor = Int(minorText) else { return nil }
        self.init(major: major, minor: minor, suffix: String(digits[1].drop { $0.isNumber }))
    }

    public static func < (lhs: TmuxVersion, rhs: TmuxVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.suffix) < (rhs.major, rhs.minor, rhs.suffix)
    }

    public var description: String { "\(major).\(minor)\(suffix)" }
}

/// tmux on the host, by execution of the launch chain.
public enum TmuxCheck: Sendable, Equatable {
    /// The whole chain was accepted, detached, on a throwaway socket. (An
    /// attached client is phase 1a's acceptance.)
    case accepted(version: String, passthrough: Bool)
    /// The chain ran but this version is below the floor.
    case tooOld(version: String)
    /// tmux refused a command: which one, and tmux's own line.
    case refused(version: String, command: String?, line: String)
    case missing
    case notChecked(reason: String)

    public static let deadline: TimeInterval = 10

    /// Detached, on a throwaway socket: the chain with a `new-session -d`
    /// that exits at once, then `kill-server`. When the chain is refused,
    /// each command is tried alone to name the one tmux would not take.
    static var script: String {
        let probes = TmuxChain.configure.map { command in
            "  e1=$(tmux -L \"$s\" -f /dev/null start-server ';' \(command.words) ';' kill-server 2>&1 >/dev/null) "
                + "|| { printf 'refused\\t%s\\n' \(RemoteQuoting.quote(command.name)); printf '%s\\n' \"$e1\"; done_=1; }\n"
                + "  [ -z \"$done_\" ] || { cleanup; exit 0; }\n"
                + "  cleanup\n"
        }.joined()
        return """
        n=$1
        s=temple-check-$n
        cleanup() { tmux -L "$s" kill-server >/dev/null 2>&1; rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$s"; }
        v=$(tmux -V 2>&1) || { printf 'missing\\t%s\\n' "$v"; exit 0; }
        printf 'version\\t%s\\n' "$v"
        e=$(tmux -L "$s" -f /dev/null \(TmuxChain.head) new-session -d -s check -c "$HOME" -e PATH="$PATH" 'exit 0' ';' kill-server 2>&1 >/dev/null); st=$?
        cleanup
        printf 'chain\\t%s\\n' "$st"
        [ "$st" -eq 0 ] && exit 0
        printf '%s\\n' "$e" | head -n 5
        done_=
        \(probes)  e1=$(tmux -L "$s" -f /dev/null start-server ';' new-session -d -s check -c "$HOME" -e PATH="$PATH" 'exit 0' ';' kill-server 2>&1 >/dev/null) || { printf 'refused\\t%s\\n' new-session; printf '%s\\n' "$e1"; }
        cleanup
        exit 0
        """
    }

    public static func run(nonce: String, using exec: RemoteExec) async -> TmuxCheck {
        do {
            let output = try await exec.run(script: script, args: [nonce], deadline: deadline)
            return parse(output)
        } catch {
            return .notChecked(reason: error.localizedDescription)
        }
    }

    static func parse(_ output: RemoteOutput) -> TmuxCheck {
        guard output.status == 0 else {
            return .notChecked(reason: output.firstErrorLine ?? "ssh exited with status \(output.status)")
        }
        var version: String?
        var chain: Int32?
        var refused: String?
        var refusedLine: String?
        var chainLines: [String] = []
        var afterRefused = false
        for line in output.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "missing": return .missing
            case "version": version = fields.count > 1 ? fields[1] : ""
            case "chain": chain = fields.count > 1 ? Int32(fields[1]) : nil
            case "refused": refused = fields.count > 1 ? fields[1] : nil; afterRefused = true
            default:
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                if afterRefused { if refusedLine == nil { refusedLine = text } } else if chain != nil { chainLines.append(text) }
            }
        }
        guard let version, let chain else {
            return .notChecked(reason: output.firstErrorLine ?? "the tmux check printed nothing Temple expected")
        }
        let number = TmuxVersion(version)
        let shown = number?.description ?? version.replacingOccurrences(of: "tmux ", with: "")
        if chain != 0 {
            return .refused(version: shown, command: refused, line: refusedLine ?? chainLines.first ?? "exit status \(chain)")
        }
        if let number, number < TmuxChain.floor { return .tooOld(version: shown) }
        return .accepted(version: shown, passthrough: number.map { $0 >= TmuxChain.passthroughSince } ?? true)
    }

    public var provesUnavailable: Bool {
        switch self {
        case .tooOld, .refused, .missing: true
        case .accepted, .notChecked: false
        }
    }
}

/// systemd-logind's `KillUserProcesses`: advisory only. Temple changes
/// nothing on the host.
public enum LogindCheck: Sendable, Equatable {
    case killsUserProcesses(Bool)
    /// No busctl, or logind did not answer: nothing to say.
    case notAvailable(reason: String)

    public static let deadline: TimeInterval = 10

    static let script = """
    command -v busctl >/dev/null 2>&1 || { echo nobusctl; exit 0; }
    v=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager KillUserProcesses 2>&1); st=$?
    printf 'busctl\\t%s\\n%s\\n' "$st" "$v"
    """

    public static func run(using exec: RemoteExec) async -> LogindCheck {
        do {
            return parse(try await exec.run(script: script, args: [], deadline: deadline))
        } catch {
            return .notAvailable(reason: error.localizedDescription)
        }
    }

    static func parse(_ output: RemoteOutput) -> LogindCheck {
        guard output.status == 0 else { return .notAvailable(reason: output.firstErrorLine ?? "status \(output.status)") }
        let lines = output.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let head = lines.first else { return .notAvailable(reason: "no answer") }
        if head == "nobusctl" { return .notAvailable(reason: "no busctl on this host") }
        guard head == "busctl\t0" || head.hasPrefix("busctl\t0"), lines.count > 1 else {
            return .notAvailable(reason: lines.dropFirst().first ?? head)
        }
        switch lines[1] {
        case "b true": return .killsUserProcesses(true)
        case "b false": return .killsUserProcesses(false)
        default: return .notAvailable(reason: lines[1])
        }
    }
}

/// Why ssh would not connect, from its own stderr.
public enum SSHFailure: Sendable, Equatable {
    /// "Host key verification failed." with no changed-key banner.
    case unknownHostKey
    /// The changed-key banner; `offending` is ssh's `Offending … key in …:N`.
    case changedHostKey(offending: String?)
    case other(firstLine: String)
    /// The interactive connect left no master: ssh said why on the
    /// terminal, where its words stay.
    case connectFailed
    /// A master answered, but the first query over it did not run on the
    /// host (a dead connection behind a live master, a refused session):
    /// ssh's line. Never reported as connected.
    case unconfirmed(String)
    /// This Mac could not prepare the test (the socket directory).
    case localSetup(String)

    public static func classify(stderr: String, status: Int32) -> SSHFailure {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") }) {
            return .changedHostKey(offending: lines.first { $0.hasPrefix("Offending ") && $0.contains(" key in ") })
        }
        if lines.contains("Host key verification failed.") { return .unknownHostKey }
        let first = lines.first { line in
            !line.isEmpty && !line.hasPrefix("Warning: Permanently added") && !line.hasPrefix("Pseudo-terminal will not")
                && !(line.hasPrefix("Connection to ") && line.hasSuffix(" closed."))
        }
        return .other(firstLine: first ?? "ssh exited with status \(status)")
    }

    /// The copy the sheet and the Hosts list show.
    public var message: String {
        switch self {
        case .unknownHostKey:
            "ssh hasn't seen this host's key before. Test the connection to check it and confirm it."
        case .changedHostKey(let offending):
            "ssh says this host's key has changed and will not connect. Temple won't change your known_hosts; check the host first."
                + (offending.map { " ssh named the line: \($0)." } ?? "")
        case .other(let line):
            "Couldn't connect: \(line.hasSuffix(".") ? String(line.dropLast()) : line)."
        case .connectFailed:
            "Couldn't connect. See ssh's message above."
        case .unconfirmed(let line):
            "Couldn't confirm the connection: \(line.hasSuffix(".") ? String(line.dropLast()) : line)."
        case .localSetup(let reason):
            "Temple couldn't prepare the test: \(reason.hasSuffix(".") ? String(reason.dropLast()) : reason)."
        }
    }

    /// A changed key offers Close only: no retry until the user has looked.
    /// The line under a host in the Hosts list, where ssh's message is not
    /// on screen.
    public var listMessage: String {
        guard case .connectFailed = self else { return message }
        return "Couldn't connect. Test the connection to see ssh's message."
    }

    public var allowsRetry: Bool {
        if case .changedHostKey = self { return false }
        return true
    }
}

/// What one Test connection found: the status line under the host, and the
/// proven incompatibilities `availability` reports. Memory only.
public struct HostTestSummary: Sendable, Equatable {
    public var failure: SSHFailure?
    /// From `ssh -G`: `user@hostname`.
    public var connectedAs: String?
    public var environment: RemoteEnvironment?
    public var claude: ToolCheck?
    public var codex: ToolCheck?
    public var tmux: TmuxCheck?
    public var logind: LogindCheck?

    public init(failure: SSHFailure? = nil, connectedAs: String? = nil, environment: RemoteEnvironment? = nil,
                claude: ToolCheck? = nil, codex: ToolCheck? = nil, tmux: TmuxCheck? = nil, logind: LogindCheck? = nil) {
        self.failure = failure; self.connectedAs = connectedAs; self.environment = environment
        self.claude = claude; self.codex = codex; self.tmux = tmux; self.logind = logind
    }

    public static let notTested = "Not tested yet. Test the connection to check this host."

    /// One status line: how it connected and what runs there, then each
    /// problem in its own sentence.
    public var statusLine: String {
        if let failure { return failure.listMessage }
        var sentences: [String] = []
        sentences.append(connectedAs.map { "Connected as \($0)." } ?? "Connected.")
        var running: [String] = []
        if case .runs(_, let version, _)? = claude { running.append("Claude Code \(AgentInstall.versionNumber(in: version) ?? version)") }
        if case .runs(_, let version, _)? = codex { running.append("Codex \(AgentInstall.versionNumber(in: version) ?? version)") }
        if case .accepted(let version, _)? = tmux { running.append("tmux \(version)") }
        if !running.isEmpty { sentences.append(running.joined(separator: ", ") + ".") }
        for (name, check) in [("claude", claude), ("codex", codex)] {
            if let problem = check.flatMap({ Self.problem(name, $0) }) { sentences.append(problem) }
        }
        if let problem = tmux.flatMap(Self.problem) { sentences.append(problem) }
        if let environment, environment.path == nil {
            sentences.append("Couldn't read the login shell's PATH: \(environment.problem ?? "no answer"); using ssh's default environment.")
        }
        return sentences.joined(separator: " ")
    }

    static func problem(_ binary: String, _ check: ToolCheck) -> String? {
        switch check {
        case .runs: nil
        case .missing: "No \(binary) on PATH."
        case .fails(_, _, let line, _): "\(binary) is there but didn't run: \(line)."
        case .notChecked(let reason): "\(binary) wasn't checked: \(reason)"
        }
    }

    static func problem(_ check: TmuxCheck) -> String? {
        switch check {
        case .accepted(let version, let passthrough):
            passthrough ? nil : "tmux \(version): clipboard passthrough is off on this version."
        case .tooOld(let version): "tmux \(version): Temple needs tmux 3.2 or newer to keep sessions running."
        case .refused(let version, _, let line): "tmux \(version) refused the launch chain: \(line)"
        case .missing: "No tmux on this host. Install tmux 3.2 or newer to start sessions here."
        case .notChecked(let reason): "tmux wasn't checked: \(reason)"
        }
    }

    /// `.unavailable` only when a test connected and the CLI or tmux did not
    /// run; nil otherwise (not tested, couldn't connect, or it ran).
    public func unavailableReason(for agent: Agent) -> String? {
        guard failure == nil else { return nil }
        let check = agent == .claude ? claude : codex
        if let check, check.provesUnavailable, let problem = Self.problem(agent.binaryName, check) { return problem }
        if let tmux, tmux.provesUnavailable { return Self.problem(tmux) }
        return nil
    }

    /// Whether the last test proved tmux missing (⌘N leaves such hosts out).
    public var provesTmuxMissing: Bool { tmux == .missing }
}
