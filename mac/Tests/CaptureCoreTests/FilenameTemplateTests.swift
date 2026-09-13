import XCTest
@testable import CaptureCore

final class FilenameTemplateTests: XCTestCase {
    func testRendersAllTokens() {
        let date = Date(timeIntervalSince1970: 1_757_000_000) // fixed for determinism
        let context = FilenameTemplateContext(
            date: date, domain: "example.com", pageTitle: "Product / Page", app: "Google Chrome",
            project: "PDP Audit", width: 1440, height: 900, counter: 3
        )
        let result = FilenameTemplate.render("{project}_{domain}_{viewport}_{date}_{counter}", context: context)
        XCTAssertTrue(result.contains("PDP Audit") || result.contains("PDP-Audit"))
        XCTAssertTrue(result.contains("example.com"))
        XCTAssertTrue(result.contains("1440x900"))
        XCTAssertTrue(result.contains("003"))
        XCTAssertFalse(result.contains("/"))
    }

    func testMissingTokensDoNotLeaveLiteralBraces() {
        let context = FilenameTemplateContext(app: "Capture")
        let result = FilenameTemplate.render("{app}_{pageTitle}_{counter}", context: context)
        XCTAssertFalse(result.contains("{"))
        XCTAssertFalse(result.contains("}"))
    }

    func testEmptyTemplateFallsBackToDefaultName() {
        let result = FilenameTemplate.render("{pageTitle}", context: FilenameTemplateContext())
        XCTAssertEqual(result, "Capture")
    }

    func testSanitizesInvalidFilesystemCharacters() {
        let sanitized = FilenameTemplate.sanitizeComponent("a/b:c?d")
        XCTAssertFalse(sanitized.contains("/"))
        XCTAssertFalse(sanitized.contains(":"))
        XCTAssertFalse(sanitized.contains("?"))
    }
}
