import Foundation
import TempleCore

// Prints the real project → session index from ~/.claude and ~/.codex.
// A no-UI proof that TempleCore reads live data (Phase 1).

let index = SessionIndex.buildDefault()

let df = DateFormatter()
df.dateFormat = "MMM d HH:mm"

let totalSessions = index.allSessions.count
print("Temple — \(index.projects.count) projects, \(totalSessions) sessions\n")

let limit = CommandLine.arguments.contains("--all") ? Int.max : 8

for project in index.projects.prefix(30) {
    print("📁 \(project.name)  —  \(project.path)")
    for session in project.sessions.prefix(limit) {
        let badge = session.agent == .claude ? "◆ claude" : "◇ codex "
        let when = df.string(from: session.updatedAt)
        print("   \(badge)  \(when)  \(session.title)")
    }
    if project.sessions.count > limit {
        print("   … and \(project.sessions.count - limit) more")
    }
    print("")
}
