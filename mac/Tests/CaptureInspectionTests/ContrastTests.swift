import XCTest
@testable import CaptureInspection

final class ContrastRatioTests: XCTestCase {
    func testBlackOnWhiteIsExactly21To1() throws {
        // The canonical WCAG reference value: pure black text on pure
        // white background is the maximum possible contrast, exactly
        // (1.0 + 0.05) / (0.0 + 0.05) = 21.
        let black = try ParsedColor(cssString: "#000000")
        let white = try ParsedColor(cssString: "#FFFFFF")
        XCTAssertEqual(Contrast.ratio(foreground: black, background: white), 21.0, accuracy: 0.0001)
    }

    func testContrastRatioIsSymmetric() throws {
        let black = try ParsedColor(cssString: "#000000")
        let white = try ParsedColor(cssString: "#FFFFFF")
        XCTAssertEqual(
            Contrast.ratio(foreground: black, background: white),
            Contrast.ratio(foreground: white, background: black),
            accuracy: 0.0001
        )
    }

    func testIdenticalColorsHaveRatioOfOne() throws {
        let gray = try ParsedColor(cssString: "#808080")
        XCTAssertEqual(Contrast.ratio(foreground: gray, background: gray), 1.0, accuracy: 0.0001)
    }

    func testKnownAABoundaryGrayOnWhiteIsApproximately4Point5To1() throws {
        // #767676 on white is a commonly-cited "just clears WCAG AA
        // (4.5:1) for normal text" reference gray.
        let gray = try ParsedColor(cssString: "#767676")
        let white = try ParsedColor(cssString: "#FFFFFF")
        let ratio = Contrast.ratio(foreground: gray, background: white)
        XCTAssertEqual(ratio, 4.54, accuracy: 0.15)
    }

    func testRatioIsMonotonicWithDarkness() throws {
        let white = try ParsedColor(cssString: "#FFFFFF")
        let lightGray = try ParsedColor(cssString: "#CCCCCC")
        let midGray = try ParsedColor(cssString: "#808080")
        let black = try ParsedColor(cssString: "#000000")

        let lightRatio = Contrast.ratio(foreground: lightGray, background: white)
        let midRatio = Contrast.ratio(foreground: midGray, background: white)
        let blackRatio = Contrast.ratio(foreground: black, background: white)

        XCTAssertLessThan(1.0, lightRatio)
        XCTAssertLessThan(lightRatio, midRatio)
        XCTAssertLessThan(midRatio, blackRatio)
        XCTAssertEqual(blackRatio, 21.0, accuracy: 0.0001)
    }
}

final class ContrastThresholdTests: XCTestCase {
    func testAANormalTextThresholdIsExactly4Point5() {
        XCTAssertTrue(Contrast.Result(ratio: 4.5).passesAANormalText)
        XCTAssertFalse(Contrast.Result(ratio: 4.49).passesAANormalText)
    }

    func testAALargeTextThresholdIsExactly3() {
        XCTAssertTrue(Contrast.Result(ratio: 3.0).passesAALargeText)
        XCTAssertFalse(Contrast.Result(ratio: 2.99).passesAALargeText)
    }

    func testAAANormalTextThresholdIsExactly7() {
        XCTAssertTrue(Contrast.Result(ratio: 7.0).passesAAANormalText)
        XCTAssertFalse(Contrast.Result(ratio: 6.99).passesAAANormalText)
    }

    func testAAALargeTextThresholdIsExactly4Point5() {
        XCTAssertTrue(Contrast.Result(ratio: 4.5).passesAAALargeText)
        XCTAssertFalse(Contrast.Result(ratio: 4.49).passesAAALargeText)
    }

    func testFormattedRatioMatchesTheHoverCardExample() {
        // The spec digest's exact hover-card example: "Contrast 18.9:1".
        XCTAssertEqual(Contrast.Result(ratio: 18.9).formattedRatio, "18.9:1")
    }

    func testEvaluateProducesAllFourFlagsFromTwoColors() throws {
        let black = try ParsedColor(cssString: "#000000")
        let white = try ParsedColor(cssString: "#FFFFFF")
        let result = Contrast.evaluate(foreground: black, background: white)
        XCTAssertTrue(result.passesAANormalText)
        XCTAssertTrue(result.passesAALargeText)
        XCTAssertTrue(result.passesAAANormalText)
        XCTAssertTrue(result.passesAAALargeText)
    }
}

final class ColorParsingTests: XCTestCase {
    func testParsesSixDigitHex() throws {
        let color = try ParsedColor(cssString: "#111111")
        XCTAssertEqual(color.red, 0x11.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(color.alpha, 1)
    }

    func testParsesThreeDigitShorthandHex() throws {
        let color = try ParsedColor(cssString: "#FFF")
        XCTAssertEqual(color.red, 1, accuracy: 0.0001)
        XCTAssertEqual(color.green, 1, accuracy: 0.0001)
        XCTAssertEqual(color.blue, 1, accuracy: 0.0001)
    }

    func testParsesEightDigitHexWithAlpha() throws {
        let color = try ParsedColor(cssString: "#00000080")
        XCTAssertEqual(color.alpha, 0x80.0 / 255, accuracy: 0.01)
    }

    func testParsesRgbFunctionalForm() throws {
        let color = try ParsedColor(cssString: "rgb(255, 255, 255)")
        XCTAssertEqual(color.red, 1)
        XCTAssertEqual(color.green, 1)
        XCTAssertEqual(color.blue, 1)
    }

    func testParsesRgbaFunctionalFormWithSpaces() throws {
        let color = try ParsedColor(cssString: "rgba(17 17 17 / 0.5)")
        XCTAssertEqual(color.red, 17.0 / 255, accuracy: 0.001)
        XCTAssertEqual(color.alpha, 0.5, accuracy: 0.001)
    }

    func testParsesPercentageComponents() throws {
        let color = try ParsedColor(cssString: "rgb(50%, 50%, 50%)")
        XCTAssertEqual(color.red, 0.5, accuracy: 0.001)
    }

    func testUnrecognizedFormatThrows() {
        XCTAssertThrowsError(try ParsedColor(cssString: "not-a-color")) { error in
            XCTAssertEqual(error as? ColorParsingError, .unrecognizedFormat("not-a-color"))
        }
    }

    func testMalformedHexThrows() {
        XCTAssertThrowsError(try ParsedColor(cssString: "#ZZZZZZ"))
    }
}
