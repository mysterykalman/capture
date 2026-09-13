import CaptureCore
import XCTest
@testable import CaptureHistory

final class AuditFindingStoreTests: HistoryStoreTestCase {
    func testCountFindingsStartsAtZero() throws {
        XCTAssertEqual(try store.countFindings(category: .pdp), 0)
    }

    func testCreateFindingAssignsSequentialIdsPerCategory() throws {
        let first = try store.createFinding(
            title: "Recommendation module lacks product relevance",
            category: .pdp, severity: .medium, findingText: "...", pageUrl: "https://example.com/p/1"
        )
        let second = try store.createFinding(
            title: "CTA below the fold on smaller laptops",
            category: .pdp, severity: .high, findingText: "...", pageUrl: "https://example.com/p/1"
        )
        let firstNav = try store.createFinding(
            title: "Breadcrumb missing on category pages",
            category: .navigation, severity: .low, findingText: "...", pageUrl: "https://example.com/c/1"
        )

        XCTAssertEqual(first.id, "PDP-01")
        XCTAssertEqual(second.id, "PDP-02")
        // A different category has its own independent sequence.
        XCTAssertEqual(firstNav.id, "NAV-01")
    }

    func testCountFindingsReflectsCreatedRows() throws {
        _ = try store.createFinding(title: "A", category: .cart, severity: .low, findingText: "...", pageUrl: "https://x")
        _ = try store.createFinding(title: "B", category: .cart, severity: .low, findingText: "...", pageUrl: "https://x")

        XCTAssertEqual(try store.countFindings(category: .cart), 2)
        XCTAssertEqual(try store.countFindings(category: .checkout), 0)
    }

    func testSequentialIdGenerationMatchesAuditFindingIdGeneratorDirectly() throws {
        // The store must produce exactly what CaptureCore.AuditFindingIdGenerator
        // would produce given the store's own countFindings as existingCount —
        // i.e. HistoryStore is really just wiring the two together, not
        // reimplementing numbering logic itself.
        let generator = AuditFindingIdGenerator()

        for i in 0..<4 {
            let existingCount = try store.countFindings(category: .accessibility)
            let expectedId = generator.nextId(category: .accessibility, existingCount: existingCount)
            let created = try store.createFinding(
                title: "Issue \(i)", category: .accessibility, severity: .opportunity,
                findingText: "...", pageUrl: "https://example.com"
            )
            XCTAssertEqual(created.id, expectedId)
        }
    }

    func testFindingIdsResetPerProject() throws {
        let projectA = try store.createProject(name: "Project A")
        let projectB = try store.createProject(name: "Project B")

        let a1 = try store.createFinding(
            title: "A1", category: .seo, severity: .medium, findingText: "...",
            pageUrl: "https://a.example.com", projectId: projectA
        )
        let b1 = try store.createFinding(
            title: "B1", category: .seo, severity: .medium, findingText: "...",
            pageUrl: "https://b.example.com", projectId: projectB
        )

        XCTAssertEqual(a1.id, "SEO-01")
        XCTAssertEqual(b1.id, "SEO-01", "a different project's category sequence starts over at 01")
    }

    func testFetchFindingByHumanId() throws {
        let created = try store.createFinding(
            title: "Search returns irrelevant results", category: .search, severity: .high,
            findingText: "Query 'boots' returns unrelated items.", pageUrl: "https://example.com/search?q=boots"
        )

        let fetched = try XCTUnwrap(try store.finding(id: created.id))
        XCTAssertEqual(fetched.title, created.title)
        XCTAssertEqual(fetched.category, .search)
        XCTAssertEqual(fetched.severity, .high)
        XCTAssertEqual(fetched.status, .open)
    }

    func testUpdateFindingPersistsChanges() throws {
        var created = try store.createFinding(
            title: "Checkout button contrast too low", category: .checkout, severity: .high,
            findingText: "Fails WCAG AA.", pageUrl: "https://example.com/checkout"
        )
        created.status = .resolved
        created.recommendation = "Increase contrast to at least 4.5:1"

        try store.updateFinding(created)

        let fetched = try XCTUnwrap(try store.finding(id: created.id))
        XCTAssertEqual(fetched.status, .resolved)
        XCTAssertEqual(fetched.recommendation, "Increase contrast to at least 4.5:1")
    }

    func testFindingsFilteredByStatus() throws {
        var open = try store.createFinding(title: "Open one", category: .content, severity: .low, findingText: "...", pageUrl: "https://x")
        let stillOpen = try store.createFinding(title: "Still open", category: .content, severity: .low, findingText: "...", pageUrl: "https://x")
        open.status = .resolved
        try store.updateFinding(open)

        let resolved = try store.findings(category: .content, status: .resolved)
        XCTAssertEqual(resolved.map(\.id), [open.id])

        let stillOpenResults = try store.findings(category: .content, status: .open)
        XCTAssertEqual(stillOpenResults.map(\.id), [stillOpen.id])
    }

    func testDeleteFinding() throws {
        let created = try store.createFinding(title: "Temp", category: .merchandising, severity: .low, findingText: "...", pageUrl: "https://x")
        XCTAssertTrue(try store.deleteFinding(id: created.id))
        XCTAssertNil(try store.finding(id: created.id))
        XCTAssertFalse(try store.deleteFinding(id: created.id))
    }

    func testElementEvidenceAndMeasurementIdsRoundTrip() throws {
        let evidenceId = UUID()
        let created = try store.createFinding(
            title: "Anchored finding", category: .homepage, severity: .medium, findingText: "...",
            pageUrl: "https://example.com", elementEvidenceIds: [evidenceId], measurementIds: ["m-1", "m-2"],
            tags: ["responsive"]
        )

        let fetched = try XCTUnwrap(try store.finding(id: created.id))
        XCTAssertEqual(fetched.elementEvidenceIds, [evidenceId])
        XCTAssertEqual(fetched.measurementIds, ["m-1", "m-2"])
        XCTAssertEqual(fetched.tags, ["responsive"])
    }
}
