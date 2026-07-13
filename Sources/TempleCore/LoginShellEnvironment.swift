import Foundation

/// GUI apps launched from Finder inherit launchd's minimal `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), so agents spawned inside Temple's
/// terminals can't find user-installed tools — agent hooks fail with
/// "command not found" even though the same session works in a real
/// terminal. Adopt the user's login-shell `PATH` once at startup so every
/// child process inherits a normal environment.
///
/// That adopted `PATH` is also the only honest answer to "which `claude` does
/// the user mean?". Probing a hardcoded list of install directories picks the
/// wrong binary the moment a machine has two — a stale `/opt/homebrew/bin/claude`
/// from an old npm install shadows the current one in `~/.local/bin`, and the
/// user never notices because their own shell orders them the other way round.
/// So resolve binaries against the shell's `PATH`, in its order: `locate`.
public enum LoginShellEnvironment {
    /// The login shell's `PATH`, resolved once by `adoptLoginShellPATH`.
    /// `nil` until then, and if the shell could not be read.
    public private(set) static var adoptedPATH: String?

    /// Set when we could not read the shell's `PATH` — Temple is then running on
    /// launchd's minimal environment and will struggle to find anything the user
    /// installed. The UI says so rather than letting launches fail mysteriously.
    public private(set) static var problem: String?

    /// The shell we ask. macOS always sets `SHELL`; the default is a backstop.
    public static var shell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Ask the user's login shell for its PATH. Bounded so a hung shell rc
    /// can never wedge app launch; nil on any failure.
    public static func resolveLoginShellPATH(timeout: TimeInterval = 5) -> String? {
        let shell = Self.shell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Login *and interactive*. A login-only zsh sources `.zshenv`/`.zprofile`
        // but never `.zshrc` — which is where a great deal of a real PATH gets
        // assembled (version-manager shims, `~/.local/bin`, per-tool exports).
        // Without `-i` we'd adopt a PATH the user has never actually typed a command
        // into, and resolve tools they don't use to run their agents.
        process.arguments = ["-lic", "echo \(marker); /usr/bin/printenv PATH"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // An interactive shell that inherits our stdin can block on a read.
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            TempleCoreLog.env.error("failed to launch login shell \(shell, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
        // Read to EOF rather than polling `isRunning`: the pipe holds 64K, and a
        // chatty rc file can fill it and deadlock the shell we're waiting on.
        let killed = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            killed.fired = true
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        if killed.fired {
            TempleCoreLog.env.error("login shell \(shell, privacy: .public) timed out after \(timeout)s while resolving PATH")
            return nil
        }
        guard let output = String(data: data, encoding: .utf8),
              let path = parse(output), !path.isEmpty else {
            TempleCoreLog.env.error("login shell \(shell, privacy: .public) returned an empty PATH")
            return nil
        }
        return path
    }

    /// Replace this process's PATH with the login shell's (children inherit
    /// it). No-op when resolution fails.
    public static func adoptLoginShellPATH() {
        guard let path = resolveLoginShellPATH() else {
            problem = "Couldn't read a PATH from your shell (\(shell)). Temple is running on macOS's minimal GUI environment, so it may not find your tools."
            return
        }
        problem = nil
        adoptedPATH = path
        guard path != ProcessInfo.processInfo.environment["PATH"] else { return }
        setenv("PATH", path, 1)
    }

    /// The executable `name` resolves to on the shell's `PATH` — the same answer
    /// `command -v name` gives in the user's terminal. `nil` if the shell could
    /// not be read, or has no such command.
    public static func locate(_ name: String) -> String? {
        locate(name, on: adoptedPATH ?? ProcessInfo.processInfo.environment["PATH"])
    }

    static func locate(_ name: String, on path: String?) -> String? {
        guard let path else { return nil }
        // Relative PATH entries are legal but resolve against the *spawning*
        // process's cwd, which isn't the shell's — skip them rather than resolve
        // them to something the user never meant.
        for dir in path.split(separator: ":") where dir.hasPrefix("/") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Fences off whatever an rc file prints on startup — p10k's instant prompt,
    /// MOTDs, version-manager chatter. Only what follows the marker is ours.
    private static let marker = "__temple_path__"

    /// Written by the watchdog, read after the process is reaped — the two never
    /// overlap, since `watchdog.cancel()` precedes the read.
    private final class TimeoutFlag: @unchecked Sendable {
        var fired = false
    }

    /// The first non-empty line after the marker.
    static func parse(_ output: String) -> String? {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.lastIndex(of: marker) else { return nil }
        return lines[lines.index(after: start)...].first { !$0.isEmpty }
    }
}
