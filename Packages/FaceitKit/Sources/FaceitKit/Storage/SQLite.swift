import Foundation
import SQLite3

/// Minimal SQLite wrapper. The database lives in the shared App Group container and is opened by
/// the app and by every widget process, so it runs in WAL mode with a busy timeout.
final class SQLiteDB: @unchecked Sendable {
    enum DBError: Error, CustomStringConvertible {
        case open(String), prepare(String), step(String)
        var description: String {
            switch self { case .open(let m), .prepare(let m), .step(let m): return m }
        }
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &db, flags, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw DBError.open(msg)
        }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw DBError.step(m)
        }
    }

    enum Value { case int(Int64), double(Double), text(String), blob(Data), null }

    @discardableResult
    func run(_ sql: String, _ params: [Value] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError.step(String(cString: sqlite3_errmsg(db))) }
        return Int(sqlite3_changes(db))
    }

    func query(_ sql: String, _ params: [Value] = []) throws -> [[Value]] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [[Value]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DBError.step(String(cString: sqlite3_errmsg(db))) }
            let cols = sqlite3_column_count(stmt)
            rows.append((0..<cols).map { i in
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: return .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return .blob(Data()) }
                    return .blob(Data(bytes: p, count: n))
                default: return .null
                }
            })
        }
        return rows
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), Self.transient) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }
}

extension SQLiteDB.Value {
    var double: Double? {
        switch self { case .double(let d): return d; case .int(let i): return Double(i); default: return nil }
    }
    var int: Int? {
        switch self { case .int(let i): return Int(i); case .double(let d): return Int(d); default: return nil }
    }
    var text: String? { if case .text(let s) = self { return s } else { return nil } }
    var blob: Data? {
        switch self { case .blob(let b): return b; case .text(let s): return Data(s.utf8); default: return nil }
    }
}
