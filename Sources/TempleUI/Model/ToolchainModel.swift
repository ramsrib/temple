import Foundation
import TempleCore

/// Which agent CLIs this machine has, which one Temple will launch, and what's
/// wrong with the others — kept live for Settings and the launcher banner.
///
/// Nothing here is ever persisted. Detection is recomputed each launch and lives
/// only in memory, precisely so it can never be mistaken later for something the
/// user chose (see `SettingsStore`). The user's choice is the override, and the
/// override always wins — Temple's job is then to *verify* it and say so if it's
/// broken, not to quietly substitute its own answer.
///
/// Detection runs a process per install (`--version`), so it happens off the main
/// thread and off the launch path: a session opened before detection settles uses
/// the shell's own answer, and the verified one takes over the moment it lands.
@MainActor
public final class ToolchainModel: ObservableObject {
    @Published public private(set) var resolutions: [Agent: ToolchainResolution] = [:]
    /// The result of running the user's override, when they've set one.
    @Published public private(set) var overrideChecks: [Agent: AgentInstall] = [:]
    /// The CLI's objection to the user's extra arguments, if it raised one. Only
    /// ever a complaint — see `AgentToolchain.check`, a silent pass proves nothing.
    @Published public private(set) var argumentComplaints: [Agent: ArgumentComplaint] = [:]
    @Published public private(set) var isDetecting = false

    /// What the user typed in Settings, if anything.
    public var override: (Agent) -> String = { _ in "" }
    /// The extra arguments the user wants on every launch.
    public var arguments: (Agent) -> [String] = { _ in [] }

    private let resolve: @Sendable (Agent) -> ToolchainResolution
    private let probe: @Sendable (String, [String]) -> (version: String?, failure: String?, details: String?)

    public init(resolve: @escaping @Sendable (Agent) -> ToolchainResolution = { AgentToolchain.resolve($0) },
                probe: @escaping @Sendable (String, [String]) -> (version: String?, failure: String?, details: String?)
                    = { AgentToolchain.probe($0, arguments: $1) }) {
        self.resolve = resolve
        self.probe = probe
    }

    /// Probing is slow and runs off the main actor, so answers can come back out of
    /// order: a startup detection that began before the user typed an override can
    /// land *after* the recheck that found the override broken, and clobber it — the
    /// warning vanishes while the broken override is still what we launch. Every
    /// publication therefore carries the generation it was computed from, and a stale
    /// one is dropped.
    ///
    /// Two counters, because the two halves go stale for different reasons: the
    /// machine's installs (`detectGeneration`) and what the user typed
    /// (`userGeneration`). A slow detect can still publish its resolutions even if the
    /// user has since edited a field — it just may not publish its view of that field.
    private var detectGeneration = 0
    private var userGeneration = 0

    public func detect() {
        guard !isDetecting else { return }
        isDetecting = true
        detectGeneration += 1
        userGeneration += 1
        let detectGen = detectGeneration
        let userGen = userGeneration
        let resolve = self.resolve
        let probe = self.probe
        // Read the user's settings on the main actor; the probing happens off it.
        let overrides = currentOverrides()
        let arguments = currentArguments()
        // A plain dispatch queue, NOT `Task.detached`: probing blocks a thread for as
        // long as the CLI takes to answer, and Swift's cooperative pool has one thread
        // per core. Parking blocking work there starves every other task in the process
        // — including the hop back to the main actor that publishes this very result.
        Self.work.async {
            let found = Agent.allCases.reduce(into: [Agent: ToolchainResolution]()) { acc, agent in
                acc[agent] = resolve(agent)
            }
            let checked = Self.check(overrides, with: probe)
            let complaints = Self.complaints(about: arguments,
                                             launchPaths: Self.healthyLaunchPaths(overrides: overrides,
                                                                                  overrideChecks: checked,
                                                                                  resolutions: found),
                                             with: probe)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if detectGen == self.detectGeneration {
                    self.resolutions = found
                    self.isDetecting = false
                }
                guard userGen == self.userGeneration else {
                    // The user edited a field while we were probing, so their verdict
                    // was computed against a toolchain we hadn't resolved yet: with no
                    // known binary, `complaints` had nothing to ask, and its empty
                    // result would read as "your arguments are fine" forever. Now that
                    // the installs ARE known, redo the user's half against them.
                    self.recheckUserSettings()
                    return
                }
                self.overrideChecks = checked
                self.argumentComplaints = complaints
            }
        }
    }

    /// Serial: two detections at once would only make the machine slower, and their
    /// results are ordered by generation anyway.
    private static let work = DispatchQueue(label: "com.sriramb.temple.toolchain", qos: .userInitiated)

    private func currentOverrides() -> [Agent: String] {
        Agent.allCases.reduce(into: [Agent: String]()) { acc, agent in
            let path = override(agent)
            if !path.isEmpty { acc[agent] = path }
        }
    }

    private func currentArguments() -> [Agent: [String]] {
        Agent.allCases.reduce(into: [Agent: [String]]()) { acc, agent in
            let args = arguments(agent)
            if !args.isEmpty { acc[agent] = args }
        }
    }

    /// The binary we'd launch for each agent — but *only* where that binary is
    /// known to work.
    ///
    /// A broken binary fails every invocation, including the one we'd use to ask
    /// "do you accept these flags?". Asking anyway makes the CLI's crash look like an
    /// objection to the user's arguments, and Settings ends up accusing a perfectly
    /// good `--dangerously-skip-permissions` of causing a crash it had nothing to do
    /// with. One fault, one report — the binary's.
    nonisolated private static func healthyLaunchPaths(overrides: [Agent: String],
                                                       overrideChecks: [Agent: AgentInstall],
                                                       resolutions: [Agent: ToolchainResolution]) -> [Agent: String] {
        Agent.allCases.reduce(into: [Agent: String]()) { acc, agent in
            if let override = overrides[agent] {
                if overrideChecks[agent]?.isUsable == true { acc[agent] = override }
            } else {
                acc[agent] = resolutions[agent]?.chosen?.path   // `chosen` is usable by construction
            }
        }
    }

    nonisolated private static func complaints(
        about arguments: [Agent: [String]],
        launchPaths: [Agent: String],
        with probe: @Sendable (String, [String]) -> (version: String?, failure: String?, details: String?)
    ) -> [Agent: ArgumentComplaint] {
        arguments.reduce(into: [Agent: ArgumentComplaint]()) { acc, entry in
            guard let path = launchPaths[entry.key] else { return }
            let result = probe(path, entry.value)
            guard let failure = result.failure else { return }   // silence proves nothing; only complaints count
            acc[entry.key] = ArgumentComplaint(arguments: entry.value,
                                               binary: path,
                                               failure: failure,
                                               details: result.details)
        }
    }

    nonisolated private static func check(_ overrides: [Agent: String],
                                          with probe: @Sendable (String, [String]) -> (version: String?, failure: String?, details: String?))
    -> [Agent: AgentInstall] {
        overrides.reduce(into: [Agent: AgentInstall]()) { acc, entry in
            let result = probe(entry.value, [])
            acc[entry.key] = AgentInstall(path: entry.value,
                                          origin: .knownLocation,
                                          version: result.version,
                                          failure: result.failure,
                                          details: result.details)
        }
    }

    public func resolution(for agent: Agent) -> ToolchainResolution? { resolutions[agent] }

    /// The override's health, when one is set — `nil` when the user hasn't chosen.
    ///
    /// The verdict is keyed to the exact path it was made about, so a check goes
    /// stale the instant the user edits the field. Showing a green tick against a
    /// path we never ran would be worse than showing nothing.
    public func overrideCheck(for agent: Agent) -> AgentInstall? {
        let path = override(agent)
        guard !path.isEmpty,
              let check = overrideChecks[agent],
              check.path == path else { return nil }
        return check
    }

    /// The CLI's objection to this agent's arguments, keyed to the exact arguments
    /// *and the exact binary* it objected to — so editing either invalidates the
    /// verdict rather than leaving a complaint standing against something the user has
    /// already changed. One CLI's "unexpected argument" says nothing about another's.
    public func argumentComplaint(for agent: Agent) -> ArgumentComplaint? {
        guard let complaint = argumentComplaints[agent],
              complaint.arguments == arguments(agent),
              complaint.binary == launchPath(for: agent) else { return nil }
        return complaint
    }

    /// Re-run just the user's own settings (on commit of a Settings field) — no need
    /// to re-probe every install on the machine to answer "does this one work?".
    public func recheckUserSettings() {
        userGeneration += 1
        let userGen = userGeneration
        let probe = self.probe
        let overrides = currentOverrides()
        let arguments = currentArguments()
        let resolutions = self.resolutions
        Self.work.async {
            let checked = Self.check(overrides, with: probe)
            let complaints = Self.complaints(about: arguments,
                                             launchPaths: Self.healthyLaunchPaths(overrides: overrides,
                                                                                  overrideChecks: checked,
                                                                                  resolutions: resolutions),
                                             with: probe)
            Task { @MainActor [weak self] in
                guard let self, userGen == self.userGeneration else { return }
                self.overrideChecks = checked
                self.argumentComplaints = complaints
            }
        }
    }

    /// The binary to launch. The user's override outranks detection — including a
    /// broken override, which we launch anyway and complain about loudly. Silently
    /// substituting our own pick for theirs is how a tool loses trust.
    public func launchPath(for agent: Agent) -> String {
        let override = override(agent)
        if !override.isEmpty { return override }
        if let chosen = resolutions[agent]?.chosen { return chosen.path }
        return LoginShellEnvironment.locate(agent.binaryName) ?? agent.binaryName
    }

    /// Nothing we know of is wrong with *how* we'd launch this agent: the binary we
    /// picked runs, the user's override (if they set one) runs, and the CLI raised no
    /// objection to their arguments.
    ///
    /// This is what tells an agent that died at launch apart from an agent Temple
    /// launched wrongly. A `claude` that starts, parses its flags, and says "no
    /// conversation found with session ID …" did not fail to start — it started and
    /// told us something. Sending that user to Settings to check a command that is
    /// provably fine wastes their time, and teaches them to ignore the warning for the
    /// day the command really *is* the problem.
    ///
    /// Unknowns count as fine: while detection is still in flight, or when the user
    /// pinned a path we haven't probed, we take their word rather than accuse them.
    public func canLaunch(_ agent: Agent) -> Bool {
        if argumentComplaint(for: agent) != nil { return false }
        if let check = overrideCheck(for: agent) { return check.isUsable }
        if !override(agent).isEmpty { return true }          // their explicit choice, unprobed
        guard let resolution = resolutions[agent] else { return true }   // detection hasn't landed
        return resolution.chosen != nil
    }

    /// Problems worth interrupting the user for, as opposed to merely reporting in
    /// Settings.
    public func warnings(defaultAgent: Agent) -> [ToolchainWarning] {
        var warnings: [ToolchainWarning] = []
        if let shell = LoginShellEnvironment.problem {
            warnings.append(ToolchainWarning(agent: nil, message: shell, isFatal: true))
        }
        for agent in Agent.allCases {
            // An override means the user has decided. Narrating what detection
            // *would* have picked is noise at best and a lie at worst ("using X
            // instead" — we aren't). The only thing worth saying is if their
            // choice doesn't run.
            if let check = overrideCheck(for: agent) {
                if let failure = check.failure {
                    warnings.append(ToolchainWarning(
                        agent: agent,
                        message: "\(agent.displayName) is set to \(check.path), which doesn't run: \(failure)",
                        isFatal: true))
                }
                continue
            }
            guard let resolution = resolutions[agent], let problem = resolution.problem else { continue }
            // An agent they neither use nor installed isn't a problem — nagging
            // about it trains them to ignore the banner that matters.
            guard !resolution.installs.isEmpty || agent == defaultAgent else { continue }
            warnings.append(ToolchainWarning(agent: agent,
                                             message: problem,
                                             isFatal: resolution.chosen == nil))
        }
        // Arguments go on *every* launch, so a rejected flag breaks every session —
        // worth saying even when the binary itself is perfectly fine.
        for agent in Agent.allCases {
            guard let complaint = argumentComplaint(for: agent) else { continue }
            warnings.append(ToolchainWarning(
                agent: agent,
                message: "\(agent.displayName) rejects the arguments you set: \(complaint.failure)",
                isFatal: true))
        }
        return warnings
    }
}

/// A CLI's own words about why it won't take the user's extra arguments.
public struct ArgumentComplaint: Equatable, Sendable {
    public let arguments: [String]
    public let binary: String
    public let failure: String
    public let details: String?
}

public struct ToolchainWarning: Identifiable, Equatable, Sendable {
    /// `nil` when the problem is the environment itself, not one agent.
    public let agent: Agent?
    public let message: String
    /// Temple can't launch this at all, as opposed to having worked around it.
    public let isFatal: Bool

    public var id: String { (agent?.rawValue ?? "environment") + message }
}
