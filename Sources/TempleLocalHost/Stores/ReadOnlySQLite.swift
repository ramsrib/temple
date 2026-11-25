import Foundation
import SQLite3
import TempleCore

/// Reads another program's SQLite database without ever writing to it or
/// creating a file beside it (ADR-043, ADR-044), in one of three ways:
///
/// - **No `-wal`**: no process has it open (a WAL writer keeps one). Read
///   `immutable=1`, which takes no locks and creates nothing, as a checked
///   snapshot: before and after, no `-wal` and the same size, modification
///   time and file number. A WAL database changes its main file only by
///   checkpointing, so an unchanged file with no log is a consistent read.
///   (The system SQLite can't open such a file `mode=ro` at all:
///   `SQLITE_CANTOPEN`, measured on 3.54.0.)
/// - **A `-wal` and a `-shm`**: a writer has it open. Read `mode=ro` in one
///   transaction, as any reader of a live database does.
/// - **A `-wal` and no `-shm`**: a writer died; nothing has it open. A
///   `mode=ro` open would create the `-shm` (measured, 2026-11-25), so the
///   two files are copied to a private folder, their stats the same before
///   and after, and the copy is read.
///
/// Anything that changed meanwhile is read again; a read that never
/// settles fails. One race is left: a last writer that closes, removing
/// both files, between the check and a `mode=ro` open, which then
/// recreates them empty (harmless to `agy`, which uses them as its own).
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
        /// Another connection's lock, or a snapshot that kept changing:
        /// worth reading again, never a verdict on the file.
        var isTransient: Bool { [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_PROTOCOL].contains(code & 0xff) }
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
        for _ in 0..<attempts {
            let wal = there(url.path + "-wal"), shm = there(url.path + "-shm")
            if !wal { return try snapshot(url, queries) }
            if shm {
                do { return try run(url, immutable: false, queries) } catch let failure as Failure where failure.isCantOpen {
                    // The writer closed between the check and the open.
                    continue
                }
            }
            if let rows = try copied(url, queries) { return rows }
        }
        throw Failure(code: SQLITE_BUSY, message: "\(url.lastPathComponent) changed while it was read")
    }

    /// Whether anything (a link included) is at `path`.
    private static func there(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// A database and the log a dead writer left, copied and read; nil when
    /// either changed, went, or a `-shm` appeared while they were copied
    /// (the read starts over and picks its way again). A database or log
    /// that is a link is refused: a copy of the link would lead back.
    private static func copied(_ url: URL, _ queries: [Query]) throws -> [[[Value]]]? {
        let wal = URL(fileURLWithPath: url.path + "-wal")
        guard !isLink(url.path), !isLink(wal.path) else {
            throw Failure(code: SQLITE_CANTOPEN, message: "\(url.lastPathComponent) or its log is a link")
        }
        guard let before = MainFileStamp(url), let logBefore = MainFileStamp(wal) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("temple-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("c.db")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            try FileManager.default.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
        } catch {
            return nil
        }
        guard MainFileStamp(url) == before, MainFileStamp(wal) == logBefore, !there(url.path + "-shm") else { return nil }
        return try run(copy, immutable: false, readOnly: false, queries)
    }

    private static func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
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

    /// `readOnly` false: a private copy, which SQLite may recover its log in.
    private static func run(_ url: URL, immutable: Bool, readOnly: Bool = true, _ queries: [Query]) throws -> [[[Value]]] {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = readOnly ? [URLQueryItem(name: "mode", value: "ro")] : []
        if immutable { items.append(URLQueryItem(name: "immutable", value: "1")) }
        components?.queryItems = items.isEmpty ? nil : items
        guard let uri = components?.url?.absoluteString else { throw Failure(code: SQLITE_MISUSE, message: "no URI for \(url.path)") }
        var handle: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
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
