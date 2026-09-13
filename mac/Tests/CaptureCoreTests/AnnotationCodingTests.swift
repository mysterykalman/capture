import XCTest
@testable import CaptureCore

final class AnnotationCodingTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        let annotation = Annotation(
            type: .counter,
            frame: CaptureRect(x: 10, y: 20, width: 30, height: 30),
            zIndex: 2,
            style: .object(["colour": .string("#4D6BFF")]),
            typeData: .object(["startNumber": .number(1), "format": .string("numeric")]),
            anchor: Annotation.Anchor(kind: .domElement, elementEvidenceId: UUID(), relativeAnchor: CapturePoint(x: 0.5, y: 0.5))
        )
        let data = try CaptureCoreJSON.encoder.encode(annotation)
        let decoded = try CaptureCoreJSON.decoder.decode(Annotation.self, from: data)
        XCTAssertEqual(decoded.id, annotation.id)
        XCTAssertEqual(decoded.type, .counter)
        XCTAssertEqual(decoded.anchor.kind, .domElement)
        XCTAssertEqual(decoded.style?["colour"]?.stringValue, "#4D6BFF")
    }

    func testAnchorDefaultsToCanvas() {
        let annotation = Annotation(type: .arrow, frame: .zero, zIndex: 0)
        XCTAssertEqual(annotation.anchor.kind, .canvas)
    }
}

final class ElementEvidenceLocatorTests: XCTestCase {
    func testRankedCandidatesPrefersDataAttributeOverAbsolutePath() {
        let locator = ElementEvidence.Locator(
            primary: "//div/button",
            candidates: [
                .init(strategy: .absolutePath, value: "//div/button", confidence: 0.9),
                .init(strategy: .dataAttribute, value: "[data-testid=submit]", confidence: 0.5)
            ]
        )
        XCTAssertEqual(locator.rankedCandidates.first?.strategy, .dataAttribute)
    }

    func testHigherConfidenceWinsWithinSameStrategy() {
        let locator = ElementEvidence.Locator(
            primary: "x",
            candidates: [
                .init(strategy: .classStructure, value: "a", confidence: 0.4),
                .init(strategy: .classStructure, value: "b", confidence: 0.8)
            ]
        )
        XCTAssertEqual(locator.rankedCandidates.first?.value, "b")
    }
}

final class AnchorResolutionTests: XCTestCase {
    func testLowConfidenceIsNotTrustworthy() {
        let resolution = AnchorResolution(resolved: true, confidence: 0.4, rect: .zero)
        XCTAssertFalse(resolution.isTrustworthy)
    }

    func testHighConfidenceWithRectIsTrustworthy() {
        let resolution = AnchorResolution(resolved: true, confidence: 0.9, rect: .zero)
        XCTAssertTrue(resolution.isTrustworthy)
    }
}

final class AuditFindingIdGeneratorTests: XCTestCase {
    func testGeneratesSequentialIds() {
        let generator = AuditFindingIdGenerator()
        XCTAssertEqual(generator.nextId(category: .pdp, existingCount: 0), "PDP-01")
        XCTAssertEqual(generator.nextId(category: .pdp, existingCount: 6), "PDP-07")
        XCTAssertEqual(generator.nextId(category: .navigation, existingCount: 0), "NAV-01")
    }
}
