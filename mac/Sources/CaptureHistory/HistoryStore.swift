import CaptureCore
import CoreGraphics
import Foundation

/// The local history repository (Part I §10/§25, spec digest
/// `15_history_projects.md`). Owns `history.sqlite`: capture metadata,
/// content-hash dedupe, FTS5 search, projects, and `AuditFinding` CRUD.
/// UI/other modules never touch `SQLiteConnection` directly — this is the
/// only public surface.
public final class HistoryStore: @unchecked Sendable {
    public enum StoreError: Error, Sendable {
        case captureNotFound(UUID)
        case findingNotFound(String)
        case projectNotFound(UUID)
        /// A row read back from SQLite didn't decode into its Swift type
        /// (e.g. an unparsable UUID or an unrecognized enum raw value).
        /// Should never happen for data this store itself wrote; surfaced
        /// rather than silently dropped in case the database was touched
        /// out of band.
        case corruptRow(table: String, column: String)
    }

    let connection: SQLiteConnection
    private let logger = CaptureLogger(category: "history")
    private let idGenerator = AuditFindingIdGenerator()

    /// Opens (creating if necessary) the SQLite file at `path` and runs
    /// migrations. Pass `":memory:"` for an ephemeral in-process database.
    public init(path: String) throws {
        self.connection = try SQLiteConnection(path: path)
        try HistorySchema.migrate(connection)
    }

    /// Convenience for the real on-disk layout described in Part I §10:
    /// `~/Library/Application Support/Capture/history.sqlite`.
    public convenience init(applicationSupportDirectory: URL) throws {
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        let dbURL = applicationSupportDirectory.appendingPathComponent("history.sqlite")
        try self.init(path: dbURL.path)
    }

    public func close() {
        connection.close()
    }

    // MARK: - Column lists (kept in one place so SELECT order and
    // `mapCaptureRow`'s column indices can never silently drift apart)

    private static let captureColumnList = [
        "id", "media_content_hash", "capture_date", "source_app", "url", "domain", "page_title",
        "project_id", "capture_type", "width", "height", "upload_status", "privacy_status",
        "favourite", "ocr_text", "annotation_text", "os", "browser", "colour_scheme", "locale",
        "created_at", "updated_at"
    ]
    private static let captureColumns = captureColumnList.joined(separator: ", ")
    private static let qualifiedCaptureColumns = captureColumnList.map { "c.\($0)" }.joined(separator: ", ")

    private static let findingColumnList = [
        "id", "project_id", "title", "category", "severity", "status", "finding", "recommendation",
        "expected_impact", "page_url", "viewport_width", "viewport_height", "capture_id",
        "element_evidence_ids", "measurement_ids", "tags", "created_at", "updated_at"
    ]
    private static let findingColumns = findingColumnList.joined(separator: ", ")

    // MARK: - Captures

    /// Inserts a new capture row, or — if `allowDuplicate` is `false`
    /// (the default) and a capture with the same `mediaHash` already
    /// exists — returns the existing capture's id instead of creating a
    /// new one. This is the dedupe-by-content-hash behaviour required by
    /// spec digest §15: "If the exact same screenshot is saved twice:
    /// reference same blob; create another logical capture only if user
    /// explicitly asks" (that explicit ask is `allowDuplicate: true`).
    @discardableResult
    public func insertCapture(
        metadata: CaptureMetadata,
        mediaHash: String,
        projectId: UUID? = nil,
        captureType: ProjectManifest.Kind,
        dimensions: CaptureSize,
        tags: [String] = [],
        ocrText: String? = nil,
        annotationText: String? = nil,
        allowDuplicate: Bool = false
    ) throws -> UUID {
        if !allowDuplicate, let existing = try findExistingCapture(byContentHash: mediaHash) {
            logger.info("Reusing existing capture for duplicate content hash (existing id \(existing.id.uuidString.prefix(8))…)")
            return existing.id
        }

        let id = UUID()
        let now = Date()
        let domain = metadata.url.flatMap(Self.domain(fromURLString:))

        try connection.transaction {
            try connection.execute(
                """
                INSERT INTO captures (\(Self.captureColumns))
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """,
                params: [
                    .text(id.uuidString),
                    .text(mediaHash),
                    .real(metadata.timestamp.timeIntervalSince1970),
                    .text(metadata.sourceApp),
                    Self.textOrNull(metadata.url),
                    Self.textOrNull(domain),
                    Self.textOrNull(metadata.pageTitle),
                    Self.textOrNull(projectId?.uuidString),
                    .text(captureType.rawValue),
                    .real(Double(dimensions.width)),
                    .real(Double(dimensions.height)),
                    .text(UploadStatus.none.rawValue),
                    .text(PrivacyStatus.unreviewed.rawValue),
                    .bool(false),
                    Self.textOrNull(ocrText),
                    Self.textOrNull(annotationText),
                    .text(metadata.os),
                    Self.textOrNull(metadata.browser),
                    Self.textOrNull(metadata.colourScheme),
                    Self.textOrNull(metadata.locale),
                    .real(now.timeIntervalSince1970),
                    .real(now.timeIntervalSince1970)
                ]
            )

            for tag in tags {
                try connection.execute(
                    "INSERT OR IGNORE INTO capture_tags (capture_id, tag) VALUES (?, ?);",
                    params: [.text(id.uuidString), .text(tag)]
                )
            }

            try reindexCaptureFTS(id: id)
        }

        return id
    }

    /// Looks up a capture by its media content hash (Part I §9's
    /// `contentHash`, the same value stored in `manifest.json.source`).
    /// The dedupe rule keys off this, not filename or capture date, so two
    /// captures of pixel-identical content always resolve to one row
    /// unless the caller explicitly opts into a duplicate.
    public func findExistingCapture(byContentHash hash: String) throws -> HistoryEntry? {
        let rows = try connection.query(
            "SELECT \(Self.captureColumns) FROM captures WHERE media_content_hash = ? ORDER BY capture_date DESC LIMIT 1;",
            params: [.text(hash)],
            map: mapCaptureRow
        )
        return rows.first
    }

    public func capture(id: UUID) throws -> HistoryEntry? {
        let rows = try connection.query(
            "SELECT \(Self.captureColumns) FROM captures WHERE id = ?;",
            params: [.text(id.uuidString)],
            map: mapCaptureRow
        )
        return rows.first
    }

    public func recentCaptures(limit: Int) throws -> [HistoryEntry] {
        try connection.query(
            "SELECT \(Self.captureColumns) FROM captures ORDER BY capture_date DESC LIMIT ?;",
            params: [.int(limit)],
            map: mapCaptureRow
        )
    }

    /// Full-text + filtered search (Part I §25). When `query` is empty
    /// (after trimming) this degrades to a plain filtered browse over
    /// `captures` with no FTS5 join — useful for e.g. "show me every
    /// recording in this project" with no text query at all.
    public func search(query: String, filters: HistorySearchFilters = HistorySearchFilters()) throws -> [HistoryEntry] {
        var whereClauses: [String] = []
        var params: [SQLiteConnection.Value] = []
        var fromClause = "captures c"

        if let matchExpression = Self.ftsMatchExpression(from: query) {
            fromClause = "captures_fts f JOIN captures c ON c.id = f.capture_id"
            whereClauses.append("f MATCH ?")
            params.append(.text(matchExpression))
        }

        if let domain = filters.domain {
            whereClauses.append("c.domain = ?")
            params.append(.text(domain))
        }
        if let captureType = filters.captureType {
            whereClauses.append("c.capture_type = ?")
            params.append(.text(captureType.rawValue))
        }
        if let projectId = filters.projectId {
            whereClauses.append("c.project_id = ?")
            params.append(.text(projectId.uuidString))
        }
        if filters.favouriteOnly {
            whereClauses.append("c.favourite = 1")
        }
        if let range = filters.dateRange {
            whereClauses.append("c.capture_date BETWEEN ? AND ?")
            params.append(.real(range.lowerBound.timeIntervalSince1970))
            params.append(.real(range.upperBound.timeIntervalSince1970))
        }
        if !filters.tags.isEmpty {
            let placeholders = filters.tags.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("c.id IN (SELECT capture_id FROM capture_tags WHERE tag IN (\(placeholders)))")
            params.append(contentsOf: filters.tags.map { .text($0) })
        }

        var sql = "SELECT \(Self.qualifiedCaptureColumns) FROM \(fromClause)"
        if !whereClauses.isEmpty {
            sql += " WHERE " + whereClauses.joined(separator: " AND ")
        }
        sql += " ORDER BY c.capture_date DESC;"

        return try connection.query(sql, params: params, map: mapCaptureRow)
    }

    public func setFavourite(_ favourite: Bool, forCapture id: UUID) throws {
        try connection.execute(
            "UPDATE captures SET favourite = ?, updated_at = ? WHERE id = ?;",
            params: [.bool(favourite), .real(Date().timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    public func setPrivacyStatus(_ status: PrivacyStatus, forCapture id: UUID) throws {
        try connection.execute(
            "UPDATE captures SET privacy_status = ?, updated_at = ? WHERE id = ?;",
            params: [.text(status.rawValue), .real(Date().timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    public func setUploadStatus(_ status: UploadStatus, forCapture id: UUID) throws {
        try connection.execute(
            "UPDATE captures SET upload_status = ?, updated_at = ? WHERE id = ?;",
            params: [.text(status.rawValue), .real(Date().timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    /// Updates a capture's OCR/annotation text (e.g. after OCR completes,
    /// or after the editor's annotation text changes) and re-syncs FTS.
    public func updateSearchableText(forCapture id: UUID, ocrText: String?, annotationText: String?) throws {
        try connection.transaction {
            try connection.execute(
                "UPDATE captures SET ocr_text = ?, annotation_text = ?, updated_at = ? WHERE id = ?;",
                params: [Self.textOrNull(ocrText), Self.textOrNull(annotationText), .real(Date().timeIntervalSince1970), .text(id.uuidString)]
            )
            try reindexCaptureFTS(id: id)
        }
    }

    public func setTags(_ tags: [String], forCapture id: UUID) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM capture_tags WHERE capture_id = ?;", params: [.text(id.uuidString)])
            for tag in tags {
                try connection.execute(
                    "INSERT OR IGNORE INTO capture_tags (capture_id, tag) VALUES (?, ?);",
                    params: [.text(id.uuidString), .text(tag)]
                )
            }
            try reindexCaptureFTS(id: id)
        }
    }

    /// "Remove from history" (spec digest §15's security-delete list —
    /// this store only owns the history index row; deleting the
    /// underlying media file / OCR index / cloud copy are separate steps
    /// owned by the caller, since this module has no filesystem or
    /// network access).
    @discardableResult
    public func deleteCapture(id: UUID) throws -> Bool {
        try connection.transaction {
            try connection.execute("DELETE FROM captures_fts WHERE capture_id = ?;", params: [.text(id.uuidString)])
            try connection.execute("DELETE FROM captures WHERE id = ?;", params: [.text(id.uuidString)])
            return connection.changedRowCount > 0
        }
    }

    private func reindexCaptureFTS(id: UUID) throws {
        let rows = try connection.query(
            "SELECT url, page_title, ocr_text, annotation_text FROM captures WHERE id = ?;",
            params: [.text(id.uuidString)]
        ) { statement in
            (statement.optionalText(0), statement.optionalText(1), statement.optionalText(2), statement.optionalText(3))
        }

        try connection.execute("DELETE FROM captures_fts WHERE capture_id = ?;", params: [.text(id.uuidString)])

        guard let (url, pageTitle, ocrText, annotationText) = rows.first else {
            // Capture no longer exists; leaving no FTS row is correct.
            return
        }

        let tags = try tags(forCapture: id)
        try connection.execute(
            "INSERT INTO captures_fts (capture_id, ocr_text, annotation_text, url, page_title, tags) VALUES (?,?,?,?,?,?);",
            params: [
                .text(id.uuidString),
                .text(ocrText ?? ""),
                .text(annotationText ?? ""),
                .text(url ?? ""),
                .text(pageTitle ?? ""),
                .text(tags.joined(separator: " "))
            ]
        )
    }

    private func tags(forCapture id: UUID) throws -> [String] {
        try connection.query(
            "SELECT tag FROM capture_tags WHERE capture_id = ? ORDER BY tag ASC;",
            params: [.text(id.uuidString)]
        ) { $0.text(0) }
    }

    private func mapCaptureRow(_ statement: SQLiteConnection.Statement) throws -> HistoryEntry {
        guard let id = UUID(uuidString: statement.text(0)) else {
            throw StoreError.corruptRow(table: "captures", column: "id")
        }
        guard let captureType = ProjectManifest.Kind(rawValue: statement.text(8)) else {
            throw StoreError.corruptRow(table: "captures", column: "capture_type")
        }
        let projectId = statement.optionalText(7).flatMap(UUID.init(uuidString:))

        return HistoryEntry(
            id: id,
            mediaContentHash: statement.text(1),
            captureDate: Date(timeIntervalSince1970: statement.double(2)),
            sourceApp: statement.optionalText(3),
            url: statement.optionalText(4),
            domain: statement.optionalText(5),
            pageTitle: statement.optionalText(6),
            projectId: projectId,
            captureType: captureType,
            dimensions: CaptureSize(width: CGFloat(statement.double(9)), height: CGFloat(statement.double(10))),
            uploadStatus: UploadStatus(rawValue: statement.text(11)) ?? .none,
            privacyStatus: PrivacyStatus(rawValue: statement.text(12)) ?? .unreviewed,
            favourite: statement.bool(13),
            tags: try tags(forCapture: id),
            ocrText: statement.optionalText(14),
            annotationText: statement.optionalText(15),
            os: statement.optionalText(16),
            browser: statement.optionalText(17),
            colourScheme: statement.optionalText(18),
            locale: statement.optionalText(19),
            createdAt: Date(timeIntervalSince1970: statement.double(20)),
            updatedAt: Date(timeIntervalSince1970: statement.double(21))
        )
    }

    // MARK: - Projects

    @discardableResult
    public func createProject(name: String, retentionPolicy: RetentionPolicy? = nil) throws -> UUID {
        let id = UUID()
        try connection.execute(
            "INSERT INTO projects (id, name, created_at, retention_policy, favourite) VALUES (?,?,?,?,0);",
            params: [.text(id.uuidString), .text(name), .real(Date().timeIntervalSince1970), Self.textOrNull(retentionPolicy?.rawValue)]
        )
        return id
    }

    public func project(id: UUID) throws -> ProjectSummary? {
        try connection.query(
            "SELECT id, name, created_at, retention_policy, favourite FROM projects WHERE id = ?;",
            params: [.text(id.uuidString)],
            map: mapProjectRow
        ).first
    }

    public func projects() throws -> [ProjectSummary] {
        try connection.query(
            "SELECT id, name, created_at, retention_policy, favourite FROM projects ORDER BY created_at DESC;",
            map: mapProjectRow
        )
    }

    /// Sets (or clears, passing `nil`) this project's retention override.
    /// `RetentionPolicy.purgeExpired` reads this back every time it runs.
    public func setRetentionPolicy(_ policy: RetentionPolicy?, forProject id: UUID) throws {
        try connection.execute(
            "UPDATE projects SET retention_policy = ? WHERE id = ?;",
            params: [Self.textOrNull(policy?.rawValue), .text(id.uuidString)]
        )
    }

    private func mapProjectRow(_ statement: SQLiteConnection.Statement) throws -> ProjectSummary {
        guard let id = UUID(uuidString: statement.text(0)) else {
            throw StoreError.corruptRow(table: "projects", column: "id")
        }
        let policy = statement.optionalText(3).flatMap(RetentionPolicy.init(rawValue:))
        return ProjectSummary(
            id: id,
            name: statement.text(1),
            createdAt: Date(timeIntervalSince1970: statement.double(2)),
            retentionPolicy: policy,
            favourite: statement.bool(4)
        )
    }

    // MARK: - Audit findings

    /// Number of findings already created for `category`, optionally
    /// scoped to one project (so numbering restarts per-project rather
    /// than being one global sequence across every audit). This is the
    /// value `AuditFindingIdGenerator.nextId(category:existingCount:)`
    /// needs — this store is the "source of truth" the generator's doc
    /// comment refers to.
    public func countFindings(category: AuditFinding.Category, projectId: UUID? = nil) throws -> Int {
        let rows: [Int]
        if let projectId {
            rows = try connection.query(
                "SELECT COUNT(*) FROM audit_findings WHERE category = ? AND project_id = ?;",
                params: [.text(category.rawValue), .text(projectId.uuidString)]
            ) { $0.int(0) }
        } else {
            rows = try connection.query(
                "SELECT COUNT(*) FROM audit_findings WHERE category = ?;",
                params: [.text(category.rawValue)]
            ) { $0.int(0) }
        }
        return rows.first ?? 0
    }

    /// Creates a new finding, assigning its human-facing sequential id
    /// (`PDP-01`, `NAV-02`, ...) via `CaptureCore.AuditFindingIdGenerator`
    /// fed by `countFindings(category:projectId:)`.
    @discardableResult
    public func createFinding(
        title: String,
        category: AuditFinding.Category,
        severity: AuditFinding.Severity,
        findingText: String,
        recommendation: String? = nil,
        expectedImpact: String? = nil,
        pageUrl: String,
        viewport: [Double]? = nil,
        captureId: UUID? = nil,
        elementEvidenceIds: [UUID] = [],
        measurementIds: [String] = [],
        projectId: UUID? = nil,
        tags: [String] = []
    ) throws -> AuditFinding {
        try connection.transaction {
            let existingCount = try countFindings(category: category, projectId: projectId)
            let humanId = idGenerator.nextId(category: category, existingCount: existingCount)
            let now = Date()
            let record = AuditFinding(
                id: humanId,
                projectId: projectId,
                title: title,
                category: category,
                severity: severity,
                status: .open,
                finding: findingText,
                recommendation: recommendation,
                expectedImpact: expectedImpact,
                pageUrl: pageUrl,
                viewport: viewport,
                captureId: captureId,
                elementEvidenceIds: elementEvidenceIds,
                measurementIds: measurementIds,
                createdAt: now,
                updatedAt: now,
                tags: tags
            )
            try insertFindingRow(record)
            try reindexFindingFTS(id: record.id)
            return record
        }
    }

    public func finding(id: String) throws -> AuditFinding? {
        try connection.query(
            "SELECT \(Self.findingColumns) FROM audit_findings WHERE id = ?;",
            params: [.text(id)],
            map: mapFindingRow
        ).first
    }

    public func findings(projectId: UUID? = nil, category: AuditFinding.Category? = nil, status: AuditFinding.Status? = nil) throws -> [AuditFinding] {
        var whereClauses: [String] = []
        var params: [SQLiteConnection.Value] = []
        if let projectId {
            whereClauses.append("project_id = ?")
            params.append(.text(projectId.uuidString))
        }
        if let category {
            whereClauses.append("category = ?")
            params.append(.text(category.rawValue))
        }
        if let status {
            whereClauses.append("status = ?")
            params.append(.text(status.rawValue))
        }
        var sql = "SELECT \(Self.findingColumns) FROM audit_findings"
        if !whereClauses.isEmpty {
            sql += " WHERE " + whereClauses.joined(separator: " AND ")
        }
        sql += " ORDER BY created_at ASC;"
        return try connection.query(sql, params: params, map: mapFindingRow)
    }

    /// Replaces a finding's mutable fields in place. `id`, `projectId`,
    /// and `createdAt` are treated as identity and never change here —
    /// build a new `AuditFinding` value (e.g. `existing` with fields
    /// overwritten) and pass that in, with `updatedAt` left to this method.
    public func updateFinding(_ finding: AuditFinding) throws {
        try connection.transaction {
            var updated = finding
            updated.updatedAt = Date()
            try connection.execute(
                """
                UPDATE audit_findings SET
                    title = ?, category = ?, severity = ?, status = ?, finding = ?,
                    recommendation = ?, expected_impact = ?, page_url = ?,
                    viewport_width = ?, viewport_height = ?, capture_id = ?,
                    element_evidence_ids = ?, measurement_ids = ?, tags = ?, updated_at = ?
                WHERE id = ?;
                """,
                params: [
                    .text(updated.title), .text(updated.category.rawValue), .text(updated.severity.rawValue),
                    .text(updated.status.rawValue), .text(updated.finding),
                    Self.textOrNull(updated.recommendation), Self.textOrNull(updated.expectedImpact), .text(updated.pageUrl),
                    Self.viewportComponent(updated.viewport, at: 0), Self.viewportComponent(updated.viewport, at: 1),
                    Self.textOrNull(updated.captureId?.uuidString),
                    .text(try Self.encodeStringArray(updated.elementEvidenceIds.map { $0.uuidString })),
                    .text(try Self.encodeStringArray(updated.measurementIds)),
                    .text(try Self.encodeStringArray(updated.tags)),
                    .real(updated.updatedAt.timeIntervalSince1970),
                    .text(updated.id)
                ]
            )
            guard connection.changedRowCount > 0 else { throw StoreError.findingNotFound(finding.id) }
            try reindexFindingFTS(id: updated.id)
        }
    }

    @discardableResult
    public func deleteFinding(id: String) throws -> Bool {
        try connection.transaction {
            try connection.execute("DELETE FROM audit_findings_fts WHERE finding_id = ?;", params: [.text(id)])
            try connection.execute("DELETE FROM audit_findings WHERE id = ?;", params: [.text(id)])
            return connection.changedRowCount > 0
        }
    }

    /// Simple prefix/word search over finding titles via `audit_findings_fts`
    /// (spec digest §10: "FTS5 for: ... finding title").
    public func searchFindings(titleQuery: String) throws -> [AuditFinding] {
        guard let matchExpression = Self.ftsMatchExpression(from: titleQuery) else { return [] }
        return try connection.query(
            """
            SELECT \(Self.findingColumnList.map { "af.\($0)" }.joined(separator: ", "))
            FROM audit_findings_fts f
            JOIN audit_findings af ON af.id = f.finding_id
            WHERE f MATCH ?
            ORDER BY af.created_at ASC;
            """,
            params: [.text(matchExpression)],
            map: mapFindingRow
        )
    }

    private func insertFindingRow(_ finding: AuditFinding) throws {
        try connection.execute(
            """
            INSERT INTO audit_findings (\(Self.findingColumns))
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """,
            params: [
                .text(finding.id),
                Self.textOrNull(finding.projectId?.uuidString),
                .text(finding.title),
                .text(finding.category.rawValue),
                .text(finding.severity.rawValue),
                .text(finding.status.rawValue),
                .text(finding.finding),
                Self.textOrNull(finding.recommendation),
                Self.textOrNull(finding.expectedImpact),
                .text(finding.pageUrl),
                Self.viewportComponent(finding.viewport, at: 0),
                Self.viewportComponent(finding.viewport, at: 1),
                Self.textOrNull(finding.captureId?.uuidString),
                .text(try Self.encodeStringArray(finding.elementEvidenceIds.map { $0.uuidString })),
                .text(try Self.encodeStringArray(finding.measurementIds)),
                .text(try Self.encodeStringArray(finding.tags)),
                .real(finding.createdAt.timeIntervalSince1970),
                .real(finding.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    private func reindexFindingFTS(id: String) throws {
        try connection.execute("DELETE FROM audit_findings_fts WHERE finding_id = ?;", params: [.text(id)])
        let titles = try connection.query(
            "SELECT title FROM audit_findings WHERE id = ?;",
            params: [.text(id)]
        ) { $0.text(0) }
        guard let title = titles.first else { return }
        try connection.execute(
            "INSERT INTO audit_findings_fts (finding_id, title) VALUES (?, ?);",
            params: [.text(id), .text(title)]
        )
    }

    private func mapFindingRow(_ statement: SQLiteConnection.Statement) throws -> AuditFinding {
        guard let category = AuditFinding.Category(rawValue: statement.text(3)) else {
            throw StoreError.corruptRow(table: "audit_findings", column: "category")
        }
        guard let severity = AuditFinding.Severity(rawValue: statement.text(4)) else {
            throw StoreError.corruptRow(table: "audit_findings", column: "severity")
        }
        guard let status = AuditFinding.Status(rawValue: statement.text(5)) else {
            throw StoreError.corruptRow(table: "audit_findings", column: "status")
        }
        let projectId = statement.optionalText(1).flatMap(UUID.init(uuidString:))
        let captureId = statement.optionalText(12).flatMap(UUID.init(uuidString:))
        let viewportWidth = statement.optionalDouble(10)
        let viewportHeight = statement.optionalDouble(11)
        let viewport: [Double]? = viewportWidth.map { [$0, viewportHeight ?? 0] }

        let elementEvidenceIds = (try? Self.decodeStringArray(statement.text(13)))?.compactMap(UUID.init(uuidString:)) ?? []
        let measurementIds = (try? Self.decodeStringArray(statement.text(14))) ?? []
        let tags = (try? Self.decodeStringArray(statement.text(15))) ?? []

        return AuditFinding(
            id: statement.text(0),
            projectId: projectId,
            title: statement.text(2),
            category: category,
            severity: severity,
            status: status,
            finding: statement.text(6),
            recommendation: statement.optionalText(7),
            expectedImpact: statement.optionalText(8),
            pageUrl: statement.text(9),
            viewport: viewport,
            captureId: captureId,
            elementEvidenceIds: elementEvidenceIds,
            measurementIds: measurementIds,
            createdAt: Date(timeIntervalSince1970: statement.double(16)),
            updatedAt: Date(timeIntervalSince1970: statement.double(17)),
            tags: tags
        )
    }

    // MARK: - Small shared helpers

    private static func textOrNull(_ value: String?) -> SQLiteConnection.Value {
        value.map { .text($0) } ?? .null
    }

    private static func viewportComponent(_ viewport: [Double]?, at index: Int) -> SQLiteConnection.Value {
        guard let viewport, viewport.count > index else { return .null }
        return .real(viewport[index])
    }

    private static func encodeStringArray(_ values: [String]) throws -> String {
        let data = try CaptureCoreJSON.encoder.encode(values)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeStringArray(_ json: String) throws -> [String] {
        guard let data = json.data(using: .utf8) else { return [] }
        return try CaptureCoreJSON.decoder.decode([String].self, from: data)
    }

    /// `example.com` from `https://example.com/products/x?y=1`, or `nil`
    /// if `urlString` doesn't parse to a URL with a host.
    static func domain(fromURLString urlString: String) -> String? {
        URL(string: urlString)?.host
    }

    /// Builds an FTS5 `MATCH` query string from free-text user input.
    /// Every whitespace-separated token becomes a quoted prefix term
    /// (`"token"*`), ANDed together:
    ///   - quoting neutralizes FTS5's query-syntax operators (`-`, `:`,
    ///     `"`, parentheses, `NEAR`, ...) so arbitrary user text — tags,
    ///     URLs, page titles — never produces an FTS5 syntax error;
    ///   - the `*` suffix gives prefix matching ("chec" finds "checkout"),
    ///     which is the closest FTS5's tokenizer gets to substring search
    ///     without a trigram tokenizer.
    /// Returns `nil` for empty/whitespace-only input (the caller should
    /// fall back to a plain filtered query with no FTS join in that case).
    static func ftsMatchExpression(from raw: String) -> String? {
        let tokens = raw
            .split(whereSeparator: { $0.isWhitespace })
            .map { token -> String in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
        guard !tokens.isEmpty else { return nil }
        return tokens.joined(separator: " AND ")
    }
}
