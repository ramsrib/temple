import Foundation
import SQLite3
import TempleCore

/// Reads another program's SQLite database without ever writing to it
/// (ADR-043). The database is opened `mode=ro` and read in one transaction.
///
/// A WAL database that no process has open has no `-shm` file, and the
/// system SQLite cannot open it read-only then: the first statement fails
/// with `SQLITE_CANTOPEN` (measured on 3.54.0, SESSION-FORMATS.md). With a
/// `-wal` and no `-shm` (a writer that crashed) it can, and reads the log
/// through an index built in memory. Only for
/// that error the read is made with `immutable=1`, which takes no locks and
/// assumes nobody writes, as a checked snapshot: before and after the read
/// the database has no `-wal` and the same size, modification time and file
/// number. A WAL database changes its main file only by checkpointing, so an
/// unchanged file with no WAL is a consistent read; anything else is read
/// again, and a read that never settles fails.
enum ReadOnlySQLite {
    enum Value: Equatable {
        case null, integer(Int64), real(Double), text(String), blob(Data)
        var text: String? { if case .text(let s) = self { return s }; return nil }
        var integer: Int64? { if case .integer(let i) = self { return i }; return nil }
        var blob: Data? {
            switch self {
            case .blob(let d): return d
            case .text(let s): return Data(s.utf8)
            default: return nil
            }
        }
    }

    struct Failure: Error, LocalizedError, Equatable {
        let code: Int32
        let message: String
        var errorDescription: String? { message }
        var isCantOpen: Bool { code & 0xff == SQLITE_CANTOPEN }
    }

    /// A statement and the values bound to it.
    struct Query {
        let sql: String
        var arguments: [String] = []
    }

    static let attempts = 3

    /// The rows of each query, all read in one transaction. A missing file
    /// throws `ENOENT` as a POSIX error, so callers can tell it from a
    /// failure to read.
    static func read(_ url: URL, _ queries: [Query]) throws -> [[[Value]]] {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            return try run(url, immutable: false, queries)
        } catch let failure as Failure where failure.isCantOpen {
            return try snapshot(url, queries)
        }
    }

    private static func snapshot(_ url: URL, _ queries: [Query]) throws -> [[[Value]]] {
        let wal = URL(fileURLWithPath: url.path + "-wal")
        func quiet() -> MainFileStamp? {
            guard !FileManager.default.fileExists(atPath: wal.path) else { return nil }
            return MainFileStamp(url)
        }
        for _ in 0..<attempts {
            // A WAL means a writer has (or had) the file open: its commits
            // may be there and not in the main file, so it is no snapshot.
            guard let before = quiet() else { break }
            let rows = try run(url, immutable: true, queries)
            if let after = quiet(), after == before { return rows }
        }
        throw Failure(code: SQLITE_BUSY, message: "\(url.lastPathComponent) changed while it was read")
    }

    private struct MainFileStamp: Equatable {
        let size: Int64, seconds: Int, nanos: Int, inode: UInt64
        init?(_ url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            size = Int64(info.st_size); seconds = info.st_mtimespec.tv_sec
            nanos = info.st_mtimespec.tv_nsec; inode = UInt64(info.st_ino)
        }
    }

    private static func run(_ url: URL, immutable: Bool, _ queries: [Query]) throws -> [[[Value]]] {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: immutable ? "immutable" : "mode", value: immutable ? "1" : "ro")]
        guard let uri = components?.url?.absoluteString else { throw Failure(code: SQLITE_MISUSE, message: "no URI for \(url.path)") }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let opened = sqlite3_open_v2(uri, &handle, flags, nil)
        defer { sqlite3_close_v2(handle) }
        guard opened == SQLITE_OK, let db = handle else { throw failure(handle, opened) }
        sqlite3_busy_timeout(db, 250)
        try exec(db, "BEGIN")
        defer { _ = sqlite3_exec(db, "COMMIT", nil, nil, nil) }
        return try queries.map { try rows(db, $0) }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw failure(db, code) }
    }

    private static func rows(_ db: OpaquePointer, _ query: Query) throws -> [[Value]] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, query.sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK, let statement else { throw failure(db, prepared) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in query.arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), argument, -1, transient)
        }
        var result: [[Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw failure(db, step) }
            var row: [Value] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, column))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if count > 0, let bytes = sqlite3_column_blob(statement, column) { row.append(.blob(Data(bytes: bytes, count: count))) }
                    else { row.append(.blob(Data())) }
                default: row.append(.null)
                }
            }
            result.append(row)
        }
        return result
    }

    private static func failure(_ db: OpaquePointer?, _ code: Int32) -> Failure {
        guard let db else { return Failure(code: code, message: String(cString: sqlite3_errstr(code))) }
        let extended = sqlite3_extended_errcode(db)
        return Failure(code: extended & 0xff == code & 0xff ? extended : code, message: String(cString: sqlite3_errmsg(db)))
    }
}
