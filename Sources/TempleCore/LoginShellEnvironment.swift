import Foundation

/// GUI apps launched from Finder inherit launchd's minimal `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), so agents spawned inside Temple's
/// terminals can't find user-installed tools — agent hooks fail with
/// "command not found" even though the same session works in a real
/// terminal. Adopt the user's login-shell `PATH` once at startup so every
/// child process inherits a normal environment.
public enum LoginShellEnvironment {
    /// Ask the user's login shell for its PATH. Bounded so a hung shell rc
    /// can never wedge app launch; nil on any failure.
    public static func resolveLoginShellPATH(timeout: TimeInterval = 3) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            TempleCoreLog.env.error("failed to launch login shell \(shell, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        guard !process.isRunning else {
            process.terminate()
            TempleCoreLog.env.error("login shell \(shell, privacy: .public) timed out after \(timeout)s while resolving PATH")
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard path?.isEmpty == false else {
            TempleCoreLog.env.error("login shell \(shell, privacy: .public) returned an empty PATH")
            return nil
        }
        return path
    }

    /// Replace this process's PATH with the login shell's (children inherit
    /// it). No-op when resolution fails or already matches.
    public static func adoptLoginShellPATH() {
        guard let path = resolveLoginShellPATH(),
              path != ProcessInfo.processInfo.environment["PATH"] else { return }
        setenv("PATH", path, 1)
    }
}
