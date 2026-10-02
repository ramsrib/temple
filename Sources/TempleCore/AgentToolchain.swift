import Foundation

/// One installed copy of an agent CLI, and whether it actually runs.
public struct AgentInstall: Equatable, Sendable, Identifiable {
    /// Where the install was found. Ordering within a resolution follows this:
    /// PATH entries first, in the shell's own order, then anything we only found
    /// by looking in the usual places.
    public enum Origin: Equatable, Sendable {
        /// On the user's `PATH` — `rank` is its position, so the shell's
        /// precedence survives into our list.
        case path(rank: Int)
        /// A well-known install directory that is *not* on the user's `PATH`.
        /// Usable as a last resort, never preferred: if it isn't on their PATH,
        /// it isn't what they'd get by typing the command.
        case knownLocation
    }

    public let path: String
    public let origin: Origin
    /// Whatever `--version` printed, verbatim — we don't presume a format.
    public let version: String?
    /// Why this install can't be used; `nil` if it runs.
    public let failure: String?
    /// The raw output behind `failure`, for a user who wants the whole story.
    public let details: String?

    public var id: String { path }
    public var isUsable: Bool { failure == nil }

    /// The version number inside `version` ("2.1.288 (Claude Code)" →
    /// "2.1.288", "codex-cli 0.160.0" → "0.160.0"), for the places that name
    /// the agent already. Still no presumed format: when there is no number in
    /// it, the raw string comes back unchanged.
    public var versionNumber: String? { Self.versionNumber(in: version) }

    /// `versionNumber` for any `--version` output (an override's verdict
    /// carries only the string).
    public static func versionNumber(in version: String?) -> String? {
        guard let version else { return nil }
        guard let match = version.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else {
            return version
        }
        return String(version[match])
    }
    public var isOnPATH: Bool { if case .path = origin { return true }; return false }

    public init(path: String, origin: Origin, version: String? = nil,
                failure: String? = nil, details: String? = nil) {
        self.path = path
        self.origin = origin
        self.version = version
        self.failure = failure
        self.details = details
    }
}

/// What Temple found for one agent, what it will run, and what's wrong with the rest.
public struct ToolchainResolution: Equatable, Sendable {
    public let agent: Agent
    /// Every install found, in the order the user's shell would reach them.
    public let installs: [AgentInstall]
    /// The first install that actually runs — what Temple launches.
    public let chosen: AgentInstall?

    public init(agent: Agent, installs: [AgentInstall], chosen: AgentInstall?) {
        self.agent = agent
        self.installs = installs
        self.chosen = chosen
    }

    /// Installs the shell would have reached *before* the one we chose, which we
    /// skipped because they don't run. These are the interesting ones: the user's
    /// shell prefers them, so anything else that resolves the command — a hook, a
    /// script, another terminal — is still getting a broken binary.
    public var shadowedFailures: [AgentInstall] {
        guard let chosen, case .path(let winner) = chosen.origin else {
            return installs.filter { !$0.isUsable }
        }
        return installs.filter { install in
            guard case .path(let rank) = install.origin else { return false }
            return rank < winner && !install.isUsable
        }
    }

    /// A one-line account of anything the user should know, or `nil` when the
    /// toolchain is simply healthy.
    public var problem: String? {
        guard let chosen else {
            if installs.isEmpty {
                return "No \(agent.binaryName) found on your PATH."
            }
            return "Every \(agent.binaryName) found on this machine fails to run."
        }
        if let first = shadowedFailures.first {
            return "Skipped \(first.path) — it fails to run. Using \(chosen.path) instead."
        }
        if !chosen.isOnPATH {
            return "\(agent.binaryName) isn't on the PATH your shell gives Temple; found it at \(chosen.path)."
        }
        return nil
    }
}

/// Finds the agent CLIs on this machine and works out which one Temple can
/// actually launch.
///
/// The rule is: *ask, then verify, then report*. We ask the user's shell (never a
/// hardcoded list — see `LoginShellEnvironment`), we verify by running each
/// candidate rather than assuming a machine has a working one, and whatever we
/// couldn't use we hand to the UI to explain. Temple makes no assumption about
/// which Node, version manager, or CLI version is installed; a binary that runs
/// is good, one that doesn't is skipped and reported.
public enum AgentToolchain {

    /// Directories worth a look when the shell's `PATH` doesn't have the command.
    /// Deliberately consulted *last* — this is a fallback, not the source of truth.
    public static var knownLocations: [String] {
        ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// Run `<path> --version` and see what happens.
    public typealias Prober = @Sendable (String) -> (version: String?, failure: String?, details: String?)

    public static func resolve(_ agent: Agent,
                               path: String? = LoginShellEnvironment.adoptedPATH,
                               knownLocations: [String] = AgentToolchain.knownLocations,
                               isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                               probe: Prober = { AgentToolchain.probe($0) }) -> ToolchainResolution {
        let candidates = discover(agent.binaryName,
                                  path: path,
                                  knownLocations: knownLocations,
                                  isExecutable: isExecutable)
        let installs = candidates.map { candidate -> AgentInstall in
            let result = probe(candidate.path)
            return AgentInstall(path: candidate.path,
                                origin: candidate.origin,
                                version: result.version,
                                failure: result.failure,
                                details: result.details)
        }
        return ToolchainResolution(agent: agent,
                                   installs: installs,
                                   chosen: installs.first(where: \.isUsable))
    }

    /// Every executable named `name` the user could reach, in shell order.
    static func discover(_ name: String,
                         path: String?,
                         knownLocations: [String],
                         isExecutable: (String) -> Bool) -> [(path: String, origin: AgentInstall.Origin)] {
        var found: [(path: String, origin: AgentInstall.Origin)] = []
        var seen = Set<String>()

        // Relative PATH entries resolve against the spawning process's cwd, not
        // the shell's — skip them rather than resolve them to something the user
        // never meant.
        let dirs = (path ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
        for (rank, dir) in dirs.enumerated() {
            let candidate = "\(dir)/\(name)"
            guard isExecutable(candidate), seen.insert(canonical(candidate)).inserted else { continue }
            found.append((candidate, .path(rank: rank)))
        }
        for dir in knownLocations {
            let candidate = "\(dir)/\(name)"
            guard isExecutable(candidate), seen.insert(canonical(candidate)).inserted else { continue }
            found.append((candidate, .knownLocation))
        }
        return found
    }

    /// Two PATH entries can name the same binary (a symlinked `~/.local/bin` and
    /// its target); listing it twice would tell the user they have two installs.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: Probing

    private static let probeTimeout: TimeInterval = 15

    /// Ask a binary whether it accepts `arguments`, by running them alongside
    /// `--version` — a parse-only invocation that does no work.
    ///
    /// **This can only ever prove a failure, never a success.** Measured on the real
    /// CLIs: `codex --bogus-flag --version` exits 2 and names the bad flag, but
    /// `claude --bogus-flag --version` exits 0 and prints its version, because
    /// `--version` short-circuits before argument parsing. So a clean result here
    /// means "no objection", not "these flags are good" — and we must never render
    /// it as a tick. A bad `claude` flag can only be caught when the agent is
    /// actually launched, which is what the early-exit reporting in
    /// `OpenSessionsModel` is for.
    public static func check(_ path: String, arguments: [String]) -> (failure: String?, details: String?) {
        guard !arguments.isEmpty else { return (nil, nil) }
        let result = probe(path, arguments: arguments)
        return (result.failure, result.details)
    }

    /// Run the binary. This is the whole point: a `claude` that can't start is not a
    /// `claude` we can launch, and no amount of inspecting its path would have told
    /// us that. *Why* it can't start is its own business — a broken install, a
    /// runtime it can't work with, a build too old for its own config. Temple has no
    /// opinion on any of that and shouldn't: it asks the only question it can answer
    /// honestly, "does this run?", and reports whatever the binary says back.
    /// How a verdict starts when the binary never ran at all (the OS refused to
    /// exec it), as opposed to running and failing. Settings tells the two apart
    /// by this prefix — it is our own wording, not something parsed from a CLI.
    public static let launchFailurePrefix = "can't be launched: "

    public static func probe(_ path: String, arguments: [String] = []) -> (version: String?, failure: String?, details: String?) {
        // The command inherits our environment: `adoptLoginShellPATH` has already put
        // the user's PATH in it, so the binary resolves whatever it depends on exactly
        // as it will at launch. Probing under a different environment than we launch
        // under would make this test worthless.
        let result: CommandCapture.Result
        do {
            result = try CommandCapture.launch(path, arguments + ["--version"], timeout: probeTimeout)
        } catch {
            // The reason matters: the first exec of a freshly downloaded binary
            // by a freshly installed app can fail while macOS evaluates it, and
            // "can't be launched" alone reads as a broken install. The
            // localized text goes in the verdict; domain and code, which the
            // text can omit, go in the details for the next forensic look.
            let ns = ((error as? CommandCapture.LaunchFailure)?.underlying ?? error) as NSError
            return (nil, launchFailurePrefix + "\(error)", "\(ns.domain) \(ns.code)")
        }
        let text = result.output
        if result.timedOut {
            return (nil, "didn't respond to --version within \(Int(probeTimeout))s", text.isEmpty ? nil : text)
        }
        guard result.status == 0 else {
            return (nil, summarize(text) ?? "exited with status \(result.status)", text)
        }
        return (firstLine(text), nil, nil)
    }

    static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// The most useful line of a failed run — the one a person would point at.
    /// A crashing CLI tends to bury its cause in a stack trace, where the first line
    /// is blank or a banner and the last is some footer about the runtime. The first
    /// line that actually names an error beats both.
    static func summarize(_ text: String) -> String? {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let telling = lines.first { line in
            line.contains("Error") || line.contains("error") ||
            line.contains("not found") || line.lowercased().contains("cannot")
        }
        return truncate(telling ?? lines[lines.count - 1])
    }

    private static func truncate(_ line: String, limit: Int = 140) -> String {
        line.count <= limit ? line : String(line.prefix(limit)) + "…"
    }
}
