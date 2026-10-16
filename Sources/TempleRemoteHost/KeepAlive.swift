import Foundation
import TempleCore

/// What keeps an agent alive on a host while no tab is attached to it
/// (docs/designs/remote-ssh.md section 4). One small protocol, so trying
/// another keep-alive (shpool) later is a change here, not a redesign:
///
/// - creation and attachment are different commands, chosen by Temple from
///   the run's state, never by a pre-check on the host;
/// - liveness is three-valued and only a positive absence ends a run;
/// - the one destructive action is a stop whose outcome is decoded once,
///   the same way everywhere.
///
/// It never lists or discovers sessions: Temple only ever asks about the
/// sessions it started, each on the server it was created on.
public protocol KeepAlive: Sendable {
    /// The remote command (for `ssh -t … -- <host> <command>`) that creates
    /// the session and runs the pane command in it.
    func createCommand(_ launch: RemoteLaunchPlan) -> String
    /// The remote command that attaches to an existing session and creates
    /// nothing.
    func attachCommand(_ launch: RemoteLaunchPlan) -> String
    func liveness(session: String, socket: String?, using exec: RemoteExec) async -> Liveness
    /// Liveness with the attached count, for "Sessions on <host>".
    func probe(session: String, socket: String?, using exec: RemoteExec) async -> Probe
    /// The one-command, attached-checked stop. `waitTenths`: how long the
    /// host may wait for Temple's own client (already detached on this
    /// side) to leave before the check, in tenths of a second.
    func stop(session: String, socket: String?, waitTenths: Int, using exec: RemoteExec) async throws -> StopOutcome
}

/// Everything one launch on a host needs, decided before anything runs.
public struct RemoteLaunchPlan: Sendable, Equatable {
    /// How the launch gets its PATH (section 2's one policy).
    public enum Path: Sendable, Equatable {
        /// The login shell's PATH, resolved by a query.
        case resolved(String)
        /// Resolution ran on the host and found none: ssh's default
        /// environment, as the checks used.
        case fallback
        /// Not resolved yet (no query has reached the host): the launch asks
        /// the login shell itself, with the same resolver and its bound.
        case unresolved
    }

    /// The run's handle: the session is `temple-<handle>`.
    public var handle: String
    /// The launch record's name on the host (`[A-Za-z0-9._-]`).
    public var marker: String
    /// The folder as the user named it; the pane expands `~` and enters it.
    public var directory: String
    /// The agent's argv, run by the pane with `exec` (the pane pid is the
    /// agent's).
    public var agentArgv: [String]
    public var path: Path
    /// Claude's config root from the same login environment as the PATH;
    /// nil when Temple has none (the launch resolves it with the PATH, or
    /// the agent keeps whatever its environment gives).
    public var claudeConfig: RemoteEnvironment.ClaudeConfig?
    /// The pinned server's socket, for an attach (nil: `-L temple`).
    public var socket: String?

    public init(handle: String, marker: String, directory: String, agentArgv: [String], path: Path,
                claudeConfig: RemoteEnvironment.ClaudeConfig? = nil, socket: String?) {
        self.handle = handle; self.marker = marker; self.directory = directory
        self.agentArgv = agentArgv; self.path = path; self.claudeConfig = claudeConfig; self.socket = socket
    }
}

/// tmux's words for a session that is not there: the one diagnostic that
/// proves absence, matched exactly for the name asked about.
enum TmuxDiagnostic {
    static func isMissing(_ output: RemoteOutput, session: String) -> Bool {
        output.status == 1 && output.firstErrorLine == "can't find session: \(session)"
    }

    static func socketMissing(_ stderr: String) -> Bool {
        stderr.contains("no server running on")
            || (stderr.contains("error connecting to") && stderr.contains("No such file or directory"))
    }
}

/// The liveness contract (section 5): `has-session` against the pinned
/// socket, with stderr kept.
public enum Liveness: Sendable, Equatable {
    /// The server has the session.
    case present
    /// The pinned server answered and does not have it: the only answer
    /// that ends a run.
    case absent
    /// Anything else. `socketMissing`: tmux said there is no server at the
    /// socket (`no server running on`, or `error connecting to … (No such
    /// file or directory)`), which in v1 is not proof: tmux can lose its
    /// socket while the server lives.
    case unknown(reason: String, socketMissing: Bool)

    public static func classify(_ output: RemoteOutput, session: String) -> Liveness {
        guard output.reachedCommand else {
            return .unknown(reason: output.firstErrorLine ?? "ssh exited with status \(output.status)", socketMissing: false)
        }
        if output.status == 0 { return .present }
        if TmuxDiagnostic.isMissing(output, session: session) { return .absent }
        let line = output.firstErrorLine ?? (output.status == 127 ? "tmux is not on PATH" : "tmux exited with status \(output.status)")
        return .unknown(reason: line, socketMissing: TmuxDiagnostic.socketMissing(output.stderr))
    }
}

/// Liveness with the session's attached count.
public enum Probe: Sendable, Equatable {
    case present(attached: Int)
    case absent
    case unknown(reason: String, reachedHost: Bool)
}

/// One decoded stop outcome, the same everywhere (implementation note 5):
/// the query succeeded without `temple-not-killed` → killed; the marker →
/// refused (another client is attached); the pinned server answered that the
/// session is not there (its exact words) → absent; anything else, a failure
/// or a deadline → unconfirmed. A cancelled query may already have taken
/// effect, so an unconfirmed stop is never retried automatically.
public enum StopOutcome: Sendable, Equatable {
    case killed
    case refused
    case absent
    /// `reachedHost` false: ssh never reached the host (the host did not
    /// answer); true: the command ran, or may have, and did not confirm.
    case unconfirmed(reason: String, reachedHost: Bool)

    public static let notKilledMarker = "temple-not-killed"

    public static func decode(_ output: RemoteOutput, session: String) -> StopOutcome {
        guard output.reachedCommand else {
            return .unconfirmed(reason: output.firstErrorLine ?? "ssh exited with status \(output.status)", reachedHost: false)
        }
        if output.stdout.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == notKilledMarker }) {
            return .refused
        }
        if output.status == 0 { return .killed }
        if TmuxDiagnostic.isMissing(output, session: session) { return .absent }
        return .unconfirmed(reason: output.firstErrorLine ?? "tmux exited with status \(output.status)", reachedHost: true)
    }

    /// A query that failed without an answer. A deadline may have reached
    /// the host; a process that never started did not.
    public static func failed(_ error: Error) -> StopOutcome {
        if case RemoteExecError.launchFailed? = error as? RemoteExecError {
            return .unconfirmed(reason: error.localizedDescription, reachedHost: false)
        }
        return .unconfirmed(reason: error.localizedDescription, reachedHost: true)
    }
}

/// Where launch records live on a host, and how they are written: a real
/// directory the user owns, mode 0700, not a symlink, checked before every
/// record operation; records written beside without following a link, then
/// moved into place. A stable location in the account's home, the same for
/// every connection: `~/.temple/launch/<marker>`.
public enum RecordDirectory {
    /// The locator a run row persists.
    public static func locator(marker: String) -> String { "~/.temple/launch/\(marker)" }

    /// The marker a locator names; nil for anything else.
    public static func marker(from locator: String) -> String? {
        let name = locator.split(separator: "/").last.map(String.init) ?? locator
        guard RemoteQuoting.isSafeToken(name), locator == Self.locator(marker: name) || locator == name else { return nil }
        return name
    }

    /// `temple_record_dir` prints the checked directory or fails;
    /// `temple_write <path> <text>` writes a record.
    static let functions = #"""
    temple_record_dir() {
      _d=$HOME/.temple; _r=$_d/launch; _u=$(id -u)
      [ -n "$HOME" ] || return 1
      umask 077
      [ -L "$_d" ] && return 1
      [ -d "$_d" ] || mkdir -m 700 "$_d" 2>/dev/null || return 1
      [ -n "$(find "$_d" -maxdepth 0 -type d -user "$_u" ! -perm -020 ! -perm -002 2>/dev/null)" ] || return 1
      [ -L "$_r" ] && return 1
      [ -d "$_r" ] || mkdir -m 700 "$_r" 2>/dev/null || return 1
      [ -n "$(find "$_r" -maxdepth 0 -type d -user "$_u" -perm 700 2>/dev/null)" ] || return 1
      printf '%s' "$_r"
    }
    temple_write() {
      rm -f "$1.tmp" && ( set -C; printf '%s\n' "$2" > "$1.tmp" ) && mv -f "$1.tmp" "$1"
    }
    """#
}

/// The hidden tmux server, one command queue per creation (section 4).
public struct TmuxKeepAlive: KeepAlive {
    public init() {}

    // MARK: Launch

    /// The wrapper the user's ssh runs on the host, arguments
    /// `mode marker socket pane`; the handle comes in `TEMPLE_HANDLE`.
    ///
    /// - `create`: one client invocation, one command queue on one server:
    ///   configure, then `new-session` (no `-A`: a duplicate name is a loud
    ///   failure, never an attach to something Temple did not start), in `/`
    ///   (the pane enters the folder itself; `-c` is format-expanded by tmux,
    ///   so no user path goes there). The pane learns where to write its
    ///   record from `-e TEMPLE_RECORD`. The client's own failure goes to
    ///   `<marker>.client`, apart from the pane's `<marker>` (note 3): a tmux
    ///   client can fail after the session exists.
    /// - `attach`: `attach-session` on the pinned socket (`-S`), or on
    ///   `-L temple` when the run has no pin yet. It runs no pane command
    ///   and writes no record.
    ///
    /// PATH follows the plan: the resolved PATH, ssh's default environment,
    /// or (not resolved yet) the login shell asked here by the same bounded
    /// resolver the environment query uses.
    public static var wrapperScript: String {
        RemoteEnvironment.resolverFunction + "\n" + RecordDirectory.functions + "\n" + """
        mode=$1; m=$2; sock=$3; pane=$4
        s=temple-$TEMPLE_HANDLE
        T=$(printf '\\t')
        unset TMUX TEMPLE_HANDLE
        if [ -n "$TEMPLE_RESOLVE_PATH" ]; then
          unset TEMPLE_RESOLVE_PATH
          mk="__temple_env_$$__"
          if e=$(temple_bounded "$mk") && temple_parse_env "$e" "$mk"; then
            [ -n "$TEMPLE_ENV_PATH" ] && { PATH=$TEMPLE_ENV_PATH; export PATH; }
            TEMPLE_CFG=$TEMPLE_ENV_CFG; TEMPLE_CFG_VALUE=$TEMPLE_ENV_CFG_VALUE
          fi
        fi
        cs=$TEMPLE_CFG; cv=$TEMPLE_CFG_VALUE
        unset TEMPLE_CFG TEMPLE_CFG_VALUE
        rd=
        if [ -n "$m" ]; then rd=$(temple_record_dir) || rd=; fi
        [ -n "$rd" ] && find "$rd" -type f -mmin +1440 -delete 2>/dev/null
        case $mode in
        attach)
          if [ -n "$sock" ]; then exec tmux -S "$sock" attach-session -t "=$s"; fi
          exec tmux -L temple attach-session -t "=$s" ;;
        create)
          r=; e=/dev/null
          if [ -n "$rd" ]; then
            r=$rd/$m; e=$rd/$m.err; rm -f "$e"
            # Claude's config root for the pane, as the login environment
            # sets it: a file here, never a tmux argument (formats), so an
            # older server's environment cannot win.
            if [ -n "$cs" ]; then
              rm -f "$rd/$m.cfgin"; ( set -C; printf '%s\n%s' "$cs" "$cv" > "$rd/$m.cfgin" ) 2>/dev/null
            fi
          fi
          tmux -L temple -f /dev/null \(TmuxChain.head) new-session -s "$s" -c / -e PATH="$PATH" -e TEMPLE_RECORD="$r" "$pane" 2>"$e"
          st=$?
          if [ "$st" -ne 0 ] && [ -n "$rd" ]; then
            temple_write "$rd/$m.client" "failed${T}tmux${T}${st}${T}$(head -n 1 "$e" 2>/dev/null)"
          fi
          [ -n "$rd" ] && rm -f "$e"
          exit "$st" ;;
        esac
        exit 2
        """
    }

    /// The pane, run by the server's `/bin/sh -c`, arguments `dir argv…`:
    /// expands `~`, enters the folder or reports that it could not, pipes
    /// what the pane shows (its first 64 KiB, `pipe-pane`) beside its record
    /// so an agent that fails at once leaves its own words, records `ok`
    /// with the remote clock, the canonical folder (trailing newlines
    /// kept), its own pid and start time, and the server it runs under
    /// (from `$TMUX`, parsed from the right: `<socket>,<server pid>,
    /// <session index>`), then `exec`s the agent: the pane pid is the
    /// agent's, and the diagnostics change nothing about liveness.
    /// `/proc/<pid>/stat` is read past the last `)` (note 2). The record
    /// directory is checked before it is written. Claude's config root is
    /// applied from the launch's own file (set, or unset so an older tmux
    /// server's value cannot win) and recorded as the agent will have it,
    /// hex-encoded: the transcript check inspects exactly that root.
    public static var paneScript: String {
        RecordDirectory.functions + "\n" + #"""
        d=$1; shift
        r=$TEMPLE_RECORD
        unset TEMPLE_RECORD
        T=$(printf '\t'); NL='
        '
        m=
        if [ -n "$r" ]; then rd=$(temple_record_dir) && [ "${r%/*}" = "$rd" ] && m=$r; fi
        if [ -n "$m" ] && [ -f "$m.cfgin" ] && [ ! -L "$m.cfgin" ]; then
          cs=$(head -n 1 "$m.cfgin"); cv=$(tail -n +2 "$m.cfgin"; printf x); cv=${cv%x}
          rm -f "$m.cfgin"
          case $cs in set) CLAUDE_CONFIG_DIR=$cv; export CLAUDE_CONFIG_DIR ;; unset) unset CLAUDE_CONFIG_DIR ;; esac
        fi
        if [ -n "${CLAUDE_CONFIG_DIR+x}" ]; then
          cfg="set${T}$(printf '%s' "$CLAUDE_CONFIG_DIR" | od -An -tx1 | tr -d ' \n')"
        else
          cfg=unset
        fi
        rec() { [ -n "$m" ] || return 0; temple_write "$m" "$1"; }
        pst() { [ -r "/proc/$1/stat" ] || return 0; x=$(cat "/proc/$1/stat" 2>/dev/null) || return 0; x=${x##*)}; set -- $x; [ $# -ge 20 ] || return 0; shift 19; printf '%s' "$1"; }
        case $d in "~") d=$HOME;; "~/"*) d=$HOME/${d#"~/"};; esac
        cd -- "$d" || { rec "failed${T}cd${T}$?"; exit 1; }
        if [ -n "$m" ] && [ -n "$TMUX_PANE" ]; then
          q=$(printf '%s' "$m.out" | sed "s/'/'\\\\''/g; s/#/##/g")
          tmux pipe-pane -t "$TMUX_PANE" "exec head -c 65536 >> '$q'" 2>/dev/null
        fi
        w=$(pwd -P; printf x); w=${w%x}; w=${w%"$NL"}
        t=${TMUX%,*}; sp=${t##*,}; so=${t%,*}
        rec "ok${NL}epoch${T}$(date +%s)${NL}pane${T}$$${T}$(pst $$)${NL}server${T}${sp}${T}$(pst "$sp")${NL}socket${T}${so}${NL}cfg${T}${cfg}${NL}dir${T}${w}"
        exec "$@"
        """#
    }

    /// The pane command tmux runs: `exec sh -c '<pane script>' temple-pane
    /// <dir> <argv…>`, quoted by the one quoting function.
    public static func paneCommand(directory: String, agentArgv: [String]) -> String {
        "exec " + RemoteQuoting.command(["sh", "-c", paneScript, "temple-pane", directory] + agentArgv)
    }

    public func createCommand(_ launch: RemoteLaunchPlan) -> String {
        Self.remoteCommand(mode: "create", launch: launch,
                           pane: Self.paneCommand(directory: launch.directory, agentArgv: launch.agentArgv))
    }

    public func attachCommand(_ launch: RemoteLaunchPlan) -> String {
        Self.remoteCommand(mode: "attach", launch: launch, pane: "")
    }

    /// `env [PATH=…|TEMPLE_RESOLVE_PATH=1] TEMPLE_HANDLE=… sh -c '<wrapper>'
    /// temple-launch <mode> <marker> <socket> <pane>`: every word
    /// single-quoted; the handle in an environment assignment, never a shell
    /// word of its own.
    static func remoteCommand(mode: String, launch: RemoteLaunchPlan, pane: String) -> String {
        precondition(RemoteQuoting.isSafeToken(launch.handle) && RemoteQuoting.isSafeToken(launch.marker))
        var words = ["env"]
        switch launch.path {
        case .resolved(let path): words.append("PATH=\(path)")
        case .fallback: break
        case .unresolved: words.append("TEMPLE_RESOLVE_PATH=1")
        }
        switch launch.claudeConfig {
        case .set(let value)?: words += ["TEMPLE_CFG=set", "TEMPLE_CFG_VALUE=\(value)"]
        case .unset?: words.append("TEMPLE_CFG=unset")
        case nil: break
        }
        words += ["TEMPLE_HANDLE=\(launch.handle)", "sh", "-c", wrapperScript, "temple-launch", mode, launch.marker,
                  launch.socket ?? "", pane]
        return RemoteQuoting.command(words)
    }

    // MARK: Queries

    static let tmuxFunction = #"t() { if [ -n "$sock" ]; then tmux -S "$sock" "$@"; else tmux -L temple "$@"; fi; }"#

    /// Arguments `socket session`.
    static let hasSessionScript = """
    sock=$1; s=$2
    \(tmuxFunction)
    t has-session -t "=$s"
    """

    /// Arguments `socket session`: present with its attached count, in one
    /// queue (`has-session` first: a target pane that names no session does
    /// not fail on its own).
    static let probeScript = """
    sock=$1; s=$2
    \(tmuxFunction)
    t has-session -t "=$s" ';' display-message -p -t "=$s:" '#{session_attached}'
    """

    /// Arguments `socket session wait`. Waits up to `wait` tenths of a
    /// second for the session's attached count to reach zero (Temple's own
    /// client was detached first, on this side), then one command queue in
    /// one client: `has-session` (a gone session answers with tmux's own
    /// words, never as a refusal), then the server checks that no client is
    /// attached and kills in the same queue, or prints `temple-not-killed`
    /// (implementation note 4). `display-message` and `if-shell` take a
    /// target pane, where an exact session is `=<name>:`.
    static let stopScript = """
    sock=$1; s=$2; w=$3
    \(tmuxFunction)
    i=0
    while [ "$i" -lt "$w" ]; do
      t has-session -t "=$s" 2>/dev/null || break
      n=$(t display-message -p -t "=$s:" '#{session_attached}' 2>/dev/null) || break
      [ "$n" = 0 ] && break
      sleep 0.1 2>/dev/null || sleep 1
      i=$((i+1))
    done
    t has-session -t "=$s" ';' if-shell -F -t "=$s:" '#{==:#{session_attached},0}' "kill-session -t =$s" 'display-message -p \(StopOutcome.notKilledMarker)'
    """

    public static let queryDeadline: TimeInterval = 5
    public static let stopDeadline: TimeInterval = 10

    /// Without a pinned socket (no record collected yet) the run is asked
    /// about on `-L temple`, but nothing that server says proves absence:
    /// the session may live on a server elsewhere.
    static let unpinned = "Temple has no record of the server this session was started on"

    public func liveness(session: String, socket: String?, using exec: RemoteExec) async -> Liveness {
        precondition(RemoteQuoting.isSafeToken(session))
        do {
            let liveness = Liveness.classify(try await exec.run(script: Self.hasSessionScript, args: [socket ?? "", session],
                                                                deadline: Self.queryDeadline), session: session)
            if socket == nil, liveness == .absent { return .unknown(reason: Self.unpinned, socketMissing: false) }
            return liveness
        } catch {
            return .unknown(reason: error.localizedDescription, socketMissing: false)
        }
    }

    public func probe(session: String, socket: String?, using exec: RemoteExec) async -> Probe {
        precondition(RemoteQuoting.isSafeToken(session))
        do {
            let output = try await exec.run(script: Self.probeScript, args: [socket ?? "", session], deadline: Self.queryDeadline)
            if output.reachedCommand, output.status == 0,
               let count = Int(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return .present(attached: count)
            }
            switch Liveness.classify(output, session: session) {
            case .absent: return socket == nil ? .unknown(reason: Self.unpinned, reachedHost: true) : .absent
            case .present: return .unknown(reason: "tmux answered without a count", reachedHost: true)
            case .unknown(let reason, _): return .unknown(reason: reason, reachedHost: output.reachedCommand)
            }
        } catch {
            return .unknown(reason: error.localizedDescription, reachedHost: false)
        }
    }

    /// Throws only `CancellationError`, when the query was cancelled before
    /// any answer arrived: an answer that did arrive is always decoded.
    public func stop(session: String, socket: String?, waitTenths: Int, using exec: RemoteExec) async throws -> StopOutcome {
        precondition(RemoteQuoting.isSafeToken(session))
        do {
            let outcome = StopOutcome.decode(try await exec.run(script: Self.stopScript,
                                                                args: [socket ?? "", session, String(max(0, waitTenths))],
                                                                deadline: Self.stopDeadline), session: session)
            if socket == nil, outcome == .absent { return .unconfirmed(reason: Self.unpinned, reachedHost: true) }
            return outcome
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(error)
        }
    }
}
