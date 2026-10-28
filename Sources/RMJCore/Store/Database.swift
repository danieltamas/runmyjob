import Foundation
import SQLite3

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)

    public var intValue: Int64? { if case .int(let value) = self { value } else { nil } }
    public var textValue: String? { if case .text(let value) = self { value } else { nil } }

    public static func optional(_ value: Int64?) -> SQLValue { value.map(SQLValue.int) ?? .null }
    public static func optional(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
}

public typealias Row = [String: SQLValue]

public struct DatabaseError: Error, Equatable, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "sqlite \(code): \(message)" }
}

/// The ledger's SQLite file. The actor serialises this process's use of the connection; WAL and
/// `busy_timeout` serialise the app and every `rmj` process against each other.
public actor Database {
    private static let busyTimeoutMS: Int32 = 5000
    private let connection: Connection

    public init(url: URL) throws {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK, let opened else {
            let error = DatabaseError(code: SQLITE_CANTOPEN, message: opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open")
            sqlite3_close(opened)
            throw error
        }
        connection = Connection(opened)
        sqlite3_busy_timeout(opened, Self.busyTimeoutMS)
        // journal_mode returns a row; it is read, not run as a statement that must be empty.
        _ = try Self.run(opened, "PRAGMA journal_mode = WAL", [])
        _ = try Self.run(opened, "PRAGMA synchronous = NORMAL", [])
        _ = try Self.run(opened, "PRAGMA foreign_keys = ON", [])
        try Self.migrate(opened)
    }

    /// Rows changed by an INSERT, UPDATE or DELETE.
    @discardableResult
    public func execute(_ sql: String, _ arguments: [SQLValue] = []) throws -> Int {
        try Self.run(open(), sql, arguments).changes
    }

    public func query(_ sql: String, _ arguments: [SQLValue] = []) throws -> [Row] {
        try Self.run(open(), sql, arguments).rows
    }

    /// One write transaction, taking the file's write lock up front so two processes never deadlock
    /// on an upgrade; rolled back when `body` throws.
    public func transaction<T: Sendable>(_ body: @Sendable (isolated Database) throws -> T) throws -> T {
        let connection = open()
        _ = try Self.run(connection, "BEGIN IMMEDIATE", [])
        do {
            let result = try body(self)
            _ = try Self.run(connection, "COMMIT", [])
            return result
        } catch {
            _ = try? Self.run(connection, "ROLLBACK", [])
            throw error
        }
    }

    private func open() -> OpaquePointer {
        connection.pointer
    }

    private static func run(_ db: OpaquePointer, _ sql: String, _ arguments: [SQLValue]) throws -> (rows: [Row], changes: Int) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, position)
            case .int(let number): sqlite3_bind_int64(statement, position, number)
            case .real(let number): sqlite3_bind_double(statement, position, number)
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, transient)
            }
        }
        var rows = [Row]()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var row = Row()
                for column in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, column))
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(statement, column))
                    case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                    case SQLITE_NULL: row[name] = .null
                    default: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                    }
                }
                rows.append(row)
            case SQLITE_DONE:
                return (rows, Int(sqlite3_changes(db)))
            default:
                throw DatabaseError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private static func migrate(_ db: OpaquePointer) throws {
        _ = try run(db, "BEGIN IMMEDIATE", [])
        do {
            try Schema.apply { try run(db, $0, []) }
            _ = try run(db, "COMMIT", [])
        } catch {
            _ = try? run(db, "ROLLBACK", [])
            throw error
        }
    }
}

/// Owns the sqlite handle so closing it does not depend on the actor's isolation.
private final class Connection: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { sqlite3_close(pointer) }
}
