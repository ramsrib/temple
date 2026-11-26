import Foundation
import XCTest
@testable import TempleRemoteHost

/// A file dropped or pasted onto a tab on a host, copied there by the
/// real script under `/bin/sh` with a temp `TMPDIR` and a temp fallback
/// for `/tmp` (no network, nothing outside the test's folder).
final class FileHandoffTests: XCTestCase {
    let tree = TempTree("temple-handoff")
    var tmp: String { tree.path + "/tmp" }
    var fallback: String { tree.path + "/fallback" }

    func exec(tmpdir: String?) -> LocalShellExec {
        var environment = hostEnvironment(home: tree.path + "/home", path: "/usr/bin:/bin")
        environment["TMPDIR"] = tmpdir
        return LocalShellExec(path: nil, environment: environment)
    }
    var exec: LocalShellExec { exec(tmpdir: tmp) }

    override func setUp() {
        super.setUp()
        _ = tree.directory("tmp")
        _ = tree.directory("home")
        _ = tree.directory("fallback")
        chmod(tmp, 0o755)
        chmod(fallback, 0o700)
        FileHandoff.fallbackFolder = fallback
    }

    override func tearDown() {
        FileHandoff.fallbackFolder = "/tmp"
        super.tearDown()
    }

    func testAScreenshotArrivesWholeUnderItsOwnNameInAPrivateFolderOfItsOwn() async throws {
        // Every byte value, so nothing on the way treats the payload as text.
        let bytes = Data((0..<(300 << 10)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let source = tree.url.appendingPathComponent("Screenshot 2026-11-26 at 14.03.22.png")
        try bytes.write(to: source)

        let result = await FileHandoff.copy(source, host: "box", using: exec)
        guard case .copied(let path) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(path.hasPrefix(tmp + "/temple-"), path)
        XCTAssertEqual((path as NSString).lastPathComponent, "Screenshot-2026-11-26-at-14.03.22.png")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        let folder = (path as NSString).deletingLastPathComponent
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), [(path as NSString).lastPathComponent],
                       "nothing but the whole file (no .part)")

        // A second drop of the same name gets a folder of its own.
        guard case .copied(let again) = await FileHandoff.copy(source, host: "box", using: exec) else { return XCTFail() }
        XCTAssertNotEqual((again as NSString).deletingLastPathComponent, folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// A `TMPDIR` other accounts could change, or one that isn't a plain
    /// absolute path, is not used: the fallback is.
    func testAnUntrustedTmpdirIsPassedOverForTheFallback() async throws {
        let groupWritable = tree.directory("group").path
        chmod(groupWritable, 0o775)   // the account's own, but its group can write in it
        chmod(tmp, 0o777)   // the account's own, but anyone can write in it
        let spaced = tree.directory("with space").path
        for tmpdir in [tmp, groupWritable, "tmp", spaced, tree.path + "/missing"] {
            guard case .copied(let path) = await FileHandoff.copy(Data("x".utf8), named: "a.txt", host: "box",
                                                                  using: exec(tmpdir: tmpdir)) else {
                return XCTFail(tmpdir)
            }
            XCTAssertTrue(path.hasPrefix(fallback + "/temple-"), "\(tmpdir): \(path)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp), [])
    }

    func testNothingIsWrittenWhenNoTemporaryFolderCanBeTrusted() async throws {
        chmod(tmp, 0o777)
        chmod(fallback, 0o777)
        let result = await FileHandoff.copy(Data("x".utf8), named: "a.txt", host: "box", using: exec)
        guard case .failed(let why) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(why.hasPrefix("\(fallback) on box can be changed by other accounts"), why)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fallback), [])
    }

    func testFoldersAndOversizedFilesAreRefusedBeforeAnythingIsSent() async throws {
        let directory = tree.directory("shots")
        guard case .failed(let why) = await FileHandoff.copy(directory, host: "box", using: exec) else { return XCTFail() }
        XCTAssertEqual(why, "shots is a folder. Open it and drag the files you want.")

        // Sparse: the size is what counts, not the disk it takes.
        let huge = tree.url.appendingPathComponent("huge.mov")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(FileHandoff.maximumBytes + 1))
        try handle.close()
        guard case .failed(let tooBig) = await FileHandoff.copy(huge, host: "box", using: exec) else { return XCTFail() }
        XCTAssertEqual(tooBig, "huge.mov is larger than 100 MB. Temple copies files up to 100 MB.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp), [], "nothing reached the host")
    }

    /// A link is copied as what it points at; a pipe is never read (it
    /// would never end).
    func testALinkCopiesItsTargetAndAPipeIsRefused() async throws {
        let target = tree.url.appendingPathComponent("real.txt")
        try Data("real".utf8).write(to: target)
        let link = tree.url.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        guard case .copied(let path) = await FileHandoff.copy(link, host: "box", using: exec) else { return XCTFail() }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "real")
        XCTAssertTrue(path.hasSuffix("/link.txt"), "named as dropped")

        let fifo = tree.url.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let refused = await FileHandoff.copy(fifo, host: "box", using: exec)
        XCTAssertEqual(refused, .failed("pipe couldn't be read on this Mac."))
    }

    func testANameIsMadeSafeForTheHostAndKeepsItsExtension() {
        XCTAssertEqual(FileHandoff.hostFileName("shot 1.png"), "shot-1.png")
        XCTAssertEqual(FileHandoff.hostFileName("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(FileHandoff.hostFileName("..."), "file")
        XCTAssertEqual(FileHandoff.hostFileName("über’s $(rm) `x`.jpg"), "ber-s-rm-x.jpg")
        XCTAssertEqual(FileHandoff.hostFileName("日本語.png"), "file.png", "the extension survives a name with none left")
        XCTAssertEqual(FileHandoff.hostFileName("-n"), "n")
        let long = FileHandoff.hostFileName(String(repeating: "a", count: 300) + ".jpeg")
        XCTAssertEqual(long.count, 100)
        XCTAssertTrue(long.hasSuffix(".jpeg"))
        for name in ["", " ", "日本語.png", "a\nb.txt", "'quoted'.pdf"] {
            XCTAssertTrue(RemoteQuoting.isSafeToken(FileHandoff.hostFileName(name)), name)
        }
    }

    /// Only a whole answer for this copy, from a command that ended well,
    /// is believed: an absolute path in its own folder, under its own name.
    func testOnlyThisCopysOwnPathIsBelieved() {
        func parse(_ stdout: String, status: Int32 = 0) -> FileHandoff.Result {
            FileHandoff.parse(RemoteOutput(status: status, stdout: stdout, stderr: ""), folder: "ab12", name: "s.png",
                              size: 10, host: "box")
        }
        let good = "/tmp/temple-ab12-Xy3kQ9zA/s.png"
        XCTAssertEqual(parse("temple-copied \(good)\n"), .copied(path: good))
        XCTAssertNotEqual(parse("temple-copied \(good)\n", status: 255), .copied(path: good), "ssh failed")
        XCTAssertNotEqual(parse("temple-copied tmp/temple-ab12-Xy3kQ9zA/s.png\n"),
                          .copied(path: "tmp/temple-ab12-Xy3kQ9zA/s.png"), "relative")
        XCTAssertNotEqual(parse("temple-copied /tmp/temple-other-Xy3kQ9zA/s.png\n"),
                          .copied(path: "/tmp/temple-other-Xy3kQ9zA/s.png"), "another copy's folder")
        XCTAssertNotEqual(parse("temple-copied /tmp/x\n"), .copied(path: "/tmp/x"), "cut short")
        XCTAssertEqual(parse("temple-copy-short 4\n"),
                       .failed("Only 4 bytes of 10 bytes arrived, so the partial copy on box was removed. Try again."))
        XCTAssertEqual(parse(""), .failed("Temple couldn't confirm the copy reached box. Try again."))
    }
}
