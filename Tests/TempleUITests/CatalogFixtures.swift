import Foundation
import TempleCore
@testable import TempleUI

// Explicit transcript facts for isolated catalog fixtures.
func catalogFixture(id: String, agent: Agent, projectPath: String, title: String,
                    createdAt: Date?, updatedAt: Date, filePath: URL,
                    messageCount: Int? = nil, model: String? = nil,
                    lastMessagePreview: String? = nil, gitBranch: String? = nil,
                    originator: String? = nil) -> TranscriptSummary {
    TranscriptSummary(id: id, agent: agent, locator: TranscriptLocator(localURL: filePath),
        modifiedAt: updatedAt, cwd: projectPath, firstPrompt: title, createdAt: createdAt,
        gitBranch: gitBranch, model: model, messageCount: messageCount,
        lastMessagePreview: lastMessagePreview, originator: originator)
}

extension TranscriptSummary {
    var title: String { titleFact ?? legacyTitleHint ?? laterPromptHint ?? (agent == .claude ? "(untitled)" : "(no prompt)") }
    var projectPath: String { cwd ?? directoryHint ?? "(unknown)" }
    var updatedAt: Date { modifiedAt }
    var filePath: URL { locator.localURL! }
    var resume: (argv: [String], cwd: String) { (agent.resumeArgv(sessionID: id), projectPath) }
}
extension EngineSnapshot {
    /// The parsed facts this snapshot authorizes, newest first.
    var allSessions: [TranscriptSummary] {
        facts.values.compactMap(\.summary).sorted { $0.modifiedAt == $1.modifiedAt ? $0.id < $1.id : $0.modifiedAt > $1.modifiedAt }
    }
}

extension AuthorizedFacts {
    /// Facts for a summary, authorized for the row's current membership.
    static func current(_ summary: TranscriptSummary, in db: TempleDB, opRevision: UInt64 = 1) -> AuthorizedFacts? {
        guard let incarnation = try? db.sessionState(summary.id)?.incarnation else { return nil }
        return AuthorizedFacts(authorization: .init(runEpoch: 1, opRevision: opRevision, incarnation: incarnation),
                               locator: summary.locator, agent: summary.agent,
                               signature: TranscriptSignature(modifiedAt: summary.modifiedAt, size: 1, identity: 1),
                               coverage: 1, sharedRevision: nil, summary: summary)
    }
}

extension EngineSnapshot {
    /// Resolutions, and the summaries as facts authorized against `db`'s rows.
    static func authorized(generation: UInt64, resolutions: [String: MemberResolution],
                           summaries: [String: TranscriptSummary], in db: TempleDB, opRevision: UInt64 = 1) -> EngineSnapshot {
        EngineSnapshot(generation: generation, resolutions: resolutions,
                       facts: summaries.compactMapValues { AuthorizedFacts.current($0, in: db, opRevision: opRevision) })
    }
}

struct CatalogFixtureProject {
    let path: String
    let sessions: [TranscriptSummary]
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
struct CatalogFixtureIndex {
    let projects: [CatalogFixtureProject]
    var allSessions: [TranscriptSummary] { projects.flatMap(\.sessions) }
    static func grouping(_ summaries: [TranscriptSummary]) -> Self {
        Self(projects: Dictionary(grouping: summaries, by: \.projectPath).map {
            CatalogFixtureProject(path: $0.key, sessions: $0.value.sorted { $0.modifiedAt > $1.modifiedAt })
        }.sorted { ($0.sessions.first?.modifiedAt ?? .distantPast) > ($1.sessions.first?.modifiedAt ?? .distantPast) })
    }
    var snapshot: EngineSnapshot { EngineSnapshot(generation: 1,
        resolutions: Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, .loaded($0.filePath)) })) }
    func snapshot(authorizedBy db: TempleDB, generation: UInt64 = 1) -> EngineSnapshot {
        .authorized(generation: generation,
                    resolutions: Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, .loaded($0.filePath)) }),
                    summaries: Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, $0) }), in: db)
    }
}

/// Hand-fed catalog streams speak for this Mac unless a test names a host.
extension AsyncStream.Continuation where Element == HostCatalogEvent {
    @discardableResult
    func yield(_ batch: CatalogBatch, host: HostID = .local) -> YieldResult {
        yield(HostCatalogEvent(host: host, batch: batch))
    }
}
