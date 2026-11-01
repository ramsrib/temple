import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

/// Open a session by id's lookup on a host (docs/designs/
/// open-existing-sessions.md section 5): per agent, found only after a
/// confirming read, "not found" only for a store listed to the end, and a
/// failed transport never either.
final class RemoteLookupTests: XCTestCase {
    typealias Box = RemoteSourceTests.Box
    typealias Provider = RemoteSourceTests.Provider
    static let host = RemoteSourceTests.host

    let fixtures = RemoteSourceTests()
    func uuid() -> String { UUID().uuidString.lowercased() }

    func source(_ box: Box, roots: [Agent: RemoteTranscriptRoot]? = nil) -> RemoteSessionSource {
        RemoteSessionSource(host: Self.host, provider: Provider(box.exec, roots: roots))
    }

    func testFoundClaudeSessionCarriesItsFolder() async throws {
        let box = Box()
        let id = uuid()
        box.claude(id, lines: fixtures.claudeLines(id, cwd: "/work/app"))
        let lookup = try await source(box).lookup(id: id)
        guard case .found(let locator, let directory) = lookup[.claude] else { return XCTFail("\(lookup)") }
        XCTAssertEqual(locator.host, Self.host)
        XCTAssertTrue(locator.path.hasSuffix("/\(id).jsonl"))
        XCTAssertEqual(directory, "/work/app")
        XCTAssertEqual(lookup[.codex], .notFound, "Codex's store was there and listed to the end")
        XCTAssertEqual(lookup.found, [.claude])
    }

    func testFoundCodexSession() async throws {
        let box = Box()
        let id = uuid()
        box.codex(id, lines: fixtures.codexLines(id, cwd: "/work/api"))
        let lookup = try await source(box).lookup(id: id)
        guard case .found(_, let directory) = lookup[.codex] else { return XCTFail("\(lookup)") }
        XCTAssertEqual(directory, "/work/api")
        XCTAssertEqual(lookup[.claude], .notFound)
    }

    func testNeitherStoreHasItIsNotFoundAnywhere() async throws {
        let box = Box()
        let lookup = try await source(box).lookup(id: uuid())
        XCTAssertTrue(lookup.notFoundAnywhere)
    }

    func testMissingStoreIsCannotTellNeverNotFound() async throws {
        let box = Box()
        try FileManager.default.removeItem(atPath: box.home + "/.codex")
        let lookup = try await source(box).lookup(id: uuid())
        XCTAssertEqual(lookup[.codex], .cannotTell(.noStore))
        XCTAssertEqual(lookup[.claude], .notFound)
        XCTAssertFalse(lookup.notFoundAnywhere)
    }

    func testFoundAgentWinsOverTheOtherStoresTrouble() async throws {
        let box = Box()
        let id = uuid()
        box.claude(id, lines: fixtures.claudeLines(id))
        try FileManager.default.removeItem(atPath: box.home + "/.codex")
        let lookup = try await source(box).lookup(id: id)
        XCTAssertEqual(lookup.found, [.claude])
    }

    func testUnknownRootIsCannotTell() async throws {
        let box = Box()
        let lookup = try await source(box, roots: [.claude: RemoteTranscriptRoot(.unset, base: nil)!]).lookup(id: uuid())
        XCTAssertEqual(lookup[.codex], .cannotTell(.storeUnknown))
    }

    func testFileNamedForTheIdButRecordingAnotherSessionCannotTell() async throws {
        let box = Box()
        let id = uuid(), other = uuid()
        box.claude(id, lines: fixtures.claudeLines(other))
        let lookup = try await source(box).lookup(id: id)
        XCTAssertEqual(lookup[.claude], .cannotTell(.notThisSession), "a file name is not identity")
    }

    func testBothAgentsHaveTheId() async throws {
        let box = Box()
        let id = uuid()
        box.claude(id, lines: fixtures.claudeLines(id))
        box.codex(id, lines: fixtures.codexLines(id))
        let lookup = try await source(box).lookup(id: id)
        XCTAssertEqual(lookup.found, [.claude, .codex])
    }

    func testTransportFailureThrows() async {
        let box = Box()
        let watching = RemoteSourceTests.Watching(box.exec)
        watching.broken = true
        let source = RemoteSessionSource(host: Self.host, provider: Provider(watching))
        do {
            _ = try await source.lookup(id: uuid())
            XCTFail("expected a transport failure")
        } catch {
            guard case LocateError.transport = error else { return XCTFail("\(error)") }
        }
    }

    /// A store folder without its sessions folder searched nothing: never
    /// "not found".
    func testStoreWithoutItsSessionsFolderCannotTell() async throws {
        let box = Box()
        try FileManager.default.removeItem(atPath: box.home + "/.codex/sessions")
        try FileManager.default.removeItem(atPath: box.home + "/.claude/projects")
        let lookup = try await source(box).lookup(id: uuid())
        XCTAssertEqual(lookup[.codex], .cannotTell(.noStore))
        XCTAssertEqual(lookup[.claude], .cannotTell(.noStore))
        XCTAssertFalse(lookup.notFoundAnywhere)
    }

    /// An id no host could name is refused before any host is asked.
    func testAnIdThatIsNoIdIsNeverNotFound() async {
        let box = Box()
        let watching = RemoteSourceTests.Watching(box.exec)
        let source = RemoteSessionSource(host: Self.host, provider: Provider(watching))
        do {
            _ = try await source.lookup(id: "not an id;")
            XCTFail("expected a refusal")
        } catch {}
        XCTAssertEqual(watching.calls, 0)
    }
}
