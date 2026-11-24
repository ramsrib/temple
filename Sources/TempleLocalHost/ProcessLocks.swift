import Darwin
import Foundation
import TempleCore

/// Which Antigravity conversation a process has loaded: the one
/// `presence/<id>.lock` it holds open (ADR-043, SESSION-FORMATS.md). Only
/// the process itself counts, never a child; only an open descriptor, never
/// a lock file (they are never deleted).
enum ProcessLocks {
    /// The process's start time, or nil when there is no such process.
    static func start(_ pid: pid_t) -> ProcessStart? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessStart(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    struct Unreadable: Error { let reason: String }

    /// The paths of every file the process has open.
    static func openPaths(_ pid: pid_t) throws -> [String] {
        func failed() -> Unreadable { Unreadable(reason: "pid \(pid)'s open files couldn't be read (\(String(cString: strerror(errno))))") }
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { throw failed() }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { throw failed() }
        let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        var paths: [String] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else {
                // Closed since it was listed, or revoked (ENOENT): no lock.
                if errno == EBADF || errno == ENOENT { continue }
                throw failed()
            }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// The session ids whose lock under `presence` is among `paths`. Both
    /// the folder's own spelling and its resolved one are matched: the
    /// kernel reports the path the file was opened by.
    static func lockedIDs(_ paths: [String], presence: URL) -> Set<String> {
        let prefixes = Set([presence.path, presence.resolvingSymlinksInPath().path].map { SessionPaths.normalized($0) + "/" })
        var ids: Set<String> = []
        for raw in paths {
            let path = SessionPaths.normalized(raw)
            guard let prefix = prefixes.first(where: { path.hasPrefix($0) }) else { continue }
            let name = path.dropFirst(prefix.count)
            guard !name.contains("/"), name.hasSuffix(".lock") else { continue }
            let stem = String(name.dropLast(5))
            if UUID(uuidString: stem) != nil { ids.insert(stem.lowercased()) }
        }
        return ids
    }

    /// The answer for one process: its start time read before and after its
    /// descriptors, so a process that ended or a pid reused meanwhile is
    /// never answered for.
    static func identify(_ request: ProcessIdentityRequest, store: AntigravitySessionStore,
                         start: (pid_t) -> ProcessStart? = ProcessLocks.start,
                         openPaths: (pid_t) throws -> [String] = ProcessLocks.openPaths) -> ProcessIdentity {
        guard request.pid > 0, let before = start(request.pid) else { return .ended }
        if let expected = request.started, expected != before { return .ended }
        let paths: [String]
        do { paths = try openPaths(request.pid) } catch let error as Unreadable {
            return start(request.pid) == before ? .inconclusive(error.reason, started: before) : .ended
        } catch { return .inconclusive(error.localizedDescription, started: before) }
        guard start(request.pid) == before else { return .ended }
        let ids = lockedIDs(paths, presence: store.presenceRoot)
        guard ids.count <= 1 else { return .inconclusive("the process holds \(ids.count) conversations' locks", started: before) }
        guard let id = ids.first else { return .none(started: before) }
        let database = store.conversationsRoot.appendingPathComponent("\(id).db")
        var info = stat()
        let created: Date? = stat(database.path, &info) == 0
            ? Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec) + TimeInterval(info.st_birthtimespec.tv_nsec) / 1_000_000_000)
            : nil
        return .session(id: id, locator: TranscriptLocator(localURL: database), createdAt: created, started: before)
    }
}

extension LocalSessionSource {
    public func identifyProcess(_ request: ProcessIdentityRequest) async -> ProcessIdentity {
        guard request.agent == .antigravity, let store = antigravityStore else { return .unsupported }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: ProcessLocks.identify(request, store: store))
            }
        }
    }
}
