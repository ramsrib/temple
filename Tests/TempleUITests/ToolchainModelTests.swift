import XCTest
import TempleCore
@testable import TempleUI

@MainActor
final class ToolchainModelTests: XCTestCase {

    private func install(_ path: String, rank: Int = 0, failure: String? = nil) -> AgentInstall {
        AgentInstall(path: path,
                     origin: .path(rank: rank),
                     version: failure == nil ? "1.2.3" : nil,
                     failure: failure)
    }

    /// `overrides` maps an agent to the path the user typed; `broken` are paths that
    /// fail when run; `rejected` are arguments the CLI refuses.
    private func model(_ resolutions: [Agent: ToolchainResolution],
                       overrides: [Agent: String] = [:],
                       broken: Set<String> = [],
                       arguments: [Agent: [String]] = [:],
                       rejected: Set<String> = []) -> ToolchainModel {
        let model = ToolchainModel(
            resolve: { resolutions[$0] ?? ToolchainResolution(agent: $0, installs: [], chosen: nil) },
            probe: { path, args -> (version: String?, failure: String?, details: String?) in
                if broken.contains(path) {
                    return (version: nil, failure: "TypeError: …", details: "…stack…")
                }
                if let bad = args.first(where: { rejected.contains($0) }) {
                    return (version: nil, failure: "error: unexpected argument '\(bad)' found", details: nil)
                }
                return (version: "1.2.3", failure: nil, details: nil)
            })
        model.override = { overrides[$0] ?? "" }
        model.arguments = { arguments[$0] ?? [] }
        model.detect()
        // Wait for the work to *finish*, not for a guessed interval — a fixed sleep
        // passes alone and fails under a loaded suite, which is how a flaky test is
        // born.
        let deadline = Date().addingTimeInterval(5)
        while model.isDetecting && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(model.isDetecting, "detection did not finish")
        return model
    }

    private func resolution(_ agent: Agent, _ installs: [AgentInstall]) -> ToolchainResolution {
        ToolchainResolution(agent: agent, installs: installs, chosen: installs.first(where: \.isUsable))
    }

    func testLaunchesTheVerifiedInstall() {
        let model = model([.claude: resolution(.claude, [
            install("/opt/homebrew/bin/claude", rank: 0, failure: "TypeError: …"),
            install("/Users/x/.local/bin/claude", rank: 1),
        ])])
        XCTAssertEqual(model.launchPath(for: .claude), "/Users/x/.local/bin/claude")
    }

    /// An override is the user's call — it wins even over a verified install.
    func testOverrideBeatsDetection() {
        let model = model([.claude: resolution(.claude, [install("/Users/x/.local/bin/claude")])],
                          overrides: [.claude: "/custom/claude"])
        XCTAssertEqual(model.launchPath(for: .claude), "/custom/claude")
    }

    /// Even a *broken* override is launched, not silently swapped for our own pick.
    /// Substituting our judgment for the user's decision behind their back is worse
    /// than failing where they can see it — so we run it, and we say it's broken.
    func testBrokenOverrideIsStillLaunchedAndIsReported() {
        let model = model([.claude: resolution(.claude, [install("/Users/x/.local/bin/claude")])],
                          overrides: [.claude: "/custom/claude"],
                          broken: ["/custom/claude"])

        XCTAssertEqual(model.launchPath(for: .claude), "/custom/claude")
        let warnings = model.warnings(defaultAgent: .claude)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].isFatal)
        XCTAssertTrue(warnings[0].message.contains("/custom/claude"))
        XCTAssertTrue(warnings[0].message.contains("doesn't run"))
    }

    /// With an override set, detection's opinion is not news. Reporting "skipped X,
    /// using Y instead" would also be false — we're using neither, we're using the
    /// override.
    func testDetectionIsNotNarratedWhenTheUserHasDecided() {
        let model = model([.claude: resolution(.claude, [
            install("/opt/homebrew/bin/claude", rank: 0, failure: "TypeError: …"),
            install("/Users/x/.local/bin/claude", rank: 1),
        ])], overrides: [.claude: "/custom/claude"])

        XCTAssertTrue(model.warnings(defaultAgent: .claude).isEmpty)
    }

    /// A verdict belongs to the exact path it was made about — edit the field and
    /// the old tick must vanish rather than vouch for a path we never ran.
    func testOverrideVerdictGoesStaleWhenThePathChanges() {
        let model = model([:], overrides: [.claude: "/custom/claude"])
        XCTAssertNotNil(model.overrideCheck(for: .claude))

        model.override = { _ in "/somewhere/else/claude" }
        XCTAssertNil(model.overrideCheck(for: .claude))
    }

    // MARK: Whose fault a dead tab is

    /// A verified binary + accepted arguments means a launch that dies is the agent's
    /// own business (a session that no longer exists, a cwd that moved). The UI must
    /// not blame the command — and must not send the user to Settings to check
    /// something that is provably fine.
    func testAHealthyToolchainIsNotBlamedForAnAgentThatDiesOnItsOwn() {
        let model = model([.claude: resolution(.claude, [install("/Users/x/.local/bin/claude")])],
                          arguments: [.claude: ["--dangerously-skip-permissions"]])
        XCTAssertTrue(model.canLaunch(.claude))
    }

    func testABrokenBinaryOrRejectedArgumentsDoesBlameTheCommand() {
        let broken = model([.claude: resolution(.claude, [install("/opt/homebrew/bin/claude", failure: "TypeError: …")])])
        XCTAssertFalse(broken.canLaunch(.claude))

        let badArgs = model([.claude: resolution(.claude, [install("/Users/x/.local/bin/claude")])],
                            arguments: [.claude: ["--bogus"]],
                            rejected: ["--bogus"])
        XCTAssertFalse(badArgs.canLaunch(.claude))

        let badOverride = model([.claude: resolution(.claude, [install("/Users/x/.local/bin/claude")])],
                                overrides: [.claude: "/custom/claude"],
                                broken: ["/custom/claude"])
        XCTAssertFalse(badOverride.canLaunch(.claude))
    }

    /// Before detection lands we know nothing — and an accusation we can't support is
    /// worse than silence.
    func testUnknownToolchainIsGivenTheBenefitOfTheDoubt() {
        let fresh = ToolchainModel(resolve: { ToolchainResolution(agent: $0, installs: [], chosen: nil) },
                                   probe: { _, _ in (version: "1.2.3", failure: nil, details: nil) })
        XCTAssertTrue(fresh.canLaunch(.claude), "accused the command before detection had run")
    }

    // MARK: Out-of-order results

    /// Probing is slow and off the main actor, so a startup detection can land *after*
    /// a recheck the user triggered later. If the stale answer wins, the "your override
    /// is broken" warning silently disappears — while the broken override is still
    /// exactly what Temple launches. The newer verdict must survive.
    func testAStaleDetectionCannotEraseANewerOverrideVerdict() {
        var overridePath = ""
        // Detection probes slowly; the recheck the user triggers will overtake it.
        let model = ToolchainModel(
            resolve: { agent in
                Thread.sleep(forTimeInterval: 0.6)
                return ToolchainResolution(agent: agent, installs: [], chosen: nil)
            },
            probe: { path, _ -> (version: String?, failure: String?, details: String?) in
                path == "/broken/claude"
                    ? (version: nil, failure: "TypeError: …", details: nil)
                    : (version: "1.2.3", failure: nil, details: nil)
            })
        model.override = { _ in overridePath }
        model.arguments = { _ in [] }

        model.detect()                       // starts with NO override, and is slow
        overridePath = "/broken/claude"      // user types a broken override…
        model.recheckUserSettings()          // …and it is probed and lands first

        let deadline = Date().addingTimeInterval(5)
        while model.isDetecting && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        // Let any late (stale) publication from detect() attempt to land.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(model.launchPath(for: .claude), "/broken/claude")
        XCTAssertNotNil(model.overrideCheck(for: .claude), "the newer verdict was clobbered by the stale one")
        XCTAssertTrue(model.warnings(defaultAgent: .claude).contains { $0.isFatal })
    }

    /// Editing arguments *while startup detection is still running* used to lose the
    /// argument probe entirely: the recheck snapshotted an empty `resolutions`, so it
    /// had no binary to ask, and detection's own answer was then dropped as stale. The
    /// rejected flag was never reported — false confidence, permanently.
    func testArgumentsEditedDuringDetectionAreStillProbedOnceTheInstallsAreKnown() {
        var args: [String] = []
        let model = ToolchainModel(
            resolve: { agent in
                Thread.sleep(forTimeInterval: 0.5)          // detection is slow…
                return ToolchainResolution(
                    agent: agent,
                    installs: [AgentInstall(path: "/bin/\(agent.binaryName)", origin: .path(rank: 0), version: "1.2.3")],
                    chosen: AgentInstall(path: "/bin/\(agent.binaryName)", origin: .path(rank: 0), version: "1.2.3"))
            },
            probe: { _, probed -> (version: String?, failure: String?, details: String?) in
                probed.contains("--bogus")
                    ? (version: nil, failure: "error: unexpected argument '--bogus' found", details: nil)
                    : (version: "1.2.3", failure: nil, details: nil)
            })
        model.override = { _ in "" }
        model.arguments = { _ in args }

        model.detect()                    // …and starts before the user types anything
        args = ["--bogus"]
        model.recheckUserSettings()       // lands while `resolutions` is still empty

        let deadline = Date().addingTimeInterval(5)
        while model.argumentComplaint(for: .claude) == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertNotNil(model.argumentComplaint(for: .claude),
                        "the rejected argument was never probed against the detected binary")
        XCTAssertFalse(model.canLaunch(.claude))
    }

    // MARK: Arguments

    /// Extra args ride on *every* launch, so a flag the CLI rejects breaks every
    /// session — even when the binary itself is perfectly healthy.
    func testRejectedArgumentsAreReportedAgainstAHealthyBinary() {
        let model = model([.claude: resolution(.claude, [install("/Users/x/.local/bin/claude")])],
                          arguments: [.claude: ["--bogus"]],
                          rejected: ["--bogus"])

        let warnings = model.warnings(defaultAgent: .claude)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].isFatal)
        XCTAssertTrue(warnings[0].message.contains("--bogus"))
        XCTAssertEqual(model.argumentComplaint(for: .claude)?.arguments, ["--bogus"])
    }

    func testAcceptedArgumentsAreSilent() {
        let model = model([.claude: resolution(.claude, [install("/Users/x/.local/bin/claude")])],
                          arguments: [.claude: ["--dangerously-skip-permissions"]])
        XCTAssertTrue(model.warnings(defaultAgent: .claude).isEmpty)
        XCTAssertNil(model.argumentComplaint(for: .claude))
    }

    /// The complaint is bound to the arguments it was made about, so fixing the text
    /// clears the error instead of leaving it accusing text that no longer exists.
    func testArgumentComplaintGoesStaleWhenTheArgumentsChange() {
        let model = model([.claude: resolution(.claude, [install("/Users/x/.local/bin/claude")])],
                          arguments: [.claude: ["--bogus"]],
                          rejected: ["--bogus"])
        XCTAssertNotNil(model.argumentComplaint(for: .claude))

        model.arguments = { _ in ["--fine"] }
        XCTAssertNil(model.argumentComplaint(for: .claude))
    }

    /// A broken binary fails *every* invocation, including the one that asks "do you
    /// accept these flags?". Reporting that as an argument problem would accuse a
    /// perfectly good flag of a crash thrown by Node. One fault, one report.
    func testABrokenBinaryIsNotBlamedOnTheArguments() {
        let model = model([.claude: resolution(.claude, [install("/Users/x/.local/bin/claude")])],
                          overrides: [.claude: "/custom/claude"],
                          broken: ["/custom/claude"],
                          arguments: [.claude: ["--dangerously-skip-permissions"]])

        XCTAssertNil(model.argumentComplaint(for: .claude))
        let warnings = model.warnings(defaultAgent: .claude)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].message.contains("/custom/claude"))
        XCTAssertFalse(warnings[0].message.contains("arguments"))
    }

    /// Arguments are checked against the binary Temple will really launch — the
    /// override, when there is one, not whatever detection would have picked.
    func testArgumentsAreCheckedAgainstTheOverriddenBinary() {
        let model = model([.claude: resolution(.claude, [install("/Users/x/.local/bin/claude")])],
                          overrides: [.claude: "/custom/claude"],
                          arguments: [.claude: ["--bogus"]],
                          rejected: ["--bogus"])
        XCTAssertEqual(model.argumentComplaint(for: .claude)?.binary, "/custom/claude")
    }

    /// Working around a broken install is worth a word, but not an alarm.
    func testWarnsWhenItHadToSkipABrokenInstall() {
        let model = model([.claude: resolution(.claude, [
            install("/opt/homebrew/bin/claude", rank: 0, failure: "TypeError: …"),
            install("/Users/x/.local/bin/claude", rank: 1),
        ])])
        let warnings = model.warnings(defaultAgent: .claude)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertFalse(warnings[0].isFatal)
        XCTAssertTrue(warnings[0].message.contains("/opt/homebrew/bin/claude"))
    }

    func testFatalWhenNothingRuns() {
        let model = model([.claude: resolution(.claude, [
            install("/opt/homebrew/bin/claude", failure: "TypeError: …"),
        ])])
        XCTAssertTrue(model.warnings(defaultAgent: .claude).contains { $0.isFatal })
    }

    /// Not everyone uses both agents. "You don't have codex" is not a problem for
    /// someone who never asked for codex — nagging about it would train them to
    /// ignore the banner that matters.
    func testSilentAboutAnAgentYouNeitherUseNorInstalled() {
        let model = model([
            .claude: resolution(.claude, [install("/Users/x/.local/bin/claude")]),
            .codex: resolution(.codex, []),
        ])
        XCTAssertTrue(model.warnings(defaultAgent: .claude).isEmpty)
        XCTAssertEqual(model.warnings(defaultAgent: .codex).count, 1)
    }

    /// But an agent you *have* installed that can't run is always worth saying —
    /// every other tool on the machine resolves that same broken binary.
    func testSpeaksUpAboutABrokenNonDefaultAgent() {
        let model = model([
            .claude: resolution(.claude, [install("/Users/x/.local/bin/claude")]),
            .codex: resolution(.codex, [install("/opt/homebrew/bin/codex", failure: "crashed")]),
        ])
        let warnings = model.warnings(defaultAgent: .claude)
        XCTAssertEqual(warnings.map(\.agent), [.codex])
        XCTAssertTrue(warnings[0].isFatal)
    }
}
