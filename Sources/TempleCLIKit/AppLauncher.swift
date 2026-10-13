import AppKit
import Darwin
import Foundation
import TempleCore

/// Starting Temple for a command that acts (`sessions new`, `sessions open`).
/// Only the app this binary ships in is ever started, and only when no
/// Temple is running at all: LaunchServices, asked to open a bundle whose id
/// is already running, activates the running copy instead (AGENTS.md), and a
/// second instance on the same state directory would restore every tab
/// twice. A Temple that runs but does not answer is reported, not worked
/// around. Never for a redirected state directory, whose Temple (a demo, a
/// test) is started by whoever redirected it.
enum AppLauncher {
    enum Plan: Equatable {
        /// Something answers already.
        case ready
        case launch(URL)
        case refuse(String)
    }

    struct Running: Equatable {
        let pid: Int32
        let path: String?
    }

    static func plan(serving: Bool, redirected: Bool, app: URL?, running: [Running]) -> Plan {
        if serving { return .ready }
        if redirected { return .refuse("Temple isn't running (TEMPLE_STATE_DIR is set; start that Temple first)") }
        if let other = running.first {
            return .refuse("Temple is running (pid \(other.pid)\(other.path.map { ", \($0)" } ?? "")) but does not "
                           + "answer the command line; it may be an older version. Quit it, or open a session in it.")
        }
        guard let app else { return .refuse("Temple isn't running") }
        return .launch(app)
    }

    static func ensureRunning(socket: URL = ControlSocket.url(), wait: TimeInterval = 20) throws {
        if ControlClient.isServing(socket) { return }
        // One launch decision at a time across commands: two `sessions new`
        // at once would otherwise both see no Temple and start two, each
        // restoring every tab before either knew of the other. The second
        // waits here and then finds the first one's Temple answering.
        let lockFD = open(socket.path + ".launch.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw CLIError("could not start Temple: \(String(cString: strerror(errno)))") }
        defer { close(lockFD) }  // releases the lock
        while flock(lockFD, LOCK_EX) != 0 {
            guard errno == EINTR else { throw CLIError("could not start Temple: \(String(cString: strerror(errno)))") }
        }
        let app = enclosingApp()
        let bundleID = app.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "com.sriramb.temple"
        func running() -> [Running] {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .map { Running(pid: $0.processIdentifier, path: $0.bundleURL?.path) }
        }
        var others = running()
        var serving = ControlClient.isServing(socket)
        // One that is running may be a launch on its way to listening, or a
        // quit on its way out: look again after the grace.
        if !serving, !others.isEmpty {
            serving = waitForServer(socket, seconds: 5)
            others = running()
        }
        switch plan(serving: serving, redirected: TempleState.isRedirected, app: app, running: others) {
        case .ready: return
        case .refuse(let message): throw CLIError(message)
        case .launch(let app): try launch(app, socket: socket, wait: wait)
        }
    }

    private static func launch(_ app: URL, socket: URL, wait: TimeInterval) throws {
        // `-n`: this bundle, as a new instance, rather than whatever copy
        // LaunchServices would choose to activate for its id.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", app.path]
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            throw CLIError("could not start Temple: \(error.localizedDescription)")
        }
        guard open.terminationStatus == 0 else { throw CLIError("could not start Temple (open exited \(open.terminationStatus))") }
        guard waitForServer(socket, seconds: wait) else { throw CLIError("Temple did not start within \(Int(wait)) seconds") }
    }

    private static func waitForServer(_ socket: URL, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if ControlClient.isServing(socket) { return true }
            usleep(200_000)
        }
        return ControlClient.isServing(socket)
    }

    /// `…/Temple.app` when this binary is `…/Temple.app/Contents/Helpers/temple`,
    /// reached through any symlink (Homebrew links it onto the PATH).
    static func enclosingApp(executable: String? = executablePath()) -> URL? {
        guard let executable else { return nil }
        let helpers = URL(fileURLWithPath: executable).deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }

    private static func executablePath() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0, let resolved = realpath(buffer, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
