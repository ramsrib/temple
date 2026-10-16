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
public protocol KeepAlive: Sendable {
    /// The remote command (for `ssh -t … -- <host> <command>`) that creates
    /// the session and runs the pane command in it.
    func createCommand(_ launch: RemoteLaunchPlan) -> String
    /// The remote command that attaches to an existing session and creates
    /// nothing.
    func attachCommand(_ launch: RemoteLaunchPlan) -> String
    func liveness(session: String, socket: String?, using exec: RemoteExec) async -> Liveness
    /// The one-command, attached-checked stop. `waitTenths`: how long the
    /// host may wait for Temple's own client (already detached on this
    /// side) to leave before the check, in tenths of a second.
    func stop(session: String, socket: String?, waitTenths: Int, using exec: RemoteExec) async -> StopOutcome
    func list(using exec: RemoteExec) async -> SessionListing
}

/// Everything one launch on a host needs, decided before anything runs.
public struct RemoteLaunchPlan: Sendable, Equatable {
    /// The run's handle: the session is `temple-<handle>`.
    public var handle: String
    /// The launch record's name on the host (`[A-Za-z0-9._-]`).
    public var marker: String
    /// The folder as the user named it; the pane expands `~` and enters it.
    public var directory: String
    /// The agent's argv, run by the pane with `exec` (the pane pid is the
    /// agent's).
    public var agentArgv: [String]
    /// The resolved remote PATH; nil when Temple has none yet, and then the
    /// launch asks the login shell itself, as the environment query would.
    public var path: String?
    /// The pinned server's socket, for an attach (nil: `-L temple`).
    public var socket: String?

    public init(handle: String, marker: String, directory: String, agentArgv: [String], path: String?, socket: String?) {
        self.handle = handle; self.marker = marker; self.directory = directory
        self.agentArgv = agentArgv; self.path = path; self.socket = socket
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
    /// socket (`no server running on`, or 3.2a's `error connecting to …
    /// (No such file or directory)`), which in v1 is not proof: tmux can lose
    /// its socket while the server lives.
    case unknown(reason: String, socketMissing: Bool)

    public static func classify(_ output: RemoteOutput) -> Liveness {
        guard output.reachedCommand else {
            return .unknown(reason: output.firstErrorLine ?? "ssh exited with status \(output.status)", socketMissing: false)
        }
        if output.status == 0 { return .present }
        let stderr = output.stderr
        if output.status == 1, stderr.contains("can't find session") { return .absent }
        let line = output.firstErrorLine ?? (output.status == 127 ? "tmux is not on PATH" : "tmux exited with status \(output.status)")
        let missing = stderr.contains("no server running on")
            || (stderr.contains("error connecting to") && stderr.contains("No such file or directory"))
        return .unknown(reason: line, socketMissing: missing)
    }
}

/// One decoded stop outcome, the same everywhere (implementation note 5):
/// the query succeeded without `temple-not-killed` → killed; the marker →
/// refused (another client is attached); the pinned server answered that the
/// session is not there → absent; anything else, a failure or a deadline →
/// unconfirmed. A cancelled query may already have taken effect, so an
/// unconfirmed stop is never retried automatically.
public enum StopOutcome: Sendable, Equatable {
    case killed
    case refused
    case absent
    /// `reachedHost` false: ssh never reached the host (the host did not
    /// answer); true: the command ran, or may have, and did not confirm.
    case unconfirmed(reason: String, reachedHost: Bool)

    public static let notKilledMarker = "temple-not-killed"

    public static func decode(_ output: RemoteOutput) -> StopOutcome {
        guard output.reachedCommand else {
            return .unconfirmed(reason: output.firstErrorLine ?? "ssh exited with status \(output.status)", reachedHost: false)
        }
        if output.stdout.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == notKilledMarker }) {
            return .refused
        }
        if output.status == 0 { return .killed }
        if output.status == 1, output.stderr.contains("can't find session") { return .absent }
        return .unconfirmed(reason: output.firstErrorLine ?? "tmux exited with status \(output.status)", reachedHost: true)
    }

    public static func failed(_ error: Error) -> StopOutcome {
        .unconfirmed(reason: error.localizedDescription, reachedHost: !(error is CancellationError) && Self.mayHaveReached(error))
    }

    /// A deadline or a cancellation may have reached the host; a process
    /// that never started did not.
    private static func mayHaveReached(_ error: Error) -> Bool {
        if case RemoteExecError.launchFailed? = error as? RemoteExecError { return false }
        return true
    }
}

/// The sessions on Temple's private server.
public enum SessionListing: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let attached: Int
        public init(name: String, attached: Int) { self.name = name; self.attached = attached }
    }
    case listed([Entry])
    /// No server at Temple's socket: nothing is listed, and nothing is
    /// proven gone (the socket may be lost).
    case noServer
    case failed(String)
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
    ///   failure, never an attach to something Temple did not start). The
    ///   pane learns where to write its record from `-e TEMPLE_RECORD`.
    ///   The client's own failure goes to `<marker>.client`, apart from the
    ///   pane's `<marker>` (implementation note 3): a tmux client can fail
    ///   after the session exists, so it proves nothing about creation.
    /// - `attach`: `attach-session` on the pinned socket (`-S`), or on
    ///   `-L temple` when the run has no pin yet. It runs no pane command
    ///   and writes no record.
    ///
    /// Without a resolved PATH it asks the login shell first, exactly as the
    /// environment query does, so the agent and tmux see the PATH the probe
    /// saw.
    public static var wrapperScript: String {
        """
        mode=$1; m=$2; sock=$3; pane=$4
        s=temple-$TEMPLE_HANDLE
        unset TMUX TEMPLE_HANDLE
        if [ -n "$TEMPLE_RESOLVE_PATH" ]; then
          unset TEMPLE_RESOLVE_PATH
          k=__temple_path_$$__; sh_=${SHELL:-/bin/sh}
          for v in 1 2 3; do
            case $v in
              1) o=$("$sh_" -lic "echo $k; printenv PATH; echo $k" </dev/null 2>/dev/null) ;;
              2) o=$("$sh_" -l -c "echo $k; printenv PATH; echo $k" </dev/null 2>/dev/null) ;;
              *) o=$("$sh_" -c "echo $k; printenv PATH; echo $k" </dev/null 2>/dev/null) ;;
            esac
            case $o in *"$k"*"$k"*)
              p=${o#*"$k"}; p=${p%"$k"*}; p=$(printf '%s\\n' "$p" | grep / | head -n 1)
              [ -n "$p" ] && { PATH=$p; export PATH; }
              break ;;
            esac
          done
        fi
        mdir=${TMPDIR:-/tmp}/temple-launch-$(id -u); umask 077
        mkdir -p "$mdir" 2>/dev/null && find "$mdir" -type f -mmin +1440 -delete 2>/dev/null
        { [ -d "$mdir" ] && [ -w "$mdir" ]; } || m=
        case $mode in
        attach)
          if [ -n "$sock" ]; then exec tmux -S "$sock" attach-session -t "=$s"; fi
          exec tmux -L temple attach-session -t "=$s" ;;
        create)
          r=; e=/dev/null
          if [ -n "$m" ]; then r=$mdir/$m; e=$mdir/$m.err; fi
          tmux -L temple -f /dev/null \(TmuxChain.head) new-session -s "$s" -c "$HOME" -e PATH="$PATH" -e TEMPLE_RECORD="$r" "$pane" 2>"$e"
          st=$?
          if [ "$st" -ne 0 ] && [ -n "$m" ]; then
            l=$(head -n 1 "$e" 2>/dev/null)
            printf 'failed\\ttmux\\t%s\\t%s\\n' "$st" "$l" > "$mdir/$m.client.tmp" && mv -f "$mdir/$m.client.tmp" "$mdir/$m.client"
          fi
          [ -n "$m" ] && rm -f "$e"
          exit "$st" ;;
        esac
        exit 2
        """
    }

    /// The pane, run by the server's `/bin/sh -c`, arguments `dir argv…`:
    /// expands `~`, enters the folder or reports that it could not, records
    /// `ok` with the remote clock, the canonical folder, its own pid and
    /// start time, and the server it runs under (from `$TMUX`, parsed from
    /// the right: `<socket>,<server pid>,<session index>`, and a socket path
    /// may hold commas), then `exec`s the agent: the pane pid is the agent's.
    /// `/proc/<pid>/stat` is read past the last `)`, so a process name with
    /// spaces or parentheses cannot shift the fields (note 2).
    public static let paneScript = #"""
    d=$1; shift
    m=$TEMPLE_RECORD
    unset TEMPLE_RECORD
    T=$(printf '\t')
    case $d in "~") d=$HOME;; "~/"*) d=$HOME/${d#"~/"};; esac
    rec() { [ -n "$m" ] || return 0; printf '%s\n' "$1" > "$m.tmp" && mv -f "$m.tmp" "$m"; }
    pst() { [ -r "/proc/$1/stat" ] || return 0; x=$(cat "/proc/$1/stat" 2>/dev/null) || return 0; x=${x##*)}; set -- $x; [ $# -ge 20 ] || return 0; shift 19; printf '%s' "$1"; }
    cd -- "$d" || { rec "failed${T}cd${T}$?"; exit 1; }
    t=${TMUX%,*}; sp=${t##*,}; so=${t%,*}
    rec "ok
    epoch${T}$(date +%s)
    pane${T}$$${T}$(pst $$)
    server${T}${sp}${T}$(pst "$sp")
    socket${T}${so}
    dir${T}$(pwd -P)"
    exec "$@"
    """#

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

    /// `env PATH=… TEMPLE_HANDLE=… sh -c '<wrapper>' temple-launch <mode>
    /// <marker> <socket> <pane>`: every word single-quoted; the handle in an
    /// environment assignment, never a shell word of its own.
    static func remoteCommand(mode: String, launch: RemoteLaunchPlan, pane: String) -> String {
        precondition(RemoteQuoting.isSafeToken(launch.handle) && RemoteQuoting.isSafeToken(launch.marker))
        var words = ["env"]
        if let path = launch.path { words.append("PATH=\(path)") } else { words.append("TEMPLE_RESOLVE_PATH=1") }
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

    /// Arguments `socket session wait`. Waits up to `wait` tenths of a
    /// second for the session's attached count to reach zero (Temple's own
    /// client was detached first, on this side), then one non-yielding
    /// command in one client: the server checks that no client is attached
    /// and kills in the same queue, or prints `temple-not-killed`
    /// (implementation note 4). `display-message` and `if-shell` take a
    /// target pane, where an exact session is `=<name>:` (a bare `=<name>`
    /// does not resolve there, and the check would then never pass).
    static let stopScript = """
    sock=$1; s=$2; w=$3
    \(tmuxFunction)
    i=0
    while [ "$i" -lt "$w" ]; do
      n=$(t display-message -p -t "=$s:" '#{session_attached}' 2>/dev/null) || break
      [ "$n" = 0 ] && break
      sleep 0.1 2>/dev/null || sleep 1
      i=$((i+1))
    done
    t if-shell -F -t "=$s:" '#{==:#{session_attached},0}' "kill-session -t =$s" 'display-message -p \(StopOutcome.notKilledMarker)'
    """

    /// The attached count first, then the name: a tab in tmux's output is
    /// printed as `_` under a C locale, and a name may hold spaces.
    static let listScript = "tmux -L temple list-sessions -F '#{session_attached} #{session_name}'"

    public static let queryDeadline: TimeInterval = 5
    public static let stopDeadline: TimeInterval = 10

    public func liveness(session: String, socket: String?, using exec: RemoteExec) async -> Liveness {
        precondition(RemoteQuoting.isSafeToken(session))
        do {
            return Liveness.classify(try await exec.run(script: Self.hasSessionScript, args: [socket ?? "", session],
                                                        deadline: Self.queryDeadline))
        } catch {
            return .unknown(reason: error.localizedDescription, socketMissing: false)
        }
    }

    public func stop(session: String, socket: String?, waitTenths: Int, using exec: RemoteExec) async -> StopOutcome {
        precondition(RemoteQuoting.isSafeToken(session))
        do {
            return StopOutcome.decode(try await exec.run(script: Self.stopScript,
                                                         args: [socket ?? "", session, String(max(0, waitTenths))],
                                                         deadline: Self.stopDeadline))
        } catch {
            return .failed(error)
        }
    }

    public func list(using exec: RemoteExec) async -> SessionListing {
        do {
            return Self.parseListing(try await exec.run(script: Self.listScript, args: [], deadline: Self.queryDeadline))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func parseListing(_ output: RemoteOutput) -> SessionListing {
        guard output.reachedCommand else { return .failed(output.firstErrorLine ?? "ssh exited with status \(output.status)") }
        if output.status != 0 {
            if output.stderr.contains("no server running on")
                || (output.stderr.contains("error connecting to") && output.stderr.contains("No such file or directory")) {
                return .noServer
            }
            return .failed(output.firstErrorLine ?? "tmux exited with status \(output.status)")
        }
        let entries = output.stdout.split(whereSeparator: \.isNewline).compactMap { line -> SessionListing.Entry? in
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let attached = Int(fields[0]), !fields[1].isEmpty else { return nil }
            return SessionListing.Entry(name: String(fields[1]), attached: attached)
        }
        return .listed(entries)
    }
}
