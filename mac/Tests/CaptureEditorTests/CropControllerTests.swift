import CaptureCore
@testable import CaptureEditor
import XCTest

final class CropControllerTests: XCTestCase {
    private let sourceSize = CaptureSize(width: 1000, height: 800)
    private lazy var controller = CropController(sourceSize: sourceSize)

    // MARK: - Reset / clamp

    func testResetToSourceCoversTheWholeImage() {
        let rect = controller.resetToSource()
        XCTAssertEqual(rect, CaptureRect(x: 0, y: 0, width: 1000, height: 800))
    }

    func testClampToSourceKeepsRectWithinBounds() {
        let outOfBounds = CaptureRect(x: -50, y: -20, width: 2000, height: 2000)
        let clamped = controller.clampToSource(outOfBounds)
        XCTAssertGreaterThanOrEqual(clamped.minX, 0)
        XCTAssertGreaterThanOrEqual(clamped.minY, 0)
        XCTAssertLessThanOrEqual(clamped.maxX, sourceSize.width)
        XCTAssertLessThanOrEqual(clamped.maxY, sourceSize.height)
    }

    // MARK: - Free resize (no aspect lock)

    func testBottomRightHandleFreeResizeDoesNotMoveOrigin() {
        let rect = CaptureRect(x: 100, y: 100, width: 200, height: 150)
        let resized = controller.resize(rect, handle: .bottomRight, to: CGPoint(x: 400, y: 350))
        XCTAssertEqual(resized, CaptureRect(x: 100, y: 100, width: 300, height: 250))
    }

    func testTopLeftHandleFreeResizeMovesOriginKeepsOppositeCornerFixed() {
        let rect = CaptureRect(x: 100, y: 100, width: 200, height: 150)
        let resized = controller.resize(rect, handle: .topLeft, to: CGPoint(x: 50, y: 60))
        // Opposite corner (bottom-right) stays at (300, 250).
        XCTAssertEqual(resized.maxX, 300, accuracy: 0.001)
        XCTAssertEqual(resized.maxY, 250, accuracy: 0.001)
        XCTAssertEqual(resized.minX, 50, accuracy: 0.001)
        XCTAssertEqual(resized.minY, 60, accuracy: 0.001)
    }

    // MARK: - Aspect-locked resize

    func testAspectLockedCornerResizeMatchesTargetRatio() {
        let rect = CaptureRect(x: 0, y: 0, width: 200, height: 200)
        let resized = controller.resize(rect, handle: .bottomRight, to: CGPoint(x: 400, y: 100), aspectRatio: .sixteenByNine)
        let ratio = resized.width / resized.height
        XCTAssertEqual(ratio, 16.0 / 9.0, accuracy: 0.001)
        // Opposite corner (top-left) unaffected by aspect correction.
        XCTAssertEqual(resized.minX, 0, accuracy: 0.001)
        XCTAssertEqual(resized.minY, 0, accuracy: 0.001)
    }

    func testAspectLockedEdgeHandleKeepsHorizontalCentreFixed() {
        let rect = CaptureRect(x: 100, y: 100, width: 200, height: 200)
        // Drag the bottom edge down; width must grow to match 1:1 ratio,
        // centred horizontally, with the top edge staying put.
        let resized = controller.resize(rect, handle: .bottom, to: CGPoint(x: 200, y: 500), aspectRatio: .square)
        XCTAssertEqual(resized.height, 400, accuracy: 0.001)
        XCTAssertEqual(resized.width, 400, accuracy: 0.001)
        XCTAssertEqual(resized.minY, 100, accuracy: 0.001) // top edge fixed
        XCTAssertEqual(resized.midX, rect.midX, accuracy: 0.001) // horizontally centred
    }

    // MARK: - Centre resize

    func testCentreResizeGrowsSymmetricallyAboutCentre() {
        let rect = CaptureRect(x: 400, y: 300, width: 100, height: 100) // centre (450, 350)
        let resized = controller.resize(rect, handle: .bottomRight, to: CGPoint(x: 600, y: 500), fromCentre: true)
        XCTAssertEqual(resized.midX, rect.midX, accuracy: 0.001)
        XCTAssertEqual(resized.midY, rect.midY, accuracy: 0.001)
        // bottomRight moved by (+200, +200); centre-resize mirrors that on
        // the opposite edge too, doubling the total size change.
        XCTAssertEqual(resized.width, 300, accuracy: 0.001)
        XCTAssertEqual(resized.height, 300, accuracy: 0.001)
    }

    func testCentreResizeExactDimensions() {
        let rect = CaptureRect(x: 400, y: 300, width: 100, height: 100)
        let resized = controller.centreResize(rect, width: 300, height: 200)
        XCTAssertEqual(resized.midX, rect.midX, accuracy: 0.001)
        XCTAssertEqual(resized.midY, rect.midY, accuracy: 0.001)
        XCTAssertEqual(resized.width, 300, accuracy: 0.001)
        XCTAssertEqual(resized.height, 200, accuracy: 0.001)
    }

    // MARK: - Exact dimensions (numeric entry)

    func testExactDimensionsKeepsTopLeftAnchorByDefault() {
        let rect = CaptureRect(x: 50, y: 50, width: 100, height: 100)
        let resized = controller.exactDimensions(rect, width: 300, height: 40)
        XCTAssertEqual(resized.minX, 50, accuracy: 0.001)
        XCTAssertEqual(resized.minY, 50, accuracy: 0.001)
        XCTAssertEqual(resized.width, 300, accuracy: 0.001)
        XCTAssertEqual(resized.height, 40, accuracy: 0.001)
    }

    func testExactDimensionsClampsToSource() {
        let rect = CaptureRect(x: 900, y: 700, width: 50, height: 50)
        let resized = controller.exactDimensions(rect, width: 500, height: 500)
        XCTAssertLessThanOrEqual(resized.maxX, sourceSize.width)
        XCTAssertLessThanOrEqual(resized.maxY, sourceSize.height)
    }

    // MARK: - Keyboard nudge

    func testNudgeMovesWholeRectBySmallAmount() {
        let rect = CaptureRect(x: 100, y: 100, width: 50, height: 50)
        let nudged = controller.nudge(rect, dx: CropController.KeyboardNudge.small, dy: 0)
        XCTAssertEqual(nudged.x, 101, accuracy: 0.001)
        XCTAssertEqual(nudged.width, 50, accuracy: 0.001) // move, not resize
    }

    func testNudgeMovesByLargeAmountWithShift() {
        let rect = CaptureRect(x: 100, y: 100, width: 50, height: 50)
        let nudged = controller.nudge(rect, dx: 0, dy: CropController.KeyboardNudge.large)
        XCTAssertEqual(nudged.y, 110, accuracy: 0.001)
    }

    func testNudgeHandleResizesBySmallAmount() {
        let rect = CaptureRect(x: 100, y: 100, width: 50, height: 50)
        let nudged = controller.nudgeHandle(rect, handle: .bottomRight, dx: CropController.KeyboardNudge.small, dy: CropController.KeyboardNudge.small)
        XCTAssertEqual(nudged.width, 51, accuracy: 0.001)
        XCTAssertEqual(nudged.height, 51, accuracy: 0.001)
    }

    func testNudgeDoesNotCrossSourceBounds() {
        let rect = CaptureRect(x: 0, y: 0, width: 50, height: 50)
        let nudged = controller.nudge(rect, dx: -100, dy: -100)
        XCTAssertEqual(nudged.minX, 0, accuracy: 0.001)
        XCTAssertEqual(nudged.minY, 0, accuracy: 0.001)
    }

    // MARK: - Snap-engine integration

    func testSnappedResizeSnapsToSourceEdge() {
        let rect = CaptureRect(x: 100, y: 100, width: 200, height: 200)
        // Drag the right handle to x=997 — within default tolerance of the
        // source's own right edge at x=1000.
        let result = controller.snappedResize(rect, handle: .right, to: CGPoint(x: 997, y: 200), candidateRects: [])
        XCTAssertEqual(result.rect.maxX, 1000, accuracy: 0.001)
        XCTAssertFalse(result.activeGuides.isEmpty)
    }

    func testSnappedResizeSnapsToCandidateRectEdge() {
        let rect = CaptureRect(x: 0, y: 0, width: 100, height: 100)
        let domElement = CaptureRect(x: 305, y: 0, width: 50, height: 50)
        let result = controller.snappedResize(rect, handle: .right, to: CGPoint(x: 303, y: 50), candidateRects: [domElement])
        XCTAssertEqual(result.rect.maxX, 305, accuracy: 0.001)
    }
}
