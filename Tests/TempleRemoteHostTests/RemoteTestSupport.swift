import Foundation
import XCTest
@testable import TempleRemoteHost

/// A temp tree a test owns, removed when it ends.
final class TempTree {
    let url: URL
    init(_ name: String = "temple-remote") {
        url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    var path: String { url.path }

    @discardableResult
    func write(_ relative: String, _ text: String, executable: Bool = false) -> URL {
        let file = url.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: file, atomically: true, encoding: .utf8)
        if executable { chmod(file.path, 0o755) }
        return file
    }

    func directory(_ relative: String) -> URL {
        let directory = url.appendingPathComponent(relative, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// An exec that records what it was asked and answers from a closure,
/// so a test can count what ran on the seam.
final class RecordingExec: RemoteExec, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(script: String, args: [String])] = []
    let answer: @Sendable (String, [String]) async throws -> RemoteOutput
    init(answer: @escaping @Sendable (String, [String]) async throws -> RemoteOutput) { self.answer = answer }
    var calls: [(script: String, args: [String])] { lock.withLock { _calls } }
    func run(script: String, args: [String], input: Data?, deadline: TimeInterval) async throws -> RemoteOutput {
        lock.withLock { _calls.append((script, args)) }
        return try await answer(script, args)
    }
}

/// The base environment for a local stand-in host: a temp HOME and a PATH
/// of the test's choosing.
func hostEnvironment(home: String, path: String, extra: [String: String] = [:]) -> [String: String] {
    var environment = ["HOME": home, "PATH": path, "TMPDIR": home + "/tmp", "SHELL": "/bin/sh", "LANG": "C"]
    try? FileManager.default.createDirectory(atPath: home + "/tmp", withIntermediateDirectories: true)
    environment.merge(extra) { $1 }
    return environment
}

/// Where this Mac's real tmux is, if one is installed (`brew install tmux`).
func installedTmux() -> String? {
    ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
}
