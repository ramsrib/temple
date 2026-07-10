import Foundation
import TempleCore

// Prints the real project → session index from ~/.claude and ~/.codex.
// A no-UI proof that TempleCore reads live data (Phase 1).

let df = DateFormatter()
df.dateFormat = "MMM d HH:mm"

let limit = CommandLine.arguments.contains("--all") ? Int.max : 8
let includeNoise = CommandLine.arguments.contains("--all")

if CommandLine.arguments.contains("--help") {
    print("Usage: templectl [--watch] [--all] [--search <term>]\n  --all  include noise sessions and do not cap sessions per project")
    exit(0)
}

func printIndex(_ index: SessionIndex, compact: Bool = false) {
    let totalSessions = index.allSessions.count
    print(compact
          ? "index updated: \(index.projects.count) projects, \(totalSessions) sessions"
          : "Temple — \(index.projects.count) projects, \(totalSessions) sessions\n")
    guard !compact else { return }
    for project in index.projects.prefix(30) {
        print("📁 \(project.name)  —  \(project.path)")
        for session in project.sessions.prefix(limit) {
            let badge = session.agent == .claude ? "◆ claude" : "◇ codex "
            let when = df.string(from: session.updatedAt)
            let detail = session.gitBranch ?? session.model ?? session.messageCount.map { "\($0) messages" }
            print("   \(badge)  \(when)  \(session.title)\(detail.map { "  [\($0)]" } ?? "")")
        }
        if project.sessions.count > limit {
            print("   … and \(project.sessions.count - limit) more")
        }
        print("")
    }
}

let searchQuery: String? = {
    guard let index = CommandLine.arguments.firstIndex(of: "--search"),
          CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}()

if let searchQuery {
    let index = SessionIndex.buildDefault().filteringNoise(includeNoise: includeNoise)
    for session in index.search(searchQuery) {
        let badge = session.agent == .claude ? "◆ claude" : "◇ codex "
        let project = URL(fileURLWithPath: session.projectPath).lastPathComponent
        print("\(badge)  \(project)  —  \(session.title)")
    }
} else if CommandLine.arguments.contains("--watch") {
    let watcher = SessionWatcher()
    var first = true
    for await index in watcher.start() {
        printIndex(index.filteringNoise(includeNoise: includeNoise), compact: !first)
        first = false
        fflush(stdout) // live proof harness: keep updates visible when piped/redirected
    }
} else {
    printIndex(SessionIndex.buildDefault().filteringNoise(includeNoise: includeNoise))
}
