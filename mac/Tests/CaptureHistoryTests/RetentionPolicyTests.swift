import CaptureCore
import XCTest
@testable import CaptureHistory

final class RetentionPolicyTests: HistoryStoreTestCase {
    /// Inserts a capture whose `capture_date` is `ageInSeconds` in the
    /// past, bypassing `insertCapture`'s `Date()`-stamped `CaptureMetadata`
    /// convenience so tests can precisely control age.
    @discardableResult
    private func insertCapture(hash: String, ageInSeconds: TimeInterval) throws -> UUID {
        let metadata = CaptureMetadata(
            timestamp: Date(timeIntervalSinceNow: -ageInSeconds),
            sourceApp: "TestApp",
            os: "macOS 15.0"
        )
        return try store.insertCapture(
            metadata: metadata,
            mediaHash: hash,
            captureType: .screenshot,
            dimensions: .zero
        )
    }

    func testPurgeDeletesOnlyExpiredCaptures() throws {
        let oldId = try insertCapture(hash: "old", ageInSeconds: 40 * 24 * 3600) // 40 days old
        let freshId = try insertCapture(hash: "fresh", ageInSeconds: 3600) // 1 hour old

        let deletedCount = try store.purgeExpired(defaultPolicy: .days30)

        XCTAssertEqual(deletedCount, 1)
        XCTAssertNil(try store.capture(id: oldId), "capture older than the 30-day policy must be purged")
        XCTAssertNotNil(try store.capture(id: freshId), "capture within the 30-day policy must survive")
    }

    func testPurgeIsIdempotent() throws {
        try insertCapture(hash: "old", ageInSeconds: 40 * 24 * 3600)

        let firstPass = try store.purgeExpired(defaultPolicy: .days30)
        let secondPass = try store.purgeExpired(defaultPolicy: .days30)

        XCTAssertEqual(firstPass, 1)
        XCTAssertEqual(secondPass, 0, "a second purge with nothing new to expire must delete nothing")
    }

    func testForeverPolicyNeverDeletes() throws {
        let veryOldId = try insertCapture(hash: "ancient", ageInSeconds: 5 * 365 * 24 * 3600) // 5 years old

        let deletedCount = try store.purgeExpired(defaultPolicy: .forever)

        XCTAssertEqual(deletedCount, 0)
        XCTAssertNotNil(try store.capture(id: veryOldId), "forever policy must never purge, however old the capture")
    }

    func testProjectRetentionOverrideTakesPrecedenceOverDefault() throws {
        // Project keeps everything forever, even though the app-wide
        // default is aggressive (24 hours).
        let projectId = try store.createProject(name: "Legal Hold", retentionPolicy: .forever)
        let metadata = CaptureMetadata(timestamp: Date(timeIntervalSinceNow: -10 * 24 * 3600), sourceApp: "App", os: "macOS 15.0")
        let protectedId = try store.insertCapture(
            metadata: metadata, mediaHash: "protected", projectId: projectId,
            captureType: .screenshot, dimensions: .zero
        )

        // An un-projected capture of the same age should be purged under
        // the aggressive default.
        let unprotectedId = try insertCapture(hash: "unprotected", ageInSeconds: 10 * 24 * 3600)

        let deletedCount = try store.purgeExpired(defaultPolicy: .hours24)

        XCTAssertEqual(deletedCount, 1)
        XCTAssertNotNil(try store.capture(id: protectedId), "project-level forever override must protect its captures")
        XCTAssertNil(try store.capture(id: unprotectedId), "captures with no project must fall back to the default policy")
    }

    func testProjectOverrideCanBeStricterThanDefault() throws {
        // Project purges aggressively (24h) even though the app-wide
        // default is lenient (forever) — Part I §25: "Never silently
        // retain sensitive captures forever if user chose a shorter
        // policy."
        let projectId = try store.createProject(name: "Sensitive Client Audit", retentionPolicy: .hours24)
        let metadata = CaptureMetadata(timestamp: Date(timeIntervalSinceNow: -48 * 3600), sourceApp: "App", os: "macOS 15.0")
        let sensitiveId = try store.insertCapture(
            metadata: metadata, mediaHash: "sensitive", projectId: projectId,
            captureType: .screenshot, dimensions: .zero
        )

        let deletedCount = try store.purgeExpired(defaultPolicy: .forever)

        XCTAssertEqual(deletedCount, 1)
        XCTAssertNil(try store.capture(id: sensitiveId), "a stricter per-project policy must not be overridden by a lenient default")
    }

    func testSessionPolicyOnlyPurgesPriorSessions() throws {
        let projectId = try store.createProject(name: "Ephemeral Work", retentionPolicy: .session)
        let sessionStart = Date()

        let staleMetadata = CaptureMetadata(timestamp: sessionStart.addingTimeInterval(-3600), sourceApp: "App", os: "macOS 15.0")
        let staleId = try store.insertCapture(
            metadata: staleMetadata, mediaHash: "previous-session", projectId: projectId,
            captureType: .screenshot, dimensions: .zero
        )

        let currentMetadata = CaptureMetadata(timestamp: sessionStart.addingTimeInterval(60), sourceApp: "App", os: "macOS 15.0")
        let currentId = try store.insertCapture(
            metadata: currentMetadata, mediaHash: "current-session", projectId: projectId,
            captureType: .screenshot, dimensions: .zero
        )

        // Without a session boundary, session-policy captures are left alone.
        XCTAssertEqual(try store.purgeExpired(defaultPolicy: .forever), 0)
        XCTAssertNotNil(try store.capture(id: staleId))

        // With an explicit session boundary, only the capture that predates
        // the new session is purged.
        let deletedCount = try store.purgeExpired(defaultPolicy: .forever, sessionStartDate: sessionStart)
        XCTAssertEqual(deletedCount, 1)
        XCTAssertNil(try store.capture(id: staleId))
        XCTAssertNotNil(try store.capture(id: currentId))
    }

    func testPurgeRemovesFTSRowsToo() throws {
        let id = try insertCapture(hash: "old-fts", ageInSeconds: 40 * 24 * 3600)
        try store.updateSearchableText(forCapture: id, ocrText: "purgeable content", annotationText: nil)

        XCTAssertEqual(try store.search(query: "purgeable").count, 1)
        _ = try store.purgeExpired(defaultPolicy: .days30)
        XCTAssertTrue(try store.search(query: "purgeable").isEmpty, "purge must also drop the now-orphaned FTS row")
    }
}
