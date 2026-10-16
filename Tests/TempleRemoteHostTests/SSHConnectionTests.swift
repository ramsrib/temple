import Darwin
import Foundation
import XCTest
@testable import TempleRemoteHost

/// Runs the real `/usr/bin/ssh` against this Mac: `ssh -G` with fixture
/// configs, and connections to local TCP listeners on 127.0.0.1 that this
/// file opens itself (no sshd, no other machine, never the user's
/// `~/.ssh/config`). A review under a no-ssh rule skips this file.
final class SSHConnectionTests: XCTestCase {
    let state = URL(fileURLWithPath: "/private/tmp/temple-b-env/state", isDirectory: true)
    let added = RemoteHostRecord(name: "box", source: .temple, address: "10.0.0.2", user: "me", port: 2222,
                                 identityFile: "~/.ssh/id box", proxyJump: "bastion")

    func testAConfigAliasGetsTempleOptionsOnly() {
        let connection = SSHConnection(record: .config("masterblaster-mentes"), stateDirectory: state, sshPath: "/usr/bin/ssh")
        let key = SSHConnection.socketKey(stateDirectory: state, record: .config("masterblaster-mentes"))
        XCTAssertEqual(connection.argv(.query, remoteCommand: "cmd"), [
            "/usr/bin/ssh", "-o", "ControlPath=/private/tmp/temple-b-env/state/ssh/\(key)",
            "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes",
            "-o", "StdinNull=no", "-o", "ForkAfterAuthentication=no", "-o", "SessionType=default",
            "-o", "RemoteCommand=none", "-T",
            "--", "masterblaster-mentes", "cmd",
        ])
        XCTAssertEqual(connection.argv(.interactive, remoteCommand: "true"), [
            "/usr/bin/ssh", "-o", "ControlMaster=auto", "-o", "ControlPath=/private/tmp/temple-b-env/state/ssh/\(key)",
            "-o", "ControlPersist=600", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "StdinNull=no", "-o", "ForkAfterAuthentication=no", "-o", "SessionType=default",
            "-o", "RemoteCommand=none", "-t", "--", "masterblaster-mentes", "true",
        ])
        XCTAssertEqual(Array(connection.argv(.overMaster, remoteCommand: "cmd").suffix(12)), [
            "-o", "StdinNull=no", "-o", "ForkAfterAuthentication=no", "-o", "SessionType=default",
            "-o", "RemoteCommand=none", "-T", "--", "masterblaster-mentes", "cmd",
        ])
    }

    /// `ForkAfterAuthentication yes` in a config (no RemoteCommand, the
    /// default SessionType) makes ssh refuse any invocation without a
    /// command before doing anything: Temple's helpers (`-O check`, `-G`)
    /// force it off. Argv, then each helper run against a fixture config
    /// (`-G` resolves only; `-O check` asks a socket that isn't there and
    /// can't fall back to a connection).
    func testHelpersOverrideForkAfterAuthentication() throws {
        let tree = TempTree("ssh-fork")
        let config = tree.write("config", "Host box\n  HostName 127.0.0.1\n  ForkAfterAuthentication yes\n")
        let connection = SSHConnection(record: .config("box"), stateDirectory: tree.url, sshPath: "/usr/bin/ssh")
        for argv in [connection.masterCheckArgv, connection.resolutionArgv] {
            XCTAssertNotNil(argv.firstIndex(of: "ForkAfterAuthentication=no"), "\(argv)")
            XCTAssertLessThan(argv.firstIndex(of: "ForkAfterAuthentication=no")!, argv.firstIndex(of: "--")!)
            var withConfig = argv
            withConfig.insert(contentsOf: ["-F", config.path], at: 1)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: withConfig[0])
            process.arguments = Array(withConfig.dropFirst())
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertFalse(stderr.contains("Cannot fork into background"), stderr)
            if argv.contains("-G") {
                XCTAssertEqual(process.terminationStatus, 0, stderr)
                XCTAssertTrue(stdout.contains("forkafterauthentication no"))
            }
        }
    }

    /// A config that would eat a session's stdin or never run its command
    /// (`StdinNull`, `ForkAfterAuthentication`, `SessionType`,
    /// `RemoteCommand`) is overridden for every purpose: `ssh -G` with a
    /// fixture config and Temple's own options resolves to what a session
    /// needs. (`ssh -G` only; nothing connects.)
    func testInheritedOptionsThatWouldEatStdinAreOverridden() throws {
        let tree = TempTree("ssh-stdin")
        let config = tree.write("config", "Host box\n  StdinNull yes\n  ForkAfterAuthentication yes\n"
                                + "  SessionType none\n  RemoteCommand echo hijacked\n")
        let connection = SSHConnection(record: .config("box"), stateDirectory: state, sshPath: "/usr/bin/ssh")
        for purpose in [SSHConnection.Purpose.query, .overMaster, .interactive] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-G", "-F", config.path] + connection.arguments(for: purpose) + ["--", "box"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let lines = Set(text.split(separator: "\n").map(String.init))
            for expected in ["stdinnull no", "forkafterauthentication no", "sessiontype default"] {
                XCTAssertTrue(lines.contains(expected), "\(purpose): \(expected)")
            }
            XCTAssertFalse(text.contains("hijacked"), "\(purpose): the config's RemoteCommand is gone")
        }
    }

    func testAnAddedHostLeadsWithItsOwnOptions() {
        let connection = SSHConnection(record: added, stateDirectory: state, sshPath: "/usr/bin/ssh")
        XCTAssertEqual(Array(connection.arguments(for: .query).prefix(10)), [
            "-o", "HostName=10.0.0.2", "-o", "User=me", "-o", "Port=2222",
            "-o", "IdentityFile=\"~/.ssh/id box\"", "-o", "ProxyJump=bastion",
        ])
        for purpose in [SSHConnection.Purpose.query, .interactive] {
            let words = connection.argv(purpose, remoteCommand: nil)
            XCTAssertFalse(words.contains("-O"), "Temple never sends a control command")
            XCTAssertFalse(words.contains { $0.hasPrefix("StrictHostKeyChecking") || $0.hasPrefix("UserKnownHostsFile")
                || $0.hasPrefix("IdentitiesOnly") || $0 == "-i" })
            XCTAssertEqual(words.suffix(2), ["--", "box"])
        }
        XCTAssertEqual(connection.resolutionArgv.prefix(2), ["/usr/bin/ssh", "-G"])
    }

    func testTheSocketKeyFollowsEveryParameterAndTheStateDirectory() {
        let base = SSHConnection.socketKey(stateDirectory: state, record: added)
        XCTAssertTrue(base.hasPrefix("m-"))
        XCTAssertEqual(base.count, 18)
        XCTAssertEqual(base, SSHConnection.socketKey(stateDirectory: state, record: added), "stable")
        var edits: [RemoteHostRecord] = []
        for change in [{ (r: inout RemoteHostRecord) in r.port = 22 }, { $0.address = "10.0.0.3" }, { $0.user = "you" },
                       { $0.identityFile = nil }, { $0.proxyJump = "other" }] {
            var record = added
            change(&record)
            edits.append(record)
        }
        let keys = Set(edits.map { SSHConnection.socketKey(stateDirectory: state, record: $0) })
        XCTAssertEqual(keys.count, edits.count)
        XCTAssertFalse(keys.contains(base), "an edit yields a new socket")
        XCTAssertNotEqual(SSHConnection.socketKey(stateDirectory: URL(fileURLWithPath: "/private/tmp/other-state"), record: added),
                          base, "two isolated instances never share a master")
    }

    /// Where ssh resolves the host is part of the key: an alias retargeted
    /// in the config gets a new socket; resolved settings that don't move
    /// the destination don't.
    func testTheSocketKeyFollowsWhereSSHResolvesTheHost() {
        let base: [String: String] = ["hostname": "10.0.0.1", "user": "mentes", "port": "22"]
        let key = SSHConnection.socketKey(stateDirectory: state, record: .config("box"), resolved: base)
        for (field, value) in [("hostname", "10.0.0.2"), ("user", "other"), ("port", "2222"),
                               ("proxyjump", "bastion"), ("proxycommand", "nc %h %p")] {
            var moved = base
            moved[field] = value
            XCTAssertNotEqual(SSHConnection.socketKey(stateDirectory: state, record: .config("box"), resolved: moved), key, field)
        }
        var unrelated = base
        unrelated["compression"] = "yes"
        let connection = SSHConnection(record: .config("box"), stateDirectory: state, sshPath: "/usr/bin/ssh", resolved: unrelated)
        XCTAssertEqual(connection.controlPath.hasSuffix(key), true, "only the destination's fields count")
        XCTAssertEqual(connection.resolved, base)
    }

    func testALongStateDirectoryFallsBackToTheTemporaryDirectory() {
        let long = URL(fileURLWithPath: "/private/tmp/" + String(repeating: "x", count: 70), isDirectory: true)
        let connection = SSHConnection(record: added, stateDirectory: long, sshPath: "/usr/bin/ssh",
                                       temporaryDirectory: "/var/folders/ab/cd/T/", uid: 501)
        XCTAssertTrue(connection.usesFallbackDirectory)
        XCTAssertEqual(connection.socketDirectory, "/var/folders/ab/cd/T/temple-ssh-501")
        XCTAssertTrue(connection.controlPath.hasSuffix(SSHConnection.socketKey(stateDirectory: long, record: added)))
        XCTAssertLessThanOrEqual(connection.controlPath.utf8.count, SSHConnection.maximumControlPathLength)
        let short = SSHConnection(record: added, stateDirectory: state, sshPath: "/usr/bin/ssh")
        XCTAssertFalse(short.usesFallbackDirectory)
        // A temporary directory too long as well: /tmp, which always fits.
        let longTemp = SSHConnection(record: added, stateDirectory: long, sshPath: "/usr/bin/ssh",
                                     temporaryDirectory: "/var/folders/" + String(repeating: "t", count: 60), uid: 501)
        XCTAssertEqual(longTemp.socketDirectory, "/tmp/temple-ssh-501")
        XCTAssertLessThanOrEqual(longTemp.controlPath.utf8.count, SSHConnection.maximumControlPathLength)
        // The installed app's own directory fits.
        let real = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Temple", isDirectory: true)
        XCTAssertFalse(SSHConnection(record: added, stateDirectory: real, sshPath: "/usr/bin/ssh").usesFallbackDirectory)
    }

    /// `ssh -G` against a fixture config (never the user's): the record's
    /// options win for that host, a `Host *` block still applies to what
    /// Temple does not set, and a socket path with a space or `%` arrives
    /// whole.
    func testSSHResolvesOptionsWithPrecedenceAndHostStarSurvives() throws {
        let tree = TempTree("ssh-g")
        let config = tree.write("config", """
        Host box
          User fromconfig
          Port 9999
        Host *
          User everyone
          Compression yes
          ServerAliveCountMax 7
        """)
        let stateWithSpace = tree.directory("Application Support/Te%mple")
        let connection = SSHConnection(record: added, stateDirectory: stateWithSpace, sshPath: "/usr/bin/ssh")
        for purpose in [SSHConnection.Purpose.query, .interactive] {
            let argv = ["/usr/bin/ssh", "-F", config.path, "-G"] + connection.arguments(for: purpose).filter { $0 != "-t" && $0 != "-T" }
                + ["--", "box"]
            let resolved = ConnectionTest.parseResolution(try run(argv, home: tree.path))
            XCTAssertEqual(resolved["hostname"], "10.0.0.2")
            XCTAssertEqual(resolved["user"], "me", "the record's option wins over the config's Host block and Host *")
            XCTAssertEqual(resolved["port"], "2222")
            XCTAssertEqual(resolved["proxyjump"], "bastion")
            XCTAssertEqual(resolved["compression"], "yes", "Host * still applies")
            XCTAssertEqual(resolved["controlpath"], connection.controlPath, "spaces and % arrive whole")
            XCTAssertEqual(resolved["identityfile"]?.hasSuffix("/.ssh/id box"), true)
            XCTAssertEqual(resolved["batchmode"], purpose == .query ? "yes" : "no")
            XCTAssertEqual(resolved["serveralivecountmax"], purpose == .query ? "7" : "3")
        }
        // A config alias is the config's alone.
        let alias = SSHConnection(record: .config("box"), stateDirectory: stateWithSpace, sshPath: "/usr/bin/ssh")
        let resolved = ConnectionTest.parseResolution(try run(
            ["/usr/bin/ssh", "-F", config.path, "-G"] + alias.hostOptions + ["--", "box"], home: tree.path))
        XCTAssertEqual(resolved["user"], "fromconfig")
        XCTAssertEqual(resolved["port"], "9999")
    }

    /// The master probe and every master-only query stay on the socket:
    /// with a config that says `ControlMaster yes` or `ask` (which makes ssh
    /// skip the socket) and a socket that fails the mux handshake (which
    /// lets ssh fall back), the real ssh never opens a connection. The host
    /// is a local TCP listener that would see one. The control case shows
    /// the trap works: the old probe, without the overrides, does connect.
    func testTheProbeAndMasterOnlyQueriesNeverConnect() async throws {
        let tree = TempTree("probe")
        let trap = try TCPTrap()
        defer { trap.close() }
        let state = tree.directory("state")
        for setting in ["yes", "ask", "auto"] {
            let config = tree.write("config-\(setting)", """
            Host box
              HostName 127.0.0.1
              Port \(trap.port)
              ControlMaster \(setting)
            """)
            let connection = SSHConnection(record: .config("box"), stateDirectory: state, sshPath: "/usr/bin/ssh")
            try connection.prepareSocketDirectory()
            // Nothing at the socket, then a socket that fails the handshake.
            for broken in [false, true] {
                let listener = broken ? try HandshakeBreaker(path: connection.controlPath) : nil
                defer { listener?.close() }
                for argv in [connection.masterCheckArgv,
                             connection.argv(.overMaster, remoteCommand: "true")] {
                    let withConfig = [argv[0], "-F", config.path] + argv.dropFirst()
                    let output = try await ProcessRunner.run(withConfig[0], Array(withConfig.dropFirst()), deadline: 10)
                    XCTAssertNotEqual(output.status, 0, "\(setting) broken=\(broken) \(argv.contains("check") ? "probe" : "query")")
                    XCTAssertFalse(trap.sawConnection(), "\(setting) broken=\(broken): ssh opened a connection\n\(output.stderr)")
                }
            }
        }
        // A host added in Temple with its own ProxyJump, pointed at the trap:
        // the jump never runs, socket missing or broken.
        let jumpConfig = tree.write("config-jump", "Host *\n  ControlMaster yes\n")
        let jumping = SSHConnection(record: RemoteHostRecord(name: "jumpy", source: .temple, address: "localhost",
                                                             port: Int(trap.port), proxyJump: "127.0.0.1:\(trap.port)"),
                                    stateDirectory: state, sshPath: "/usr/bin/ssh")
        try jumping.prepareSocketDirectory()
        for broken in [false, true] {
            let listener = broken ? try HandshakeBreaker(path: jumping.controlPath) : nil
            defer { listener?.close() }
            let argv = jumping.argv(.overMaster, remoteCommand: "true")
            XCTAssertLessThan(argv.firstIndex(of: "ProxyCommand=/usr/bin/false")!, argv.firstIndex(of: "ProxyJump=127.0.0.1:\(trap.port)")!,
                              "the master-only options lead")
            let withConfig = [argv[0], "-F", jumpConfig.path] + argv.dropFirst()
            let output = try await ProcessRunner.run(withConfig[0], Array(withConfig.dropFirst()), deadline: 10)
            XCTAssertNotEqual(output.status, 0)
            XCTAssertFalse(trap.sawConnection(), "jump broken=\(broken): ssh opened a connection\n\(output.stderr)")
        }
        // Control for the jump: the host's options first, as before.
        let hostFirst = ["/usr/bin/ssh", "-F", jumpConfig.path] + jumping.hostOptions
            + ["-o", "ControlPath=\(jumping.controlPath)"] + SSHConnection.masterOnly + ["-T", "--", "jumpy", "true"]
        _ = try? await ProcessRunner.run(hostFirst[0], Array(hostFirst.dropFirst()), deadline: 3)
        XCTAssertTrue(trap.sawConnection(), "with the host's ProxyJump first, the jump does connect: the order matters")

        // Control: the probe as it was (no overrides) under ControlMaster yes.
        let config = tree.write("config-control", "Host box\n  HostName 127.0.0.1\n  Port \(trap.port)\n  ControlMaster yes\n")
        let connection = SSHConnection(record: .config("box"), stateDirectory: state, sshPath: "/usr/bin/ssh")
        _ = try? await ProcessRunner.run("/usr/bin/ssh", ["-F", config.path, "-o", "ControlPath=\(connection.controlPath)",
                                                          "-o", "BatchMode=yes", "-O", "check", "--", "box"], deadline: 3)
        XCTAssertTrue(trap.sawConnection(), "without the overrides ssh does connect: the trap works")
    }

    func testOptionValuesQuoteByScalar() {
        XCTAssertEqual(SSHConnection.optionValue("plain/path"), "plain/path")
        XCTAssertEqual(SSHConnection.optionValue("a\"\u{0301}b"), "\"a\\\"\u{0301}b\"")
        XCTAssertEqual(SSHConnection.optionValue("é"), "\"é\"", "anything not plain ASCII is quoted")
        XCTAssertEqual(SSHConnection.optionValue("a\\\u{0301}"), "\"a\\\\\u{0301}\"")
    }

    func testStaleSocketsGoOnlyWhenNothingListens() throws {
        let tree = TempTree("sock")
        let dead = tree.path + "/dead"
        let live = tree.path + "/live"
        let plain = tree.write("plain", "not a socket").path
        let deadFD = try bindSocket(dead)
        close(deadFD) // bound, never listening, now closed: connect is refused
        let liveFD = try bindSocket(live)
        XCTAssertEqual(listen(liveFD, 1), 0)
        defer { close(liveFD) }
        XCTAssertTrue(SocketHygiene.removeIfNothingListens(dead))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead))
        XCTAssertFalse(SocketHygiene.removeIfNothingListens(live))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live))
        XCTAssertFalse(SocketHygiene.removeIfNothingListens(plain), "not a socket: inconclusive, kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plain))
        XCTAssertFalse(SocketHygiene.removeIfNothingListens(tree.path + "/absent"))
    }

    /// The socket directory is never a symlink, never another user's, and
    /// always 0700; anything else refuses, and a test refuses to start.
    func testASymlinkedOrForeignSocketDirectoryIsRefused() throws {
        let tree = TempTree("sockdir-bad")
        let elsewhere = tree.directory("elsewhere")
        let state = tree.directory("state")
        try FileManager.default.createSymbolicLink(atPath: state.path + "/ssh", withDestinationPath: elsewhere.path)
        let connection = SSHConnection(record: added, stateDirectory: state, sshPath: "/usr/bin/ssh")
        XCTAssertThrowsError(try connection.prepareSocketDirectory()) { error in
            XCTAssertEqual((error as? SocketDirectoryError)?.reason, "it is not a directory")
        }
        // A real directory someone else owns (simulated by naming another owner).
        let other = SSHConnection(record: added, stateDirectory: tree.directory("state2"), sshPath: "/usr/bin/ssh")
        XCTAssertThrowsError(try other.prepareSocketDirectory(owner: getuid() &+ 1)) { error in
            XCTAssertEqual((error as? SocketDirectoryError)?.reason, "another user owns it")
            XCTAssertEqual(error.localizedDescription, "Temple won't use \(other.socketDirectory) for ssh's connection: another user owns it.")
        }
        // Ours but loose: tightened to 0700.
        let loose = tree.directory("state3/ssh")
        chmod(loose.path, 0o755)
        try SSHConnection(record: added, stateDirectory: tree.url.appendingPathComponent("state3"), sshPath: "/usr/bin/ssh")
            .prepareSocketDirectory()
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: loose.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        // A plain file where the directory should be.
        let file = tree.directory("state4")
        tree.write("state4/ssh", "not a directory")
        XCTAssertThrowsError(try SSHConnection(record: added, stateDirectory: file, sshPath: "/usr/bin/ssh").prepareSocketDirectory())
    }

    func testTheSocketDirectoryIsOwnerOnly() throws {
        let tree = TempTree("sockdir")
        let connection = SSHConnection(record: added, stateDirectory: tree.url, sshPath: "/usr/bin/ssh")
        try connection.prepareSocketDirectory()
        let attributes = try FileManager.default.attributesOfItem(atPath: connection.socketDirectory)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(connection.socketDirectory, tree.path + "/ssh")
    }

    private func bindSocket(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(result, 0)
        return fd
    }

    private func run(_ argv: [String], home: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let pipe = Pipe(), errors = Pipe()
        process.standardOutput = pipe
        process.standardError = errors
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: error, as: UTF8.self))
        return String(decoding: data, as: UTF8.self)
    }
}

/// A TCP listener on 127.0.0.1 that only notices connections.
final class TCPTrap {
    let port: UInt16
    private let fd: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
    }


    /// Whether anyone connected since the last call (each one is closed).
    func sawConnection() -> Bool {
        var saw = false
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { break }
            Darwin.close(client)
            saw = true
        }
        return saw
    }

    func close() { Darwin.close(fd) }
}

/// A Unix socket at a master's path that accepts and hangs up at once: the
/// mux handshake fails.
final class HandshakeBreaker: @unchecked Sendable {
    private let fd: Int32
    private let path: String

    init(path: String) throws {
        self.path = path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        self.fd = fd
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                Darwin.close(client)
            }
        }
    }

    func close() {
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        unlink(path)
    }
}

// Runs the local ssh binary (against a ProxyCommand, never the network):
// kept with the other ssh-invoking tests, so a run that must not invoke ssh
// can leave this class out by filter.
extension SSHConnectionTests {
    /// The case the grammar exists for, without a network: a config whose
    /// `ProxyCommand` puts `%h` and `%r` into shell text. Every address and
    /// user the form accepts arrives as itself, and nothing else runs.
    func testAcceptedValuesReachAProxyCommandAsThemselves() throws {
        let tree = TempTree("proxy")
        let marker = tree.path + "/seen"
        let config = tree.write("config", "Host *\n  ProxyCommand /bin/sh -c 'printf \"%%s|%%s\" %h %r > \(marker); exit 1'\n")
        for (address, user) in [("box.lan", "me"), ("10.0.0.2", "mentes_2"), ("2001:db8::42", "a.b-c")] {
            var form = RemoteHostForm()
            form.name = "box"; form.address = address; form.user = user
            guard case .success(let record) = form.validate(editing: nil, existing: [], configAliases: []) else {
                return XCTFail("\(address) refused")
            }
            let connection = SSHConnection(record: record, stateDirectory: tree.url, sshPath: "/usr/bin/ssh")
            try? FileManager.default.removeItem(atPath: marker)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-F", config.path] + connection.hostOptions
                + ["-o", "BatchMode=yes", "-o", "ControlPath=none", "--", record.name, "true"]
            process.environment = ["HOME": tree.path, "PATH": "/usr/bin:/bin"]
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(try String(contentsOfFile: marker, encoding: .utf8), "\(address)|\(user)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tree.path).sorted(), ["config", "seen"],
                       "nothing else was written")
    }
}

// Resolves with the real `ssh -G`: kept with the other ssh-invoking tests.
extension SSHConnectionTests {
    /// Retargeting an alias in the config gives it a new socket at once:
    /// the old destination's master is never asked, and the identity shown
    /// is the one the socket was keyed by. Resolved by the real `ssh -G`
    /// against a fixture config.
    @MainActor
    func testARetargetedAliasNeverReusesTheOldMaster() async throws {
        let tree = TempTree("ct-retarget")
        let config = tree.path + "/config"
        let ssh = ConnectionTestTests.standInSSH(tree)
        try "master".write(toFile: tree.path + "/mode", atomically: true, encoding: .utf8)
        let state = tree.directory("state")
        func test(target: String) async throws -> ConnectionTest {
            try "Host box\n  HostName \(target)\n  User mentes\n".write(toFile: config, atomically: true, encoding: .utf8)
            let test = ConnectionTest(record: .config("box"), stateDirectory: state, sshPath: ssh.path,
                                      makeExec: { _, path in ConnectionTestTests.host(PathLog())(path) },
                                      resolve: { argv in await ConnectionTest.sshResolve(["/usr/bin/ssh", "-F", config] + argv.dropFirst()) })
            let started = await test.start()
            XCTAssertTrue(started)
            return test
        }
        let first = try await test(target: "10.0.0.1")
        let firstPath = try XCTUnwrap(first.connection?.controlPath)
        try await ConnectionTestTests.runTerminal(first)
        first.terminalExited()
        await ConnectionTestTests.waitUntil { first.phase == .finished }
        XCTAssertEqual(first.summary?.statusLine.hasPrefix("Connected as mentes@10.0.0.1."), true)

        // The same alias, pointed elsewhere, while the first master lives on.
        let second = try await test(target: "10.0.0.2")
        let secondPath = try XCTUnwrap(second.connection?.controlPath)
        XCTAssertNotEqual(secondPath, firstPath, "a new destination, a new socket")
        try await ConnectionTestTests.runTerminal(second)
        second.terminalExited()
        await ConnectionTestTests.waitUntil { second.phase == .finished }
        XCTAssertEqual(second.summary?.statusLine.hasPrefix("Connected as mentes@10.0.0.2."), true)
        let checks = try String(contentsOfFile: tree.path + "/calls", encoding: .utf8).split(separator: "\n")
            .filter { $0.contains("-O check") }
        XCTAssertEqual(checks.count, 2)
        XCTAssertTrue(checks[1].contains(secondPath), "the second test asked its own socket, not the old master's")
        XCTAssertFalse(checks[1].contains(firstPath))
    }
}

