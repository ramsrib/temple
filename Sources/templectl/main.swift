import Foundation
import TempleCore

// Row browsing by default; --disk explicitly browses the transcript catalog.

let df = DateFormatter()
df.dateFormat = "MMM d HH:mm"

let limit = CommandLine.arguments.contains("--all") ? Int.max : 8
let includeNoise = CommandLine.arguments.contains("--all")

if CommandLine.arguments.contains("--help") {
    print("Usage: templectl [--disk] [--watch] [--all] [--search <term>] [--import-all]\n  --disk  browse the transcript catalog instead of Temple rows\n  --all  include noise sessions and do not cap sessions per project\n  --import-all  make every indexed session a Temple session (demo state dirs only)")
    exit(0)
}

func openDatabase(readOnly: Bool = false) throws -> TempleDB {
    do {
        return try readOnly ? TempleDB(readOnlyPath: TempleDB.defaultPath()) : TempleDB(path: TempleDB.defaultPath())
    } catch TempleDBError.newerSchema {
        FileHandle.standardError.write(Data((TempleDBError.updateRequiredMessage + "\n").utf8))
        exit(1)
    }
}

// `make demo` seeds sessions Temple never saw; this imports each one so the
// demo sidebar has something in it. Refused against the real state dir:
// a row for every session on disk would erase the line the sidebar draws,
// and there is no telling those rows from the ones the user made.
if CommandLine.arguments.contains("--import-all") {
    guard TempleState.isRedirected else {
        FileHandle.standardError.write(Data("templectl: --import-all needs TEMPLE_STATE_DIR set to a directory other than the real state dir\n".utf8))
        exit(1)
    }
    let db = try openDatabase()
    let sessions = ClaudeSessionStore().loadSummaries() + CodexSessionStore().loadSummaries()
    var imported = 0
    for session in sessions where try db.sessionState(session.id) == nil {
        try db.join(sessionID: session.id, via: .imported, agent: session.agent,
                    transcriptPath: session.locator.localURL,
                    core: SessionCore(host: session.locator.host, directory: session.cwd,
                                      directorySource: session.cwd == nil ? nil : .transcript,
                                      title: session.firstPrompt ?? session.historyPrompt, lastActiveAt: session.modifiedAt))
        imported += 1
    }
    print("imported \(imported) sessions")
    exit(0)
}

let searchQuery: String? = {
    guard let index = CommandLine.arguments.firstIndex(of: "--search"),
          CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}()

func printRows(_ rows: [Session], compact: Bool = false) {
    let projects = SessionRowProject.grouping(rows)
    print(compact ? "rows updated: \(projects.count) projects, \(rows.count) sessions"
          : "Temple: \(projects.count) projects, \(rows.count) sessions\n")
    for row in rows.prefix(compact || limit == Int.max ? rows.count : 30 * limit) {
        let agent = row.agent?.rawValue ?? "unknown"
        let project = row.project?.displayName ?? "No project"
        let resolution: String
        switch row.resolution {
        case .confirmedAbsent: resolution = "Transcript missing"
        case .loaded: resolution = "Transcript found"
        case .resolving: resolution = "Resolving"
        case .awaitingCreation: resolution = "Awaiting creation"
        case .unreadable: resolution = "Transcript unreadable"
        case .mismatch: resolution = "Transcript identity mismatch"
        case .incomplete: resolution = "Transcript incomplete"
        case nil: resolution = "Unresolved"
        }
        print("\(agent)  \(project)  \(df.string(from: row.sortDate))  \(row.displayTitle)  [\(resolution)]")
    }
}

if CommandLine.arguments.contains("--disk") {
    let catalog = SessionFilter.filtered(SessionCatalog().load(), includeNoise: includeNoise)
    for summary in catalog {
        let title = summary.sharedTitleHint ?? summary.recordedTitle ?? summary.firstPrompt ?? summary.historyPrompt ?? summary.laterPromptHint ?? "New \(summary.agent.displayName) session"
        let path = summary.cwd ?? summary.directoryHint ?? ""
        if let searchQuery, ![title, path, summary.agent.rawValue].contains(where: { $0.localizedCaseInsensitiveContains(searchQuery) }) { continue }
        print("\(summary.agent.rawValue)  \(path)  \(title)")
    }
} else if CommandLine.arguments.contains("--watch") {
    let database = try openDatabase(readOnly: !TempleState.isRedirected)
    let watcher = SessionWatcher(database: database)
    let snapshots = watcher.snapshots()
    let legacyUpdates = watcher.start()
    defer { watcher.stop(); withExtendedLifetime(legacyUpdates) {} }
    for await snapshot in snapshots {
        if !database.isReadOnly {
            for summary in snapshot.summaries.values {
                _ = try database.fillCoreFields(sessionID: summary.id, expectedHost: summary.locator.host,
                    agent: summary.agent, directory: summary.cwd, title: summary.firstPrompt ?? summary.historyPrompt,
                    lastActiveAt: summary.modifiedAt)
            }
        }
        let states = try database.sessionStates()
        watcher.setEnrichmentWanted(Dictionary(uniqueKeysWithValues: states.compactMap { state in
            var missing = Set<SessionCoreField>()
            if state.agent == nil { missing.insert(.agent) }; if state.directory == nil { missing.insert(.directory) }
            if state.title == nil { missing.insert(.title) }; if state.lastActiveAt == nil { missing.insert(.lastActiveAt) }
            return missing.isEmpty ? nil : (state.id, missing)
        }))
        let rows = states.map { Session(state: $0, resolution: snapshot.resolutions[$0.id]) }
            .sorted { $0.sortDate == $1.sortDate ? $0.id < $1.id : $0.sortDate > $1.sortDate }
        printRows(searchQuery.map { SessionRowSearch.rank(rows, query: $0) } ?? rows, compact: true)
        fflush(stdout)
    }
} else {
    let database = try openDatabase(readOnly: !TempleState.isRedirected)
    let rows = try database.sessionStates().map { Session(state: $0) }
        .sorted { $0.sortDate == $1.sortDate ? $0.id < $1.id : $0.sortDate > $1.sortDate }
    printRows(searchQuery.map { SessionRowSearch.rank(rows, query: $0) } ?? rows)
}
