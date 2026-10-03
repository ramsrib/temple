import TempleCore

/// Search durable row presentation.
public enum RowSearch {
    public static func rank(_ rows: [Session], query: String) -> [Session] {
        SessionRowSearch.rank(rows, query: query)
    }
}
