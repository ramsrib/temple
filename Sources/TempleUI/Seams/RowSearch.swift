import Foundation
import TempleCore

/// Search the titles and identities actually rendered by row consumers.
public enum RowSearch {
    public static func rank(_ rows: [Session], query: String) -> [Session] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return rows.compactMap { row -> (Session, Int)? in
            let title = row.displayTitle.lowercased()
            let score: Int
            if title == q { score = 500 }
            else if title.hasPrefix(q) { score = 400 }
            else if title.contains(q) { score = 300 }
            else if row.project?.displayName.lowercased().contains(q) == true { score = 200 }
            else if row.agent?.displayName.lowercased().contains(q) == true || row.agent?.rawValue.lowercased().contains(q) == true { score = 100 }
            else { return nil }
            return (row, score)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.sortDate != $1.0.sortDate { return $0.0.sortDate > $1.0.sortDate }
            return $0.0.id < $1.0.id
        }.map(\.0)
    }
}
