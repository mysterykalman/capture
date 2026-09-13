import CaptureCore
import XCTest
@testable import CaptureInspection

final class CopyFormattersTests: XCTestCase {
    func testCopySelectorReturnsTheLocatorPrimaryString() {
        let evidence = ForensicsFixtures.hoverCardExampleEvidence()
        XCTAssertEqual(CopyFormatters.copySelector(evidence), "button.product-form__submit")
    }

    func testCopyAsJSONRoundTripsBackToTheSameEvidence() throws {
        let evidence = ForensicsFixtures.hoverCardExampleEvidence()
        let json = try CopyFormatters.copyAsJSON(evidence)
        let decoded = try CaptureCoreJSON.decoder.decode(ElementEvidence.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, evidence.id)
        XCTAssertEqual(decoded.locator.primary, evidence.locator.primary)
        XCTAssertEqual(decoded.rect.width, evidence.rect.width)
    }

    func testCopyCSSIncludesEveryKnownComputedProperty() {
        let evidence = ForensicsFixtures.hoverCardExampleEvidence()
        let css = CopyFormatters.copyCSS(evidence)

        XCTAssertTrue(css.hasPrefix("button.product-form__submit {"), css)
        XCTAssertTrue(css.contains("width: 328px;"), css)
        XCTAssertTrue(css.contains("height: 48px;"), css)
        XCTAssertTrue(css.contains("font-family: Inter;"), css)
        XCTAssertTrue(css.contains("font-size: 16px;"), css)
        XCTAssertTrue(css.contains("font-weight: 600;"), css)
        XCTAssertTrue(css.contains("line-height: 20px;"), css)
        XCTAssertTrue(css.contains("color: #FFFFFF;"), css)
        XCTAssertTrue(css.contains("background-color: #111111;"), css)
        XCTAssertTrue(css.contains("border-radius: 4px;"), css)
        XCTAssertTrue(css.contains("display: flex;"), css)
        XCTAssertTrue(css.contains("padding: 14px 24px;"), css)
        XCTAssertTrue(css.contains("gap: 8px;"), css)
        XCTAssertTrue(css.hasSuffix("}"), css)
    }

    func testCopyCSSOmitsPropertiesTheEvidenceDoesNotHaveRatherThanFabricatingThem() {
        let bare = ElementEvidence(
            url: "https://example.com",
            viewport: .init(width: 1440, height: 900, devicePixelRatio: 1, scrollX: 0, scrollY: 0),
            locator: .init(primary: "div"),
            rect: .init(x: 0, y: 0, width: 100, height: 20)
        )
        let css = CopyFormatters.copyCSS(bare)
        XCTAssertFalse(css.contains("font-family"))
        XCTAssertFalse(css.contains("color:"))
        XCTAssertTrue(css.contains("width: 100px;"))
    }

    func testCopyIssueEvidenceHasTheExpectedLabeledLines() {
        let evidence = ForensicsFixtures.hoverCardExampleEvidence()
        let markdown = CopyFormatters.copyIssueEvidence(evidence)
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[0], "URL: https://example.com/products/x")
        XCTAssertEqual(lines[1], "Viewport: 1440×900")
        XCTAssertEqual(lines[2], "Selector: button.product-form__submit")
        XCTAssertTrue(lines[3].hasPrefix("Evidence: "))
        XCTAssertTrue(lines[3].contains("328 × 48 px"), lines[3])
        XCTAssertTrue(lines[3].contains("18.9:1"), lines[3])
        XCTAssertTrue(lines[4].hasPrefix("CSS: "))
        XCTAssertTrue(lines[4].contains("color: #FFFFFF;"), lines[4])
    }
}
