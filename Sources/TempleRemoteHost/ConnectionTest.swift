import Combine
import Foundation
import TempleCore

/// One Test connection, as the sheet runs it (docs/designs/remote-ssh.md
/// sections 2 and 7):
///
/// 1. **Connect, interactively**, in the sheet's own terminal:
///    `ssh -t <arguments> -- <name> true`, which creates the master. The
///    user answers whatever ssh asks there; the surface stays for the whole
///    test, so the fingerprint ssh showed is still on screen with the result.
/// 2. **On exit 0, check**: the remote environment, then (in the same
///    terminal, over the master) the launch chain with an attached client,
///    then as queries `claude`, `codex`, the chain detached, and logind.
///    Exit non-zero: no checks; ssh's own line, host-key cases apart.
///
/// The terminal runs `surfaceArgv`, a small local wrapper that records the
/// connect's exit status and stderr in `workDirectory`, then waits for the
/// attached step's argv (`go`, NUL-separated) and records its status. The
/// test watches those files. Nothing here is persisted.
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

    let workDirectory: URL
    private let makeExec: (String?) -> RemoteExec
    private let resolve: () async -> [String: String]
    private var task: Task<Void, Never>?
    private let pollInterval: Duration

    /// `makeExec(path)` builds a query exec with that PATH (nil: ssh's
    /// default environment). `resolve` runs `ssh -G`.
    public init(record: RemoteHostRecord, connection: SSHConnection, workDirectory: URL,
                makeExec: @escaping (String?) -> RemoteExec,
                resolve: @escaping () async -> [String: String],
                pollInterval: Duration = .milliseconds(200)) {
        self.record = record
        self.connection = connection
        self.workDirectory = workDirectory
        self.makeExec = makeExec
        self.resolve = resolve
        self.pollInterval = pollInterval
    }

    /// What the terminal runs. The environment is the surface's own, plus
    /// nothing: ssh asks on the terminal and nowhere else.
    public var surfaceArgv: [String] {
        ["/bin/sh", "-c", Self.wrapperScript, "temple-test", workDirectory.path]
            + connection.argv(.interactive, remoteCommand: "true")
    }

    /// The terminal's working directory: the user's home, never a remote path.
    public var surfaceDirectory: String { NSHomeDirectory() }

    /// Records the connect's status and stderr (stderr still reaches the
    /// terminal, through `tee`), then runs the attached step when Temple
    /// hands it over, then stays, so the terminal keeps what it showed until
    /// the sheet closes.
    static let wrapperScript = #"""
    r=$1; shift
    exec 3>&1
    ( "$@" 2>&1 1>&3; echo $? > "$r/connect.code" ) | tee "$r/connect.err" >&2
    mv "$r/connect.code" "$r/connect.status"
    if [ "$(cat "$r/connect.status")" = 0 ]; then
      i=0
      while [ ! -f "$r/go" ] && [ "$i" -lt 600 ]; do sleep 0.2; i=$((i+1)); done
      if [ -s "$r/go" ]; then
        xargs -0 -o sh -c '"$@"; echo $? > "$0/attach.code"; mv "$0/attach.code" "$0/attach.status"' "$r" < "$r/go"
      fi
    fi
    while :; do sleep 3600; done
    """#

    /// Clears a stale socket (positive proof only), then watches.
    public func start() {
        guard task == nil else { return }
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? connection.prepareSocketDirectory()
        SocketHygiene.removeIfNothingListens(connection.controlPath)
        task = Task { [weak self] in await self?.run() }
    }

    /// The sheet closed: stop watching and querying, and remove the work
    /// files. The terminal's client is the sheet's to terminate; the master
    /// is left to expire.
    public func cancel() {
        task?.cancel()
        task = nil
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// The terminal's process ended before the test did (the user closed
    /// it, or it failed to start).
    public func terminalEnded() {
        guard phase == .connecting || phase == .checking else { return }
        task?.cancel()
        task = nil
        if phase == .connecting {
            finish(failure: .other(firstLine: "the terminal closed before ssh finished"))
        } else {
            finish()
        }
    }

    // MARK: The run

    private func run() async {
        guard let status = await waitForStatus("connect.status", timeout: nil) else { return }
        if status != 0 {
            let stderr = (try? String(contentsOf: file("connect.err"), encoding: .utf8)) ?? ""
            finish(failure: SSHFailure.classify(stderr: stderr, status: status))
            return
        }
        phase = .checking
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

        // The attached chain, in the terminal, over the master.
        set(Row(id: "tmux", verdict: .running, line: "tmux: running the launch chain…"))
        let attachedNonce = RemoteQuoting.nonce()
        let attachArgv = ["/usr/bin/env", "TERM=xterm-256color"]
            + connection.argv(.interactive, remoteCommand: RemoteQuoting.shellCommand(
                script: TmuxCheck.attachedScript, args: [attachedNonce], path: environment.path))
        writeGo(attachArgv)
        let attachedStatus = await waitForStatus("attach.status", timeout: 30)
        if Task.isCancelled { return }

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

        let tmux = await TmuxCheck.run(nonce: RemoteQuoting.nonce(), attachedNonce: attachedNonce,
                                       attachedStatus: attachedStatus ?? 124, using: exec)
        if Task.isCancelled { return }
        summaryDraft.tmux = tmux
        set(Self.row(tmux))

        set(Row(id: "logind", verdict: .running, line: "logind: checking…"))
        let logind = await LogindCheck.run(using: exec)
        if Task.isCancelled { return }
        summaryDraft.logind = logind
        set(Self.row(logind))

        let resolved = await resolution
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

    private func file(_ name: String) -> URL { workDirectory.appendingPathComponent(name) }

    /// Polls for a status file; nil when cancelled or out of time.
    private func waitForStatus(_ name: String, timeout: TimeInterval?) async -> Int32? {
        let start = Date()
        while !Task.isCancelled {
            if let text = try? String(contentsOf: file(name), encoding: .utf8),
               let status = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return status
            }
            if let timeout, Date().timeIntervalSince(start) > timeout { return nil }
            try? await Task.sleep(for: pollInterval)
        }
        return nil
    }

    private func writeGo(_ argv: [String]) {
        var data = Data()
        for word in argv { data.append(Data(word.utf8)); data.append(0) }
        let temporary = file("go.tmp")
        guard (try? data.write(to: temporary)) != nil else { return }
        // Atomic: the wrapper never reads half an argv.
        rename(temporary.path, file("go").path)
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
            Row(id: "tmux", verdict: .ok, line: "tmux: \(version), launch chain accepted")
        case .accepted(let version, false):
            Row(id: "tmux", verdict: .advisory,
                line: "tmux: \(version), launch chain accepted; allow-passthrough: not on this version, clipboard passthrough off")
        case .tooOld(let version):
            Row(id: "tmux", verdict: .problem, line: "tmux: \(version): Temple needs tmux 3.2 or newer to keep sessions running")
        case .refused(let version, let command, let line):
            Row(id: "tmux", verdict: .problem, line: "tmux: \(version), " + (command.map { "`\($0)`: " } ?? "") + line)
        case .attachedFailed(let version, let line):
            Row(id: "tmux", verdict: .problem, line: "tmux: \(version), attached client failed: \(line)")
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
