import Foundation
import TempleCore
import Darwin

// Row browsing by default; --disk explicitly browses the transcript catalog.

let df = DateFormatter()
df.dateFormat = "MMM d HH:mm"

let limit = CommandLine.arguments.contains("--all") ? Int.max : 8
let includeNoise = CommandLine.arguments.contains("--all")

if CommandLine.arguments.contains("--help") {
    print("Usage: templectl [--disk] [--watch] [--all] [--search <term>] [--import-all] [--metrics]\n  --metrics  report watch parses, publications, CPU seconds and open descriptors once per second\n  --disk  browse the transcript catalog instead of Temple rows\n  --all  include noise sessions and do not cap sessions per project\n  --import-all  make every indexed session a Temple session (demo state dirs only)")
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

func readCatalog() async throws -> [TranscriptSummary] {
    var summaries: [TranscriptSummary] = []
    for try await batch in LocalSessionSource().catalog(CatalogQuery()) {
        if case .sessions(let sessions, _, _) = batch { summaries.append(contentsOf: sessions) }
        if case .storeFailed(_, let message) = batch { fputs("catalog: \(message)\n", stderr) }
    }
    return summaries.sorted { $0.modifiedAt > $1.modifiedAt }
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
    let sessions = try await readCatalog()
    var imported = 0
    for session in sessions where try db.sessionState(session.id) == nil {
        try db.join(sessionID: session.id, via: .imported, agent: session.agent,
                    transcriptPath: session.locator.localURL,
                    core: SessionCore(host: session.locator.host, directory: session.cwd,
                                      directorySource: session.cwd == nil ? nil : .transcript,
                                      title: session.titleFact, lastActiveAt: session.modifiedAt))
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

func catalogTitle(_ summary: TranscriptSummary) -> String { summary.catalogTitle }

if CommandLine.arguments.contains("--disk") {
    let catalog = SessionFilter.filtered(try await readCatalog(), includeNoise: includeNoise)
    if let searchQuery {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scored: [(TranscriptSummary, Int)] = needle.isEmpty ? [] : catalog.compactMap { summary in
            let title = catalogTitle(summary).lowercased()
            let project = URL(fileURLWithPath: summary.cwd ?? summary.directoryHint ?? "").lastPathComponent.lowercased()
            let score: Int
            if title == needle { score = 500 }
            else if title.hasPrefix(needle) { score = 400 }
            else if title.contains(needle) { score = 300 }
            else if project.contains(needle) { score = 200 }
            else if summary.agent.displayName.lowercased().contains(needle) || summary.agent.rawValue.contains(needle) { score = 100 }
            else { return nil }
            return (summary, score)
        }
        let ranked = scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.modifiedAt != rhs.0.modifiedAt { return lhs.0.modifiedAt > rhs.0.modifiedAt }
            return lhs.0.id < rhs.0.id
        }
        for (summary, _) in ranked {
            print("\(summary.agent.rawValue)  \(summary.cwd ?? summary.directoryHint ?? "")  \(catalogTitle(summary))")
        }
    } else {
        let groups = Dictionary(grouping: catalog) { $0.cwd ?? $0.directoryHint ?? "" }
        let paths = groups.keys.sorted {
            let lhs = groups[$0]!.map(\.modifiedAt).max() ?? .distantPast
            let rhs = groups[$1]!.map(\.modifiedAt).max() ?? .distantPast
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        print("Temple: \(groups.count) projects, \(catalog.count) catalog sessions\n")
        for path in paths.prefix(30) {
            print("📁 \(path.isEmpty ? "No project" : URL(fileURLWithPath: path).lastPathComponent)  \(path)")
            let summaries = groups[path]!
            for summary in summaries.prefix(limit) {
                print("   \(summary.agent.rawValue)  \(df.string(from: summary.modifiedAt))  \(catalogTitle(summary))")
            }
            if summaries.count > limit { print("   … and \(summaries.count - limit) more") }
        }
    }
} else if CommandLine.arguments.contains("--watch") {
    let watchStart = Date()
    let wantsMetrics = CommandLine.arguments.contains("--metrics")
    let disableWatcher = CommandLine.arguments.contains("--benchmark-disable-watcher")
    if disableWatcher {
        let keys = ["TEMPLE_CLAUDE_ROOT", "TEMPLE_CODEX_ROOT", "TEMPLE_STATE_DIR"]
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path + "/"
        guard wantsMetrics, keys.allSatisfy({ key in
            guard let path = ProcessInfo.processInfo.environment[key] else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(temporaryRoot)
        }) else {
            fputs("The disabled-watcher control requires --metrics and all roots under /private/tmp.\n", stderr)
            exit(2)
        }
    }
    let database = try openDatabase(readOnly: !TempleState.isRedirected)
    let initialRows = try database.sessionStates().map { Session(state: $0) }
    if wantsMetrics {
        print("durable rows available: \(initialRows.count), elapsed_seconds=\(Date().timeIntervalSince(watchStart))")
        fflush(stdout)
    }
    let watcher = SessionEngine(source: LocalSessionSource(monitorChanges: !disableWatcher), database: database)
    let snapshots = watcher.snapshots()
    let engineUpdates = watcher.start()
    let metricsTask = wantsMetrics ? Task {
        while !Task.isCancelled {
            let counters = watcher.metrics
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let userCPU = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            let systemCPU = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            let capacity = max(1, Int(proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)))
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<proc_fdinfo>.alignment)
            let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, buffer, Int32(capacity))
            buffer.deallocate()
            let sample: [String: Any] = ["event": "metrics", "parses": counters.parses,
                "verifications": counters.verifications, "publications": counters.publications,
                "observations": counters.observations, "enumerations": counters.enumerations,
                "monitoring": watcher.isMonitoring,
                "cpu_seconds": userCPU + systemCPU,
                "wall_seconds": Date().timeIntervalSince(watchStart),
                "open_fds": Int(bytes) / MemoryLayout<proc_fdinfo>.stride]
            if let data = try? JSONSerialization.data(withJSONObject: sample, options: .sortedKeys) {
                print(String(decoding: data, as: UTF8.self)); fflush(stdout)
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
        }
    } : nil
    defer { metricsTask?.cancel(); watcher.stop(); withExtendedLifetime(engineUpdates) {} }
    var firstPublication = true
    for await snapshot in snapshots {
        if firstPublication, wantsMetrics {
            print("first engine publication: elapsed_seconds=\(Date().timeIntervalSince(watchStart))")
            firstPublication = false
        }
        if !database.isReadOnly {
            for summary in snapshot.summaries.values {
                _ = try database.fillCoreFields(sessionID: summary.id, expectedHost: summary.locator.host,
                    agent: summary.agent, directory: summary.cwd, title: summary.titleFact,
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
