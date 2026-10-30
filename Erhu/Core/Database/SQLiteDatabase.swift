import Foundation
import SQLite3

enum SQLValue: Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension Int64: SQLBindable { var sqlValue: SQLValue { .int(self) } }
extension Int: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int32: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Double: SQLBindable { var sqlValue: SQLValue { .double(self) } }
extension Float: SQLBindable { var sqlValue: SQLValue { .double(Double(self)) } }
extension Bool: SQLBindable { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { var sqlValue: SQLValue { .blob(self) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    var sqlValue: SQLValue { map(\.sqlValue) ?? .null }
}

struct DatabaseError: Error, CustomStringConvertible {
    let message: String
    let sql: String?
    var description: String { sql.map { "\(message) (\($0))" } ?? message }
}

/// One result row; columns are read by name (as written in the query) or index.
struct Row {
    fileprivate let statement: OpaquePointer
    fileprivate let columns: [String: Int32]

    private func index(_ name: String) -> Int32 {
        guard let i = columns[name] else { preconditionFailure("No column \(name) in result") }
        return i
    }

    func isNull(_ name: String) -> Bool { sqlite3_column_type(statement, index(name)) == SQLITE_NULL }
    func int64(_ name: String) -> Int64 { sqlite3_column_int64(statement, index(name)) }
    func int(_ name: String) -> Int { Int(int64(name)) }
    func double(_ name: String) -> Double { sqlite3_column_double(statement, index(name)) }
    func float(_ name: String) -> Float { Float(double(name)) }
    func bool(_ name: String) -> Bool { int64(name) != 0 }

    func string(_ name: String) -> String {
        guard let text = sqlite3_column_text(statement, index(name)) else { return "" }
        return String(cString: text)
    }

    func optionalString(_ name: String) -> String? { isNull(name) ? nil : string(name) }
    func optionalInt(_ name: String) -> Int? { isNull(name) ? nil : int(name) }
    func optionalInt64(_ name: String) -> Int64? { isNull(name) ? nil : int64(name) }
    func optionalBool(_ name: String) -> Bool? { isNull(name) ? nil : bool(name) }

    func data(_ name: String) -> Data {
        let i = index(name)
        guard let bytes = sqlite3_column_blob(statement, i) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, i)))
    }
}

/// A small SQLite wrapper (SQLite ships with iOS). Every call is serialised by a recursive lock, so
/// a transaction can call back into the database. Writes post [Database.didChange] on the main
/// queue (coalesced), which the app's stores observe instead of Room's flows.
final class SQLiteDatabase: @unchecked Sendable {
    static let didChange = Notification.Name("SQLiteDatabase.didChange")

    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0
    private var notifyScheduled = false
    private var changedTables: Set<String> = []

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            throw DatabaseError(message: "Could not open database at \(path)", sql: nil)
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
    }

    /// An in-memory database (tests).
    static func inMemory() throws -> SQLiteDatabase { try SQLiteDatabase(path: ":memory:") }

    deinit {
        sqlite3_close_v2(handle)
    }

    var userVersion: Int {
        get { (try? query("PRAGMA user_version") { $0.int("user_version") }.first) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    /// Runs one statement; returns the number of rows it changed.
    @discardableResult
    func execute(_ sql: String, _ args: [SQLBindable] = []) throws -> Int {
        try locked {
            let statement = try prepare(sql, args)
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error(sql) }
            let changes = Int(sqlite3_changes(handle))
            if changes > 0, let table = Self.writtenTable(sql) { markDirty(table: table) }
            return changes
        }
    }

    /// Runs several statements separated by semicolons (schema creation).
    func executeScript(_ sql: String) throws {
        try locked {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error(sql) }
            markDirty()
        }
    }

    func query<T>(_ sql: String, _ args: [SQLBindable] = [], _ map: (Row) throws -> T) throws -> [T] {
        try locked {
            let statement = try prepare(sql, args)
            defer { sqlite3_finalize(statement) }
            var columns: [String: Int32] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                columns[String(cString: sqlite3_column_name(statement, i))] = i
            }
            var out: [T] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw error(sql) }
                out.append(try map(Row(statement: statement, columns: columns)))
            }
            return out
        }
    }

    var lastInsertRowId: Int64 { locked { sqlite3_last_insert_rowid(handle) } }

    /// Runs [body] in one transaction: everything or nothing.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            let outer = transactionDepth == 0
            if outer { try execute("BEGIN IMMEDIATE") }
            transactionDepth += 1
            do {
                let result = try body()
                transactionDepth -= 1
                if outer { try execute("COMMIT") }
                return result
            } catch {
                transactionDepth -= 1
                if outer { try? execute("ROLLBACK") }
                throw error
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func prepare(_ sql: String, _ args: [SQLBindable]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error(sql) }
        for (i, arg) in args.enumerated() {
            let position = Int32(i + 1)
            switch arg.sqlValue {
            case .int(let v): sqlite3_bind_int64(statement, position, v)
            case .double(let v): sqlite3_bind_double(statement, position, v)
            case .text(let v): sqlite3_bind_text(statement, position, v, -1, Self.transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(v.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }

    private func error(_ sql: String) -> DatabaseError {
        DatabaseError(message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }

    /// Coalesced notifications identify the written tables, so cache writes do not rebuild the library.
    static func affects(_ notification: Notification, tables: Set<String>) -> Bool {
        guard let changed = notification.userInfo?["tables"] as? Set<String> else { return true }
        return changed.contains("*") || !changed.isDisjoint(with: tables)
    }

    private static func writtenTable(_ sql: String) -> String? {
        let words = sql.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let command = words.first else { return nil }
        switch command {
        case "insert", "replace":
            guard let into = words.firstIndex(of: "into"), words.indices.contains(into + 1) else { return "*" }
            return words[into + 1].components(separatedBy: "(")[0]
        case "update": return words.count > 1 && words[1] != "or" ? words[1] : "*"
        case "delete": return words.count > 2 ? words[2] : "*"
        default: return nil
        }
    }

    private func markDirty(table: String = "*") {
        changedTables.insert(table)
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let tables = self.locked { () -> Set<String> in
                defer { self.notifyScheduled = false; self.changedTables.removeAll() }
                return self.changedTables
            }
            NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["tables": tables])
        }
    }
}

/// "?, ?, ?" for an IN list of [count] values.
func placeholders(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
