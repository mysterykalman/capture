import CaptureCore
@testable import CaptureEditor
import CoreGraphics
import XCTest

final class AnnotationStyleDecodingTests: XCTestCase {
    // MARK: - Hex colour parsing

    func testParsesSixDigitHex() {
        let colour = CGColor.capture_parse(hex: "#FF0000")
        XCTAssertNotNil(colour)
        XCTAssertEqual(colour?.components?[0], 1, accuracy: 0.001)
        XCTAssertEqual(colour?.components?[1], 0, accuracy: 0.001)
        XCTAssertEqual(colour?.components?[2], 0, accuracy: 0.001)
    }

    func testParsesEightDigitHexWithAlpha() {
        let colour = CGColor.capture_parse(hex: "#00FF0080")
        XCTAssertNotNil(colour)
        XCTAssertEqual(colour?.alpha ?? 0, 128.0 / 255.0, accuracy: 0.01)
    }

    func testParsesThreeDigitShorthand() {
        let shorthand = CGColor.capture_parse(hex: "#F00")
        let full = CGColor.capture_parse(hex: "#FF0000")
        XCTAssertEqual(shorthand?.components?[0], full?.components?[0], accuracy: 0.001)
        XCTAssertEqual(shorthand?.components?[1], full?.components?[1], accuracy: 0.001)
        XCTAssertEqual(shorthand?.components?[2], full?.components?[2], accuracy: 0.001)
    }

    func testParsesWithoutLeadingHash() {
        XCTAssertNotNil(CGColor.capture_parse(hex: "00FF00"))
    }

    func testRejectsInvalidHex() {
        XCTAssertNil(CGColor.capture_parse(hex: "not-a-colour"))
        XCTAssertNil(CGColor.capture_parse(hex: "#12345")) // 5 digits, invalid length
        XCTAssertNil(CGColor.capture_parse(hex: nil))
    }

    // MARK: - StyleReader defaults

    func testStyleReaderFallsBackToDefaultsWhenStyleIsNil() {
        let reader = StyleReader(style: nil, typeData: nil)
        XCTAssertEqual(reader.thickness, 4)
        XCTAssertEqual(reader.lineDashStyle, .solid)
        XCTAssertFalse(reader.isHandDrawn)
        XCTAssertNil(reader.fillColour)
    }

    func testStyleReaderReadsPresentValues() {
        let style: JSONValue = .object([
            AnnotationStyleKeys.colour: .string("#112233"),
            AnnotationStyleKeys.thickness: .number(6),
            AnnotationStyleKeys.lineStyle: .string("dashed"),
            AnnotationStyleKeys.handDrawn: .bool(true)
        ])
        let reader = StyleReader(style: style, typeData: nil)
        XCTAssertEqual(reader.thickness, 6)
        XCTAssertEqual(reader.lineDashStyle, .dashed)
        XCTAssertTrue(reader.isHandDrawn)
    }

    func testStyleReaderExplicitPointsRoundTrip() {
        let style: JSONValue = .object([
            AnnotationStyleKeys.points: .array([
                .object(["x": .number(1), "y": .number(2)]),
                .object(["x": .number(3), "y": .number(4)])
            ])
        ])
        let reader = StyleReader(style: style, typeData: nil)
        XCTAssertEqual(reader.explicitPoints?.count, 2)
        XCTAssertEqual(reader.explicitPoints?[0], CGPoint(x: 1, y: 2))
        XCTAssertEqual(reader.explicitPoints?[1], CGPoint(x: 3, y: 4))
    }

    func testStyleReaderTypeDataAccessors() {
        let typeData: JSONValue = .object([
            AnnotationStyleKeys.counterFormat: .string("roman"),
            AnnotationStyleKeys.counterStartNumber: .number(3),
            AnnotationStyleKeys.redactionMode: .string(RedactionMode.secureRandomizedPixelation.rawValue)
        ])
        let reader = StyleReader(style: nil, typeData: typeData)
        XCTAssertEqual(reader.typeDataString(AnnotationStyleKeys.counterFormat), "roman")
        XCTAssertEqual(reader.typeDataInt(AnnotationStyleKeys.counterStartNumber, default: 1), 3)
        XCTAssertEqual(reader.typeDataString(AnnotationStyleKeys.redactionMode), RedactionMode.secureRandomizedPixelation.rawValue)
    }

    // MARK: - LineDashStyle

    func testDashPatternsAreNilOnlyForSolid() {
        XCTAssertNil(LineDashStyle.solid.dashPattern(forThickness: 4))
        XCTAssertNotNil(LineDashStyle.dashed.dashPattern(forThickness: 4))
        XCTAssertNotNil(LineDashStyle.dotted.dashPattern(forThickness: 4))
    }

    func testDottedStyleUsesRoundCap() {
        XCTAssertEqual(LineDashStyle.dotted.lineCap, .round)
        XCTAssertEqual(LineDashStyle.solid.lineCap, .butt)
    }

    func testUnknownLineStyleStringFallsBackToSolid() {
        XCTAssertEqual(LineDashStyle(rawValue: "squiggly"), .solid)
    }
}
