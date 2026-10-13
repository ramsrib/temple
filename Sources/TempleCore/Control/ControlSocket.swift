import Darwin
import Foundation

/// The Unix socket between the `temple` command line and the running app
/// (ADR-034): in the state directory, mode 0600, and answered only for a
/// peer running as this user. One request per connection: the client writes
/// one JSON line, the app answers with one, and closes.
public enum ControlSocket {
    public static func url(in directory: URL = TempleState.directory) -> URL {
        directory.appendingPathComponent(ControlProtocol.socketName)
    }

    /// `sockaddr_un` for a path, or nil when the path does not fit
    /// (`sun_path` is 104 bytes on Darwin, terminator included).
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func connect(_ fd: Int32, _ address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func newSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd >= 0 { prepare(fd) }
        return fd
    }

    /// Close-on-exec, so an agent Temple launches inherits nothing of the
    /// socket; and no SIGPIPE, so a peer that hangs up mid-write does not
    /// kill the writer.
    static func prepare(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
        var time = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    /// One line, or everything up to EOF; nil past the size limit or on a
    /// read error (a timeout included).
    static func readMessage(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
            if data.count > ControlProtocol.maxMessageBytes { return nil }
            if let newline = data.firstIndex(of: UInt8(ascii: "\n")) { return data.prefix(upTo: newline) }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var message = data
        message.append(UInt8(ascii: "\n"))
        return message.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 { if errno == EINTR { continue }; return false }
                offset += written
            }
            return true
        }
    }
}

// MARK: - Client

public enum ControlClientError: Error, Equatable {
    /// Nothing answers at the socket: Temple is not running (or is a build
    /// without the command line, or another Temple owns a different state
    /// directory).
    case notRunning
    case transport(String)
}

public enum ControlClient {
    public static func send(_ request: ControlRequest, socket: URL = ControlSocket.url(),
                            timeout: TimeInterval = 30) throws -> ControlResponse {
        guard let address = ControlSocket.address(socket.path) else {
            throw ControlClientError.transport("the socket path is too long: \(socket.path)")
        }
        let fd = ControlSocket.newSocket()
        guard fd >= 0 else { throw ControlClientError.transport(String(cString: strerror(errno))) }
        defer { close(fd) }
        if ControlSocket.connect(fd, address) != 0 {
            let code = errno
            if code == ENOENT || code == ECONNREFUSED { throw ControlClientError.notRunning }
            throw ControlClientError.transport(String(cString: strerror(code)))
        }
        ControlSocket.setTimeouts(fd, seconds: timeout)
        let body = try JSONEncoder().encode(request)
        guard ControlSocket.writeAll(fd, body) else {
            throw ControlClientError.transport("could not send the request: \(String(cString: strerror(errno)))")
        }
        shutdown(fd, SHUT_WR)
        guard let reply = ControlSocket.readMessage(fd), !reply.isEmpty else {
            throw ControlClientError.transport("Temple did not answer")
        }
        // The version first: an answer from another protocol may not decode.
        if let envelope = try? JSONDecoder().decode(ControlEnvelope.self, from: reply),
           envelope.version != ControlProtocol.version {
            throw ControlClientError.transport(ControlProtocol.mismatch(command: ControlProtocol.version, temple: envelope.version).error!.message)
        }
        do {
            return try JSONDecoder().decode(ControlResponse.self, from: reply)
        } catch {
            throw ControlClientError.transport("Temple's answer could not be read: \(error)")
        }
    }

    /// Something answers at the socket.
    public static func isServing(_ socket: URL = ControlSocket.url()) -> Bool {
        guard let address = ControlSocket.address(socket.path) else { return false }
        let fd = ControlSocket.newSocket()
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return ControlSocket.connect(fd, address) == 0
    }
}

// MARK: - Server

/// A request's one chance to change something. An action claims it
/// (`commit`) in the same synchronous turn as its change; the server's
/// deadline claims it (`expire`) before answering "did not answer in time".
/// Exactly one wins, so a timeout never reports nothing happened about a
/// request that went on to act, and a request that timed out never acts.
public final class ControlCommit: @unchecked Sendable {
    private enum State { case pending, committed, expired }
    private let lock = NSLock()
    private var state = State.pending

    public init() {}

    /// True when the request may go on to change something.
    public func commit() -> Bool { claim(.committed) }
    func expire() -> Bool { claim(.expired) }

    private func claim(_ next: State) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .pending else { return state == next }
        state = next
        return true
    }
}

/// Listens on the socket and hands each request to `handler`.
///
/// Ownership is a lock, not a guess: the server holds an exclusive `flock` on
/// `<socket>.lock` for as long as it listens, and only the holder creates or
/// removes the socket file. So a second Temple on the same state directory
/// gets `.alreadyServed` however busy the first one is (a failed connect
/// proves nothing: a full accept queue refuses too), and a socket file left
/// by a process that died is replaced, because its lock died with it.
///
/// Everything about connections happens on one serial queue, and each
/// connection's descriptor belongs to a `DispatchIO`, which closes it exactly
/// once, after its last read or write: nothing here closes a number another
/// path may still use. Every descriptor is made close-on-exec as soon as it
/// exists (Darwin has no atomic way for sockets), so agents Temple launches
/// do not inherit them.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest, ControlCommit) async -> ControlResponse

    public enum StartFailure: Error, Equatable {
        /// Another process holds this socket.
        case alreadyServed
        case failed(String)
    }

    /// How long a request may take before it is answered with an error.
    /// Opening a session outside Temple reads the catalog, which can take a
    /// while cold.
    public static let handlerDeadline: TimeInterval = 150
    /// Reading the request, and writing the answer, each get this long.
    static let transferDeadline: TimeInterval = 5
    /// More connections than this at once are closed unanswered.
    static let maxConnections = 32
    static let acceptBatch = 8
    /// A request that committed to a change and has still not answered this
    /// long after its deadline is answered "acted, outcome unknown".
    static let committedGrace: TimeInterval = 10

    private let url: URL
    private let lockFD: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "com.sriramb.temple.control")
    /// Left by the cancel handler: every `stop` caller waits on it.
    private let stopped = DispatchGroup()
    // Confined to `queue`.
    private var isStopping = false
    private var connections: [ObjectIdentifier: Connection] = [:]

    private init(url: URL, fd: Int32, lockFD: Int32, handler: @escaping Handler, deadline: TimeInterval) {
        self.url = url
        self.lockFD = lockFD
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, fd] in
            // A batch at a time: the source fires again while connections
            // wait, and in between the queue runs reads, deadlines and stop.
            for _ in 0..<Self.acceptBatch {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }  // EWOULDBLOCK: drained
                ControlSocket.prepare(client)
                guard let self, !self.isStopping, self.connections.count < Self.maxConnections else {
                    close(client)
                    continue
                }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
                let connection = Connection(fd: client, queue: self.queue, handler: handler, deadline: deadline) {
                    [weak self] finished in self?.connections[ObjectIdentifier(finished)] = nil
                }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start()
            }
        }
        // The listener closes once no event handler can still be using its
        // number; the path is removed and ownership released only after.
        let path = url.path, stopped = stopped
        stopped.enter()
        source.setCancelHandler {
            close(fd)
            unlink(path)
            close(lockFD)
            stopped.leave()
        }
        source.resume()
    }

    /// Without `stop`, the listener still closes and ownership is still
    /// released (by the cancel handler); nothing waits, because the last
    /// reference may be dropped on the server's own queue.
    deinit { source.cancel() }

    public static func start(at url: URL, deadline: TimeInterval = handlerDeadline,
                             handler: @escaping Handler) -> Result<ControlServer, StartFailure> {
        let path = url.path
        guard let address = ControlSocket.address(path) else {
            return .failure(.failed("the socket path is too long: \(path)"))
        }
        let lockFD = open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { return .failure(.failed("lock \(path).lock: \(String(cString: strerror(errno)))")) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(lockFD)
            return code == EWOULDBLOCK ? .failure(.alreadyServed)
                : .failure(.failed("lock \(path).lock: \(String(cString: strerror(code)))"))
        }
        func fail(_ message: String) -> Result<ControlServer, StartFailure> {
            close(lockFD)
            return .failure(.failed(message))
        }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else { return fail("\(path) exists and is not a socket") }
            unlink(path)  // ours to replace: whoever made it no longer holds the lock
        }
        let fd = ControlSocket.newSocket()
        guard fd >= 0 else { return fail(String(cString: strerror(errno))) }
        var bound = address
        let bindResult = withUnsafePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            return fail("bind \(path): \(message)")
        }
        guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            unlink(path)
            return fail("listen \(path): \(message)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return .success(ControlServer(url: url, fd: fd, lockFD: lockFD, handler: handler, deadline: deadline))
    }

    /// Stops listening and closes every connection unanswered; returns, for
    /// every caller, once the socket file is gone and ownership is released.
    public func stop() {
        queue.sync {
            guard !isStopping else { return }
            isStopping = true
            for connection in connections.values { connection.abandon() }
            connections = [:]
            source.cancel()
        }
        stopped.wait()
    }
}

/// One accepted connection: receiving, then handling, then replying, then
/// closed, each step at most once, all on the server's queue. The deadline,
/// `stop` and the handler's answer race only through `ControlCommit` and the
/// state, so whichever comes first decides and the rest do nothing.
private final class Connection {
    private enum State { case receiving, handling, replying, closed }

    private let io: DispatchIO
    private let queue: DispatchQueue
    private let handler: ControlServer.Handler
    private let deadline: TimeInterval
    private let finished: (Connection) -> Void
    private let commit = ControlCommit()
    private var state = State.receiving
    private var received = Data()
    private var task: Task<Void, Never>?

    init(fd: Int32, queue: DispatchQueue, handler: @escaping ControlServer.Handler, deadline: TimeInterval,
         finished: @escaping (Connection) -> Void) {
        self.queue = queue
        self.handler = handler
        self.deadline = deadline
        self.finished = finished
        io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in Darwin.close(fd) }
    }

    func start() {
        io.setLimit(lowWater: 1)
        io.read(offset: 0, length: ControlProtocol.maxMessageBytes + 1, queue: queue) { [self] done, data, error in
            guard state == .receiving else { return }
            if let data { received.append(contentsOf: data) }
            if let newline = received.firstIndex(of: UInt8(ascii: "\n")) {
                handle(received.prefix(upTo: newline))
            } else if received.count > ControlProtocol.maxMessageBytes || error != 0 {
                close()
            } else if done {
                received.isEmpty ? close() : handle(received)
            }
        }
        queue.asyncAfter(deadline: .now() + ControlServer.transferDeadline) { [self] in
            if state == .receiving { close() }
        }
    }

    private func handle(_ body: Data) {
        state = .handling
        // The version first, before anything that depends on it: another
        // version's request may not decode as this one's.
        guard let envelope = try? JSONDecoder().decode(ControlEnvelope.self, from: body) else {
            return reply(.failure(.invalid, "unreadable request"))
        }
        guard envelope.version == ControlProtocol.version else {
            return reply(ControlProtocol.mismatch(command: envelope.version, temple: ControlProtocol.version))
        }
        let request: ControlRequest
        do {
            request = try JSONDecoder().decode(ControlRequest.self, from: body)
        } catch {
            return reply(.failure(.invalid, "unreadable request: \(error)"))
        }
        let handler = handler, commit = commit, queue = queue
        task = Task { [weak self] in
            let answer = await handler(request, commit)
            queue.async { self?.reply(answer) }
        }
        queue.asyncAfter(deadline: .now() + deadline) { [weak self] in
            guard let self, self.state == .handling else { return }
            if self.commit.expire() {
                self.task?.cancel()
                self.reply(.failure(.refused, "Temple did not answer in time, and changed nothing."))
                return
            }
            // It committed: something may have changed, so it may not say
            // otherwise, but it does not hold the connection for ever.
            self.queue.asyncAfter(deadline: .now() + ControlServer.committedGrace) { [weak self] in
                guard let self, self.state == .handling else { return }
                self.reply(.failure(.refused, "Temple acted but did not finish answering; check `temple sessions ls`."))
            }
        }
    }

    private func reply(_ response: ControlResponse) {
        // A second answer (the handler's, after the deadline's) is dropped;
        // it never cuts the first one off.
        guard state == .handling else { return }
        guard var data = try? JSONEncoder().encode(response) else { return close() }
        state = .replying
        data.append(UInt8(ascii: "\n"))
        let payload = data.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: payload, queue: queue) { [self] done, _, error in
            if done || error != 0 { close() }
        }
        queue.asyncAfter(deadline: .now() + ControlServer.transferDeadline) { [weak self] in self?.close() }
    }

    /// `stop`: closed unanswered.
    func abandon() {
        _ = commit.expire()
        task?.cancel()
        close()
    }

    private func close() {
        guard state != .closed else { return }
        state = .closed
        io.close(flags: .stop)
        finished(self)
    }
}
