import Foundation

/// Search the titles and identities actually rendered by row consumers.
public enum SessionRowSearch {
    public static func rank(_ rows: [Session], query: String) -> [Session] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return rows.compactMap { row -> (Session, Int)? in
            // The displayed title or an original one, whichever scores better.
            let titleScore = row.searchTitles.map { title -> Int in
                let title = title.lowercased()
                return title == q ? 500 : title.hasPrefix(q) ? 400 : title.contains(q) ? 300 : 0
            }.max() ?? 0
            let score: Int
            if titleScore > 0 { score = titleScore }
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
