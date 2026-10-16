import Darwin
import Foundation

/// What one remote command printed and how it ended.
public struct RemoteOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    /// Whether the command itself ran on the host (its marker arrived):
    /// false means ssh, the master or the network failed first, and the
    /// status and stderr are ssh's.
    public var reachedCommand: Bool
    public init(status: Int32, stdout: String, stderr: String, reachedCommand: Bool = true) {
        self.status = status; self.stdout = stdout; self.stderr = stderr; self.reachedCommand = reachedCommand
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
    /// `input`: bytes for the script's stdin (then end of file); nil for
    /// none. The staging query's payload travels this way, never in a
    /// command line.
    func run(script: String, args: [String], input: Data?, deadline: TimeInterval) async throws -> RemoteOutput
}

extension RemoteExec {
    public func run(script: String, args: [String], deadline: TimeInterval) async throws -> RemoteOutput {
        try await run(script: script, args: args, input: nil, deadline: deadline)
    }
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
    /// `.query` (rides the master, or connects on its own) or `.overMaster`
    /// (the master and nothing else).
    public let purpose: SSHConnection.Purpose

    public init(connection: SSHConnection, path: String?, purpose: SSHConnection.Purpose = .query) {
        precondition(purpose != .interactive, "a query never asks")
        self.connection = connection; self.path = path; self.purpose = purpose
    }

    public func run(script: String, args: [String], input: Data?, deadline: TimeInterval) async throws -> RemoteOutput {
        let marker = "__temple_\(RemoteQuoting.nonce())__"
        let invocation = Self.invocation(script: script, args: args, path: path, input: input, marker: marker)
        let argv = connection.argv(purpose, remoteCommand: invocation.command)
        let raw = try await ProcessRunner.run(argv[0], Array(argv.dropFirst()), input: invocation.stdin, deadline: deadline)
        return Self.unframe(raw, marker: marker)
    }

    /// The fixed bootstrap (`RemoteQuoting.invocation`), which prints the
    /// marker on both streams from `sh` itself, so the login shell runs one
    /// plain command whatever it is (sh, bash, zsh, fish, csh, tcsh);
    /// everything else on stdin.
    public static func invocation(script: String, args: [String], path: String?, input: Data?,
                                  marker: String) -> (command: String, stdin: Data) {
        RemoteQuoting.invocation(script: script, args: args, path: path, input: input, marker: marker)
    }

    /// Drops what came before the marker on each stream. A stream without
    /// the marker never reached the command: stdout is then empty, and
    /// stderr is ssh's own (kept whole).
    static func unframe(_ raw: ProcessRunner.Output, marker: String) -> RemoteOutput {
        let stdout = after(marker, in: raw.stdout)
        return RemoteOutput(status: raw.status, stdout: stdout ?? "",
                            stderr: after(marker, in: raw.stderr) ?? raw.stderr, reachedCommand: stdout != nil)
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

    public func run(script: String, args: [String], input: Data?, deadline: TimeInterval) async throws -> RemoteOutput {
        let marker = "__temple_\(RemoteQuoting.nonce())__"
        let invocation = SSHExec.invocation(script: script, args: args, path: path, input: input, marker: marker)
        let raw = try await ProcessRunner.run("/bin/sh", ["-c", invocation.command], environment: environment,
                                              input: invocation.stdin, deadline: deadline)
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

/// Runs a local process, reads both streams, and always comes back.
///
/// - At the deadline (or on cancellation) the process is sent SIGTERM, then
///   SIGKILL a second later, and the caller is answered at once.
/// - Once the process has exited, its streams get a short grace to drain;
///   a descendant still holding one open does not hold the answer.
/// - Whatever the outcome, both read descriptors are closed and every
///   handler released: the readers are dispatch sources on the run's own
///   queue, so a teardown never races a read in flight.
public enum ProcessRunner {
    public struct Output: Sendable, Equatable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    /// Each stream is cut at this many bytes.
    static let limit = 1 << 20
    /// How long the streams may stay open after the process has exited.
    static let drainGrace: TimeInterval = 0.5

    /// Points in a run's setup, for tests that cancel at exactly one.
    enum SetupStage: Sendable { case pipesCreated, readersAttached }
    /// Called at each setup stage; tests only.
    nonisolated(unsafe) static var setupHook: (@Sendable (SetupStage) -> Void)?

    /// `input`: written to the process's stdin by the run's own writer (a
    /// nonblocking write source on the run's queue, owned like the
    /// readers), then closed. It is cancelled, its descriptor closed, with
    /// the readers when the run is answered (an exit, a deadline, a
    /// cancellation), so a descendant that holds stdin without reading
    /// keeps nothing of Temple's waiting. A process that exits without
    /// reading costs a failed write, never a SIGPIPE.
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           input: Data? = nil, deadline: TimeInterval) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        var stdin: (read: FileHandle, write: Int32)?
        if input != nil {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw RemoteExecError.launchFailed(String(cString: strerror(errno))) }
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            // Only this side's end is nonblocking: the child reads as usual.
            _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
            _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
            let read = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
            process.standardInput = read
            stdin = (read, fds[1])
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        let run = RunState()
        if let stdin, let input { run.attach(input: input, to: stdin.write) }
        defer {
            // The child has its copy of the read end (or never started).
            try? stdin?.read.close()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                run.continuation = continuation
                guard let out = Pipes.make() else {
                    run.finish(throwing: RemoteExecError.launchFailed(String(cString: strerror(errno))))
                    return
                }
                guard let err = Pipes.make() else {
                    close(out.read); close(out.write)
                    run.finish(throwing: RemoteExecError.launchFailed(String(cString: strerror(errno))))
                    return
                }
                let outWrite = FileHandle(fileDescriptor: out.write, closeOnDealloc: true)
                let errWrite = FileHandle(fileDescriptor: err.write, closeOnDealloc: true)
                process.standardOutput = outWrite
                process.standardError = errWrite
                process.terminationHandler = { finished in run.terminated(status: finished.terminationStatus) }
                setupHook?(.pipesCreated)
                run.attach(stdout: out.read, stderr: err.read)
                setupHook?(.readersAttached)
                do {
                    // Cancelled before the process existed: start nothing.
                    guard !run.isCancelled else { throw CancellationError() }
                    RemoteProcessCounter.increment()
                    try process.run()
                } catch {
                    try? outWrite.close(); try? errWrite.close()
                    run.finish(throwing: error is CancellationError ? error : RemoteExecError.launchFailed(error.localizedDescription))
                    return
                }
                // The child has its copies; the parent's write ends must go,
                // or the streams never end.
                try? outWrite.close()
                try? errWrite.close()
                // Cancelled while it was starting: killed here, answered or not.
                if run.publish(process) {
                    run.finish(throwing: CancellationError())
                    kill(process)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                    if run.finish(throwing: RemoteExecError.deadline(seconds: deadline)) { kill(process) }
                }
            }
        } onCancel: {
            run.finish(throwing: CancellationError())
            if let process = run.cancel() { kill(process) }
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

    /// A pipe whose descriptors are close-on-exec, so no other child
    /// started meanwhile inherits them (the child's own stdout and stderr
    /// are `dup2` copies, which are not).
    enum Pipes {
        static func make() -> (read: Int32, write: Int32)? {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { return nil }
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
            return (fds[0], fds[1])
        }
    }

    /// One run: two readers on a serial queue, the process, the one answer.
    final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "com.sriramb.temple.remote.process")
        private var _continuation: CheckedContinuation<Output, Error>?
        private var process: Process?
        private var cancelled = false
        private var answered = false
        private var sources: [DispatchSourceRead] = []
        private var writer: DispatchSourceWrite?
        private var buffers: [Data] = [Data(), Data()]
        private var openStreams = 0
        private var status: Int32?

        var continuation: CheckedContinuation<Output, Error>? {
            get { lock.withLock { _continuation } }
            set { lock.withLock { _continuation = newValue } }
        }

        var isCancelled: Bool { lock.withLock { cancelled } }

        func publish(_ started: Process) -> Bool {
            lock.withLock { process = started; return cancelled }
        }

        func cancel() -> Process? {
            lock.withLock { cancelled = true; return process }
        }

        /// Starts reading both descriptors; each is closed by its source's
        /// cancel handler, which runs after any read in flight. Registering
        /// and the answer are decided under one lock: readers that arrive
        /// after the run was answered (a cancellation during setup) are
        /// disposed of at once, descriptors closed, never left behind.
        func attach(stdout: Int32, stderr: Int32) {
            var created: [DispatchSourceRead] = []
            for (index, fd) in [stdout, stderr].enumerated() {
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self, weak source] in
                    guard let self, let source else { return }
                    var chunk = [UInt8](repeating: 0, count: 65_536)
                    let count = Darwin.read(fd, &chunk, chunk.count)
                    if count > 0 {
                        self.append(chunk[0..<count], to: index)
                    } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                        source.cancel()
                        self.streamEnded()
                    }
                }
                source.setCancelHandler { close(fd) }
                created.append(source)
            }
            let late = lock.withLock { () -> Bool in
                guard !answered else { return true }
                openStreams = 2
                sources = created
                return false
            }
            for source in created {
                source.resume()
                if late { source.cancel() }
            }
        }

        /// The stdin writer: writes what the pipe takes whenever it is
        /// writable, and closes its descriptor (its cancel handler) when
        /// the input is all written, the reader has gone, or the run is
        /// answered. Registered under the same lock as the readers: one
        /// that arrives after the answer is disposed of at once.
        func attach(input: Data, to fd: Int32) {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            var offset = 0
            source.setEventHandler { [weak source] in
                guard let source else { return }
                while offset < input.count {
                    let written = input.withUnsafeBytes { buffer in
                        Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    }
                    if written > 0 { offset += written; continue }
                    if written < 0, errno == EINTR { continue }
                    if written < 0, errno == EAGAIN { return }
                    break
                }
                source.cancel()
            }
            source.setCancelHandler { close(fd) }
            let late = lock.withLock { () -> Bool in
                guard !answered else { return true }
                writer = source
                return false
            }
            source.resume()
            if late { source.cancel() }
        }

        private func append(_ chunk: ArraySlice<UInt8>, to index: Int) {
            lock.withLock {
                let room = ProcessRunner.limit - buffers[index].count
                if room > 0 { buffers[index].append(contentsOf: chunk.prefix(room)) }
            }
        }

        private func streamEnded() {
            let done = lock.withLock { () -> Bool in
                openStreams -= 1
                return openStreams == 0 && status != nil
            }
            if done { finishNormally() }
        }

        func terminated(status: Int32) {
            let done = lock.withLock { () -> Bool in
                self.status = status
                return openStreams == 0
            }
            if done { finishNormally(); return }
            // A descendant may hold a stream open: answer after a grace.
            queue.asyncAfter(deadline: .now() + ProcessRunner.drainGrace) { [weak self] in self?.finishNormally() }
        }

        private func finishNormally() {
            let answer: (CheckedContinuation<Output, Error>, Output)? = lock.withLock {
                guard !answered, let continuation = _continuation, let status else { return nil }
                answered = true
                return (continuation, Output(status: status, stdout: String(decoding: buffers[0], as: UTF8.self),
                                             stderr: String(decoding: buffers[1], as: UTF8.self)))
            }
            guard let (continuation, output) = answer else { return }
            teardown()
            continuation.resume(returning: output)
        }

        /// Answers with `error` unless already answered; true when it did.
        @discardableResult
        func finish(throwing error: Error) -> Bool {
            let continuation: CheckedContinuation<Output, Error>? = lock.withLock {
                guard !answered, let continuation = _continuation else { return nil }
                answered = true
                return continuation
            }
            guard let continuation else { return false }
            teardown()
            continuation.resume(throwing: error)
            return true
        }

        /// Every reader stopped (its descriptor closed by its cancel
        /// handler), the buffers and the continuation dropped.
        private func teardown() {
            let (stopping, writing): ([DispatchSourceRead], DispatchSourceWrite?) = lock.withLock {
                defer { sources.removeAll(); writer = nil; buffers = [Data(), Data()]; _continuation = nil }
                return (sources, writer)
            }
            for source in stopping where !source.isCancelled { source.cancel() }
            if let writing, !writing.isCancelled { writing.cancel() }
        }

    }
}
