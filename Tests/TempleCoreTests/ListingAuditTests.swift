import XCTest
@testable import TempleCore
@testable import TempleLocalHost

/// `ListingAudit`, row by row, for both stores: a listing is exhaustive only
/// when everything it met under the root was a plain directory or file, or
/// `.DS_Store`, and every entry's metadata read. Each case also checks that
/// browsing lists exactly what the listing listed before the audit existed.
final class ListingAuditTests: XCTestCase {
    private var root: URL!
    private var locked: [URL] = []
    private var claudeRoot: URL { root.appendingPathComponent("claude") }
    private var project: URL { claudeRoot.appendingPathComponent("-work-project") }
    private var sessions: URL { root.appendingPathComponent("codex/sessions") }
    private var month: URL { sessions.appendingPathComponent("2026/10") }
    private var day: URL { month.appendingPathComponent("01") }
    private var outside: URL { root.appendingPathComponent("outside") }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/temple-listing-audit-\(UUID().uuidString)")
        for dir in [project, day, outside] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("{}".utf8).write(to: project.appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl"))
        try Data("{}".utf8).write(to: day.appendingPathComponent(rollout()))
        // Something for links to point at: a folder holding a transcript of
        // each kind, and a lone transcript-named file.
        try Data("{}".utf8).write(to: outside.appendingPathComponent(rollout()))
        try Data("{}".utf8).write(to: outside.appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl"))
    }

    override func tearDown() {
        for url in locked { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func rollout() -> String { "rollout-2026-10-01T10-00-00-\(UUID().uuidString.lowercased()).jsonl" }

    // MARK: The listings as they were before the audit

    private func previousCodexListing() throws -> [String] {
        var failure: Error?
        let enumerator = FileManager.default.enumerator(at: sessions.resolvingSymlinksInPath(), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false })!
        var files: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            files.append(url.path)
        }
        if let failure { throw failure }
        return files.sorted()
    }

    private func previousClaudeListing() throws -> [String] {
        let fm = FileManager.default
        var files: [String] = []
        for dir in try fm.contentsOfDirectory(at: claudeRoot.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey]) {
            guard try dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            files += try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }.map(\.path)
        }
        return files.sorted()
    }

    /// The audited listing: browsing as before, and whether it is exhaustive.
    private func audit(_ agent: Agent, inspector: EntryInspector = .live, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        if agent == .claude {
            let listing = try ClaudeSessionStore(root: claudeRoot, inspector: inspector).enumerateSessionFilesAudited()
            XCTAssertEqual(listing.files.map(\.path).sorted(), try previousClaudeListing(), "browsing unchanged", file: file, line: line)
            return listing.exhaustive
        }
        let listing = try CodexSessionStore(root: sessions.deletingLastPathComponent(), inspector: inspector).enumerateSessionFilesAudited()
        XCTAssertEqual(listing.files.map(\.path).sorted(), try previousCodexListing(), "browsing unchanged", file: file, line: line)
        return listing.exhaustive
    }

    /// Where a case puts what it adds: Claude's project level and file
    /// level, Codex's month level and day level.
    private func places(_ agent: Agent) -> (dirLevel: URL, fileLevel: URL) {
        agent == .claude ? (claudeRoot, project) : (month, day)
    }

    private func link(_ url: URL, to target: URL) throws {
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    // MARK: Rows

    func testAPlainStoreIsExhaustive() throws {
        for agent in Agent.allCases { XCTAssertTrue(try audit(agent), "\(agent)") }
    }

    func testDSStoreAnywhereIsStillExhaustive() throws {
        for agent in Agent.allCases {
            let (dirLevel, fileLevel) = places(agent)
            try Data().write(to: dirLevel.appendingPathComponent(".DS_Store"))
            try Data().write(to: fileLevel.appendingPathComponent(".DS_Store"))
            XCTAssertTrue(try audit(agent), "\(agent)")
        }
        try Data().write(to: sessions.appendingPathComponent(".DS_Store"))
        XCTAssertTrue(try audit(.codex))
    }

    func testAnyOtherHiddenEntryIsNotExhaustive() throws {
        for agent in Agent.allCases {
            let notes = places(agent).fileLevel.appendingPathComponent(".notes")
            try Data().write(to: notes)
            XCTAssertFalse(try audit(agent), "\(agent): a hidden file")
            try FileManager.default.removeItem(at: notes)
            let stash = places(agent).dirLevel.appendingPathComponent(".stash")
            try FileManager.default.createDirectory(at: stash, withIntermediateDirectories: true)
            XCTAssertFalse(try audit(agent), "\(agent): a hidden directory")
            try FileManager.default.removeItem(at: stash)
            var flagged = places(agent).fileLevel.appendingPathComponent(agent == .claude ? "flagged.jsonl" : rollout())
            try Data("{}".utf8).write(to: flagged)
            var values = URLResourceValues(); values.isHidden = true
            try flagged.setResourceValues(values)
            XCTAssertFalse(try audit(agent), "\(agent): a file with the hidden flag")
            try FileManager.default.removeItem(at: flagged)
            XCTAssertTrue(try audit(agent), "\(agent): back to plain")
        }
    }

    func testAHiddenSymlinkToADirectoryIsNotExhaustive() throws {
        for agent in Agent.allCases {
            try link(places(agent).dirLevel.appendingPathComponent(".linked"), to: outside)
            XCTAssertFalse(try audit(agent), "\(agent)")
        }
    }

    func testAHiddenSymlinkToAFileIsNotExhaustive() throws {
        for agent in Agent.allCases {
            try link(places(agent).fileLevel.appendingPathComponent(".linked-file"), to: outside.appendingPathComponent("anything"))
            XCTAssertFalse(try audit(agent), "\(agent)")
        }
    }

    func testAVisibleSymlinkToAFileIsNotExhaustive() throws {
        let claudeTarget = try FileManager.default.contentsOfDirectory(at: outside, includingPropertiesForKeys: nil)
            .first { !$0.lastPathComponent.hasPrefix("rollout-") }!
        let codexTarget = try FileManager.default.contentsOfDirectory(at: outside, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("rollout-") }!
        try link(project.appendingPathComponent(claudeTarget.lastPathComponent), to: claudeTarget)
        try link(day.appendingPathComponent(codexTarget.lastPathComponent), to: codexTarget)
        XCTAssertFalse(try audit(.claude))
        XCTAssertFalse(try audit(.codex))
    }

    func testAVisibleSymlinkToADirectoryIsNotExhaustive() throws {
        try link(claudeRoot.appendingPathComponent("-linked-project"), to: outside)
        try link(month.appendingPathComponent("02"), to: outside)
        XCTAssertFalse(try audit(.claude))
        XCTAssertFalse(try audit(.codex))
    }

    func testADanglingSymlinkIsNotExhaustive() throws {
        for agent in Agent.allCases {
            try link(places(agent).dirLevel.appendingPathComponent("gone"), to: root.appendingPathComponent("nothing-here"))
            XCTAssertFalse(try audit(agent), "\(agent)")
        }
    }

    func testASymlinkWhoseTargetCannotBeInspectedIsNotExhaustive() throws {
        let sealed = root.appendingPathComponent("sealed")
        try FileManager.default.createDirectory(at: sealed.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealed.path)
        locked.append(sealed)
        for agent in Agent.allCases {
            try link(places(agent).dirLevel.appendingPathComponent("behind-a-wall"), to: sealed.appendingPathComponent("inner"))
            XCTAssertFalse(try audit(agent), "\(agent)")
        }
    }

    func testAMetadataReadThatFailsIsNotExhaustive() throws {
        struct Injected: Error {}
        for agent in Agent.allCases {
            let victim = places(agent).fileLevel.lastPathComponent
            let failing = EntryInspector { url, keys in
                if url.lastPathComponent == victim { throw Injected() }
                return try url.resourceValues(forKeys: keys)
            }
            XCTAssertFalse(try audit(agent, inspector: failing), "\(agent)")
            XCTAssertTrue(try audit(agent), "\(agent): the same store, read")
        }
    }

    /// An entry whose metadata does not say (no answer, rather than no) is
    /// not taken as plain.
    func testMetadataThatDoesNotSayIsNotExhaustive() throws {
        for agent in Agent.allCases {
            let silent = EntryInspector { _, _ in URLResourceValues() }
            XCTAssertFalse(try audit(agent, inspector: silent), "\(agent)")
        }
    }

    /// Scope: Claude's listing walks the root's entries and the entries
    /// directly inside each project folder, and no deeper; Claude Code puts
    /// links of its own in `<project>/<session>/subagents/`, where no
    /// candidate can be, and they decide nothing. Codex's listing walks
    /// everything under `sessions/`, so a link anywhere there counts.
    func testOnlyWhatTheListingWalksIsInScope() throws {
        let subagents = project.appendingPathComponent("\(UUID().uuidString.lowercased())/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: subagents.appendingPathComponent("agent-real.jsonl"))
        try link(subagents.appendingPathComponent("agent-linked.jsonl"), to: outside.appendingPathComponent("anything.jsonl"))
        try link(subagents.appendingPathComponent("agent-dangling.jsonl"), to: root.appendingPathComponent("nothing-here"))
        try Data().write(to: subagents.appendingPathComponent(".hidden"))
        XCTAssertTrue(try audit(.claude), "links and hidden entries below a project's own entries are out of scope")

        let claude = ClaudeSessionStore(root: claudeRoot)
        let claudePrefix = SessionPaths.normalized(claudeRoot.path)
        XCTAssertTrue(claude.inAuditScope(claudePrefix + "/-work-project"))
        XCTAssertTrue(claude.inAuditScope(claudePrefix + "/-work-project/x.jsonl"))
        XCTAssertFalse(claude.inAuditScope(claudePrefix + "/-work-project/session/subagents"))
        XCTAssertFalse(claude.inAuditScope(claudePrefix))
        XCTAssertFalse(claude.inAuditScope("/elsewhere/-p/x.jsonl"))
        let codex = CodexSessionStore(root: sessions.deletingLastPathComponent())
        let sessionsPath = SessionPaths.normalized(sessions.path)
        XCTAssertTrue(codex.inAuditScope(sessionsPath + "/2026"))
        XCTAssertTrue(codex.inAuditScope(sessionsPath + "/2026/10/01/deeper/still/x"))
        XCTAssertFalse(codex.inAuditScope(SessionPaths.normalized(sessions.deletingLastPathComponent().path) + "/history.jsonl"))

        // Deeper under Codex's root counts.
        let deep = day.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try link(deep.appendingPathComponent("link"), to: outside)
        XCTAssertFalse(try audit(.codex))
    }

    /// An error from the enumerator fails the listing, as it always did: no
    /// files, and certainly no completion.
    func testAnEnumeratorErrorFailsTheListing() throws {
        let sealedDay = month.appendingPathComponent("03")
        try FileManager.default.createDirectory(at: sealedDay, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealedDay.path)
        locked.append(sealedDay)
        XCTAssertThrowsError(try CodexSessionStore(root: sessions.deletingLastPathComponent()).enumerateSessionFilesAudited())
        XCTAssertThrowsError(try previousCodexListing(), "it failed before the audit too")

        let sealedProject = claudeRoot.appendingPathComponent("-sealed")
        try FileManager.default.createDirectory(at: sealedProject, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealedProject.path)
        locked.append(sealedProject)
        XCTAssertThrowsError(try ClaudeSessionStore(root: claudeRoot).enumerateSessionFilesAudited())
        XCTAssertThrowsError(try previousClaudeListing())
    }
}
