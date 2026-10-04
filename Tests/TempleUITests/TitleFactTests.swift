import XCTest
import TempleCore
@testable import TempleUI

/// One title chain, from transcript facts to every place a title is written
/// or shown: the fill, the import, History's catalog rows and templectl.
@MainActor
final class TitleFactTests: XCTestCase {
    private func summary(_ id: String, agent: Agent, prompt: String? = nil, recorded: String? = nil,
                         shared: String? = nil, history: String? = nil, legacy: String? = nil) -> TranscriptSummary {
        TranscriptSummary(id: id, agent: agent, locator: TranscriptLocator(localURL: URL(fileURLWithPath: "/tmp/\(id).jsonl")),
            modifiedAt: Date(timeIntervalSince1970: 100), cwd: "/work", firstPrompt: prompt, historyPrompt: history,
            recordedTitle: recorded, sharedTitle: shared, legacyTitleHint: legacy)
    }

    func testTheFactChainPrefersRecordedTitlesAndNeverStoresHints() {
        XCTAssertEqual(summary("c", agent: .claude, prompt: "Prompt", recorded: "Claude summary").titleFact, "Claude summary")
        XCTAssertEqual(summary("x", agent: .codex, prompt: "Prompt", shared: "Thread name").titleFact, "Thread name")
        XCTAssertEqual(summary("p", agent: .codex, prompt: "Prompt", history: "History").titleFact, "Prompt")
        XCTAssertEqual(summary("h", agent: .codex, history: "History").titleFact, "History")
        let hinted = summary("l", agent: .claude, legacy: "<command-name>")
        XCTAssertNil(hinted.titleFact)
        XCTAssertEqual(hinted.catalogTitle, "<command-name>", "a hint may be shown")
        XCTAssertEqual(summary("n", agent: .codex).catalogTitle, Agent.codex.newSessionTitle)
    }

    /// Fills wrote firstPrompt ?? historyPrompt, so a legacy row lost Claude's
    /// recorded summary and Codex's thread name, and History's catalog title
    /// (the summary) disagreed with the row the same session became.
    func testFillAndImportWriteTheTitleHistoryShows() throws {
        let db = try TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: db)
        let claude = summary("claude", agent: .claude, prompt: "First prompt", recorded: "Recorded summary")
        let codex = summary("codex", agent: .codex, shared: "Named thread")
        for item in [claude, codex] { overlay.join(item.id, via: .opened, agent: item.agent) }
        overlay.applyFacts(Dictionary(uniqueKeysWithValues: try [claude, codex].map {
            ($0.id, try XCTUnwrap(AuthorizedFacts.current($0, in: db)))
        }))
        XCTAssertEqual(overlay.rows["claude"]?.title, claude.catalogTitle)
        XCTAssertEqual(overlay.rows["codex"]?.title, "Named thread")

        let imported = summary("imported", agent: .claude, prompt: "First prompt", recorded: "Recorded summary")
        XCTAssertEqual(overlay.import([imported]).map(\.label), ["joined"])
        XCTAssertEqual(try db.sessionState("imported")?.title, "Recorded summary")
        XCTAssertEqual(HistoryRow(catalog: imported).title,
                       HistoryRow(member: Session(state: try XCTUnwrap(db.sessionState("imported"))), catalog: imported).title)
    }

    func testACatalogRowWithNoFolderHasNoProject() {
        let row = HistoryRow(catalog: TranscriptSummary(id: "x", agent: .codex,
            locator: TranscriptLocator(localURL: URL(fileURLWithPath: "/tmp/x.jsonl")), modifiedAt: Date()))
        XCTAssertNil(row.project, "not a key for the empty path, which reads \"/\"")
        XCTAssertTrue(row.resumeArgv.isEmpty == false, "a catalog row resumes by id")
    }
}
