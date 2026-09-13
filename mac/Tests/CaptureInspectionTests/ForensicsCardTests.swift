import CaptureCore
import XCTest
@testable import CaptureInspection

/// Builds fixtures that reproduce the spec digest's exact hover-card
/// example (`06_browser_inspector.md`) field-for-field:
/// ```text
/// button.product-form__submit
/// 328 × 48 px
///
/// Inter
/// 16 px / 600
/// line-height 20 px
///
/// Text #FFFFFF
/// Background #111111
/// Contrast 18.9:1
///
/// Padding 14px 24px
/// Radius 4px
/// Display flex
/// Gap 8px
/// ```
enum ForensicsFixtures {
    static func hoverCardExampleEvidence() -> ElementEvidence {
        ElementEvidence(
            url: "https://example.com/products/x",
            viewport: .init(width: 1440, height: 900, devicePixelRatio: 2, scrollX: 0, scrollY: 0),
            locator: .init(primary: "button.product-form__submit"),
            rect: .init(x: 0, y: 0, width: 328, height: 48),
            boxModel: .init(
                padding: .init(top: 14, right: 24, bottom: 14, left: 24),
                gap: "8px",
                display: "flex"
            ),
            typography: .init(
                fontFamilyRendered: "Inter",
                fontSizePx: 16,
                fontWeight: "600",
                lineHeightPx: 20,
                textColor: "#FFFFFF"
            ),
            appearance: .init(backgroundColor: "#111111", borderRadius: "4px")
            // accessibility.contrastRatio deliberately left nil, so the
            // 18.9:1 figure below is proven end-to-end from the real WCAG
            // math against #FFFFFF/#111111, not asserted back from an
            // extension-supplied number.
        )
    }
}

final class ForensicsCardSummarizeTests: XCTestCase {
    func testCompactCardMatchesEveryLabeledFieldInTheSpecExample() {
        let card = ForensicsCard.summarize(ForensicsFixtures.hoverCardExampleEvidence())

        XCTAssertEqual(card.selector, "button.product-form__submit")
        XCTAssertEqual(card.dimensionsLabel, "328 × 48 px")

        XCTAssertEqual(card.fontFamily, "Inter")
        XCTAssertEqual(card.fontSizeAndWeightLabel, "16 px / 600")
        XCTAssertEqual(card.lineHeightLabel, "line-height 20 px")

        XCTAssertEqual(card.textColor, "#FFFFFF")
        XCTAssertEqual(card.backgroundColor, "#111111")
        XCTAssertEqual(card.contrastLabel, "18.9:1")

        XCTAssertEqual(card.padding, "14px 24px")
        XCTAssertEqual(card.borderRadius, "4px")
        XCTAssertEqual(card.display, "flex")
        XCTAssertEqual(card.gap, "8px")
    }

    func testContrastPrefersExtensionSuppliedRatioOverLocalComputation() {
        var evidence = ForensicsFixtures.hoverCardExampleEvidence()
        // Give the extension's own (hypothetically more accurate,
        // composited-background-aware) figure priority over recomputing
        // from the two flat colour strings.
        evidence.accessibility = .init(contrastRatio: 99.0)
        let card = ForensicsCard.summarize(evidence)
        XCTAssertEqual(card.contrastRatio, 99.0)
    }

    func testMissingFieldsAreNilRatherThanFabricated() {
        let bare = ElementEvidence(
            url: "https://example.com",
            viewport: .init(width: 1440, height: 900, devicePixelRatio: 1, scrollX: 0, scrollY: 0),
            locator: .init(primary: "div"),
            rect: .init(x: 0, y: 0, width: 100, height: 20)
        )
        let card = ForensicsCard.summarize(bare)
        XCTAssertNil(card.fontFamily)
        XCTAssertNil(card.fontSizeAndWeightLabel)
        XCTAssertNil(card.textColor)
        XCTAssertNil(card.backgroundColor)
        XCTAssertNil(card.contrastRatio)
        XCTAssertNil(card.contrastLabel)
        XCTAssertNil(card.padding)
        // Geometry always has a value, since rect is required.
        XCTAssertEqual(card.dimensionsLabel, "100 × 20 px")
    }
}

final class ForensicsCardFullCardTests: XCTestCase {
    func testFullCardNeverFabricatesAnUnavailableCSSSource() {
        var evidence = ForensicsFixtures.hoverCardExampleEvidence()
        evidence.authoredSources = [
            .init(property: "color", computedValue: "#FFFFFF", sourceUnavailable: true)
        ]
        let full = ForensicsCard.fullCard(evidence)
        XCTAssertEqual(full.cssProvenance.count, 1)
        XCTAssertEqual(full.cssProvenance[0].provenanceLabel, "computed value known, source unavailable")
    }

    func testFullCardShowsAuthoredDeclarationWhenAvailable() {
        var evidence = ForensicsFixtures.hoverCardExampleEvidence()
        evidence.authoredSources = [
            .init(
                property: "color",
                computedValue: "#FFFFFF",
                authoredDeclaration: "color: #FFFFFF;",
                selector: ".product-form__submit",
                stylesheetURL: "https://example.com/theme.css",
                sourceUnavailable: false
            )
        ]
        let full = ForensicsCard.fullCard(evidence)
        XCTAssertEqual(full.cssProvenance[0].provenanceLabel, "color: #FFFFFF; — .product-form__submit")
    }

    func testFullCardDoesNotGuessAProvenanceWhenNeitherFlagNorDeclarationIsPresent() {
        var evidence = ForensicsFixtures.hoverCardExampleEvidence()
        // No authoredDeclaration, no explicit sourceUnavailable=true either
        // — still must not invent anything.
        evidence.authoredSources = [.init(property: "color", computedValue: "#FFFFFF")]
        let full = ForensicsCard.fullCard(evidence)
        XCTAssertEqual(full.cssProvenance[0].provenanceLabel, "computed value known, source unavailable")
    }

    func testFullCardIdentityPullsFromLocatorAndAccessibility() {
        let evidence = ForensicsFixtures.hoverCardExampleEvidence()
        let full = ForensicsCard.fullCard(evidence)
        XCTAssertEqual(full.identity.selector, "button.product-form__submit")
    }

    func testFullCardGeometryCarriesTheRawRectAndBoxModel() {
        let evidence = ForensicsFixtures.hoverCardExampleEvidence()
        let full = ForensicsCard.fullCard(evidence)
        XCTAssertEqual(full.geometry.rect.width, 328)
        XCTAssertEqual(full.geometry.rect.height, 48)
        XCTAssertEqual(full.geometry.padding?.top, 14)
        XCTAssertEqual(full.geometry.gap, "8px")
    }
}

final class EdgeInsetsCSSShorthandTests: XCTestCase {
    func testCollapsesToOneValueWhenAllSidesEqual() {
        XCTAssertEqual(EdgeInsets(top: 8, right: 8, bottom: 8, left: 8).cssShorthand(), "8px")
    }

    func testCollapsesToTwoValuesWhenVerticalAndHorizontalPairsMatch() {
        XCTAssertEqual(EdgeInsets(top: 14, right: 24, bottom: 14, left: 24).cssShorthand(), "14px 24px")
    }

    func testCollapsesToThreeValuesWhenOnlyLeftAndRightMatch() {
        XCTAssertEqual(EdgeInsets(top: 10, right: 20, bottom: 30, left: 20).cssShorthand(), "10px 20px 30px")
    }

    func testUsesAllFourValuesWhenNothingMatches() {
        XCTAssertEqual(EdgeInsets(top: 1, right: 2, bottom: 3, left: 4).cssShorthand(), "1px 2px 3px 4px")
    }
}
