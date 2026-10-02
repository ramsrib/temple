import XCTest
import TempleCore
@testable import TempleUI

/// The Settings page's model half: drafts and commits, Reset to default, the
/// override verdict's four states, the retry schedule it shows, the deep link,
/// and the font-family check.
@MainActor
final class SettingsEditingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: SettingsStore!
    private var probes: ProbeLog!
    private var toolchain: ToolchainModel!
    private var editor: SettingsEditor { SettingsEditor(store: store, toolchain: toolchain) }

    /// `broken` paths fail when run; `unlaunchable` ones never start; `rejected`
    /// arguments are refused by the CLI.
    private func configure(installs: [AgentInstall] = [AgentInstall(path: "/bin/claude", origin: .path(rank: 0), version: "2.1.287")],
                       broken: Set<String> = [],
                       unlaunchable: Set<String> = [],
                       rejected: Set<String> = []) {
        defaults = Fixture.uniqueDefaults()
        store = SettingsStore(defaults: defaults)
        probes = ProbeLog()
        let log = probes!
        toolchain = ToolchainModel(
            resolve: { agent in
                let mine = agent == .claude ? installs : []
                return ToolchainResolution(agent: agent, installs: mine, chosen: mine.first(where: \.isUsable))
            },
            probe: { path, args -> (version: String?, failure: String?, details: String?) in
                log.record(path, args)
                if unlaunchable.contains(path) {
                    return (nil, AgentToolchain.launchFailurePrefix + "Permission denied", "NSPOSIXErrorDomain 13")
                }
                if broken.contains(path) {
                    return (nil, "Error: Cannot find module 'cli.js'", "node:internal…\nError: Cannot find module 'cli.js'")
                }
                if let bad = args.first(where: { rejected.contains($0) }) {
                    return (nil, "error: unexpected argument '\(bad)' found", "error: unexpected argument '\(bad)' found\n\nUsage: …")
                }
                return ("9.9.9", nil, nil)
            })
        toolchain.override = { [store] in store!.overridePath(for: $0) }
        toolchain.arguments = { [store] in store!.extraArgs(for: $0) }
        toolchain.detect()
        waitUntil { !self.toolchain.isDetecting }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func settle(_ seconds: TimeInterval = 0.2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    // MARK: Draft vs commit

    func testTypingWritesNothingAndProbesNothing() {
        configure()
        let probesBefore = probes.count
        var drafts = SettingsDrafts()
        for prefix in ["/", "/o", "/opt", "/opt/claude"] {
            drafts.edit(.command(.claude), to: prefix, committed: editor.committed(.command(.claude)))
            drafts.edit(.arguments(.claude), to: "--model " + prefix, committed: editor.committed(.arguments(.claude)))
            drafts.edit(.fontFamily, to: "Men" + prefix, committed: editor.committed(.fontFamily))
        }
        settle()
        XCTAssertEqual(store.claudePath, "", "a keystroke reached the store")
        XCTAssertEqual(store.claudeExtraArgs, SettingsStore.shippedExtraArgs(for: .claude))
        XCTAssertEqual(store.fontFamily, "", "a keystroke reached the store")
        XCTAssertNil(defaults.object(forKey: "temple.settings.claudePath"), "a keystroke was persisted")
        XCTAssertEqual(probes.count, probesBefore, "a keystroke ran a probe")
        XCTAssertEqual(drafts.text(.command(.claude), committed: ""), "/opt/claude")
        XCTAssertTrue(drafts.isEdited(.command(.claude)))
    }

    func testCommitWritesTheStoreAndRechecks() {
        configure(broken: ["/opt/claude"])
        var drafts = SettingsDrafts()
        drafts.edit(.command(.claude), to: "/opt/claude", committed: "")
        XCTAssertTrue(editor.commit(.command(.claude), drafts: &drafts))
        XCTAssertEqual(store.claudePath, "/opt/claude")
        XCTAssertFalse(drafts.isEdited(.command(.claude)), "a committed draft is gone")
        XCTAssertEqual(toolchain.overrideVerdict(for: .claude), .checking, "committed, probe in flight")
        waitUntil { self.toolchain.overrideVerdict(for: .claude) != .checking }
        XCTAssertEqual(toolchain.overrideVerdict(for: .claude),
                       .doesNotRun(failure: "Error: Cannot find module 'cli.js'",
                                   details: "node:internal…\nError: Cannot find module 'cli.js'"))
        XCTAssertTrue(probes.paths.contains("/opt/claude"), "the commit probed the new path")
    }

    func testCommittingAnUnchangedFieldDoesNothing() {
        configure()
        let probesBefore = probes.count
        var drafts = SettingsDrafts()
        XCTAssertFalse(editor.commit(.command(.claude), drafts: &drafts), "no draft, nothing to commit")
        // Typed back to what it was: the draft disappears on its own.
        drafts.edit(.arguments(.claude), to: "x", committed: store.claudeExtraArgs)
        drafts.edit(.arguments(.claude), to: store.claudeExtraArgs, committed: store.claudeExtraArgs)
        XCTAssertFalse(drafts.isEdited(.arguments(.claude)))
        XCTAssertFalse(editor.commit(.arguments(.claude), drafts: &drafts))
        settle()
        XCTAssertEqual(probes.count, probesBefore, "tabbing through fields must not re-probe")
        XCTAssertFalse(toolchain.isCheckingUserSettings)
    }

    func testEscRevertsTheDraftAndASecondEscHasNothingToDo() {
        configure()
        var drafts = SettingsDrafts()
        drafts.edit(.arguments(.codex), to: "--bogus", committed: store.codexExtraArgs)
        XCTAssertTrue(drafts.revert(.arguments(.codex)))
        XCTAssertEqual(drafts.text(.arguments(.codex), committed: store.codexExtraArgs), store.codexExtraArgs)
        XCTAssertFalse(drafts.revert(.arguments(.codex)), "nothing left to revert")
        XCTAssertFalse(editor.commit(.arguments(.codex), drafts: &drafts), "a reverted draft commits nothing")
        XCTAssertEqual(store.codexExtraArgs, SettingsStore.shippedExtraArgs(for: .codex))
    }

    func testClearingTheCommandGoesBackToDetectionInOneStep() {
        configure()
        store.claudePath = "/custom/claude"
        XCTAssertTrue(editor.write(.command(.claude), ""))
        XCTAssertEqual(store.claudePath, "")
        XCTAssertNil(toolchain.overrideVerdict(for: .claude), "no override, no verdict")
        XCTAssertEqual(toolchain.launchPath(for: .claude), "/bin/claude")
    }

    func testCommandAndFamilyAreTrimmedArgumentsAreNot() {
        configure()
        editor.write(.command(.claude), "  /opt/claude\n")
        XCTAssertEqual(store.claudePath, "/opt/claude")
        editor.write(.fontFamily, "Menlo ")
        XCTAssertEqual(store.fontFamily, "Menlo")
        editor.write(.arguments(.claude), " --verbose ")
        XCTAssertEqual(store.claudeExtraArgs, " --verbose ")
    }

    func testTypedFontSizeIsClampedAndRounded() {
        configure()
        editor.write(.fontSize, "40")
        XCTAssertEqual(store.fontSize, 24)
        editor.write(.fontSize, "3")
        XCTAssertEqual(store.fontSize, 9)
        editor.write(.fontSize, "15.6")
        XCTAssertEqual(store.fontSize, 16)
        XCTAssertFalse(editor.write(.fontSize, "big"), "not a number: nothing written")
        XCTAssertEqual(store.fontSize, 16)
        XCTAssertEqual(editor.committed(.fontSize), "16")
    }

    // MARK: Reset to default

    func testResetForgetsTheOverrideRatherThanWritingTheDefault() {
        configure()
        editor.write(.arguments(.claude), "--verbose")
        XCTAssertEqual(defaults.string(forKey: "temple.settings.claudeExtraArgs"), "--verbose")
        XCTAssertFalse(store.extraArgsAreShipped(for: .claude))

        var drafts = SettingsDrafts()
        drafts.edit(.arguments(.claude), to: "--half-typed", committed: store.claudeExtraArgs)
        editor.resetArguments(.claude, drafts: &drafts)

        XCTAssertEqual(store.claudeExtraArgs, "--dangerously-skip-permissions")
        XCTAssertTrue(store.extraArgsAreShipped(for: .claude))
        XCTAssertNil(defaults.object(forKey: "temple.settings.claudeExtraArgs"),
                     "the shipped default is the code layer; it is never written into the key")
        XCTAssertFalse(drafts.isEdited(.arguments(.claude)), "reset discards a pending draft too")
        XCTAssertTrue(toolchain.isCheckingUserSettings, "the reset arguments are checked again")
        // And a fresh store reads the shipped value back from the absence.
        XCTAssertEqual(SettingsStore(defaults: defaults).claudeExtraArgs, "--dangerously-skip-permissions")
    }

    func testResetFromEmptyArguments() {
        configure()
        editor.write(.arguments(.codex), "")
        XCTAssertEqual(store.extraArgs(for: .codex), [])
        var drafts = SettingsDrafts()
        editor.resetArguments(.codex, drafts: &drafts)
        XCTAssertEqual(store.codexExtraArgs, "--dangerously-bypass-approvals-and-sandbox")
    }

    // MARK: Override verdict

    func testOverrideVerdictStates() {
        configure(broken: ["/broken/claude"], unlaunchable: ["/locked/claude"])
        XCTAssertNil(toolchain.overrideVerdict(for: .claude), "no override: Detected answers")

        editor.write(.command(.claude), "/good/claude")
        XCTAssertEqual(toolchain.overrideVerdict(for: .claude), .checking)
        waitUntil { !self.toolchain.isCheckingUserSettings }
        XCTAssertEqual(toolchain.overrideVerdict(for: .claude), .runs(version: "9.9.9"))

        editor.write(.command(.claude), "/broken/claude")
        waitUntil { !self.toolchain.isCheckingUserSettings }
        guard case .doesNotRun(let failure, _) = toolchain.overrideVerdict(for: .claude) else {
            return XCTFail("expected doesNotRun")
        }
        XCTAssertEqual(failure, "Error: Cannot find module 'cli.js'", "the CLI's own words, verbatim")

        editor.write(.command(.claude), "/locked/claude")
        waitUntil { !self.toolchain.isCheckingUserSettings }
        XCTAssertEqual(toolchain.overrideVerdict(for: .claude),
                       .couldNotLaunch(reason: "Permission denied", details: "NSPOSIXErrorDomain 13"))
        XCTAssertTrue(toolchain.overrideVerdict(for: .claude)!.isFailure)
        XCTAssertEqual(toolchain.launchPath(for: .claude), "/locked/claude", "a broken override still wins")
    }

    /// The verdict is about the committed path; a draft never gets one.
    func testAnUncommittedEditHasNoVerdict() {
        configure()
        editor.write(.command(.claude), "/good/claude")
        waitUntil { !self.toolchain.isCheckingUserSettings }
        var drafts = SettingsDrafts()
        drafts.edit(.command(.claude), to: "/good/claude2", committed: store.claudePath)
        XCTAssertEqual(toolchain.overrideVerdict(for: .claude), .runs(version: "9.9.9"),
                       "the verdict is still the committed path's — the view shows Press Return instead")
        XCTAssertEqual(store.claudePath, "/good/claude")
    }

    // MARK: No positive mark for arguments

    /// Arguments only ever get a complaint. With no objection there is nothing
    /// at all to show — no state the page could render as "OK".
    func testAcceptedArgumentsProduceNoVerdictAtAll() {
        configure(rejected: ["--bogus"])
        editor.write(.arguments(.claude), "--fine")
        waitUntil { !self.toolchain.isCheckingUserSettings }
        XCTAssertNil(toolchain.argumentComplaint(for: .claude))

        editor.write(.arguments(.claude), "--bogus")
        waitUntil { !self.toolchain.isCheckingUserSettings }
        XCTAssertEqual(toolchain.argumentComplaint(for: .claude)?.failure, "error: unexpected argument '--bogus' found")
    }

    // MARK: Subtitle

    func testSummaryStatesWhatWillRun() {
        configure(broken: ["/broken/claude"])
        XCTAssertEqual(toolchain.summary()?.map(\.text), ["Claude Code 2.1.287", "Codex not found"])
        XCTAssertEqual(toolchain.summary()?.map(\.state), [.runs, .missing])

        editor.write(.command(.claude), "/broken/claude")
        XCTAssertEqual(toolchain.summary()?.first?.text, "Claude Code: checking…")
        waitUntil { !self.toolchain.isCheckingUserSettings }
        XCTAssertEqual(toolchain.summary()?.first, ToolchainSummaryPart(agent: .claude, text: "Claude Code: doesn't run", state: .broken))
    }

    func testSummaryIsNilBeforeAnythingLands() {
        let model = ToolchainModel(resolve: { ToolchainResolution(agent: $0, installs: [], chosen: nil) },
                                   probe: { _, _ in (nil, nil, nil) })
        XCTAssertNil(model.summary(), "Checking agents…")
    }

    func testSummaryWhenEveryInstallFails() {
        configure(installs: [AgentInstall(path: "/bin/claude", origin: .path(rank: 0), failure: "TypeError")])
        XCTAssertEqual(toolchain.summary()?.first?.text, "Claude Code: doesn't run")
    }

    // MARK: Checked · retry schedule

    func testLastCheckedAndTheRetryScheduleAreExposed() {
        let flawed = ToolchainResolution(
            agent: .claude,
            installs: [AgentInstall(path: "/a/claude", origin: .path(rank: 0), failure: "didn't respond"),
                       AgentInstall(path: "/b/claude", origin: .path(rank: 1), version: "1")],
            chosen: AgentInstall(path: "/b/claude", origin: .path(rank: 1), version: "1"))
        let model = ToolchainModel(
            resolve: { $0 == .claude ? flawed : ToolchainResolution(agent: $0, installs: [], chosen: nil) },
            probe: { _, _ in ("1", nil, nil) })
        model.retryDelays = [30]
        XCTAssertNil(model.lastChecked)
        XCTAssertNil(model.nextRetryAt)
        let start = Date()
        model.detect()
        waitUntil { !model.isDetecting }
        XCTAssertNotNil(model.lastChecked)
        XCTAssertGreaterThanOrEqual(model.lastChecked!, start)
        let next = try! XCTUnwrap(model.nextRetryAt, "a flawed verdict schedules a retry, and says when")
        XCTAssertEqual(next.timeIntervalSince(start), 30, accuracy: 2)

        // Check again replaces the sleeper; the new schedule's first retry is shown.
        model.retryDelays = [0.05]
        model.detect()
        XCTAssertNil(model.nextRetryAt, "a manual check cancels the scheduled one")
        waitUntil { !model.isDetecting }
        XCTAssertNotNil(model.nextRetryAt)
        waitUntil { model.nextRetryAt == nil && !model.isDetecting }
    }

    func testACleanVerdictSchedulesNothing() {
        configure()
        XCTAssertNotNil(toolchain.lastChecked)
        XCTAssertNil(toolchain.nextRetryAt)
    }

    // MARK: Deep link

    func testOpenSettingsFocusingAnAgent() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSettings(focusing: .codex)
        XCTAssertEqual(model.activeTab?.kind, .settings)
        let request = try! XCTUnwrap(model.settingsFocus)
        XCTAssertEqual(request.agent, .codex)

        // A second click on the same warning is a new request (the page scrolls again).
        model.openSettings(focusing: .codex)
        XCTAssertNotEqual(model.settingsFocus, request)
        XCTAssertEqual(model.tabs.filter { $0.kind == .settings }.count, 1, "still one Settings tab")

        // A stale consume does not swallow the newer request.
        model.consumeSettingsFocus(request)
        XCTAssertNotNil(model.settingsFocus)
        model.consumeSettingsFocus(model.settingsFocus!)
        XCTAssertNil(model.settingsFocus)
    }

    func testAShellProblemLandsAtTheTopAndPlainOpenRequestsNothing() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSettings()
        XCTAssertNil(model.settingsFocus, "⌘, opens the page where it is")
        model.openSettings(focusing: nil)
        XCTAssertNotNil(model.settingsFocus)
        XCTAssertNil(model.settingsFocus?.agent, "nil: the top of the page")
    }

    // MARK: Font family

    func testFontFamilyVerdict() {
        let installed: Set<String> = ["Menlo", "JetBrains Mono"]
        XCTAssertNil(FontFamilyCheck.verdict(for: "Menlo", isInstalled: installed.contains))
        XCTAssertEqual(FontFamilyCheck.verdict(for: "Menol", isInstalled: installed.contains), .notInstalled)
        XCTAssertNil(FontFamilyCheck.verdict(for: "", isInstalled: { _ in false }),
                     "empty is the terminal's own default, nothing to report")
        XCTAssertNil(FontFamilyCheck.verdict(for: " Menlo ", isInstalled: installed.contains))
    }

    /// The real lookup: Menlo ships with every macOS; a nonsense name does not.
    func testFontFamilyLookupAgainstCoreText() {
        XCTAssertTrue(FontFamilyCheck.isInstalled("Menlo"))
        XCTAssertFalse(FontFamilyCheck.isInstalled("No Such Family 7f3a"))
    }
}

/// Probes run off the main actor; this records them thread-safely.
private final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, [String])] = []
    func record(_ path: String, _ args: [String]) { lock.lock(); calls.append((path, args)); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.0) }
}
