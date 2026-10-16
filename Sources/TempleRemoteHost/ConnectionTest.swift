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
    }

    public nonisolated let id = UUID()
    public let record: RemoteHostRecord
    public let connection: SSHConnection
    @Published public private(set) var phase: Phase = .connecting
    @Published public private(set) var rows: [Row] = []
    @Published public private(set) var failure: SSHFailure?
    @Published public private(set) var summary: HostTestSummary?
    /// `ssh -G`'s view of the host, for the details line.
    @Published public private(set) var resolution: [String: String] = [:]

    /// Told once, when the test ends either way.
    public var onFinished: ((HostTestSummary) -> Void)?

    private let makeExec: (String?) -> RemoteExec
    private let resolve: () async -> [String: String]
    private var task: Task<Void, Never>?
    private var started = false

    /// `makeExec(path)` builds a query exec with that PATH (nil: ssh's
    /// default environment). `resolve` runs `ssh -G`.
    public init(record: RemoteHostRecord, connection: SSHConnection,
                makeExec: @escaping (String?) -> RemoteExec,
                resolve: @escaping () async -> [String: String]) {
        self.record = record
        self.connection = connection
        self.makeExec = makeExec
        self.resolve = resolve
    }

    /// What the terminal runs: the user's ssh, connecting interactively and
    /// creating the master. `/usr/bin/env` heads it because the terminal
    /// execs its command as a login process, which ssh need not be.
    public var surfaceArgv: [String] {
        ["/usr/bin/env"] + connection.argv(.interactive, remoteCommand: "true")
    }

    /// The terminal's working directory: the user's home, never a remote path.
    public var surfaceDirectory: String { NSHomeDirectory() }

    /// Prepares the master's socket directory and clears a stale socket
    /// (positive proof only). False, with the test failed and saying why,
    /// when the directory can't be used: the terminal must then not start.
    @discardableResult
    public func start() -> Bool {
        guard !started, phase == .connecting else { return false }
        started = true
        do {
            try connection.prepareSocketDirectory()
        } catch {
            finish(failure: .localSetup(error.localizedDescription))
            return false
        }
        SocketHygiene.removeIfNothingListens(connection.controlPath)
        return true
    }

    /// The terminal's process ended, by any status and in any way. Its
    /// status proves nothing; whether the connect left a master on
    /// Temple's socket does. Called again, it does nothing.
    public func terminalExited() {
        guard started, phase == .connecting, task == nil else { return }
        let argv = connection.masterCheckArgv
        task = Task { [weak self] in
            let output = try? await ProcessRunner.run(argv[0], Array(argv.dropFirst()), deadline: Self.masterCheckDeadline)
            guard let self, !Task.isCancelled else { return }
            guard output?.status == 0 else {
                self.finish(failure: .connectFailed)
                return
            }
            self.phase = .checking
            await self.runChecks()
        }
    }

    /// How long `ssh -O check` may take (a local socket).
    nonisolated static let masterCheckDeadline: TimeInterval = 5

    /// The sheet closed: outstanding queries are cancelled (each kills its
    /// own ssh client). The terminal's client is the sheet's to terminate;
    /// the master is left to expire.
    public func cancel() {
        task?.cancel()
        task = nil
        if phase == .connecting || phase == .checking { onFinished = nil }
    }

    // MARK: The checks

    private func runChecks() async {
        async let resolution = resolve()

        set(Row(id: "shell", verdict: .running, line: "Login shell: reading its PATH…"))
        let environment = await RemoteEnvironment.resolve(using: makeExec(nil))
        if Task.isCancelled { return }
        summaryDraft.environment = environment
        if let path = environment.path {
            set(Row(id: "shell", verdict: .ok, line: "Login shell: \(environment.shell.isEmpty ? "unknown" : environment.shell), PATH read.",
                    output: path))
        } else {
            set(Row(id: "shell", verdict: .problem,
                    line: "Couldn't read the login shell's PATH: \(environment.problem ?? "no answer"); using ssh's default environment."))
        }
        let exec = makeExec(environment.path)

        set(Row(id: "claude", verdict: .running, line: "claude: checking…"))
        let claude = await ToolCheck.run("claude", using: exec)
        if Task.isCancelled { return }
        summaryDraft.claude = claude
        set(Self.row("claude", claude))

        set(Row(id: "codex", verdict: .running, line: "codex: checking…"))
        let codex = await ToolCheck.run("codex", using: exec)
        if Task.isCancelled { return }
        summaryDraft.codex = codex
        set(Self.row("codex", codex))

        set(Row(id: "tmux", verdict: .running, line: "tmux: running the detached check…"))
        let tmux = await TmuxCheck.run(nonce: RemoteQuoting.nonce(), using: exec)
        if Task.isCancelled { return }
        summaryDraft.tmux = tmux
        set(Self.row(tmux))

        set(Row(id: "logind", verdict: .running, line: "logind: checking…"))
        let logind = await LogindCheck.run(using: exec)
        if Task.isCancelled { return }
        summaryDraft.logind = logind
        set(Self.row(logind))

        let resolved = await resolution
        if Task.isCancelled { return }
        self.resolution = resolved
        if let user = resolved["user"], let host = resolved["hostname"] { summaryDraft.connectedAs = "\(user)@\(host)" }
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

    nonisolated static func row(_ binary: String, _ check: ToolCheck) -> Row {
        switch check {
        case .runs(let path, let version, let output):
            Row(id: binary, verdict: .ok,
                line: "\(binary): \(AgentInstall.versionNumber(in: version) ?? version) at \(path)", output: output)
        case .missing:
            Row(id: binary, verdict: .problem, line: "\(binary): not on PATH")
        case .fails(let path, _, let line, let output):
            Row(id: binary, verdict: .problem, line: "\(binary): at \(path), didn't run: \(line)", output: output)
        case .notChecked(let reason):
            Row(id: binary, verdict: .info, line: "\(binary): not checked: \(reason)")
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
