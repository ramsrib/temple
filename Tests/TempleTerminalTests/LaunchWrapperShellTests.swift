import XCTest
@testable import TempleTerminal
@testable import TempleUI
import TempleCore
import TempleTerminalAPI

/// The local launch wrapper run for real, the way the terminal runs it:
/// `GhosttyTerminalSurface` quotes the argv into one command line, and
/// libghostty on macOS hands it to `/bin/bash --noprofile --norc -c
/// "exec -l <line>"` in the working directory, with the surface's variables
/// added to the environment (Vendor/ghostty/src/termio/Exec.zig). Only
/// login(1) and the PTY are left out.
@MainActor
final class LaunchWrapperShellTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = URL(fileURLWithPath: "/private/tmp/temple-wrapper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // A permission test may have left a folder unreadable.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("locked").path)
        try? FileManager.default.removeItem(at: root)
    }

    /// A stand-in agent that records what it received, then exits 7.
    private func probe() throws -> URL {
        let url = root.appendingPathComponent("probe agent.sh")
        try """
        #!/bin/sh
        out="$PROBE_OUT"
        pwd -P > "$out.pwd"
        printf '%s\\0' "$@" > "$out.argv"
        printf '%s\\n' "$TERM_PROGRAM" "$CUSTOM" "$PATH" > "$out.env"
        exit 7
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Run a prepared launch as the terminal would; returns the exit status.
    private func run(_ launch: AgentLaunch, ghosttyCwd: String, extraEnv: [String: String]) throws -> Int32 {
        let spawn = TerminalIdentity.apply(to: launch.command)
        let line = try XCTUnwrap(GhosttyTerminalSurface.shellCommand(from: spawn.argv))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", "exec -l " + line]
        process.currentDirectoryURL = URL(fileURLWithPath: ghosttyCwd)
        var environment = ["PATH": "/weird/first:/usr/bin:/bin", "HOME": root.path]
        environment.merge(extraEnv) { _, new in new }
        environment.merge(spawn.env) { _, new in new }
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func collect(_ channel: LaunchResultChannel) -> [LaunchEvent] {
        var events: [LaunchEvent] = []
        channel.onEvent = { events.append($0) }
        channel.finish()
        return events
    }

    func testArgumentsFolderAndEnvironmentReachTheAgentExactlyAndItsStatusComesBack() throws {
        let folder = root.appendingPathComponent("a folder/it's \"quoted\" $HOME \\ ünï")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = root.appendingPathComponent("out").path
        let arguments = ["--resume", "id with spaces", "it's", "\"double\"", "$HOME", "back\\slash", "new\nline", "", "*", "-"]
        let probe = try probe()
        let launcher = LocalHostLauncher(binaryPath: { _ in probe.path }, extraArgs: { _ in arguments },
                                         markerDirectory: root.appendingPathComponent("markers"))
        let launch = try launcher.prepare(AgentLaunchSpec(agent: .codex, mode: .new(sessionID: nil), directory: folder.path, host: .local))
        var command = launch.command
        command.env["CUSTOM"] = "own value"
        command.env["TERM_PROGRAM"] = nil
        let status = try run(AgentLaunch(command: command, displayArgv: launch.displayArgv, result: launch.result),
                             ghosttyCwd: folder.path, extraEnv: ["PROBE_OUT": out])
        XCTAssertEqual(status, 7, "the agent replaces the wrapper (exec), so its own status is the tab's")
        let argv = try String(contentsOfFile: out + ".argv", encoding: .utf8).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        XCTAssertEqual(argv, arguments)
        XCTAssertEqual(try String(contentsOfFile: out + ".pwd", encoding: .utf8), folder.path + "\n")
        let env = try String(contentsOfFile: out + ".env", encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(env[0], "Temple", "the spawn's identity variables reach the agent")
        XCTAssertEqual(env[1], "own value", "a command's own variables reach the agent")
        XCTAssertEqual(env[2], "/weird/first:/usr/bin:/bin", "no login profile rewrote PATH")
        XCTAssertEqual(collect(try XCTUnwrap(launch.result)), [.directoryEstablished(folder.path), .finished])
    }

    /// The terminal falls back to its own cwd when the folder is gone; the
    /// wrapper's `cd` refuses, so the agent never runs anywhere else.
    func testAMissingFolderStopsTheAgentAndReportsAFailure() throws {
        let folder = root.appendingPathComponent("gone")
        let out = root.appendingPathComponent("out").path
        let probe = try probe()
        // The folder goes in the gap between `prepare`'s own check and the
        // exec (unknown here, so `prepare` proceeds): the wrapper refuses.
        let launcher = LocalHostLauncher(binaryPath: { _ in probe.path }, folderEvidence: { _ in .unknown },
                                         markerDirectory: root.appendingPathComponent("markers"))
        let launch = try launcher.prepare(AgentLaunchSpec(agent: .claude, mode: .resume(sessionID: "s"), directory: folder.path, host: .local))
        let status = try run(launch, ghosttyCwd: root.path, extraEnv: ["PROBE_OUT": out])
        XCTAssertEqual(status, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out + ".argv"), "the agent did not run")
        let events = collect(try XCTUnwrap(launch.result))
        guard case .failed(.cdFailed, let message) = events.first else { return XCTFail("\(events)") }
        XCTAssertTrue(message.contains(folder.path))
        XCTAssertEqual(events.last, .finished)
    }

    /// The shell's status cannot tell a missing folder from one it may not
    /// enter, so both are the same generic failure.
    func testAFolderItMayNotEnterIsTheSameGenericFailure() throws {
        let folder = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        let out = root.appendingPathComponent("out").path
        let probe = try probe()
        let launcher = LocalHostLauncher(binaryPath: { _ in probe.path }, markerDirectory: root.appendingPathComponent("markers"))
        let launch = try launcher.prepare(AgentLaunchSpec(agent: .claude, mode: .resume(sessionID: "s"), directory: folder.path, host: .local))
        XCTAssertEqual(try run(launch, ghosttyCwd: root.path, extraEnv: ["PROBE_OUT": out]), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out + ".argv"))
        guard case .failed(.cdFailed, _)? = collect(try XCTUnwrap(launch.result)).first else { return XCTFail() }
    }

    /// No marker can be made (here: its directory sits under a file). The
    /// launch reports nothing, but the agent still never runs outside its folder.
    func testWithoutAMarkerTheWrapperStillEntersTheFolderOrStops() throws {
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let probe = try probe()
        // Folder evidence unknown, as for a folder that goes after `prepare`.
        let launcher = LocalHostLauncher(binaryPath: { _ in probe.path }, extraArgs: { _ in ["it's", "two words"] },
                                         folderEvidence: { _ in .unknown },
                                         markerDirectory: blocker.appendingPathComponent("markers"))
        let folder = root.appendingPathComponent("here it is")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let present = try launcher.prepare(AgentLaunchSpec(agent: .claude, mode: .new(sessionID: nil), directory: folder.path, host: .local))
        XCTAssertNil(present.result, "nothing to report from")
        XCTAssertEqual(Array(present.command.argv.prefix(4)), ["/usr/bin/env", "/bin/sh", "-c", LocalHostLauncher.unreportedWrapperScript],
                       "never launched unwrapped")
        XCTAssertEqual(present.displayArgv, [probe.path, "it's", "two words"])
        let out = root.appendingPathComponent("out").path
        XCTAssertEqual(try run(present, ghosttyCwd: root.path, extraEnv: ["PROBE_OUT": out]), 7)
        XCTAssertEqual(try String(contentsOfFile: out + ".pwd", encoding: .utf8), folder.path + "\n")
        let argv = try String(contentsOfFile: out + ".argv", encoding: .utf8).split(separator: "\0").map(String.init)
        XCTAssertEqual(argv, ["it's", "two words"])

        let gone = try launcher.prepare(AgentLaunchSpec(agent: .claude, mode: .new(sessionID: nil),
                                                        directory: root.appendingPathComponent("gone").path, host: .local))
        let goneOut = root.appendingPathComponent("gone-out").path
        XCTAssertEqual(try run(gone, ghosttyCwd: root.path, extraEnv: ["PROBE_OUT": goneOut]), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: goneOut + ".argv"), "the agent did not run elsewhere")
    }
}
