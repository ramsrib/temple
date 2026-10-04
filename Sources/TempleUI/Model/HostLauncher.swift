import Darwin
import Foundation
import TempleCore
import TempleTerminalAPI

public struct AgentLaunchSpec: Sendable {
    public enum Mode: Sendable, Equatable {
        case new(sessionID: String?)
        case resume(sessionID: String)
    }
    public let agent: Agent
    public let mode: Mode
    public let directory: String
    public let host: HostID
    public init(agent: Agent, mode: Mode, directory: String, host: HostID) {
        self.agent = agent; self.mode = mode; self.directory = directory; self.host = host
    }
}

/// What a host prepared for one spawn.
@MainActor
public struct AgentLaunch {
    /// What the terminal runs (for a local launch, the agent behind a small
    /// `cd`-then-`exec` wrapper).
    public let command: TerminalCommand
    /// The agent's own argv — what a failure header shows, never the wrapper.
    public let displayArgv: [String]
    /// What the launch itself reports (the folder it entered, or why it
    /// stopped before the agent ran). Nil when the host cannot report: the
    /// folder is then unknown and nothing is recorded from the tab.
    public let result: LaunchResultChannel?
    public init(command: TerminalCommand, displayArgv: [String], result: LaunchResultChannel?) {
        self.command = command; self.displayArgv = displayArgv; self.result = result
    }
}

public enum HostLaunchError: Error, LocalizedError, Equatable {
    /// The host proved the folder gone before anything spawned.
    case directoryMissing(String)
    case unavailable(reason: String)
    case preparation(String)
    public var errorDescription: String? {
        switch self {
        case .directoryMissing(let path): "The folder \(path) no longer exists."
        case .unavailable(let reason): reason
        case .preparation(let message): message
        }
    }
}

/// Why a launch stopped before the agent ran, as the launcher saw it.
public enum LaunchFailureCategory: String, Sendable, Equatable {
    /// The folder could not be entered. A shell's `cd` status cannot tell a
    /// missing folder from a permission problem, so neither is claimed.
    case cdFailed
    case transport
}

public enum LaunchEvent: Sendable, Equatable {
    /// The spawned process is running in this folder.
    case directoryEstablished(String)
    case failed(LaunchFailureCategory, message: String)
    /// The launch is over; nothing further will be reported.
    case finished
}

/// Whether a host can launch an agent at all, with the reason when it can't.
/// Only a failure can be proven (AGENTS.md): `.available` is not a promise.
public enum LaunchAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

/// The owning host chooses the executable, arguments and transport from intent.
@MainActor
public protocol HostLauncher: AnyObject, Sendable {
    func prepare(_ spec: AgentLaunchSpec) throws -> AgentLaunch
    func availability(_ agent: Agent) -> LaunchAvailability
}

/// Where a launch's result comes from: polled for complete records, with a
/// nudge when more may be available. A protocol, not a security boundary —
/// anything that can write the record can forge it.
@MainActor
public protocol LaunchResultSource: AnyObject {
    func start(notify: @escaping @MainActor () -> Void)
    /// Complete events not returned before, in order.
    func poll() -> [LaunchEvent]
    /// Stop observing and release everything (a local marker is removed).
    func stop()
}

/// One launch's result, owned by the tab that spawned it. Events arrive on
/// the main actor through `onEvent`, in order; any that arrive before a
/// consumer is attached are held for it. `finish()` drains synchronously —
/// called on process exit, so a launcher failure is known before the tab
/// decides whether to close — then reports `.finished` and releases the
/// source. `cancel()` releases it with nothing further reported (tab closed,
/// spawn failed, launch replaced). Both are idempotent.
@MainActor
public final class LaunchResultChannel {
    public var onEvent: ((LaunchEvent) -> Void)? {
        didSet {
            guard let onEvent, !held.isEmpty else { return }
            let events = held; held.removeAll()
            events.forEach(onEvent)
        }
    }
    private var source: LaunchResultSource?
    private var held: [LaunchEvent] = []
    public private(set) var isClosed = false

    public init(source: LaunchResultSource) {
        self.source = source
        source.start { [weak self] in self?.drain() }
    }

    /// Deliver every complete record available now.
    public func drain() {
        guard !isClosed, let source else { return }
        for event in source.poll() { deliver(event) }
    }

    public func finish() {
        guard !isClosed else { return }
        drain()
        deliver(.finished)
        release()
    }

    public func cancel() {
        guard !isClosed else { return }
        release()
    }

    private func deliver(_ event: LaunchEvent) {
        if let onEvent { onEvent(event) } else { held.append(event) }
    }

    private func release() {
        isClosed = true
        source?.stop()
        source = nil
        onEvent = nil
        held.removeAll()
    }
}

@MainActor
public final class LocalHostLauncher: HostLauncher {
    private let binaryPath: (Agent) -> String
    private let extraArgs: (Agent) -> [String]
    private let availabilityCheck: (Agent) -> LaunchAvailability
    private let folderEvidence: (String) -> DirectoryEvidence
    private let markerDirectory: URL

    /// `folderEvidence` is this Mac's `stat(2)`: only `ENOENT`/`ENOTDIR` (or
    /// a file where the folder should be) prove a folder gone; anything else
    /// is unknown, and the spawn proceeds behind the wrapper's own `cd`.
    public init(binaryPath: @escaping (Agent) -> String = { $0.binaryName },
                extraArgs: @escaping (Agent) -> [String] = { _ in [] },
                availability: @escaping (Agent) -> LaunchAvailability = { _ in .available },
                folderEvidence: @escaping (String) -> DirectoryEvidence = LocalHostLauncher.statEvidence,
                markerDirectory: URL? = nil) {
        self.binaryPath = binaryPath; self.extraArgs = extraArgs
        self.availabilityCheck = availability
        self.folderEvidence = folderEvidence
        self.markerDirectory = markerDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("temple-launch", isDirectory: true)
    }

    public func availability(_ agent: Agent) -> LaunchAvailability { availabilityCheck(agent) }

    public nonisolated static func statEvidence(_ path: String) -> DirectoryEvidence {
        var info = stat()
        if stat(path, &info) == 0 { return (info.st_mode & S_IFMT) == S_IFDIR ? .exists : .missing }
        return errno == ENOENT || errno == ENOTDIR ? .missing : .unknown
    }

    /// The agent's argv, run in the spec's folder through a wrapper that
    /// enters the folder itself and records the outcome in a per-launch
    /// marker: `ok` once the folder is entered (the agent is then exec'd in
    /// place), or a failure record if it cannot be — the agent never runs
    /// anywhere else. Arguments are positional, never interpolated into the
    /// script. `/usr/bin/env` heads the argv because the terminal execs the
    /// command as a login process (`exec -l`), and a shell started that way
    /// can read profile files; env is indifferent to it, and starts the
    /// shell plainly.
    public func prepare(_ spec: AgentLaunchSpec) throws -> AgentLaunch {
        precondition(spec.host.isLocal)
        let arguments: [String]
        switch spec.mode {
        case .resume(let id): arguments = Array(spec.agent.resumeArgv(sessionID: id).dropFirst())
        case .new(let id): arguments = spec.agent == .claude ? id.map { ["--session-id", $0] } ?? [] : []
        }
        // A folder this Mac proves gone spawns nothing; if it goes in the gap
        // before exec, the wrapper's own `cd` refuses to run the agent elsewhere.
        if folderEvidence(spec.directory) == .missing { throw HostLaunchError.directoryMissing(spec.directory) }
        let argv = [binaryPath(spec.agent)] + extraArgs(spec.agent) + arguments
        guard let marker = LocalLaunchMarker(directory: markerDirectory, folder: spec.directory) else {
            // No marker, no evidence: the folder is recorded from nothing
            // (no channel), but the wrapper still enters it itself, so the
            // agent never runs anywhere else.
            TempleUILog.launch.error("launch marker unavailable; spawning without launch evidence")
            let command = TerminalCommand(argv: ["/usr/bin/env", "/bin/sh", "-c", Self.unreportedWrapperScript, "temple-launch",
                                                 spec.directory] + argv,
                                          cwd: spec.directory)
            return AgentLaunch(command: command, displayArgv: argv, result: nil)
        }
        let command = TerminalCommand(argv: ["/usr/bin/env", "/bin/sh", "-c", Self.wrapperScript, "temple-launch",
                                             spec.directory, marker.path] + argv,
                                      cwd: spec.directory)
        return AgentLaunch(command: command, displayArgv: argv, result: LaunchResultChannel(source: marker))
    }

    nonisolated static let wrapperScript = #"cd -- "$1" || { printf 'failed\tcd\t%s\n' "$?" > "$2"; exit 1; }; printf 'ok\n' > "$2"; shift 2; exec "$@""#
    /// The same enforcement with nothing reported: `cd` or exit, then exec.
    nonisolated static let unreportedWrapperScript = #"cd -- "$1" || exit 1; shift; exec "$@""#
}

/// The local launch record: a file Temple creates (mode 0600, in its own
/// temp directory) and watches before the spawn, which the wrapper writes
/// one line to. Only complete lines count, however notifications coalesce.
@MainActor
final class LocalLaunchMarker: LaunchResultSource {
    let path: String
    private let folder: String
    private var descriptor: Int32
    private var watcher: DispatchSourceFileSystemObject?
    private var consumedLines = 0

    init?(directory: URL, folder: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        Self.sweepStale(directory)
        let url = directory.appendingPathComponent(UUID().uuidString.lowercased())
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_RDONLY | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }
        path = url.path
        self.folder = folder
        descriptor = fd
    }

    func start(notify: @escaping @MainActor () -> Void) {
        guard descriptor >= 0, watcher == nil else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .extend], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { notify() } }
        watcher = source
        source.resume()
    }

    func poll() -> [LaunchEvent] {
        guard descriptor >= 0 else { return [] }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var offset: off_t = 0
        while true {
            let count = pread(descriptor, &buffer, buffer.count, offset)
            guard count > 0 else { break }
            data.append(buffer, count: count)
            offset += off_t(count)
        }
        // Complete lines only: a record still being written waits for its newline.
        guard let lastNewline = data.lastIndex(of: 0x0a) else { return [] }
        let lines = String(decoding: data[..<lastNewline], as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > consumedLines else { return [] }
        let fresh = lines[consumedLines...]
        consumedLines = lines.count
        return fresh.compactMap(event)
    }

    private func event(_ line: Substring) -> LaunchEvent? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        switch fields.first {
        case "ok": return .directoryEstablished(folder)
        case "failed":
            return .failed(.cdFailed, message: "Temple couldn't enter the folder \(folder).")
        default: return nil
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        unlink(path)
    }

    /// A launch dropped without `stop()` still gives back its descriptor,
    /// its watcher and its file.
    deinit {
        watcher?.cancel()
        if descriptor >= 0 { Darwin.close(descriptor); unlink(path) }
    }

    /// Markers outlive their launch only when the app quit mid-launch; a day
    /// later nothing can still write them.
    private static func sweepStale(_ directory: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if modified < cutoff { try? fm.removeItem(at: entry) }
        }
    }
}
