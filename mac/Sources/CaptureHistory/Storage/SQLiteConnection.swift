import Foundation
import SQLite3

/// SQLite's `SQLITE_TRANSIENT` destructor constant. It is defined in
/// `sqlite3.h` as the C macro `((sqlite3_destructor_type)-1)`, which the
/// Swift/Clang importer cannot expose directly — this is the standard
/// workaround (used by virtually every hand-written Swift SQLite wrapper).
/// Passing this to `sqlite3_bind_text`/`sqlite3_bind_blob` tells SQLite to
/// copy the bound bytes immediately, so we never have to keep our Swift
/// `String`/`Data` values alive past the `bind` call.
private let SQLiteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin, correct wrapper around SQLite's raw C API (`import SQLite3`,
/// the system library shipped with macOS — Part I §4/§37: "prefer system
/// framework if practical", no external SQLite package dependency).
///
/// Every public operation is funneled onto a private serial queue so a
/// single `SQLiteConnection` is safe to call from multiple threads/tasks
/// concurrently, and so `transaction(_:)` can guarantee the statements run
/// inside it execute back-to-back with nothing interleaved from another
/// caller. Nested calls from *inside* a `transaction` body (e.g. a
/// `HistoryStore` method calling `connection.execute` while already inside
/// `connection.transaction { ... }`) are detected via `DispatchSpecificKey`
/// and run inline instead of re-entering `queue.sync`, which would
/// otherwise deadlock on a serial queue.
///
/// This wrapper deliberately never string-interpolates values into SQL —
/// every value-carrying statement goes through `?` placeholders and
/// `Statement.bind(_:)`, even though history data is local-only, per the
/// task's injection-avoidance requirement.
public final class SQLiteConnection: @unchecked Sendable {
    public struct SQLiteError: Error, CustomStringConvertible, Sendable {
        public let code: Int32
        public let message: String

        public var description: String { "SQLiteError(code: \(code)): \(message)" }
    }

    /// A dynamically-typed bind value. Mirrors SQLite's storage classes.
    public enum Value: Sendable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)

        public static func int(_ value: Int) -> Value { .integer(Int64(value)) }
        public static func bool(_ value: Bool) -> Value { .integer(value ? 1 : 0) }
    }

    /// A prepared statement. Bind parameters, then either `step()` in a
    /// loop (for row-returning queries) or call it once (for a write that
    /// returns no rows). Automatically finalized on `deinit`.
    public final class Statement {
        fileprivate let handle: OpaquePointer
        private unowned let connection: SQLiteConnection

        fileprivate init(handle: OpaquePointer, connection: SQLiteConnection) {
            self.handle = handle
            self.connection = connection
        }

        deinit {
            sqlite3_finalize(handle)
        }

        /// Resets the statement and binds `values` in order to `?1, ?2, ...`.
        public func bind(_ values: [Value]) throws {
            var rc = sqlite3_reset(handle)
            guard rc == SQLITE_OK else { throw connection.currentError(rc) }
            sqlite3_clear_bindings(handle)

            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case .null:
                    rc = sqlite3_bind_null(handle, index)
                case .integer(let v):
                    rc = sqlite3_bind_int64(handle, index, v)
                case .real(let v):
                    rc = sqlite3_bind_double(handle, index, v)
                case .text(let v):
                    rc = sqlite3_bind_text(handle, index, v, -1, SQLiteTransientDestructor)
                case .blob(let data):
                    rc = data.withUnsafeBytes { raw -> Int32 in
                        if raw.isEmpty {
                            return sqlite3_bind_zeroblob(handle, index, 0)
                        }
                        return sqlite3_bind_blob(handle, index, raw.baseAddress, Int32(raw.count), SQLiteTransientDestructor)
                    }
                }
                guard rc == SQLITE_OK else { throw connection.currentError(rc) }
            }
        }

        /// Advances to the next row. Returns `true` if a row is available
        /// (`SQLITE_ROW`), `false` when the statement is exhausted
        /// (`SQLITE_DONE`).
        @discardableResult
        public func step() throws -> Bool {
            let rc = sqlite3_step(handle)
            switch rc {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw connection.currentError(rc)
            }
        }

        public func reset() {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
        }

        // MARK: Typed column readers (0-based column index, matching the
        // SQL `SELECT` list order).

        public func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(handle, column) == SQLITE_NULL
        }

        public func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
        public func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
        public func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
        public func bool(_ column: Int32) -> Bool { sqlite3_column_int64(handle, column) != 0 }

        public func text(_ column: Int32) -> String {
            guard let cString = sqlite3_column_text(handle, column) else { return "" }
            return String(cString: cString)
        }

        public func data(_ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(handle, column) else { return Data() }
            let count = Int(sqlite3_column_bytes(handle, column))
            return Data(bytes: bytes, count: count)
        }

        public func optionalText(_ column: Int32) -> String? { isNull(column) ? nil : text(column) }
        public func optionalInt(_ column: Int32) -> Int? { isNull(column) ? nil : int(column) }
        public func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }
        public func optionalData(_ column: Int32) -> Data? { isNull(column) ? nil : data(column) }
    }

    private var db: OpaquePointer?
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    public let path: String
    public let isReadOnly: Bool

    /// Opens (creating if necessary) the database at `path` and enables
    /// WAL journaling (Part I §35/§10). Pass `":memory:"` for an
    /// in-process throwaway database, primarily useful in tests.
    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        self.isReadOnly = readOnly
        self.queue = DispatchQueue(label: "com.capture.history.sqlite-connection")
        queue.setSpecific(key: queueKey, value: ObjectIdentifier(queue))

        var handle: OpaquePointer?
        let openFlags: Int32 = readOnly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        let rc = sqlite3_open_v2(path, &handle, openFlags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "failed to open database at \(path)"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError(code: rc, message: message)
        }
        self.db = handle

        // Keep every write bounded and safe (Part I §35: "transaction-safe
        // SQLite writes"). busy_timeout means concurrent readers/writers
        // (e.g. a future background indexer) block briefly instead of
        // failing immediately with SQLITE_BUSY.
        sqlite3_busy_timeout(handle, 5000)

        if !readOnly {
            try executeInline("PRAGMA journal_mode = WAL;")
            try executeInline("PRAGMA foreign_keys = ON;")
            try executeInline("PRAGMA synchronous = NORMAL;")
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    /// Closes the underlying database handle. Safe to call more than once.
    /// After calling this, every other method throws.
    public func close() {
        runOnQueue {
            if let db {
                sqlite3_close_v2(db)
                self.db = nil
            }
        }
    }

    // MARK: - Queue confinement

    /// Runs `body` confined to `queue`, but inline (no `sync` re-entry) if
    /// we're already executing on `queue` — this is what lets
    /// `HistoryStore` call `connection.execute(...)` freely from inside a
    /// `connection.transaction { ... }` closure without deadlocking.
    private func runOnQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    private func currentError(_ code: Int32) -> SQLiteError {
        let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown SQLite error"
        return SQLiteError(code: code, message: message)
    }

    // MARK: - Statement lifecycle (must only be called while confined to `queue`)

    private func prepareInline(_ sql: String) throws -> Statement {
        guard let db else { throw SQLiteError(code: SQLITE_MISUSE, message: "connection is closed") }
        var handle: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &handle, nil)
        guard rc == SQLITE_OK, let handle else { throw currentError(rc) }
        return Statement(handle: handle, connection: self)
    }

    @discardableResult
    private func executeInline(_ sql: String, params: [Value] = []) throws -> Statement {
        let statement = try prepareInline(sql)
        if !params.isEmpty { try statement.bind(params) }
        _ = try statement.step()
        return statement
    }

    // MARK: - Public API

    /// Prepares a statement for manual binding/stepping. Prefer `execute`
    /// or `query` for the common cases; use this directly only when you
    /// need to step through rows one at a time without materializing an
    /// array up front.
    public func prepare(_ sql: String) throws -> Statement {
        try runOnQueue { try prepareInline(sql) }
    }

    /// Executes a statement that does not return rows (DDL, INSERT,
    /// UPDATE, DELETE, PRAGMA). Parameters are bound positionally to `?`
    /// placeholders — never interpolate untrusted or variable data into
    /// `sql` itself.
    @discardableResult
    public func execute(_ sql: String, params: [Value] = []) throws -> Statement {
        try runOnQueue { try executeInline(sql, params: params) }
    }

    /// Executes a row-returning query and maps every row with `map`.
    public func query<T>(_ sql: String, params: [Value] = [], map: (Statement) throws -> T) throws -> [T] {
        try runOnQueue {
            let statement = try prepareInline(sql)
            if !params.isEmpty { try statement.bind(params) }
            var results: [T] = []
            while try statement.step() {
                results.append(try map(statement))
            }
            return results
        }
    }

    /// Runs `body` inside `BEGIN IMMEDIATE ... COMMIT`, rolling back on any
    /// thrown error (Part I §35: "History: transaction-safe SQLite
    /// writes"). `BEGIN IMMEDIATE` (rather than a plain `BEGIN`) takes the
    /// write lock up front so a multi-statement transaction can't itself
    /// upgrade mid-way and hit `SQLITE_BUSY`. Do not nest calls to
    /// `transaction` — SQLite does not support nested transactions without
    /// `SAVEPOINT`, which this wrapper does not implement.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try runOnQueue {
            try executeInline("BEGIN IMMEDIATE TRANSACTION;")
            do {
                let result = try body()
                try executeInline("COMMIT;")
                return result
            } catch {
                // Best-effort rollback: if the connection is already in a
                // bad state the rollback itself may fail, but we still
                // want to propagate the original error, not this one.
                try? executeInline("ROLLBACK;")
                throw error
            }
        }
    }

    public var lastInsertRowID: Int64 {
        runOnQueue { db.map { sqlite3_last_insert_rowid($0) } ?? 0 }
    }

    public var changedRowCount: Int {
        runOnQueue { db.map { Int(sqlite3_changes($0)) } ?? 0 }
    }
}
