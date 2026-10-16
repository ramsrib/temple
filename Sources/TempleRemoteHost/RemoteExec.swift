import Darwin
import Foundation

/// What one remote command printed and how it ended.
public struct RemoteOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }

    /// The first line of stderr that says something, trimmed; nil when none.
    public var firstErrorLine: String? { RemoteOutput.firstLine(stderr) }

    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

public enum RemoteExecError: Error, Equatable, LocalizedError {
    /// The command did not finish in time; its process was killed.
    case deadline(seconds: TimeInterval)
    /// The local process could not be started (the OS's words).
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .deadline(let seconds): "Didn't answer within \(Int(seconds.rounded())) seconds."
        case .launchFailed(let reason): "Couldn't start ssh: \(reason)"
        }
    }
}

/// The exec seam: one fixed script, positional arguments, a wall-clock
/// deadline. Production is `SSHExec`; tests run the same scripts under the
/// local `/bin/sh` (`LocalShellExec`).
public protocol RemoteExec: Sendable {
    func run(script: String, args: [String], deadline: TimeInterval) async throws -> RemoteOutput
}

/// A query to one host over the user's ssh: `BatchMode`, riding the master
/// when one is up, never creating one. The remote command is
/// `env PATH=<resolved> sh -c '<script>' temple <args…>` (one environment
/// policy; without a resolved PATH, ssh's default environment), preceded by a
/// marker on each stream so whatever the login shell's rc files print before
/// the command runs is discarded.
///
/// On the deadline the query's ssh process is killed: a client of the
/// master, never the master.
public struct SSHExec: RemoteExec {
    public let connection: SSHConnection
    public let path: String?

    public init(connection: SSHConnection, path: String?) {
        self.connection = connection; self.path = path
    }

    public func run(script: String, args: [String], deadline: TimeInterval) async throws -> RemoteOutput {
        let marker = "__temple_\(RemoteQuoting.nonce())__"
        let remote = Self.remoteCommand(script: script, args: args, path: path, marker: marker)
        let argv = connection.argv(.query, remoteCommand: remote)
        let raw = try await ProcessRunner.run(argv[0], Array(argv.dropFirst()), deadline: deadline)
        return Self.unframe(raw, marker: marker)
    }

    /// The marker, on stdout and stderr, then the command. `echo` and `exec`
    /// read the same in sh, bash, zsh and fish.
    public static func remoteCommand(script: String, args: [String], path: String?, marker: String) -> String {
        "echo \(marker); echo \(marker) >&2; exec "
            + RemoteQuoting.shellCommand(script: script, args: args, path: path)
    }

    /// Drops what came before the marker on each stream. A stream without
    /// the marker never reached the command: stdout is then empty, and
    /// stderr is ssh's own (kept whole).
    static func unframe(_ raw: ProcessRunner.Output, marker: String) -> RemoteOutput {
        RemoteOutput(status: raw.status,
                     stdout: after(marker, in: raw.stdout) ?? "",
                     stderr: after(marker, in: raw.stderr) ?? raw.stderr)
    }

    static func after(_ marker: String, in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) else { return nil }
        return lines[(index + 1)...].joined(separator: "\n")
    }
}

/// The same remote command, run by this Mac's `/bin/sh` instead of a remote
/// login shell: the scripts, the quoting and the framing, without a network.
/// `environment` replaces the process environment (a temp `HOME`, a stub
/// `tmux` on `PATH`).
public struct LocalShellExec: RemoteExec {
    public let path: String?
    public let environment: [String: String]?

    public init(path: String?, environment: [String: String]? = nil) {
        self.path = path; self.environment = environment
    }

    public func run(script: String, args: [String], deadline: TimeInterval) async throws -> RemoteOutput {
        let marker = "__temple_\(RemoteQuoting.nonce())__"
        let remote = SSHExec.remoteCommand(script: script, args: args, path: path, marker: marker)
        let raw = try await ProcessRunner.run("/bin/sh", ["-c", remote], environment: environment, deadline: deadline)
        return SSHExec.unframe(raw, marker: marker)
    }
}

/// Every local process the remote module has started (ssh queries, `ssh
/// -G`), counted where it starts: the flag-off tests assert it never moves.
public enum RemoteProcessCounter {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    public static var launches: Int { lock.withLock { count } }
    static func increment() { lock.withLock { count += 1 } }
}

/// Runs a local process, reads both streams to the end, and always comes
/// back: at the deadline (or on cancellation) the process is sent SIGTERM,
/// then SIGKILL a second later, and the caller is answered without waiting
/// for a pipe a grandchild may still hold.
public enum ProcessRunner {
    public struct Output: Sendable, Equatable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    /// Each stream is cut at this many bytes.
    static let limit = 1 << 20

    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           deadline: TimeInterval) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let state = RunState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                state.continuation = continuation
                state.expect(3) // stdout EOF, stderr EOF, termination
                read(outPipe.fileHandleForReading, into: \.stdout, state: state)
                read(errPipe.fileHandleForReading, into: \.stderr, state: state)
                process.terminationHandler = { finished in
                    state.terminated(status: finished.terminationStatus)
                }
                do {
                    // Cancelled before the process existed: start nothing.
                    guard !state.isCancelled else { throw CancellationError() }
                    RemoteProcessCounter.increment()
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    state.fail(error is CancellationError ? error : RemoteExecError.launchFailed(error.localizedDescription))
                    return
                }
                // Cancelled while it was starting: the handler found no
                // process to kill, so it is killed here, answered or not.
                if state.publish(process) {
                    _ = state.stop(with: CancellationError())
                    kill(process)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                    if state.stop(with: RemoteExecError.deadline(seconds: deadline)) { kill(process) }
                }
            }
        } onCancel: {
            _ = state.stop(with: CancellationError())
            if let process = state.cancel() { kill(process) }
        }
    }

    private static func read(_ handle: FileHandle, into keyPath: ReferenceWritableKeyPath<RunState, Data>,
                             state: RunState) {
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                state.arrived()
            } else {
                state.append(chunk, to: keyPath)
            }
        }
    }

    private static func kill(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    /// One run's bookkeeping, behind a lock: the streams, what is still
    /// awaited, and the one answer.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<Output, Error>? {
            get { lock.withLock { _continuation } }
            set { lock.withLock { _continuation = newValue } }
        }
        private var _continuation: CheckedContinuation<Output, Error>?
        private var process: Process?
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        /// Records the started process; true when the run was cancelled
        /// meanwhile (the caller kills it).
        func publish(_ started: Process) -> Bool {
            lock.withLock { process = started; return cancelled }
        }

        /// Records the cancellation; the process to kill, if it has started.
        func cancel() -> Process? {
            lock.withLock { cancelled = true; return process }
        }
        var stdout = Data()
        var stderr = Data()
        private var pending = 0
        private var status: Int32 = 0
        private var answered = false

        func expect(_ count: Int) { lock.withLock { pending = count } }

        func append(_ chunk: Data, to keyPath: ReferenceWritableKeyPath<RunState, Data>) {
            lock.withLock {
                let room = ProcessRunner.limit - self[keyPath: keyPath].count
                if room > 0 { self[keyPath: keyPath].append(chunk.prefix(room)) }
            }
        }

        func arrived() { finishIfDone { pending -= 1 } }

        func terminated(status: Int32) { finishIfDone { self.status = status; pending -= 1 } }

        private func finishIfDone(_ update: () -> Void) {
            let resume: (CheckedContinuation<Output, Error>, Output)? = lock.withLock {
                update()
                guard pending == 0, !answered, let continuation = _continuation else { return nil }
                answered = true
                return (continuation, Output(status: status, stdout: String(decoding: stdout, as: UTF8.self),
                                             stderr: String(decoding: stderr, as: UTF8.self)))
            }
            if let (continuation, output) = resume { continuation.resume(returning: output) }
        }

        /// Answers with `error` unless already answered; true when it did.
        func stop(with error: Error) -> Bool {
            let continuation: CheckedContinuation<Output, Error>? = lock.withLock {
                guard !answered, let continuation = _continuation else { return nil }
                answered = true
                return continuation
            }
            continuation?.resume(throwing: error)
            return continuation != nil
        }

        func fail(_ error: Error) { _ = stop(with: error) }
    }
}
