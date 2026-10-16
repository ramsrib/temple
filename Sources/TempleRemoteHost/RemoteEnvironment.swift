import Foundation
import TempleCore

/// The remote PATH, resolved the way `LoginShellEnvironment` resolves this
/// Mac's: ask the account's login shell, login and interactive, because a
/// non-interactive ssh command often has not read the rc file that builds
/// the real PATH. One policy for everything run on the host (probe, launch,
/// tmux, reads, the agent itself); when resolution fails, everything uses
/// ssh's default environment instead, and says so.
///
/// Memory only, never persisted: phase 0 keeps the last Test connection's
/// answer per host (in its `HostTestSummary`) and resolves again on every
/// Test connection.
public struct RemoteEnvironment: Sendable, Equatable {
    /// The login shell asked (`$SHELL` on the host).
    public let shell: String
    /// The PATH it gave; nil when it could not be read.
    public let path: String?
    /// Why there is no PATH, in words for the user.
    public let problem: String?
    /// Whether the query ran on the host at all: false when ssh, the master
    /// or the network failed first (then `problem` is ssh's line).
    public let reachedHost: Bool

    public init(shell: String, path: String?, problem: String?, reachedHost: Bool = true) {
        self.shell = shell; self.path = path; self.problem = problem; self.reachedHost = reachedHost
    }

    /// The resolution query's deadline.
    public static let deadline: TimeInterval = 5

    /// The one resolver, as shell text, shared by the environment query and
    /// the launch (one policy, section 2): `temple_login_path <marker>`
    /// asks `$SHELL` with `-lic`, then `-l -c`, then `-c` (csh and tcsh
    /// reject the bundled flags), each answer framed by the marker so motd,
    /// prompts and rc chatter are discarded, each bounded by 5 seconds
    /// where the host has `timeout` (a hung shell is not asked again). It
    /// prints the PATH and returns 0, or
    /// prints nothing and returns 3.
    public static let resolverFunction = """
    temple_login_path() {
      _m=$1; _s=${SHELL:-/bin/sh}; _p="echo $_m; printenv PATH; echo $_m"
      _t=; command -v timeout >/dev/null 2>&1 && _t="timeout 5"
      for _v in 1 2 3; do
        case $_v in
          1) _o=$($_t "$_s" -lic "$_p" </dev/null 2>/dev/null) ;;
          2) _o=$($_t "$_s" -l -c "$_p" </dev/null 2>/dev/null) ;;
          *) _o=$($_t "$_s" -c "$_p" </dev/null 2>/dev/null) ;;
        esac
        # A shell that hung past the bound is not asked again: 5 s in all.
        [ $? -eq 124 ] && return 3
        case $_o in *"$_m"*"$_m"*)
          _o=${_o#*"$_m"}; _o=${_o%"$_m"*}
          _o=$(printf '%s\n' "$_o" | grep / | head -n 1)
          [ -n "$_o" ] && { printf '%s\n' "$_o"; return 0; }
          return 3 ;;
        esac
      done
      return 3
    }
    """

    /// The query: the shell's name, then the PATH between markers.
    static let script = resolverFunction + """

    m=$1
    echo "shell ${SHELL:-/bin/sh}"
    p=$(temple_login_path "$m") || exit 3
    echo "$m"; printf '%s\n' "$p"; echo "$m"
    """

    /// Resolves through `exec`, which must carry no PATH of its own.
    public static func resolve(using exec: RemoteExec) async -> RemoteEnvironment {
        let marker = "__temple_path_\(RemoteQuoting.nonce())__"
        do {
            let output = try await exec.run(script: script, args: [marker], deadline: deadline)
            return parse(output, marker: marker)
        } catch let error as RemoteExecError {
            if case .deadline = error {
                return RemoteEnvironment(shell: "", path: nil, problem: "the login shell didn't answer within 5 seconds",
                                         reachedHost: false)
            }
            return RemoteEnvironment(shell: "", path: nil, problem: error.localizedDescription, reachedHost: false)
        } catch {
            return RemoteEnvironment(shell: "", path: nil, problem: error.localizedDescription, reachedHost: false)
        }
    }

    static func parse(_ output: RemoteOutput, marker: String) -> RemoteEnvironment {
        let lines = output.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let shell = lines.first { $0.hasPrefix("shell ") }.map { String($0.dropFirst(6)) } ?? ""
        guard output.reachedCommand, output.status == 0 || output.status == 3 else {
            // The command never ran (ssh's 255, a missing sh): ssh's words.
            return RemoteEnvironment(shell: shell, path: nil,
                                     problem: output.firstErrorLine ?? "ssh exited with status \(output.status)",
                                     reachedHost: false)
        }
        if let start = lines.firstIndex(of: marker) {
            let rest = lines[(start + 1)...]
            let end = rest.firstIndex(of: marker) ?? rest.endIndex
            if let path = rest[..<end].map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.contains("/") }) {
                return RemoteEnvironment(shell: shell, path: path, problem: nil)
            }
        }
        let name = shell.isEmpty ? "the login shell" : shell
        return RemoteEnvironment(shell: shell, path: nil, problem: "\(name) printed no PATH")
    }
}
