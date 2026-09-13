import CaptureCore
import XCTest
@testable import CaptureHistory

final class HistorySearchTests: HistoryStoreTestCase {
    func testSearchMatchesOCRText() throws {
        try insertSampleCapture(mediaHash: "h1", ocrText: "Free shipping on orders over fifty dollars")
        try insertSampleCapture(mediaHash: "h2", ocrText: "Contact our support team")

        let results = try store.search(query: "shipping")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.mediaContentHash, "h1")
    }

    func testSearchMatchesAnnotationText() throws {
        try insertSampleCapture(mediaHash: "h1", annotationText: "This button is too small for mobile")
        try insertSampleCapture(mediaHash: "h2", annotationText: "Consistent spacing here")

        let results = try store.search(query: "mobile")
        XCTAssertEqual(results.map(\.mediaContentHash), ["h1"])
    }

    func testSearchMatchesURL() throws {
        try insertSampleCapture(mediaHash: "h1", url: "https://www.acme-outfitters.com/cart")
        try insertSampleCapture(mediaHash: "h2", url: "https://www.other-store.com/checkout")

        let results = try store.search(query: "acme-outfitters")
        XCTAssertEqual(results.map(\.mediaContentHash), ["h1"])
    }

    func testSearchMatchesPageTitle() throws {
        try insertSampleCapture(mediaHash: "h1", pageTitle: "Checkout — Step 2 of 3")
        try insertSampleCapture(mediaHash: "h2", pageTitle: "Homepage")

        let results = try store.search(query: "checkout")
        XCTAssertEqual(results.map(\.mediaContentHash), ["h1"])
    }

    func testSearchMatchesTags() throws {
        try insertSampleCapture(mediaHash: "h1", tags: ["accessibility", "contrast"])
        try insertSampleCapture(mediaHash: "h2", tags: ["performance"])

        let results = try store.search(query: "accessibility")
        XCTAssertEqual(results.map(\.mediaContentHash), ["h1"])
    }

    func testSearchIsPrefixMatchAcrossFields() throws {
        try insertSampleCapture(mediaHash: "h1", pageTitle: "Recommendations Module Review")

        let results = try store.search(query: "recomm")
        XCTAssertEqual(results.map(\.mediaContentHash), ["h1"])
    }

    func testSearchWithMultipleTermsRequiresAll() throws {
        try insertSampleCapture(mediaHash: "h1", pageTitle: "Cart Drawer", ocrText: "Apply coupon code")
        try insertSampleCapture(mediaHash: "h2", pageTitle: "Cart Drawer", ocrText: "Free shipping banner")

        let results = try store.search(query: "cart coupon")
        XCTAssertEqual(results.map(\.mediaContentHash), ["h1"])
    }

    func testSearchNoMatchReturnsEmpty() throws {
        try insertSampleCapture(mediaHash: "h1", ocrText: "Add to Cart")
        let results = try store.search(query: "nonexistentterm")
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchReindexesAfterTagChange() throws {
        let id = try insertSampleCapture(mediaHash: "h1", tags: ["old-tag"])
        XCTAssertEqual(try store.search(query: "old-tag").count, 1)

        try store.setTags(["new-tag"], forCapture: id)

        XCTAssertTrue(try store.search(query: "old-tag").isEmpty, "stale FTS row for the removed tag must be gone")
        XCTAssertEqual(try store.search(query: "new-tag").map(\.id), [id])
    }

    func testSearchReindexesAfterSearchableTextUpdate() throws {
        let id = try insertSampleCapture(mediaHash: "h1", ocrText: "original text")
        XCTAssertEqual(try store.search(query: "original").count, 1)

        try store.updateSearchableText(forCapture: id, ocrText: "updated text", annotationText: nil)

        XCTAssertTrue(try store.search(query: "original").isEmpty)
        XCTAssertEqual(try store.search(query: "updated").map(\.id), [id])
    }

    func testSearchCombinesQueryWithFilters() throws {
        let projectA = try store.createProject(name: "Project A")
        let projectB = try store.createProject(name: "Project B")
        try insertSampleCapture(mediaHash: "h1", pageTitle: "Cart Review", projectId: projectA)
        try insertSampleCapture(mediaHash: "h2", pageTitle: "Cart Review", projectId: projectB)

        let results = try store.search(query: "cart", filters: HistorySearchFilters(projectId: projectA))
        XCTAssertEqual(results.map(\.mediaContentHash), ["h1"])
    }

    func testEmptyQueryFallsBackToFilteredBrowse() throws {
        try insertSampleCapture(mediaHash: "h1", captureType: .screenshot)
        try insertSampleCapture(mediaHash: "h2", captureType: .recording)

        let results = try store.search(query: "   ", filters: HistorySearchFilters(captureType: .recording))
        XCTAssertEqual(results.map(\.mediaContentHash), ["h2"])
    }

    func testFindingTitleSearch() throws {
        _ = try store.createFinding(
            title: "Recommendation module lacks product relevance",
            category: .recommendations, severity: .medium, findingText: "Shown items are unrelated.",
            pageUrl: "https://shop.example.com/products/1"
        )
        _ = try store.createFinding(
            title: "Checkout button contrast too low",
            category: .checkout, severity: .high, findingText: "Fails WCAG AA.",
            pageUrl: "https://shop.example.com/checkout"
        )

        let results = try store.searchFindings(titleQuery: "recommendation")
        XCTAssertEqual(results.map(\.title), ["Recommendation module lacks product relevance"])
    }
}
