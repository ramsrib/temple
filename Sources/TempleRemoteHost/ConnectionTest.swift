import Combine
import Foundation
import TempleCore

/// One Test connection, as the sheet runs it (docs/designs/remote-ssh.md
/// sections 2 and 7, as built in phase 0):
///
/// 1. **Connect, interactively.** The sheet's terminal runs the user's own
///    ssh and nothing else: `ssh <arguments> -- <name> true`, with
///    `ControlMaster=auto`, so it creates the master. Whatever ssh asks is
///    answered there, and whatever it says stays on screen.
/// 2. **When the terminal's process ends**, however it ends, the evidence
///    is the master the connect created, not an exit status (libghostty
///    launches through `/usr/bin/login`, whose status is not ssh's):
///    `ssh -O check` on Temple's socket. A master is up: every check runs
///    as a `BatchMode` query over it through `RemoteExec`, with its
///    deadline: the remote environment, `claude`, `codex`, tmux's version
///    and the launch chain detached on a throwaway socket, logind. No
///    master: no check, no second connection, "Couldn't connect. See ssh's
///    message above."
///
/// The attached-client check (a terminal opening under tmux with
/// `xterm-256color` outside and `tmux-256color` in the pane) is phase 1a's
/// acceptance. Nothing here is persisted.
@MainActor
public final class ConnectionTest: ObservableObject, Identifiable {
    public enum Phase: Equatable, Sendable {
        case connecting
        case checking
        case finished
        case failed
    }

    public enum Verdict: Equatable, Sendable {
        case running, ok, problem, advisory, info
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public var verdict: Verdict
        public var line: String
        /// The tool's own output, shown on request.
        public var output: String?

        /// The row with what its check ran and printed, unless it has its own.
        func showing(_ text: String) -> Row {
            var row = self
            if row.output?.isEmpty ?? true, !text.isEmpty { row.output = text }
            return row
        }
    }

    public nonisolated let id = UUID()
    public let record: RemoteHostRecord
    /// The connection the test uses, built once `ssh -G` has said where the
    /// host resolves to (nil before `start()` finishes).
    public private(set) var connection: SSHConnection?
    @Published public private(set) var phase: Phase = .connecting
    @Published public private(set) var rows: [Row] = []
    @Published public private(set) var failure: SSHFailure?
    @Published public private(set) var summary: HostTestSummary?
    /// Whether a query has run on the host over the master. Until it has,
    /// nothing may say "connected": a master alone is a local process.
    @Published public private(set) var connectionConfirmed = false
    /// `ssh -G`'s view of the host, for the details line: the same answer
    /// the connection's socket was keyed by.
    @Published public private(set) var resolution: [String: String] = [:]

    /// Told once, when the test ends either way.
    public var onFinished: ((HostTestSummary) -> Void)?

    /// What `ssh -G` said, or why it could not say.
    public enum Resolution: Sendable {
        case resolved([String: String])
        case failed(String)
    }

    private let stateDirectory: URL
    private let sshPath: String
    private let makeExec: (SSHConnection, String?) -> RemoteExec
    private let resolve: ([String]) async -> Resolution
    private var task: Task<Void, Never>?
    private var started = false
    private var cancelled = false

    /// `makeExec(connection, path)` builds an exec over that connection's
    /// master with that PATH (nil: ssh's default environment). `resolve`
    /// runs `ssh -G` (the argv it is given).
    public init(record: RemoteHostRecord, stateDirectory: URL, sshPath: String,
                makeExec: @escaping (SSHConnection, String?) -> RemoteExec,
                resolve: @escaping ([String]) async -> Resolution = ConnectionTest.sshResolve) {
        self.record = record
        self.stateDirectory = stateDirectory
        self.sshPath = sshPath
        self.makeExec = makeExec
        self.resolve = resolve
    }

    /// `ssh -G`, run locally (no connection), as key/value pairs.
    public nonisolated static func sshResolve(_ argv: [String]) async -> Resolution {
        do {
            let output = try await ProcessRunner.run(argv[0], Array(argv.dropFirst()), deadline: 5)
            guard output.status == 0 else {
                return .failed(RemoteOutput.firstLine(output.stderr) ?? "ssh -G exited with status \(output.status)")
            }
            return .resolved(parseResolution(output.stdout))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// What the terminal runs: the user's ssh, connecting interactively and
    /// creating the master. `/usr/bin/env` heads it because the terminal
    /// execs its command as a login process, which ssh need not be. Empty
    /// until `start()` has built the connection.
    public var surfaceArgv: [String] {
        guard let connection else { return [] }
        return ["/usr/bin/env"] + connection.argv(.interactive, remoteCommand: "true")
    }

    /// The terminal's working directory: the user's home, never a remote path.
    public var surfaceDirectory: String { NSHomeDirectory() }

    /// Asks `ssh -G` where the host goes, builds the connection keyed by
    /// that answer, prepares the master's socket directory and clears a
    /// stale socket (positive proof only). False, with the test failed and
    /// saying why, when any of it fails: the terminal must then not start.
    @discardableResult
    public func start() async -> Bool {
        guard !started, phase == .connecting else { return false }
        started = true
        let provisional = SSHConnection(record: record, stateDirectory: stateDirectory, sshPath: sshPath)
        let answer = await resolve(provisional.resolutionArgv)
        // Closed while ssh -G ran: nothing is prepared, nothing starts.
        guard !Task.isCancelled, !cancelled, phase == .connecting else { return false }
        guard case .resolved(let values) = answer else {
            if case .failed(let line) = answer {
                finish(failure: .localSetup("ssh couldn't read its configuration for \(record.name): \(line)"))
            }
            return false
        }
        resolution = values
        let connection = SSHConnection(record: record, stateDirectory: stateDirectory, sshPath: sshPath, resolved: values)
        do {
            try connection.prepareSocketDirectory()
        } catch {
            finish(failure: .localSetup(error.localizedDescription))
            return false
        }
        SocketHygiene.removeIfNothingListens(connection.controlPath)
        self.connection = connection
        return true
    }

    /// The terminal's process ended, by any status and in any way. Its
    /// status proves nothing; whether the connect left a master on
    /// Temple's socket does, and then the first query over it decides.
    /// Called again, it does nothing.
    public func terminalExited() {
        guard let connection, phase == .connecting, task == nil else { return }
        let argv = connection.masterCheckArgv
        task = Task { [weak self] in
            let output = try? await ProcessRunner.run(argv[0], Array(argv.dropFirst()), deadline: Self.masterCheckDeadline)
            guard let self, !Task.isCancelled else { return }
            guard output?.status == 0 else {
                self.finish(failure: .connectFailed)
                return
            }
            self.phase = .checking
            await self.runChecks(connection)
        }
    }

    /// How long `ssh -O check` may take (a local socket).
    nonisolated static let masterCheckDeadline: TimeInterval = 5

    /// The sheet closed: outstanding queries are cancelled (each kills its
    /// own ssh client). The terminal's client is the sheet's to terminate;
    /// the master is left to expire.
    public func cancel() {
        cancelled = true
        task?.cancel()
        task = nil
        if phase == .connecting || phase == .checking { onFinished = nil }
    }

    // MARK: The checks

    private func runChecks(_ connection: SSHConnection) async {
        set(Row(id: "shell", verdict: .running, line: "Login shell: reading its PATH…"))
        let environment = await RemoteEnvironment.resolve(using: makeExec(connection, nil))
        if Task.isCancelled { return }
        // A master answering proves a local process; this query running on
        // the host is what proves the connection.
        guard environment.reachedHost else {
            rows.removeAll { $0.id == "shell" }
            finish(failure: .unconfirmed(environment.problem ?? "no answer"))
            return
        }
        connectionConfirmed = true
        summaryDraft.environment = environment
        if let path = environment.path {
            set(Row(id: "shell", verdict: .ok, line: "Login shell: \(environment.shell.isEmpty ? "unknown" : environment.shell), PATH read.",
                    output: path))
        } else {
            set(Row(id: "shell", verdict: .problem,
                    line: "Couldn't read the login shell's PATH: \(environment.problem ?? "no answer"); using ssh's default environment.",
                    output: environment.problem ?? "The login shell printed no PATH."))
        }
        let exec = makeExec(connection, environment.path)

        set(Row(id: "claude", verdict: .running, line: "claude: checking…"))
        let claude = await ToolCheck.run("claude", using: exec)
        if Task.isCancelled { return }
        summaryDraft.claude = claude
        set(Self.row("claude", claude, path: environment.path))

        set(Row(id: "codex", verdict: .running, line: "codex: checking…"))
        let codex = await ToolCheck.run("codex", using: exec)
        if Task.isCancelled { return }
        summaryDraft.codex = codex
        set(Self.row("codex", codex, path: environment.path))

        set(Row(id: "tmux", verdict: .running, line: "tmux: running the detached check…"))
        let (tmux, tmuxShown) = await TmuxCheck.runShowing(nonce: RemoteQuoting.nonce(), using: exec)
        if Task.isCancelled { return }
        summaryDraft.tmux = tmux
        set(Self.row(tmux).showing(tmuxShown.isEmpty ? "the tmux check printed nothing" : tmuxShown))

        set(Row(id: "logind", verdict: .running, line: "logind: checking…"))
        let (logind, logindShown) = await LogindCheck.runShowing(using: exec)
        if Task.isCancelled { return }
        summaryDraft.logind = logind
        set(Self.row(logind).showing(logindShown.isEmpty ? "the logind check printed nothing" : logindShown))

        // The identity of the connection the checks ran over: the socket
        // was keyed by this very resolution.
        if let user = connection.resolved["user"], let host = connection.resolved["hostname"] {
            summaryDraft.connectedAs = "\(user)@\(host)"
        }
        finish()
    }

    private var summaryDraft = HostTestSummary()

    private func finish(failure: SSHFailure? = nil) {
        if let failure {
            self.failure = failure
            summaryDraft = HostTestSummary(failure: failure)
            phase = .failed
        } else {
            phase = .finished
        }
        summary = summaryDraft
        onFinished?(summaryDraft)
        onFinished = nil
    }

    private func set(_ row: Row) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row } else { rows.append(row) }
    }

    // MARK: Rows

    /// Every finished row carries its own words for "Show output": the
    /// tool's output, the PATH a missing one was looked for on, or why the
    /// check couldn't run.
    nonisolated static func row(_ binary: String, _ check: ToolCheck, path: String? = nil) -> Row {
        switch check {
        case .runs(let path, let version, let output):
            Row(id: binary, verdict: .ok,
                line: "\(binary): \(AgentInstall.versionNumber(in: version) ?? version) at \(path)",
                output: output.isEmpty ? "\(path) --version printed nothing (exit status 0)" : output)
        case .missing:
            Row(id: binary, verdict: .problem, line: "\(binary): not on PATH",
                output: "command -v \(binary) found nothing on " + (path.map { "this PATH:\n\($0)" } ?? "ssh's default PATH."))
        case .fails(let path, let status, let line, let output):
            Row(id: binary, verdict: .problem, line: "\(binary): at \(path), didn't run: \(line)",
                output: output.isEmpty ? "\(path) --version printed nothing (exit status \(status))" : output)
        case .notChecked(let reason):
            Row(id: binary, verdict: .info, line: "\(binary): not checked: \(reason)", output: reason)
        }
    }

    nonisolated static func row(_ check: TmuxCheck) -> Row {
        switch check {
        case .accepted(let version, true):
            Row(id: "tmux", verdict: .ok, line: "tmux: \(version), detached tmux check passed")
        case .accepted(let version, false):
            Row(id: "tmux", verdict: .advisory,
                line: "tmux: \(version), detached tmux check passed; allow-passthrough: not on this version, clipboard passthrough off")
        case .tooOld(let version):
            Row(id: "tmux", verdict: .problem, line: "tmux: \(version): Temple needs tmux 3.2 or newer to keep sessions running")
        case .refused(let version, let command, let line):
            Row(id: "tmux", verdict: .problem, line: "tmux: \(version), " + (command.map { "`\($0)`: " } ?? "") + line)
        case .missing:
            Row(id: "tmux", verdict: .problem, line: "tmux: not on PATH")
        case .notChecked(let reason):
            Row(id: "tmux", verdict: .info, line: "tmux: not checked: \(reason)")
        }
    }

    nonisolated static func row(_ check: LogindCheck) -> Row {
        switch check {
        case .killsUserProcesses(true):
            Row(id: "logind", verdict: .advisory,
                line: "This host ends your processes when your last login ends (KillUserProcesses=yes). Sessions won't survive a disconnect unless lingering is enabled (loginctl enable-linger).")
        case .killsUserProcesses(false):
            Row(id: "logind", verdict: .ok, line: "logind: KillUserProcesses=no")
        case .notAvailable(let reason):
            Row(id: "logind", verdict: .info, line: "logind: not checked: \(reason)")
        }
    }

    /// `ssh -G` output as key → first value.
    public nonisolated static func parseResolution(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, values[parts[0]] == nil else { continue }
            values[parts[0]] = parts[1]
        }
        return values
    }
}
