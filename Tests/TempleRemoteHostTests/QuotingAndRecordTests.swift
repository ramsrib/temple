import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

final class RemoteQuotingTests: XCTestCase {
    static let hard = ["plain", "two words", "it's", #"'\''"#, "line\nbreak", #"back\slash"#, #"\\"#, #"\'"#,
                      "$HOME `id` $(id) ; & | > <", "", "*", "~/x", "trailing\\", "'", "\"double\"", "tab\there",
                      "émoji ✓"]

    /// Each word comes back byte for byte from every shell installed here
    /// that a login shell might be (sh, bash, zsh, and fish where present).
    func testEachWordSurvivesEveryShell() throws {
        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        XCTAssertGreaterThanOrEqual(shells.count, 3)
        for shell in shells {
            let line = "printf '%s\\000' " + RemoteQuoting.command(Self.hard)
            let output = try run(shell, ["-c", line])
            let words = output.split(separator: 0, omittingEmptySubsequences: false).dropLast()
                .map { String(decoding: $0, as: UTF8.self) }
            XCTAssertEqual(words, Self.hard, shell)
        }
    }

    /// The nested form every remote command takes: a fixed script, quoted
    /// once, its arguments quoted beside it, read by the login shell and
    /// then by `sh`.
    func testTheShellCommandShapeCarriesArgumentsIntact() throws {
        let script = #"for a in "$@"; do printf '%s\000' "$a"; done"#
        for shell in ["/bin/sh", "/bin/zsh", "/bin/bash"] {
            let command = RemoteQuoting.shellCommand(script: script, args: Self.hard, path: "/usr/bin:/bin")
            XCTAssertTrue(command.hasPrefix("'env' 'PATH=/usr/bin:/bin' 'sh' '-c' "))
            let output = try run(shell, ["-c", command])
            let words = output.split(separator: 0, omittingEmptySubsequences: false).dropLast()
                .map { String(decoding: $0, as: UTF8.self) }
            XCTAssertEqual(words, Self.hard, shell)
        }
        // Without a resolved PATH, no assignment at all.
        XCTAssertTrue(RemoteQuoting.shellCommand(script: "true", args: [], path: nil).hasPrefix("'sh' '-c' 'true' 'temple'"))
    }

    /// A pane command quoted inside a script quoted inside the remote
    /// string: three levels, one function.
    func testNestedQuotingThroughThreeShells() throws {
        let inner = RemoteQuoting.command(["printf", "%s|", "it's", "a\\b", "x y"])
        let middle = RemoteQuoting.command(["sh", "-c", inner])
        let outer = RemoteQuoting.shellCommand(script: #"eval "$1""#, args: [middle], path: nil)
        XCTAssertEqual(String(decoding: try run("/bin/zsh", ["-c", outer]), as: UTF8.self), "it's|a\\b|x y|")
    }

    func testTheTokenAllowlist() {
        for token in ["abc", "A-b_c.9", "0123456789abcdef"] { XCTAssertTrue(RemoteQuoting.isSafeToken(token), token) }
        for token in ["", "a b", "a'b", "a;b", "a/b", "é", "$x", "a\nb"] { XCTAssertFalse(RemoteQuoting.isSafeToken(token), token) }
    }

    private func run(_ shell: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/private/tmp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, shell)
        return data
    }
}

final class RemoteHostRecordTests: XCTestCase {
    func testOldAndPartialJSONDecodes() throws {
        let json = #"""
        [{"name":"box"},
         {"name":"added","source":"temple","address":"10.0.0.2","user":"me","port":2222,"identityFile":"~/.ssh/id_box","proxyJump":"bastion","future":"ignored"},
         {"source":"temple"},
         "not an object",
         {"name":"box","source":"config"}]
        """#
        let list = RemoteHostList.decode(Data(json.utf8))
        XCTAssertEqual(list.records, [
            .config("box"),
            RemoteHostRecord(name: "added", source: .temple, address: "10.0.0.2", user: "me", port: 2222,
                             identityFile: "~/.ssh/id_box", proxyJump: "bastion"),
        ])
        XCTAssertEqual(list.unreadable.count, 2, "no name, not an object: kept, not erased")
        // A round trip writes the unreadable entries back as they were.
        let again = RemoteHostList.decode(list.encode())
        XCTAssertEqual(again.records, list.records)
        XCTAssertEqual(again.unreadable.count, 2)
        // A duplicate name is the same host, so a removal takes it for good.
        var removed = list
        removed.records.removeAll { $0.name == "box" }
        XCTAssertEqual(RemoteHostList.decode(removed.encode()).records.map(\.name), ["added"])
        XCTAssertEqual(RemoteHostList.decode(nil), RemoteHostList())
        XCTAssertEqual(RemoteHostList.decode(Data("garbage".utf8)), RemoteHostList())
    }

    func testAnEntryWithoutSourceIsAConfigAlias() throws {
        let record = try JSONDecoder().decode(RemoteHostRecord.self, from: Data(#"{"name":"jetson"}"#.utf8))
        XCTAssertEqual(record, .config("jetson"))
        XCTAssertEqual(record.host, HostID(rawValue: "jetson"))
    }

    func testFormValidation() {
        var form = RemoteHostForm()
        form.name = "box"; form.address = "10.0.0.2"; form.user = "me"; form.port = "2222"
        form.identityFile = "~/.ssh/id with space"; form.proxyJump = "bastion,other"
        guard case .success(let record) = form.validate(editing: nil, existing: [], configAliases: []) else {
            return XCTFail("valid form refused")
        }
        XCTAssertEqual(record, RemoteHostRecord(name: "box", source: .temple, address: "10.0.0.2", user: "me", port: 2222,
                                                identityFile: "~/.ssh/id with space", proxyJump: "bastion,other"))

        func problems(_ edit: (inout RemoteHostForm) -> Void, existing: Set<String> = [], aliases: Set<String> = [],
                      editing: String? = nil) -> [RemoteHostForm.Field: String] {
            var form = RemoteHostForm()
            form.name = "box"; form.address = "host"
            edit(&form)
            if case .failure(let problems) = form.validate(editing: editing, existing: existing, configAliases: aliases) {
                return problems.byField
            }
            return [:]
        }
        XCTAssertEqual(problems { $0.name = "" }[.name], "Give the host a name.")
        XCTAssertEqual(problems { $0.name = "-oProxyCommand=x" }[.name], "A name can't start with a dash.")
        XCTAssertEqual(problems { $0.name = "my box" }[.name], "Use letters, digits, dots, dashes and underscores.")
        XCTAssertEqual(problems({ _ in }, aliases: ["box"])[.name],
                       "~/.ssh/config already has a host named box. Turn it on under From ~/.ssh/config instead.")
        XCTAssertEqual(problems({ _ in }, existing: ["box"])[.name], "Temple already has a host named box.")
        XCTAssertNil(problems({ _ in }, existing: ["box"], editing: "box")[.name], "editing keeps its own name")
        XCTAssertEqual(problems { $0.address = "" }[.address], "Enter the host's address.")
        XCTAssertEqual(problems { $0.address = "-oProxyCommand=evil" }[.address],
                       "An address can't contain spaces or start with a dash.")
        XCTAssertEqual(problems { $0.address = "a b" }[.address], "An address can't contain spaces or start with a dash.")
        XCTAssertEqual(problems { $0.user = "a b" }[.user], "A user name can't contain spaces or start with a dash.")
        for port in ["0", "65536", "x", "-1", "22.5"] {
            XCTAssertEqual(problems { $0.port = port }[.port], "A port is a number from 1 to 65535.", port)
        }
        XCTAssertNil(problems { $0.port = "65535" }[.port])
        XCTAssertEqual(problems { $0.identityFile = "a\"b" }[.identityFile],
                       "Temple can't pass a path with a double quote or a line break to ssh.")
        XCTAssertEqual(problems { $0.proxyJump = "-J x" }[.proxyJump], "A jump host can't contain spaces or start with a dash.")
    }

    func testCopyAsSSHConfig() {
        let record = RemoteHostRecord(name: "box", source: .temple, address: "10.0.0.2", user: "me", port: 2222,
                                      identityFile: "~/.ssh/my key", proxyJump: "bastion")
        XCTAssertEqual(record.sshConfigBlock, """
        Host box
            HostName 10.0.0.2
            User me
            Port 2222
            IdentityFile "~/.ssh/my key"
            ProxyJump bastion

        """)
        XCTAssertEqual(RemoteHostRecord(name: "b", source: .temple, address: "a").sshConfigBlock, "Host b\n    HostName a\n")
    }
}

final class SSHConfigHostsTests: XCTestCase {
    func testAliasesSkipPatternsNegationsAndMatch() {
        let text = """
        # comment
        Host box jetson-mentes
          HostName 10.0.0.2
        Host *.lan !secret prod-?
          User x
        host=lower
        HOST  "quoted name"  after # trailing comment
        Match host foo exec "true"
          User y
        Host *
          ServerAliveInterval 30
        Host box
        Host -oops
        """
        XCTAssertEqual(SSHConfigHosts.aliases(in: text), ["box", "jetson-mentes", "lower", "quoted name", "after"])
    }

    func testIncludeIsFollowedOneLevel() throws {
        let tree = TempTree("ssh-config")
        let ssh = tree.directory(".ssh")
        tree.write(".ssh/config", """
        Host first
        Include config.d/*
        Include ~/.ssh/extra
        Include /nonexistent/file
        Host last
        """)
        tree.write(".ssh/config.d/a", "Host from-a\nInclude nested\n")
        tree.write(".ssh/config.d/b", "Host from-b *.wild\n")
        tree.write(".ssh/nested", "Host too-deep\n")
        tree.write(".ssh/extra", "Host from-extra first\n")
        let aliases = SSHConfigHosts.load(configURL: ssh.appendingPathComponent("config"), sshDirectory: ssh, home: tree.path)
        XCTAssertEqual(aliases, ["first", "from-a", "from-b", "from-extra", "last"])
        XCTAssertEqual(SSHConfigHosts.load(configURL: ssh.appendingPathComponent("missing"), sshDirectory: ssh, home: tree.path), [])
    }
}
