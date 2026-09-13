import CaptureCore
import XCTest
@testable import CaptureHistory

final class HistoryStoreTests: HistoryStoreTestCase {
    // MARK: - Insert + retrieve round-trip

    func testInsertAndRetrieveCaptureRoundTrips() throws {
        let metadata = makeMetadata(
            sourceApp: "com.google.Chrome",
            url: "https://shop.example.com/products/acme-widget",
            pageTitle: "Acme Widget"
        )
        let id = try store.insertCapture(
            metadata: metadata,
            mediaHash: "abc123hash",
            projectId: nil,
            captureType: .screenshot,
            dimensions: CaptureSize(width: 1920, height: 1080),
            tags: ["cro", "pdp"],
            ocrText: "Add to Cart",
            annotationText: "Arrow pointing at CTA"
        )

        let fetched = try XCTUnwrap(try store.capture(id: id))
        XCTAssertEqual(fetched.id, id)
        XCTAssertEqual(fetched.mediaContentHash, "abc123hash")
        XCTAssertEqual(fetched.sourceApp, "com.google.Chrome")
        XCTAssertEqual(fetched.url, "https://shop.example.com/products/acme-widget")
        XCTAssertEqual(fetched.domain, "shop.example.com")
        XCTAssertEqual(fetched.pageTitle, "Acme Widget")
        XCTAssertEqual(fetched.captureType, .screenshot)
        XCTAssertEqual(fetched.dimensions.width, 1920)
        XCTAssertEqual(fetched.dimensions.height, 1080)
        XCTAssertEqual(Set(fetched.tags), Set(["cro", "pdp"]))
        XCTAssertEqual(fetched.ocrText, "Add to Cart")
        XCTAssertEqual(fetched.annotationText, "Arrow pointing at CTA")
        XCTAssertEqual(fetched.uploadStatus, .none)
        XCTAssertEqual(fetched.privacyStatus, .unreviewed)
        XCTAssertFalse(fetched.favourite)
    }

    func testCaptureNotFoundReturnsNil() throws {
        let result = try store.capture(id: UUID())
        XCTAssertNil(result)
    }

    func testDomainIsDerivedFromURL() throws {
        let id = try insertSampleCapture(url: "https://www.follett.com/blue-zone")
        let fetched = try XCTUnwrap(try store.capture(id: id))
        XCTAssertEqual(fetched.domain, "www.follett.com")
    }

    func testMissingURLLeavesDomainNil() throws {
        let id = try insertSampleCapture(url: nil, pageTitle: nil)
        let fetched = try XCTUnwrap(try store.capture(id: id))
        XCTAssertNil(fetched.domain)
        XCTAssertNil(fetched.url)
    }

    // MARK: - Dedupe by content hash

    func testInsertingSameHashTwiceReusesExistingCapture() throws {
        let hash = "duplicate-hash-value"
        let firstId = try insertSampleCapture(mediaHash: hash)
        let secondId = try insertSampleCapture(mediaHash: hash)

        XCTAssertEqual(firstId, secondId, "same content hash must resolve to the same logical capture")

        let all = try store.recentCaptures(limit: 100)
        XCTAssertEqual(all.count, 1, "no duplicate row should have been created")
    }

    func testAllowDuplicateCreatesSecondLogicalCapture() throws {
        let hash = "duplicate-hash-value-2"
        let firstId = try insertSampleCapture(mediaHash: hash)
        let secondId = try insertSampleCapture(mediaHash: hash, allowDuplicate: true)

        XCTAssertNotEqual(firstId, secondId, "explicit allowDuplicate must create a second logical capture")

        let all = try store.recentCaptures(limit: 100)
        XCTAssertEqual(all.count, 2)
    }

    func testFindExistingCaptureByContentHash() throws {
        let hash = "findable-hash"
        let id = try insertSampleCapture(mediaHash: hash)

        let found = try store.findExistingCapture(byContentHash: hash)
        XCTAssertEqual(found?.id, id)

        let notFound = try store.findExistingCapture(byContentHash: "no-such-hash")
        XCTAssertNil(notFound)
    }

    // MARK: - Recent captures

    func testRecentCapturesOrderedNewestFirst() throws {
        let metadataOld = CaptureMetadata(timestamp: Date(timeIntervalSinceNow: -3600), sourceApp: "App", os: "macOS 15.0")
        let metadataNew = CaptureMetadata(timestamp: Date(), sourceApp: "App", os: "macOS 15.0")

        let olderId = try store.insertCapture(
            metadata: metadataOld, mediaHash: "old-hash", captureType: .screenshot,
            dimensions: .zero
        )
        let newerId = try store.insertCapture(
            metadata: metadataNew, mediaHash: "new-hash", captureType: .screenshot,
            dimensions: .zero
        )

        let recent = try store.recentCaptures(limit: 10)
        XCTAssertEqual(recent.first?.id, newerId)
        XCTAssertEqual(recent.last?.id, olderId)
    }

    func testRecentCapturesRespectsLimit() throws {
        for i in 0..<5 {
            try insertSampleCapture(mediaHash: "hash-\(i)")
        }
        let limited = try store.recentCaptures(limit: 3)
        XCTAssertEqual(limited.count, 3)
    }

    // MARK: - Tags / favourites / status mutation

    func testSetTagsReplacesExistingTags() throws {
        let id = try insertSampleCapture(tags: ["a", "b"])
        try store.setTags(["c"], forCapture: id)
        let fetched = try XCTUnwrap(try store.capture(id: id))
        XCTAssertEqual(fetched.tags, ["c"])
    }

    func testSetFavourite() throws {
        let id = try insertSampleCapture()
        try store.setFavourite(true, forCapture: id)
        let fetched = try XCTUnwrap(try store.capture(id: id))
        XCTAssertTrue(fetched.favourite)
    }

    func testSetPrivacyStatus() throws {
        let id = try insertSampleCapture()
        try store.setPrivacyStatus(.containsSensitiveData, forCapture: id)
        let fetched = try XCTUnwrap(try store.capture(id: id))
        XCTAssertEqual(fetched.privacyStatus, .containsSensitiveData)
    }

    func testDeleteCaptureRemovesRow() throws {
        let id = try insertSampleCapture()
        XCTAssertTrue(try store.deleteCapture(id: id))
        XCTAssertNil(try store.capture(id: id))
        // Deleting again is a no-op that reports nothing was deleted.
        XCTAssertFalse(try store.deleteCapture(id: id))
    }

    // MARK: - Projects

    func testCreateAndFetchProject() throws {
        let id = try store.createProject(name: "Trainz CRO Audit", retentionPolicy: .days90)
        let project = try XCTUnwrap(try store.project(id: id))
        XCTAssertEqual(project.name, "Trainz CRO Audit")
        XCTAssertEqual(project.retentionPolicy, .days90)
    }

    func testCaptureCanBeScopedToProject() throws {
        let projectId = try store.createProject(name: "PDP QA")
        let id = try insertSampleCapture(projectId: projectId)
        let fetched = try XCTUnwrap(try store.capture(id: id))
        XCTAssertEqual(fetched.projectId, projectId)

        let results = try store.search(query: "", filters: HistorySearchFilters(projectId: projectId))
        XCTAssertEqual(results.map(\.id), [id])
    }
}
