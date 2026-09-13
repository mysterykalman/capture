@testable import CaptureEditor
import CoreGraphics
import XCTest

final class ArrowGeometryTests: XCTestCase {
    func testTriangleHeadApexIsTheTipPoint() {
        let head = ArrowGeometry.triangleHead(from: CGPoint(x: 0, y: 0), tip: CGPoint(x: 100, y: 0), length: 20, width: 10)
        XCTAssertEqual(head.apex, CGPoint(x: 100, y: 0))
    }

    func testTriangleHeadBaseIsPerpendicularToShaftDirection() {
        // Horizontal shaft -> base points should be directly above/below
        // the base centre point (perpendicular = vertical).
        let head = ArrowGeometry.triangleHead(from: CGPoint(x: 0, y: 0), tip: CGPoint(x: 100, y: 0), length: 20, width: 10)
        let baseCentreX = 100 - 20.0
        XCTAssertEqual(head.left.x, baseCentreX, accuracy: 0.0001)
        XCTAssertEqual(head.right.x, baseCentreX, accuracy: 0.0001)
        XCTAssertEqual(head.left.y, 5, accuracy: 0.0001)
        XCTAssertEqual(head.right.y, -5, accuracy: 0.0001)
    }

    func testTriangleHeadBaseWidthMatchesRequestedWidth() {
        let head = ArrowGeometry.triangleHead(from: CGPoint(x: 0, y: 0), tip: CGPoint(x: 0, y: 100), length: 15, width: 8)
        let baseWidth = hypot(head.left.x - head.right.x, head.left.y - head.right.y)
        XCTAssertEqual(baseWidth, 8, accuracy: 0.0001)
    }

    func testShaftEndSitsHeadLengthBeforeTip() {
        let shaftEnd = ArrowGeometry.shaftEnd(from: CGPoint(x: 0, y: 0), tip: CGPoint(x: 0, y: 100), headLength: 12)
        // Note: `CGPoint` isn't `Numeric`, so `XCTAssertEqual(_:_:accuracy:)`
        // doesn't apply to it directly — compare components instead.
        XCTAssertEqual(shaftEnd.x, 0, accuracy: 0.0001)
        XCTAssertEqual(shaftEnd.y, 88, accuracy: 0.0001)
    }

    func testCurveControlPointSitsAtMidpointWhenBowIsZero() {
        let control = ArrowGeometry.curveControlPoint(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), bow: 0)
        XCTAssertEqual(control.x, 50, accuracy: 0.0001)
        XCTAssertEqual(control.y, 0, accuracy: 0.0001)
    }

    func testCurveControlPointOffsetsPerpendicularToTheChord() {
        let control = ArrowGeometry.curveControlPoint(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), bow: 20)
        // Perpendicular to a horizontal chord is vertical.
        XCTAssertEqual(control.x, 50, accuracy: 0.0001)
        XCTAssertEqual(abs(control.y), 20, accuracy: 0.0001)
    }

    func testRecommendedHeadSizeScalesWithThicknessAndClamps() {
        let thin = ArrowGeometry.recommendedHeadSize(forThickness: 1)
        let thick = ArrowGeometry.recommendedHeadSize(forThickness: 100)
        XCTAssertGreaterThanOrEqual(thin.length, 10) // clamped floor
        XCTAssertLessThanOrEqual(thick.length, 42) // clamped ceiling
        XCTAssertGreaterThan(thick.length, thin.length)
    }

    func testElbowCornerHorizontalFirst() {
        let corner = ArrowGeometry.elbowCorner(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 50), bendRatio: 0.5, horizontalFirst: true)
        XCTAssertEqual(corner, CGPoint(x: 50, y: 0))
    }

    func testElbowCornerVerticalFirst() {
        let corner = ArrowGeometry.elbowCorner(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 50), bendRatio: 0.5, horizontalFirst: false)
        XCTAssertEqual(corner, CGPoint(x: 0, y: 25))
    }
}
