import XCTest
@testable import TempleCore

/// `RemoteLog` keeps paths out of both sinks (a home folder is a name; a
/// key path says where the keys are), and keeps the host and handle.
final class RemoteLogTests: XCTestCase {
    func testPathsAreCutAndHostAndHandleKept() {
        XCTAssertEqual(RemoteLog.redacted("box h1: reattach failed: Can't create /Users/me/Library/temple/ssh/cm-x: denied"),
                       "box h1: reattach failed: Can't create <path>: denied")
        XCTAssertEqual(RemoteLog.redacted("no such identity: ~/.ssh/id_work (exit 255)"),
                       "no such identity: <path> (exit 255)")
        XCTAssertEqual(RemoteLog.redacted("masterblaster-mentes 3f2a: host says present"),
                       "masterblaster-mentes 3f2a: host says present")
        XCTAssertEqual(RemoteLog.redacted("error connecting to /tmp/tmux-501/temple, ok"), "error connecting to <path>, ok")
    }

    func testQuotedPathsWithSpacesAndTheHomeFolderGoWhole() {
        XCTAssertEqual(RemoteLog.redacted("no such identity: '/Users/Jane Doe/.ssh/id_work'"),
                       "no such identity: '<path>'")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(RemoteLog.redacted("can't write \(home)/x y/z").contains(home))
    }

    func testTextThatIsNotAPathStays() {
        for text in ["see https://example.com/status for more", "tried 1/2 times", "and/or", "retry in ~30 seconds"] {
            XCTAssertEqual(RemoteLog.redacted(text), text)
        }
    }

    /// ssh's first stderr line can be a failing ProxyCommand's, and that
    /// can carry a credential: a URL's password or query, a token.
    func testCredentialsInAnErrorAreCut() {
        let cases = [
            ("proxy: GET https://jane:hunter2@proxy.example.com/connect failed",
             "proxy: GET https://<redacted>@proxy.example.com/connect failed"),
            ("proxy: https://gw.example.com/tunnel?token=abc123&host=box refused",
             "proxy: https://gw.example.com/tunnel?<redacted> refused"),
            ("401 Unauthorized (Authorization: Bearer eyJhbGciOi.x-y_z)", "401 Unauthorized (Authorization: Bearer <redacted>)"),
            ("cloudflared: TUNNEL_TOKEN=sekrit not accepted", "cloudflared: TUNNEL_TOKEN=<redacted> not accepted"),
            ("helper --api-key sk-12345 exited 1", "helper --api-key <redacted> exited 1"),
            ("api_key: sk-12345", "api_key: <redacted>"),
            ("helper: TOKEN='sekrit' rejected", "helper: TOKEN=<redacted> rejected"),
            ("helper --password \"two words\" exited 1", "helper --password <redacted> exited 1"),
            ("{\"api_key\":\"sekrit\",\"host\":\"box\"}", "{\"api_key\":<redacted>,\"host\":\"box\"}"),
        ]
        for (text, expected) in cases { XCTAssertEqual(RemoteLog.redacted(text), expected) }
        for text in ["Too many authentication failures", "Permission denied (publickey,password).",
                     "box h1: reattach failed (2 in a row): connection refused", "Host key verification failed."] {
            XCTAssertEqual(RemoteLog.redacted(text), text)
        }
    }

    func testTheFileGetsRedactedLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remote-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url); RemoteLog.fileURL = nil }
        RemoteLog.fileURL = url
        RemoteLog.error("box h1: failed at /Users/me/secret")
        XCTAssertTrue(RemoteLog.flush())
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("error box h1: failed at <path>"), text)
        XCTAssertFalse(text.contains("/Users/me"))
    }
}
