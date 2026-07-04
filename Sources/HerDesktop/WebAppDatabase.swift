import Foundation
import SQLite3

/// Minimal SQLite access for web app data stores. Each call opens the
/// app-scoped database, runs one statement with bound parameters, and
/// returns JSON-compatible rows. Web apps only ever reach their own
/// `data.db`, so arbitrary SQL is confined to their own data.
enum WebAppDatabase {
    struct QueryResult: Equatable {
        var columns: [String]
        var rows: [[JSONValue]]
        var rowsChanged: Int
        var lastInsertRowID: Int64
    }

    enum DatabaseError: LocalizedError {
        case cannotOpen(String)
        case prepareFailed(String)
        case stepFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let message): return "Cannot open database: \(message)"
            case .prepareFailed(let message): return "SQL prepare failed: \(message)"
            case .stepFailed(let message): return "SQL execution failed: \(message)"
            }
        }
    }

    static func execute(sql: String, params: [JSONValue] = [], databaseURL: URL) throws -> QueryResult {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw DatabaseError.cannotOpen(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, param) in params.enumerated() {
            let position = Int32(index + 1)
            switch param {
            case .string(let value):
                sqlite3_bind_text(statement, position, value, -1, transient)
            case .number(let value):
                if value == value.rounded(), abs(value) < 9_007_199_254_740_991 {
                    sqlite3_bind_int64(statement, position, Int64(value))
                } else {
                    sqlite3_bind_double(statement, position, value)
                }
            case .bool(let value):
                sqlite3_bind_int(statement, position, value ? 1 : 0)
            case .null:
                sqlite3_bind_null(statement, position)
            case .array, .object:
                let data = (try? JSONEncoder().encode(param)) ?? Data("null".utf8)
                sqlite3_bind_text(statement, position, String(data: data, encoding: .utf8) ?? "null", -1, transient)
            }
        }

        let columnCount = sqlite3_column_count(statement)
        let columns = (0..<columnCount).map { index in
            sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "column\(index)"
        }
        var rows: [[JSONValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                rows.append((0..<columnCount).map { index in
                    columnValue(statement: statement, index: index)
                })
            } else if code == SQLITE_DONE {
                break
            } else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
        return QueryResult(
            columns: columns,
            rows: rows,
            rowsChanged: Int(sqlite3_changes(db)),
            lastInsertRowID: sqlite3_last_insert_rowid(db)
        )
    }

    private static func columnValue(statement: OpaquePointer, index: Int32) -> JSONValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .number(Double(sqlite3_column_int64(statement, index)))
        case SQLITE_FLOAT:
            return .number(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            return .string(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            let bytes = sqlite3_column_blob(statement, index)
            let count = Int(sqlite3_column_bytes(statement, index))
            guard let bytes, count > 0 else { return .string("") }
            return .string(Data(bytes: bytes, count: count).base64EncodedString())
        default:
            return .null
        }
    }
}
