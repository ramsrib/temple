import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

/// The pane's view of the terminal under Temple's own tmux chain, on each
/// box (opt-in, `TEMPLE_REMOTE_ACCEPTANCE`): a private server configured
/// exactly as a launch configures it, attached from a pty whose "terminal"
/// is dark and answers colour queries (OSC 10/11) as Temple's does. The
/// pane asks for the colours and reads what comes back, and the outer
/// title is checked to stay empty until the pane titles itself.
///
/// What it showed (2026-10-16): tmux 3.4 (masterblaster) asks the outer
/// terminal itself on attach and answers the pane with exactly its colours,
/// so Codex picks its palette from Temple's real background; tmux 3.2a
/// (jetson) neither asks nor answers (colour reports arrived in 3.3) and
/// no option changes that, so Codex there gets no answer and keeps its
/// default palette. Nothing Temple can set on 3.2a; said in the design doc.
extension LinuxAcceptanceTests {
    static let terminalHarness = #"""
    import os, pty, sys, time, select, re, subprocess, tempfile, shutil
    head = sys.argv[1]
    sock = "temple-accept-term-%d" % os.getpid()
    d = tempfile.mkdtemp(prefix="temple-accept-term-")
    out = os.path.join(d, "answer")
    pane = ("o=%s; sleep 1; stty raw -echo; t=$(tty); dd bs=1 count=400 if=$t of=$o.raw 2>/dev/null & p=$!; "
            "printf '\\033]10;?\\033\\\\\\033]11;?\\033\\\\\\033[c'; sleep 3; kill $p; "
            "od -An -v -tx1 $o.raw | tr -d ' \\n' > $o.t; mv $o.t $o; "
            "printf '\\033]2;Agent title\\033\\\\'; sleep 5") % out
    cmd = ["sh", "-c", 'exec tmux -L "$1" -f /dev/null ' + head + ' new-session -s x -c / "$2"', "sh", sock, pane]
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.environ.pop("TMUX", None)
        os.execvp(cmd[0], cmd)
    seen = b""; asked = set(); start = time.time(); titles = []
    while time.time() - start < 12:
        r, _, _ = select.select([fd], [], [], 0.1)
        if fd in r:
            try: data = os.read(fd, 65536)
            except OSError: break
            seen += data
            for code, colour in ((b"10", b"rgb:eeee/eeee/eeee"), (b"11", b"rgb:1111/1212/1313")):
                if code not in asked and re.search(rb"\x1b\]" + code + rb";\?(\x07|\x1b\\)", seen):
                    os.write(fd, b"\x1b]" + code + b";" + colour + b"\x1b\\"); asked.add(code)
        if b"Agent title" in seen and os.path.exists(out): break
    titles = [m.group(1).decode("utf-8", "replace") for m in re.finditer(rb"\x1b\][02];([^\x07\x1b]*)(?:\x07|\x1b\\)", seen)]
    answer = bytes.fromhex(open(out).read()) if os.path.exists(out) else b""
    print("version\t" + subprocess.run(["tmux", "-V"], capture_output=True, text=True).stdout.strip())
    print("asked\t" + ",".join(sorted(c.decode() for c in asked)))
    print("fg\t" + ("yes" if b"]10;rgb:eeee/eeee/eeee" in answer else "no"))
    print("bg\t" + ("yes" if b"]11;rgb:1111/1212/1313" in answer else "no"))
    print("da\t" + ("yes" if b"\x1b[?" in answer else "no"))
    print("titles\t" + "|".join(titles))
    subprocess.run(["tmux", "-L", sock, "kill-server"], capture_output=True)
    shutil.rmtree(d, ignore_errors=True)
    try: os.remove("%s/tmux-%d/%s" % (os.environ.get("TMUX_TMPDIR", "/tmp"), os.getuid(), sock))
    except OSError: pass
    """#

    func testTerminalColoursAndTitleUnderTemplesChainOnEachHost() async throws {
        guard !hosts.isEmpty else { throw XCTSkip("set TEMPLE_REMOTE_ACCEPTANCE=<alias>[,<alias>] to run") }
        for name in hosts {
            precondition(name.hasSuffix("-mentes"), "acceptance runs only against the -mentes agent accounts")
            let state = TempTree("acceptance-term")
            let sessions = await RemoteSessions(record: .config(name), stateDirectory: state.url, sshPath: "/usr/bin/ssh",
                                                store: { try RemoteStateStore(directory: state.url) })
            let exec = try await sessions.queryExec()
            let output = try await exec.run(script: #"exec python3 -c "$1" "$2""#,
                                            args: [Self.terminalHarness, TmuxChain.head], deadline: 40)
            var fields: [String: String] = [:]
            for line in output.stdout.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
            }
            print("== \(name): \(fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
            XCTAssertEqual(fields["da"], "yes", "\(name): the harness reads the pane's answers (\(output.stderr))")
            let version = TmuxVersion(fields["version"] ?? "")
            let reports = version.map { $0 >= TmuxVersion(major: 3, minor: 3) } ?? true
            XCTAssertEqual(fields["fg"], reports ? "yes" : "no", "\(name): OSC 10 under \(fields["version"] ?? "?")")
            XCTAssertEqual(fields["bg"], reports ? "yes" : "no", "\(name): OSC 11 under \(fields["version"] ?? "?")")
            let titles = (fields["titles"] ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            XCTAssertTrue(titles.contains("Agent title"), "\(name): the agent's title reaches the terminal: \(titles)")
            XCTAssertFalse(titles.contains { !$0.isEmpty && $0 != "Agent title" }, "\(name): no other title, the host's name included: \(titles)")
        }
    }
}
