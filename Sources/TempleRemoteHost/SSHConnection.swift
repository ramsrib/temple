import CryptoKit
import Darwin
import Foundation

/// How Temple reaches one host with the user's own `ssh`.
///
/// A host from `~/.ssh/config` is reached by its alias and nothing else. A
/// host entered in Temple is reached by the same alias mechanism plus `-o`
/// options derived from its record, so the user's `~/.ssh/config` and
/// `/etc/ssh/ssh_config` still apply to everything Temple does not set.
/// Command-line options are read first, so Temple's win for that host. No
/// config file is generated (`-F` would drop the system config).
///
/// Two kinds of connection share one ControlMaster per host:
///
/// - **interactive** (a session tab, the Test connection sheet): may create
///   the master, and may ask the user anything ssh wants to ask;
/// - **query** (every background exec): rides the master when one is up,
///   otherwise connects on its own, non-interactively (`BatchMode`), and
///   never creates one.
///
/// Temple never ends a master (`-O exit` appears nowhere): two Temple
/// processes with one state directory share it, and it expires by itself
/// through `ControlPersist`.
public struct SSHConnection: Sendable, Equatable {
    public enum Purpose: Sendable, Equatable {
        case interactive
        case query
    }

    public let record: RemoteHostRecord
    /// The user's ssh: the login shell's, else `/usr/bin/ssh`.
    public let sshPath: String
    /// The master's socket, unique to this state directory and these
    /// connection parameters.
    public let controlPath: String
    /// Whether `controlPath` is in the fallback directory (the state
    /// directory's path was too long for a Unix socket).
    public let usesFallbackDirectory: Bool

    public init(record: RemoteHostRecord, stateDirectory: URL, sshPath: String,
                temporaryDirectory: String = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(),
                uid: uid_t = getuid()) {
        self.record = record
        self.sshPath = sshPath
        let key = Self.socketKey(stateDirectory: stateDirectory, record: record)
        let primary = stateDirectory.appendingPathComponent("ssh", isDirectory: true).path + "/" + key
        if primary.utf8.count <= Self.maximumControlPathLength {
            controlPath = primary
            usesFallbackDirectory = false
        } else {
            var directory = temporaryDirectory
            while directory.hasSuffix("/") { directory.removeLast() }
            let fallback = "\(directory)/temple-ssh-\(uid)/\(key)"
            // A temporary directory long enough to overflow too: /tmp, which
            // always fits (the key still carries the state directory).
            controlPath = fallback.utf8.count <= Self.maximumControlPathLength
                ? fallback : "/tmp/temple-ssh-\(uid)/\(key)"
            usesFallbackDirectory = true
        }
    }

    public var socketDirectory: String { (controlPath as NSString).deletingLastPathComponent }

    /// ssh binds the master at `<ControlPath>.<16 random characters>` and
    /// renames it into place, and `sun_path` holds 104 bytes with its NUL:
    /// 104 - 1 - 17 leaves 86 for the path itself.
    public static let maximumControlPathLength = 86

    /// `m-` and 16 hex digits of a SHA-256 over the state directory and every
    /// connection parameter: an edit yields a new socket at once, and two
    /// isolated Temple instances never share one, even in the fallback dir.
    public static func socketKey(stateDirectory: URL, record: RemoteHostRecord) -> String {
        let fields = [stateDirectory.standardizedFileURL.path, record.name, record.address ?? "", record.user ?? "",
                      record.port.map(String.init) ?? "", record.identityFile ?? "", record.proxyJump ?? ""]
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8))
        return "m-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The host's own options: nothing for a config alias, the record's
    /// fields as `-o` options for a host entered in Temple. No
    /// `IdentitiesOnly`, no `StrictHostKeyChecking`, no `UserKnownHostsFile`,
    /// never `-i` or a password.
    public var hostOptions: [String] {
        guard record.source == .temple else { return [] }
        var options: [String] = []
        if let address = record.address { options += ["-o", "HostName=\(Self.optionValue(address))"] }
        if let user = record.user { options += ["-o", "User=\(Self.optionValue(user))"] }
        if let port = record.port { options += ["-o", "Port=\(port)"] }
        if let identity = record.identityFile { options += ["-o", "IdentityFile=\(Self.optionValue(identity))"] }
        if let jump = record.proxyJump { options += ["-o", "ProxyJump=\(Self.optionValue(jump))"] }
        return options
    }

    /// Everything between `ssh` and `--` for this purpose: the host's own
    /// options, then Temple's.
    public func arguments(for purpose: Purpose) -> [String] {
        let socket = ["-o", "ControlPath=\(Self.optionValue(Self.escapePercent(controlPath)))"]
        switch purpose {
        case .interactive:
            return hostOptions + ["-o", "ControlMaster=auto"] + socket + [
                "-o", "ControlPersist=600",
                "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                "-o", "ConnectTimeout=10",
                "-t",
            ]
        case .query:
            return hostOptions + socket + [
                "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes",
                "-T",
            ]
        }
    }

    /// The whole argv: ssh, its arguments, `--`, the host's name, and the
    /// remote command when there is one.
    public func argv(_ purpose: Purpose, remoteCommand: String?) -> [String] {
        [sshPath] + arguments(for: purpose) + ["--", record.name] + (remoteCommand.map { [$0] } ?? [])
    }

    /// `ssh -G`: what ssh will use for this host, without connecting.
    public var resolutionArgv: [String] {
        [sshPath, "-G"] + hostOptions + ["--", record.name]
    }

    /// An `-o` value as ssh tokenizes it: plain when it is one plain word,
    /// otherwise double-quoted with `\` and `"` escaped.
    static func optionValue(_ value: String) -> String {
        let plain = value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "._/~@:%+,-[]".unicodeScalars.contains(scalar)
        }
        if plain && !value.isEmpty { return value }
        var quoted = "\""
        for character in value {
            if character == "\\" || character == "\"" { quoted.append("\\") }
            quoted.append(character)
        }
        return quoted + "\""
    }

    /// `ControlPath` expands `%` tokens; a literal `%` is `%%`.
    static func escapePercent(_ path: String) -> String {
        path.replacingOccurrences(of: "%", with: "%%")
    }

    /// Creates the socket directory, owner-only.
    public func prepareSocketDirectory() throws {
        try FileManager.default.createDirectory(atPath: socketDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(socketDirectory, 0o700)
        if usesFallbackDirectory, !Self.loggedFallback.swap(true) {
            RemoteHostLog.ssh.notice("socket path too long under the state directory; using \(self.socketDirectory, privacy: .public)")
        }
    }

    private static let loggedFallback = OnceFlag()
}

/// Stale master sockets: removed only on a positive sign that nothing
/// listens. `connect()` refused means no process holds the socket; anything
/// else (a timeout, a permission problem, a path that is not a socket) is
/// inconclusive, and the file stays. ssh copes with a stale socket on its
/// own anyway.
public enum SocketHygiene {
    /// True when `path` was a socket nobody listens on, and was removed.
    @discardableResult
    public static func removeIfNothingListens(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return false }
        let identity = (info.st_dev, info.st_ino)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result != 0, errno == ECONNREFUSED else { return false }
        // Only the file that refused: a master another Temple bound at this
        // path since is a different file, and stays. (The window between
        // this check and the unlink is not closed, only narrowed; ssh
        // recovers from a missing socket by connecting directly.)
        var again = stat()
        guard lstat(path, &again) == 0, (again.st_dev, again.st_ino) == identity else { return false }
        return unlink(path) == 0
    }
}

/// A flag set once, from any thread.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// Sets the flag; returns what it was.
    func swap(_ new: Bool) -> Bool {
        lock.withLock { defer { value = new }; return value }
    }
}
