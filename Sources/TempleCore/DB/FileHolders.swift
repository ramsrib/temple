import Darwin
import Foundation

/// Another process with a file open, as the kernel reports it.
public struct FileHolder: Equatable, Sendable {
    public let pid: pid_t
    /// The process's executable, or empty when the kernel won't say.
    public let executable: String
    public init(pid: pid_t, executable: String) { self.pid = pid; self.executable = executable }

    /// How a person finds it: the app it is in (`/Applications/Temple.app`),
    /// else the executable, else the pid alone.
    public var place: String {
        if let range = executable.range(of: ".app/Contents/") {
            return String(executable[..<range.lowerBound]) + ".app (pid \(pid))"
        }
        return executable.isEmpty ? "pid \(pid)" : "\(executable) (pid \(pid))"
    }
}

/// The process list could not be read: nobody can be said not to hold the file.
public struct FileHoldersUnreadable: Error, Equatable, Sendable {
    public let reason: String
}

/// Which other processes of this user have a file open, matched by device
/// and inode (a path compare would miss `/tmp` against `/private/tmp`).
/// Processes the kernel won't describe (another user's, or one that just
/// exited) are not seen. A process list that can't be read throws: an
/// unanswered question is never "nobody".
public enum FileHolders {
    public static func others(holding url: URL) throws -> [FileHolder] {
        var target = stat()
        guard stat(url.path, &target) == 0 else { return [] }
        var pids: [pid_t] = []
        var listed: Int32 = 0
        for _ in 0..<3 {
            let estimate = proc_listallpids(nil, 0)
            guard estimate > 0 else { continue }
            pids = [pid_t](repeating: 0, count: Int(estimate) * 2)
            listed = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            if listed > 0 { break }
        }
        guard listed > 0 else {
            throw FileHoldersUnreadable(reason: "the process list couldn't be read (\(String(cString: strerror(errno))))")
        }
        let me = getpid()
        var holders: [FileHolder] = []
        for pid in pids.prefix(Int(max(listed, 0))) where pid > 0 && pid != me {
            if try holds(pid, device: Int64(target.st_dev), inode: UInt64(target.st_ino)) {
                holders.append(FileHolder(pid: pid, executable: executable(pid)))
            }
        }
        return holders
    }

    /// Whether `pid` has the file open. A process that exited meanwhile
    /// (ESRCH) or isn't this user's (EPERM, which can't write the file)
    /// doesn't; any other failure to look is not an answer, and throws.
    private static func holds(_ pid: pid_t, device: Int64, inode: UInt64) throws -> Bool {
        func unanswered() throws -> Bool {
            let code = errno
            if code == ESRCH || code == EPERM { return false }
            throw FileHoldersUnreadable(reason: "pid \(pid)'s open files couldn't be read (\(String(cString: strerror(code))))")
        }
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return try unanswered() }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for descriptors opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return try unanswered() }
        let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else {
                // Closed since it was listed, or revoked (`revoke(2)`: the
                // kernel answers ENOENT for its path; seen on Codex's app
                // server daemon, which then blocked every fresh database
                // open): not this file.
                if errno == EBADF || errno == ENOENT { continue }
                if try !unanswered() { return false }
                continue
            }
            let found = info.pvip.vip_vi.vi_stat
            if Int64(found.vst_dev) == device && UInt64(found.vst_ino) == inode { return true }
        }
        return false
    }

    private static func executable(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }
}
