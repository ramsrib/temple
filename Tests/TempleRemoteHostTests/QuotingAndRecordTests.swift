import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

final class RemoteQuotingTests: XCTestCase {
    static let hard = ["plain", "two words", "it's", #"'\''"#, "line\nbreak", #"back\slash"#, #"\\"#, #"\'"#,
                      "$HOME `id` $(id) ; & | > <", "", "*", "~/x", "trailing\\", "'", "\"double\"", "tab\there",
                      "émoji ✓", "x'\u{0301}; id; #", "\\\u{0301}", "'\u{0301}\u{0302}", "a\u{0301}'b"]

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

    /// Every query travels as a fixed bootstrap on the command line and
    /// its program on stdin: the arguments come back byte for byte through
    /// each login shell, PATH is the resolved one, the query's own input
    /// follows the program, and the command line is the same size however
    /// long the values (design note 21).
    func testAQueryCarriesEverythingOnStdinBehindAFixedCommand() throws {
        let script = #"for a in "$@"; do printf '%s\000' "$a"; done; printf 'PATH=%s\000' "$PATH"; cat"#
        let longPath = "/usr/bin:/bin:" + String(repeating: "/very/long/path/entry:", count: 2_000)
        let input = Data("after the program\n".utf8)
        let short = RemoteQuoting.invocation(script: "true", args: [], path: nil, input: nil, end: "__temple_end_x__")
        for shell in ["/bin/sh", "/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            where FileManager.default.isExecutableFile(atPath: shell) {
            let query = RemoteQuoting.invocation(script: script, args: Self.hard + [String(repeating: "x", count: 50_000)],
                                                 path: longPath, input: input, end: "__temple_end_x__")
            XCTAssertEqual(query.command, short.command, "the command line never carries a value")
            XCTAssertLessThan(query.command.utf8.count, 512)
            let output = try run(shell, ["-c", query.command], stdin: query.stdin)
            let fields = output.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            XCTAssertEqual(Array(fields.prefix(Self.hard.count + 1)), Self.hard + [String(repeating: "x", count: 50_000)], shell)
            XCTAssertEqual(fields[Self.hard.count + 1], "PATH=" + longPath, shell)
            XCTAssertEqual(fields.last, "after the program\n", shell)
        }
    }

    /// One invariant for every ssh command line Temple builds: a short,
    /// fixed bootstrap. Every real query script, over both query
    /// transports, with long PATH, arguments and input, and every
    /// interactive command (the tab's executor for the longest stage name,
    /// the Test connection's), stays within `LaunchStage.maximumCommandBytes`.
    func testEveryCommandLineTempleBuildsIsShort() {
        let connection = SSHConnection(record: .config("box"), stateDirectory: URL(fileURLWithPath: "/private/tmp/temple-b-env/state"),
                                       sshPath: "/usr/bin/ssh")
        let longPath = String(repeating: "/a/very/long/path/entry:", count: 2_000) + "/usr/bin:/bin"
        let long = String(repeating: "x'\n\\ ", count: 5_000)
        let queries: [(String, [String])] = [
            (RemoteEnvironment.script, ["__temple_path_x__"]),
            (LaunchRecords.fetchScript, ["r-m"]), (LaunchRecords.acknowledgeScript, ["r-m", "all"]),
            (LaunchRecords.outputScript, ["r-m"]), (FolderCheck.script, [long]),
            (ConversationCheck.script, ["set", long, long, "id"]),
            (LaunchStage.writeScript, ["r-m.s-cx", "123456"]), (LaunchStage.discardScript, ["r-m.s-cx"]),
            (LaunchStage.discardRunScript, ["r-m"]),
            (TmuxKeepAlive.hasSessionScript, [long, "temple-h"]), (TmuxKeepAlive.probeScript, [long, "temple-h"]),
            (TmuxKeepAlive.stopScript, [long, "temple-h", "30"]),
            (ToolCheck.script, ["claude"]), (TmuxCheck.script, ["temple-check"]), (LogindCheck.script, []),
        ]
        for (script, args) in queries {
            for purpose in [SSHConnection.Purpose.query, .overMaster] {
                let invocation = SSHExec.invocation(script: script, args: args, path: longPath,
                                                    input: Data(repeating: 0x41, count: 100_000), marker: "__temple_marker__")
                let command = connection.argv(purpose, remoteCommand: invocation.command).last ?? ""
                XCTAssertLessThanOrEqual(command.utf8.count, LaunchStage.maximumCommandBytes, String(script.prefix(40)))
            }
        }
        let stage = LaunchStage.attachName(marker: "r-" + String(repeating: "f", count: 16), nonce: String(repeating: "f", count: 16))
        XCTAssertLessThanOrEqual(LaunchStage.command(stage: stage).utf8.count, LaunchStage.maximumCommandBytes)
        XCTAssertLessThanOrEqual((connection.argv(.interactive, remoteCommand: "true").last ?? "").utf8.count,
                                 LaunchStage.maximumCommandBytes)
    }

    /// A program cut short in transit (no end line) runs nothing.
    func testATruncatedProgramRunsNothing() throws {
        let marker = "/private/tmp/temple-truncated-\(UUID().uuidString)"
        let query = RemoteQuoting.invocation(script: "touch \(marker)", args: [], path: nil, input: nil)
        let cut = query.stdin.prefix(query.stdin.count - 20)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", query.command]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(cut)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 97)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    /// A quote or backslash followed by a combining mark is one Character
    /// but two shell bytes: quoting works on scalars, so it stays quoted.
    func testCombiningMarksCannotHideAQuote() throws {
        let attack = "x'\u{0301}; touch /tmp/temple-should-not-exist; #"
        XCTAssertEqual(RemoteQuoting.quote(attack), "'x'\\''\u{0301}; touch /tmp/temple-should-not-exist; #'")
        let output = try run("/bin/sh", ["-c", "printf '%s' " + RemoteQuoting.quote(attack)])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), attack)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/temple-should-not-exist"))
    }

    func testTheTokenAllowlist() {
        for token in ["abc", "A-b_c.9", "0123456789abcdef"] { XCTAssertTrue(RemoteQuoting.isSafeToken(token), token) }
        for token in ["", "a b", "a'b", "a;b", "a/b", "é", "$x", "a\nb", "a'\u{0301}"] { XCTAssertFalse(RemoteQuoting.isSafeToken(token), token) }
    }

    private func run(_ shell: String, _ arguments: [String], stdin: Data? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/private/tmp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        let input = Pipe()
        if stdin != nil { process.standardInput = input }
        try process.run()
        if let stdin {
            // Written off this thread: the output must drain while it goes.
            let writer = input.fileHandleForWriting
            DispatchQueue.global().async { writer.write(stdin); try? writer.close() }
        }
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

    /// A hand-edited entry that would hand ssh shell syntax is kept in the
    /// store but never becomes a host.
    func testAStoredEntryFailingTheGrammarIsNeverUsed() {
        let json = #"[{"name":"evil","source":"temple","address":"$(touch /tmp/x)"},{"name":"ok","source":"temple","address":"box"}]"#
        let list = RemoteHostList.decode(Data(json.utf8))
        XCTAssertEqual(list.records.map(\.name), ["ok"])
        XCTAssertEqual(list.unreadable.count, 1)
    }

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
        let badAddress = "Enter a host name, an IPv4 address or an IPv6 address."
        for address in ["-oProxyCommand=evil", "a b", "$(id)", "`id`", "a;id", "a|id", "a&id", "a>x", "a'b", "a\"b",
                        "a\\b", "x$y", "a%h", "fe80::1%en0", "a..b", "-a.b", "a.-b", "[::1", "a\nb", "a*b", "~x"] {
            XCTAssertEqual(problems { $0.address = address }[.address], badAddress, address)
        }
        for address in ["box", "box.lan", "my_box-2.example.com", "10.0.0.2", "::1", "[::1]", "2001:db8::42", "host."] {
            XCTAssertNil(problems { $0.address = address }[.address], address)
        }
        var v6 = RemoteHostForm()
        v6.name = "v6"; v6.address = "[::1]"
        if case .success(let record) = v6.validate(editing: nil, existing: Set<String>(), configAliases: Set<String>()) {
            XCTAssertEqual(record.address, "::1", "brackets are taken off for HostName")
        } else { XCTFail("[::1] refused") }
        let badUser = "A user name can use letters, digits, dots, dashes and underscores, and can't start with a dash."
        for user in ["a b", "$(id)", "-l", "a;b", "a@b"] { XCTAssertEqual(problems { $0.user = user }[.user], badUser, user) }
        XCTAssertNil(problems { $0.user = "mentes_2.x-y" }[.user])
        for port in ["0", "65536", "x", "-1", "22.5"] {
            XCTAssertEqual(problems { $0.port = port }[.port], "A port is a number from 1 to 65535.", port)
        }
        XCTAssertNil(problems { $0.port = "65535" }[.port])
        XCTAssertEqual(problems { $0.identityFile = "a\"b" }[.identityFile],
                       "Temple can't pass a path with a double quote or a line break to ssh.")
        let badJump = "A jump host is [user@]host[:port], several separated by commas."
        for jump in ["-J x", "a b", "$(id)", "ssh://x", "a:0", "a:99999", "a,", "u@[::1", "a;b", "x@y@z"] {
            XCTAssertEqual(problems { $0.proxyJump = jump }[.proxyJump], badJump, jump)
        }
        for jump in ["bastion", "me@bastion:2222", "a,b.lan:22", "me@[2001:db8::1]:22", "10.0.0.1"] {
            XCTAssertNil(problems { $0.proxyJump = jump }[.proxyJump], jump)
        }
    }

    /// Host names are taken in ASCII only, with advice for an
    /// international one; the length limit is the name's, an optional
    /// root dot aside; labels are split by byte.
    func testHostNamesAreASCIIOnly() {
        for address in ["bücher.example", "例え.テスト", "a.\u{0301}b", "box\u{0301}"] {
            var form = RemoteHostForm()
            form.name = "idn"; form.address = address
            guard case .failure(let problems) = form.validate(editing: nil, existing: Set<String>(), configAliases: Set<String>()) else {
                return XCTFail("\(address) accepted")
            }
            XCTAssertEqual(problems.byField[.address],
                           "Use the host's ASCII name. For an international name, add it to ~/.ssh/config or enter its xn-- form.")
        }
        var jump = RemoteHostForm()
        jump.name = "j"; jump.address = "box"; jump.proxyJump = "jäger"
        if case .failure(let problems) = jump.validate(editing: nil, existing: Set<String>(), configAliases: Set<String>()) {
            XCTAssertEqual(problems.byField[.proxyJump], HostGrammar.internationalNameAdvice)
        } else { XCTFail("a non-ASCII jump host accepted") }
        XCTAssertTrue(HostGrammar.isAddress("xn--bcher-kva.example"), "the xn-- form is an ASCII name")
        let label = String(repeating: "a", count: 63)
        let longest = [label, label, label, String(repeating: "b", count: 61)].joined(separator: ".")
        XCTAssertEqual(longest.utf8.count, 253)
        XCTAssertTrue(HostGrammar.isAddress(longest))
        XCTAssertTrue(HostGrammar.isAddress(longest + "."), "the root dot does not count")
        XCTAssertFalse(HostGrammar.isAddress(longest + "b"))
        XCTAssertFalse(HostGrammar.isAddress(String(repeating: "a", count: 64) + ".lan"), "a label is 63 at most")
        XCTAssertFalse(HostGrammar.isAddress("."))
        XCTAssertFalse(HostGrammar.isAddress("a..b"))
    }

    func testAnIdentityPathCannotHideAQuoteOrBreak() {
        XCTAssertTrue(HostGrammar.isPassableIdentityPath("~/.ssh/id é"))
        for path in ["a\"\u{0301}b", "a\n\u{0301}", "a\u{7f}", "a\u{2028}b"] {
            XCTAssertFalse(HostGrammar.isPassableIdentityPath(path), path.debugDescription)
        }
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

    /// OpenSSH's own tokenizer (misc.c argv_split), case by case.
    func testWordsFollowOpenSSH() {
        XCTAssertEqual(SSHConfigHosts.words(#"a "b c" 'd e' f"#), ["a", "b c", "d e", "f"])
        XCTAssertEqual(SSHConfigHosts.words(#"a\ b c"#), ["a b", "c"])
        XCTAssertEqual(SSHConfigHosts.words(#"'it\'s' "say \"hi\"" back\\slash"#), ["it's", "say \"hi\"", "back\\slash"])
        XCTAssertEqual(SSHConfigHosts.words(#"un\known \x"#), [#"un\known"#, #"\x"#])
        XCTAssertEqual(SSHConfigHosts.words(#""a\ b""#), [#"a\ b"#], "an escaped space only outside quotes")
        XCTAssertEqual(SSHConfigHosts.words("a#b c #comment d"), ["a#b", "c"])
        XCTAssertEqual(SSHConfigHosts.words(#"x"y z"w"#), ["xy zw"])
        XCTAssertEqual(SSHConfigHosts.words("\ttab\tsep"), ["tab", "sep"])
        XCTAssertNil(SSHConfigHosts.words(#"open "quote"#), "invalid quotes")
        // A quote or backslash with a combining mark after it still acts.
        XCTAssertEqual(SSHConfigHosts.words("'a b'\u{0301} c"), ["a b\u{0301}", "c"])
        XCTAssertNil(SSHConfigHosts.words("\"\u{0301}open"), "the quote opens, and is never closed")
        XCTAssertEqual(SSHConfigHosts.words("a\\\u{0301}b"), ["a\\\u{0301}b"], "an unrecognised escape keeps its backslash")
        XCTAssertEqual(SSHConfigHosts.aliases(in: "Host *\u{0301} ok !\u{0301}no"), ["ok"])
        XCTAssertNil(SSHConfigHosts.words("open 'quote"))
        XCTAssertEqual(SSHConfigHosts.aliases(in: "Host ok\nHost 'broken\nHost after\n"), ["ok", "after"])
    }

    func testQuotedAndEscapedIncludesAreFollowed() throws {
        let tree = TempTree("ssh-config-quoted")
        let ssh = tree.directory(".ssh")
        tree.write(".ssh/config", #"""
        Include 'config.d/*'
        Include config\ extra/hosts
        Include "with space/more"
        """#)
        tree.write(".ssh/config.d/a", "Host from-single-quoted\n")
        tree.write(".ssh/config extra/hosts", "Host from-escaped\n")
        tree.write(".ssh/with space/more", "Host from-double-quoted\n")
        XCTAssertEqual(SSHConfigHosts.load(configURL: ssh.appendingPathComponent("config"), sshDirectory: ssh, home: tree.path),
                       ["from-single-quoted", "from-escaped", "from-double-quoted"])
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
