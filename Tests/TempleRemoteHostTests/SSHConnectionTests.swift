import Darwin
import Foundation
import XCTest
@testable import TempleRemoteHost

final class SSHConnectionTests: XCTestCase {
    let state = URL(fileURLWithPath: "/private/tmp/temple-b-env/state", isDirectory: true)
    let added = RemoteHostRecord(name: "box", source: .temple, address: "10.0.0.2", user: "me", port: 2222,
                                 identityFile: "~/.ssh/id box", proxyJump: "bastion")

    func testAConfigAliasGetsTempleOptionsOnly() {
        let connection = SSHConnection(record: .config("masterblaster-mentes"), stateDirectory: state, sshPath: "/usr/bin/ssh")
        let key = SSHConnection.socketKey(stateDirectory: state, record: .config("masterblaster-mentes"))
        XCTAssertEqual(connection.argv(.query, remoteCommand: "cmd"), [
            "/usr/bin/ssh", "-o", "ControlPath=/private/tmp/temple-b-env/state/ssh/\(key)",
            "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "-T",
            "--", "masterblaster-mentes", "cmd",
        ])
        XCTAssertEqual(connection.argv(.interactive, remoteCommand: "true"), [
            "/usr/bin/ssh", "-o", "ControlMaster=auto", "-o", "ControlPath=/private/tmp/temple-b-env/state/ssh/\(key)",
            "-o", "ControlPersist=600", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10", "-t", "--", "masterblaster-mentes", "true",
        ])
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
