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
        /// A tab or the Test sheet: may create the master, may ask.
        case interactive
        /// A background query: rides the master when one is up, otherwise
        /// connects on its own, never asking.
        case query
        /// A query that must ride an existing master and nothing else: if
        /// the master is gone or refuses, it fails rather than connecting.
        case overMaster
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

    /// What `ssh -G` resolved for this host when the connection was made
    /// (hostname, user, port, proxyjump, proxycommand): part of the socket
    /// key, and what the test reports it connected as.
    public let resolved: [String: String]

    /// `resolved` is `ssh -G`'s answer for this host (`resolutionArgv`). A
    /// config alias retargeted in `~/.ssh/config` resolves differently, so
    /// it gets a new socket and never reuses the old destination's master.
    public init(record: RemoteHostRecord, stateDirectory: URL, sshPath: String, resolved: [String: String] = [:],
                temporaryDirectory: String = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(),
                uid: uid_t = getuid()) {
        self.record = record
        self.sshPath = sshPath
        self.resolved = resolved.filter { Self.resolvedKeys.contains($0.key) }
        let key = Self.socketKey(stateDirectory: stateDirectory, record: record, resolved: self.resolved)
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

    /// The `ssh -G` fields that decide where a connection goes.
    public static let resolvedKeys = ["hostname", "user", "port", "proxyjump", "proxycommand"]

    /// `m-` and 16 hex digits of a SHA-256 over the state directory, every
    /// connection parameter of the record, and where ssh resolves it to: an
    /// edit, here or in `~/.ssh/config`, yields a new socket at once, and two
    /// isolated Temple instances never share one, even in the fallback dir.
    public static func socketKey(stateDirectory: URL, record: RemoteHostRecord,
                                 resolved: [String: String] = [:]) -> String {
        let fields = [stateDirectory.standardizedFileURL.path, record.name, record.address ?? "", record.user ?? "",
                      record.port.map(String.init) ?? "", record.identityFile ?? "", record.proxyJump ?? ""]
            + resolvedKeys.map { "\($0)=\(resolved[$0] ?? "")" }
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
        case .overMaster:
            // ssh keeps the first value it is given for an option, and a
            // ProxyJump given before a ProxyCommand wins: the master-only
            // options lead, before any of the host's own.
            return Self.masterOnly + socket + hostOptions + ["-o", "ClearAllForwardings=yes", "-T"]
        }
    }

    /// Options that keep ssh on the master's socket and off the network.
    /// They come first on the command line: ssh keeps the first value it is
    /// given, so they win over the host's own options (a Temple-added
    /// `ProxyJump` included) and over every config. An inherited
    /// `ControlMaster yes` or `ask` (which makes ssh skip the socket) is
    /// overridden, and a fallback after a failed mux handshake has nowhere
    /// to go: its transport is `/usr/bin/false`, which also displaces any
    /// `ProxyJump` or `ProxyCommand` a config sets.
    static let masterOnly = [
        "-o", "ControlMaster=no", "-o", "ControlPersist=no", "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=1", "-o", "ProxyCommand=/usr/bin/false",
    ]

    /// The whole argv: ssh, its arguments, `--`, the host's name, and the
    /// remote command when there is one.
    public func argv(_ purpose: Purpose, remoteCommand: String?) -> [String] {
        [sshPath] + arguments(for: purpose) + ["--", record.name] + (remoteCommand.map { [$0] } ?? [])
    }

    /// `ssh -O check` on Temple's own socket for this host: exit 0 when a
    /// master process answers there. Local: no remote command, and with
    /// `masterOnly` it can neither skip the socket nor fall back to a
    /// connection. Never `-O exit`. It proves a local master only; the
    /// first query over it proves the connection.
    public var masterCheckArgv: [String] {
        [sshPath, "-o", "ControlPath=\(Self.optionValue(Self.escapePercent(controlPath)))"] + Self.masterOnly
            + ["-O", "check", "--", record.name]
    }

    /// `ssh -G`: what ssh will use for this host, without connecting.
    public var resolutionArgv: [String] {
        [sshPath, "-G"] + hostOptions + ["--", record.name]
    }

    /// An `-o` value as ssh tokenizes it: plain when it is one plain word,
    /// otherwise double-quoted with `\` and `"` escaped.
    static func optionValue(_ value: String) -> String {
        // Scalars, not Characters: a quote with a combining mark after it
        // is still a quote to ssh's tokenizer.
        let plain = value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._/~@:%+,-[]".unicodeScalars.contains(scalar))
        }
        if plain && !value.isEmpty { return value }
        var quoted = String.UnicodeScalarView()
        quoted.append("\"")
        for scalar in value.unicodeScalars {
            if scalar == "\\" || scalar == "\"" { quoted.append("\\") }
            quoted.append(scalar)
        }
        quoted.append("\"")
        return String(quoted)
    }

    /// `ControlPath` expands `%` tokens; a literal `%` is `%%`.
    static func escapePercent(_ path: String) -> String {
        path.replacingOccurrences(of: "%", with: "%%")
    }

    /// Creates the socket directory, or checks the one there, without
    /// following a symlink: it must be a real directory, owned by this
    /// user, mode 0700 (one of ours with looser bits is tightened). Anything
    /// else throws, and nothing may start ssh with this ControlPath: a
    /// directory another account made (the `/tmp` fallback is a predictable
    /// name) would hand it the master.
    public func prepareSocketDirectory(owner: uid_t = getuid()) throws {
        let path = socketDirectory
        let parent = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: parent) {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            throw SocketDirectoryError(path: path, reason: String(cString: strerror(errno)))
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let reason = errno == ELOOP || errno == ENOTDIR ? "it is not a directory" : String(cString: strerror(errno))
            throw SocketDirectoryError(path: path, reason: reason)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw SocketDirectoryError(path: path, reason: String(cString: strerror(errno)))
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw SocketDirectoryError(path: path, reason: "it is not a directory") }
        guard info.st_uid == owner else { throw SocketDirectoryError(path: path, reason: "another user owns it") }
        if info.st_mode & 0o777 != 0o700 {
            guard fchmod(descriptor, 0o700) == 0 else {
                throw SocketDirectoryError(path: path, reason: String(cString: strerror(errno)))
            }
        }
        if usesFallbackDirectory, !Self.loggedFallback.swap(true) {
            RemoteHostLog.ssh.notice("socket path too long under the state directory; using \(path, privacy: .public)")
        }
    }

    private static let loggedFallback = OnceFlag()
}

/// Why the master's socket directory can't be used.
public struct SocketDirectoryError: Error, Equatable, LocalizedError {
    public let path: String
    public let reason: String
    public var errorDescription: String? { "Temple won't use \(path) for ssh's connection: \(reason)." }
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
