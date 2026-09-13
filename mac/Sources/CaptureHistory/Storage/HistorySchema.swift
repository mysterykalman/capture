import Foundation

/// The `history.sqlite` schema (Part I §10, §25 / spec digest
/// `15_history_projects.md`) and its migration runner.
///
/// Layout, roughly:
/// ```text
/// projects        -- lightweight logical grouping + per-project retention override
/// captures        -- one row per logical capture (screenshot/recording/assembly)
/// capture_tags    -- capture_id <-> tag join table
/// captures_fts    -- FTS5 index over OCR text, annotation text, URL, page
///                    title and tags, kept in sync by explicit re-index
///                    calls from HistoryStore (not triggers — see note below)
/// audit_findings  -- mirrors CaptureCore.AuditFinding
/// audit_findings_fts -- FTS5 index over finding title (spec digest §10:
///                        "FTS5 for: OCR; annotation text; URL; page title;
///                        tags; finding title")
/// schema_version  -- single-row version marker for the migration runner
/// ```
///
/// FTS5 sync strategy: this schema deliberately does **not** use
/// `content=`/external-content FTS5 tables driven by `INSERT`/`UPDATE`/
/// `DELETE` triggers on `captures`. `captures.id`/`audit_findings.id` are
/// `TEXT` primary keys, not `INTEGER PRIMARY KEY` rowid aliases, so an
/// external-content table would need its own bookkeeping table mapping
/// text ids to FTS rowids — that is more moving parts than it saves.
/// Instead `captures_fts`/`audit_findings_fts` are ordinary standalone FTS5
/// tables keyed by an `UNINDEXED capture_id`/`finding_id` column, and
/// `HistoryStore` explicitly deletes+reinserts the FTS row for a given
/// capture/finding every time its indexed text could have changed (insert,
/// tag change, OCR/annotation text update). Pick one approach and be
/// consistent — this file and `HistoryStore` are the only places that
/// touch `*_fts`.
public enum HistorySchema {
    /// Bump this and add a new `migrateToVN()` step (see `migrate(_:)`)
    /// when the schema changes. Never rewrite `migrateToV1` after it has
    /// shipped — add `migrateToV2`, `migrateToV3`, etc.
    public static let currentVersion = 1

    public enum SchemaError: Error, Sendable {
        case unexpectedFutureVersion(found: Int, expected: Int)
    }

    /// Idempotent: safe to call every time `HistoryStore` opens the
    /// database. On a fresh database this creates everything at
    /// `currentVersion`. On an already-current database it is a no-op
    /// (every statement is `CREATE ... IF NOT EXISTS`, and the version
    /// check short-circuits). Structured so a future `migrateToV2` can be
    /// added without touching `migrateToV1`.
    public static func migrate(_ connection: SQLiteConnection) throws {
        try connection.transaction {
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS schema_version (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    version INTEGER NOT NULL
                );
                """
            )

            var version = try readVersion(connection)

            if version < 1 {
                try migrateToV1(connection)
                version = 1
            }

            // Next migration step goes here, following the same shape:
            //
            //   if version < 2 {
            //       try migrateToV2(connection)
            //       version = 2
            //   }

            guard version <= currentVersion else {
                throw SchemaError.unexpectedFutureVersion(found: version, expected: currentVersion)
            }

            try writeVersion(connection, version)
        }
    }

    private static func readVersion(_ connection: SQLiteConnection) throws -> Int {
        let rows = try connection.query("SELECT version FROM schema_version WHERE id = 1;") { $0.int(0) }
        return rows.first ?? 0
    }

    private static func writeVersion(_ connection: SQLiteConnection, _ version: Int) throws {
        try connection.execute(
            """
            INSERT INTO schema_version (id, version) VALUES (1, ?)
            ON CONFLICT(id) DO UPDATE SET version = excluded.version;
            """,
            params: [.int(version)]
        )
    }

    // MARK: - v1

    private static func migrateToV1(_ connection: SQLiteConnection) throws {
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS projects (
                id                TEXT PRIMARY KEY,
                name              TEXT NOT NULL,
                created_at        REAL NOT NULL,
                -- NULL means "use the app-wide default retention policy";
                -- a non-NULL value here is a per-project override
                -- (spec digest §15: "Per-project override supported.").
                retention_policy  TEXT,
                favourite         INTEGER NOT NULL DEFAULT 0
            );
            """
        )

        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS captures (
                id                  TEXT PRIMARY KEY,
                media_content_hash  TEXT NOT NULL,
                capture_date        REAL NOT NULL,
                source_app          TEXT,
                url                 TEXT,
                domain              TEXT,
                page_title          TEXT,
                project_id          TEXT REFERENCES projects(id) ON DELETE SET NULL,
                capture_type        TEXT NOT NULL,
                width               REAL,
                height              REAL,
                upload_status       TEXT NOT NULL DEFAULT 'none',
                privacy_status      TEXT NOT NULL DEFAULT 'unreviewed',
                favourite           INTEGER NOT NULL DEFAULT 0,
                ocr_text            TEXT,
                annotation_text     TEXT,
                os                  TEXT,
                browser             TEXT,
                colour_scheme       TEXT,
                locale              TEXT,
                created_at          REAL NOT NULL,
                updated_at          REAL NOT NULL
            );
            """
        )
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_captures_media_hash ON captures(media_content_hash);")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_captures_project_id ON captures(project_id);")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_captures_capture_date ON captures(capture_date);")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_captures_domain ON captures(domain);")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_captures_capture_type ON captures(capture_type);")

        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS capture_tags (
                capture_id  TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
                tag         TEXT NOT NULL,
                PRIMARY KEY (capture_id, tag)
            );
            """
        )
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_capture_tags_tag ON capture_tags(tag);")

        // Standalone FTS5 index — see the sync-strategy note in this file's
        // doc comment. `capture_id` is UNINDEXED: it is never matched
        // against, only used to join back to `captures`/delete stale rows.
        try connection.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS captures_fts USING fts5(
                capture_id UNINDEXED,
                ocr_text,
                annotation_text,
                url,
                page_title,
                tags
            );
            """
        )

        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS audit_findings (
                id                    TEXT PRIMARY KEY,
                project_id            TEXT REFERENCES projects(id) ON DELETE SET NULL,
                title                 TEXT NOT NULL,
                category              TEXT NOT NULL,
                severity              TEXT NOT NULL,
                status                TEXT NOT NULL,
                finding               TEXT NOT NULL,
                recommendation        TEXT,
                expected_impact       TEXT,
                page_url              TEXT NOT NULL,
                viewport_width        REAL,
                viewport_height       REAL,
                capture_id            TEXT REFERENCES captures(id) ON DELETE SET NULL,
                -- JSON-encoded string arrays (see HistoryStore's use of
                -- CaptureCoreJSON) rather than extra join tables — these
                -- are small, order-sensitive lists owned entirely by one
                -- finding, not independently queried.
                element_evidence_ids  TEXT NOT NULL DEFAULT '[]',
                measurement_ids       TEXT NOT NULL DEFAULT '[]',
                tags                  TEXT NOT NULL DEFAULT '[]',
                created_at            REAL NOT NULL,
                updated_at            REAL NOT NULL
            );
            """
        )
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_audit_findings_category ON audit_findings(category);")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_audit_findings_project_id ON audit_findings(project_id);")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_audit_findings_status ON audit_findings(status);")

        try connection.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS audit_findings_fts USING fts5(
                finding_id UNINDEXED,
                title
            );
            """
        )
    }
}
