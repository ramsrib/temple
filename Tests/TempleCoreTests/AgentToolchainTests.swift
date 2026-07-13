import XCTest
@testable import TempleCore

final class AgentToolchainTests: XCTestCase {

    /// Both installs from the field: a current native one, and a stale npm one
    /// that crashes because the Node it resolves moved on without it.
    private let good = "/Users/x/.local/bin/claude"
    private let stale = "/opt/homebrew/bin/claude"

    private func probing(_ results: [String: (String?, String?, String?)]) -> AgentToolchain.Prober {
        { path in results[path] ?? (nil, "not probed", nil) }
    }

    private func exists(_ paths: Set<String>) -> (String) -> Bool {
        { paths.contains($0) }
    }

    func testPrefersShellPATHOrder() {
        let resolution = AgentToolchain.resolve(
            .claude,
            path: "/Users/x/.local/bin:/opt/homebrew/bin",
            knownLocations: [],
            isExecutable: exists([good, stale]),
            probe: probing([good: ("2.1.207 (Claude Code)", nil, nil),
                            stale: ("1.0.18 (Claude Code)", nil, nil)]))

        XCTAssertEqual(resolution.chosen?.path, good)
        XCTAssertEqual(resolution.chosen?.version, "2.1.207 (Claude Code)")
        XCTAssertEqual(resolution.installs.map(\.path), [good, stale])
        XCTAssertNil(resolution.problem)
    }

    /// The heart of it: the shell's first `claude` is stale and crashes under the
    /// installed Node. Temple must not launch it just because it came first — it
    /// must skip to one that actually runs, and say that it did.
    func testSkipsAnInstallThatCannotRun() {
        let resolution = AgentToolchain.resolve(
            .claude,
            path: "/opt/homebrew/bin:/Users/x/.local/bin",
            knownLocations: [],
            isExecutable: exists([good, stale]),
            probe: probing([stale: (nil, "TypeError: Cannot read properties of undefined", "…stack…"),
                            good: ("2.1.207 (Claude Code)", nil, nil)]))

        XCTAssertEqual(resolution.chosen?.path, good)
        XCTAssertEqual(resolution.shadowedFailures.map(\.path), [stale])
        XCTAssertEqual(resolution.problem,
                       "Skipped \(stale) — it fails to run. Using \(good) instead.")
    }

    func testReportsWhenNothingRuns() {
        let resolution = AgentToolchain.resolve(
            .claude,
            path: "/opt/homebrew/bin",
            knownLocations: [],
            isExecutable: exists([stale]),
            probe: probing([stale: (nil, "TypeError: Cannot read properties of undefined", nil)]))

        XCTAssertNil(resolution.chosen)
        XCTAssertEqual(resolution.problem, "Every claude found on this machine fails to run.")
    }

    func testReportsWhenNothingIsInstalled() {
        let resolution = AgentToolchain.resolve(
            .claude,
            path: "/usr/bin",
            knownLocations: [],
            isExecutable: exists([]),
            probe: probing([:]))

        XCTAssertTrue(resolution.installs.isEmpty)
        XCTAssertNil(resolution.chosen)
        XCTAssertEqual(resolution.problem, "No claude found on your PATH.")
    }

    /// A known location is a last resort, never a preference — if it isn't on the
    /// user's PATH, it isn't what they'd get by typing the command, and we say so.
    func testKnownLocationsRankBelowPATHAndAreCalledOut() {
        let resolution = AgentToolchain.resolve(
            .claude,
            path: "/usr/bin",
            knownLocations: ["/opt/homebrew/bin"],
            isExecutable: exists([stale]),
            probe: probing([stale: ("1.0.18 (Claude Code)", nil, nil)]))

        XCTAssertEqual(resolution.chosen?.path, stale)
        XCTAssertFalse(resolution.chosen?.isOnPATH ?? true)
        XCTAssertEqual(resolution.problem,
                       "claude isn't on the PATH your shell gives Temple; found it at \(stale).")
    }

    /// A PATH that lists a directory twice, or lists both a symlink and its target,
    /// must not read as "you have two installs".
    func testDeduplicatesRepeatedPATHEntries() {
        let resolution = AgentToolchain.resolve(
            .claude,
            path: "/Users/x/.local/bin:/Users/x/.local/bin",
            knownLocations: ["/Users/x/.local/bin"],
            isExecutable: exists([good]),
            probe: probing([good: ("2.1.207", nil, nil)]))

        XCTAssertEqual(resolution.installs.count, 1)
    }

    func testIgnoresRelativePATHEntries() {
        let found = AgentToolchain.discover("claude",
                                            path: "relative/bin:/Users/x/.local/bin",
                                            knownLocations: [],
                                            isExecutable: exists([good, "relative/bin/claude"]))
        XCTAssertEqual(found.map(\.path), [good])
    }

    // MARK: Failure summaries

    /// Real output from a `claude` that couldn't start. We don't care *why* it
    /// couldn't — only that the line worth showing the user is neither the first
    /// (blank) nor the last (a runtime footer), but the one that names the error.
    func testSummarizePicksTheTellingLineOutOfAStackTrace() {
        let crash = """

        file:///opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js:400
        TypeError: Cannot read properties of undefined (reading 'prototype')
            at file:///opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js:400:25482

        Node.js v26.5.0
        """
        XCTAssertEqual(AgentToolchain.summarize(crash),
                       "TypeError: Cannot read properties of undefined (reading 'prototype')")
    }

    func testSummarizeFallsBackToTheLastLine() {
        XCTAssertEqual(AgentToolchain.summarize("something odd happened\nexit 3\n"), "exit 3")
        XCTAssertNil(AgentToolchain.summarize("   \n\n"))
    }

    // MARK: Real probing

    /// The prober must actually run the thing — and report a failure as a failure.
    func testProbeRunsTheBinary() {
        let version = AgentToolchain.probe("/bin/echo")
        XCTAssertNil(version.failure)
        XCTAssertEqual(version.version, "--version")   // echo prints its argument

        let broken = AgentToolchain.probe("/usr/bin/false")
        XCTAssertNotNil(broken.failure)
    }

    /// End to end, no mocks: two real executables on a real PATH, the first of which
    /// crashes on startup the way a broken install does. Temple must run the second
    /// and explain the first — without needing to understand the crash.
    func testResolvesPastACrashingInstallForReal() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let brokenDir = root.appendingPathComponent("homebrew")
        let workingDir = root.appendingPathComponent("local")
        for dir in [brokenDir, workingDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        try write("""
        #!/bin/sh
        echo "TypeError: Cannot read properties of undefined (reading 'prototype')" >&2
        echo "Node.js v26.5.0" >&2
        exit 1
        """, to: brokenDir.appendingPathComponent("claude"))

        try write("""
        #!/bin/sh
        echo "2.1.207 (Claude Code)"
        """, to: workingDir.appendingPathComponent("claude"))

        let resolution = AgentToolchain.resolve(.claude,
                                                path: "\(brokenDir.path):\(workingDir.path)",
                                                knownLocations: [])

        XCTAssertEqual(resolution.installs.count, 2)
        XCTAssertEqual(resolution.chosen?.path, workingDir.appendingPathComponent("claude").path)
        XCTAssertEqual(resolution.chosen?.version, "2.1.207 (Claude Code)")
        XCTAssertEqual(resolution.shadowedFailures.first?.failure,
                       "TypeError: Cannot read properties of undefined (reading 'prototype')")
        XCTAssertTrue(resolution.shadowedFailures.first?.details?.contains("Node.js v26.5.0") ?? false)
    }

    /// Arguments are validated by running them next to `--version`. A CLI that
    /// parses first (codex does) names the bad flag; one that short-circuits on
    /// `--version` (claude does) says nothing — so a clean result must never be
    /// read as approval. Both behaviours, pinned.
    func testArgumentCheckCatchesARejectingCLIAndStaysSilentOnAPermissiveOne() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Parses its arguments before honouring --version (codex-like).
        let strict = dir.appendingPathComponent("strict")
        try write("""
        #!/bin/sh
        for arg in "$@"; do
          case "$arg" in
            --version) ;;
            --known) ;;
            *) echo "error: unexpected argument '$arg' found" >&2; exit 2 ;;
          esac
        done
        echo "strict-cli 1.0"
        """, to: strict)

        // Prints its version and ignores everything else (claude-like).
        let permissive = dir.appendingPathComponent("permissive")
        try write("""
        #!/bin/sh
        echo "2.1.207 (Claude Code)"
        """, to: permissive)

        XCTAssertNil(AgentToolchain.check(strict.path, arguments: ["--known"]).failure)
        XCTAssertEqual(AgentToolchain.check(strict.path, arguments: ["--bogus"]).failure,
                       "error: unexpected argument '--bogus' found")

        // The permissive CLI raises no objection even to nonsense. We report nothing
        // — silence is not a tick, and pretending otherwise would be a lie.
        XCTAssertNil(AgentToolchain.check(permissive.path, arguments: ["--bogus"]).failure)

        // No arguments to check → nothing to say, and no process spawned.
        XCTAssertNil(AgentToolchain.check(strict.path, arguments: []).failure)
    }

    private func write(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
