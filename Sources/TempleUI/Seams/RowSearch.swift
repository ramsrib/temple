import TempleCore

/// Distinct row-search API while legacy SessionSearch consumers remain.
public enum RowSearch {
    public static func rank(_ rows: [Session], query: String) -> [Session] {
        SessionRowSearch.rank(rows, query: query)
    }
}
