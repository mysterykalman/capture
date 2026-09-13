import XCTest
@testable import CaptureCore

final class SnapEngineTests: XCTestCase {
    func testSnapsWithinTolerance() {
        let engine = SnapEngine()
        let target = CaptureRect(x: 100, y: 100, width: 200, height: 150)
        let candidates = SnapEngine.lines(for: target, category: .edges)
        let moving = CaptureRect(x: 104, y: 250, width: 50, height: 50) // 4pt off target's left edge
        let result = engine.snap(moving: moving, candidates: candidates, settings: .default)
        XCTAssertEqual(result.rect.x, 100, accuracy: 0.001)
        XCTAssertFalse(result.activeGuides.isEmpty)
    }

    func testDoesNotSnapBeyondTolerance() {
        let engine = SnapEngine()
        let target = CaptureRect(x: 100, y: 100, width: 200, height: 150)
        let candidates = SnapEngine.lines(for: target, category: .edges)
        let moving = CaptureRect(x: 140, y: 250, width: 50, height: 50) // 40pt away
        let settings = SnapSettings(tolerancePoints: 8)
        let result = engine.snap(moving: moving, candidates: candidates, settings: settings)
        XCTAssertEqual(result.rect.x, 140, accuracy: 0.001)
    }

    func testDisabledCategoryIsIgnored() {
        let engine = SnapEngine()
        let target = CaptureRect(x: 100, y: 100, width: 200, height: 150)
        let candidates = SnapEngine.lines(for: target, category: .domElements)
        let moving = CaptureRect(x: 102, y: 250, width: 50, height: 50)
        var settings = SnapSettings.default
        settings.enabledCategories = [SnapCategory.edges.rawValue]
        let result = engine.snap(moving: moving, candidates: candidates, settings: settings)
        XCTAssertEqual(result.rect.x, 102, accuracy: 0.001, "domElements category is disabled, should not snap")
    }

    func testGridSnapping() {
        let engine = SnapEngine()
        let rect = CaptureRect(x: 13, y: 22, width: 100, height: 100)
        let snapped = engine.snappedToGrid(rect, increment: 8)
        XCTAssertEqual(snapped.x, 16, accuracy: 0.001)
        XCTAssertEqual(snapped.y, 24, accuracy: 0.001)
    }
}
