import XCTest
@testable import CaptureHistory

final class HistorySchemaTests: HistoryStoreTestCase {
    func testMigrateCreatesEveryTable() throws {
        // `store` (created in setUp) has already run HistorySchema.migrate.
        // Reaching into the raw connection to assert the schema exists is
        // exactly what this test is for.
        let connection = try SQLiteConnection(path: databaseURL.path)
        defer { connection.close() }

        let tableNames = Set(try connection.query(
            "SELECT name FROM sqlite_master WHERE type IN ('table', 'view');"
        ) { $0.text(0) })

        for expected in ["projects", "captures", "capture_tags", "audit_findings", "schema_version"] {
            XCTAssertTrue(tableNames.contains(expected), "expected table \(expected) to exist")
        }

        // FTS5 virtual tables show up in sqlite_master by their own name
        // (plus internal shadow tables like `captures_fts_data`, which we
        // don't need to enumerate here).
        let allNames = Set(try connection.query("SELECT name FROM sqlite_master;") { $0.text(0) })
        XCTAssertTrue(allNames.contains("captures_fts"), "expected captures_fts virtual table")
        XCTAssertTrue(allNames.contains("audit_findings_fts"), "expected audit_findings_fts virtual table")
    }

    func testMigrateIsIdempotent() throws {
        // Calling migrate a second time against the same (already-current)
        // database must not throw and must not change the recorded version.
        let connection = try SQLiteConnection(path: databaseURL.path)
        defer { connection.close() }

        XCTAssertNoThrow(try HistorySchema.migrate(connection))

        let version = try connection.query("SELECT version FROM schema_version WHERE id = 1;") { $0.int(0) }
        XCTAssertEqual(version.first, HistorySchema.currentVersion)
    }

    func testSchemaVersionRecordedAsCurrent() throws {
        let connection = try SQLiteConnection(path: databaseURL.path)
        defer { connection.close() }
        let version = try connection.query("SELECT version FROM schema_version WHERE id = 1;") { $0.int(0) }
        XCTAssertEqual(version.first, 1)
    }

    func testWALModeEnabled() throws {
        let connection = try SQLiteConnection(path: databaseURL.path)
        defer { connection.close() }
        let mode = try connection.query("PRAGMA journal_mode;") { $0.text(0) }
        XCTAssertEqual(mode.first?.lowercased(), "wal")
    }
}
