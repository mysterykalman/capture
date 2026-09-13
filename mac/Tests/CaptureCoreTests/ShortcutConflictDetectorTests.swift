import XCTest
@testable import CaptureCore

final class ShortcutConflictDetectorTests: XCTestCase {
    func testDetectsConflictWithAnotherCaptureAction() {
        let detector = ShortcutConflictDetector()
        let binding = ShortcutBinding(keyCode: 21, modifiers: [.command, .shift]) // arbitrary
        let existing: [ShortcutAction: ShortcutBinding] = [.captureWindow: binding]
        let result = detector.conflicts(assigning: binding, to: .captureArea, existing: existing, systemShortcuts: SystemShortcutRegistry())
        guard case .anotherCaptureAction(let action) = result else { return XCTFail("expected a Capture-action conflict") }
        XCTAssertEqual(action, .captureWindow)
    }

    func testDetectsConflictWithSystemShortcut() {
        let detector = ShortcutConflictDetector()
        let binding = ShortcutBinding(keyCode: 21, modifiers: [.command, .shift])
        let registry = SystemShortcutRegistry(knownShortcuts: [
            .init(binding: binding, systemDescription: "macOS Screenshot (Shift-Command-4)")
        ])
        let result = detector.conflicts(assigning: binding, to: .captureArea, existing: [:], systemShortcuts: registry)
        guard case .systemShortcut(let description) = result else { return XCTFail("expected a system conflict") }
        XCTAssertTrue(description.contains("Screenshot"))
    }

    func testNoConflictWhenReassigningSameAction() {
        let detector = ShortcutConflictDetector()
        let binding = ShortcutBinding(keyCode: 21, modifiers: [.command])
        let existing: [ShortcutAction: ShortcutBinding] = [.captureArea: binding]
        let result = detector.conflicts(assigning: binding, to: .captureArea, existing: existing, systemShortcuts: SystemShortcutRegistry())
        XCTAssertNil(result)
    }
}

final class BookmarksBarDetectionResultTests: XCTestCase {
    func testLowConfidenceDoesNotAutoApply() {
        let result = BookmarksBarDetectionResult(source: .extensionGeometry, rect: .zero, confidence: 0.3)
        XCTAssertFalse(result.shouldAutoApply)
    }

    func testNoDetectorSourceNeverAutoApplies() {
        let result = BookmarksBarDetectionResult(source: .none, rect: .zero, confidence: 0.99)
        XCTAssertFalse(result.shouldAutoApply, "source .none must never auto-apply regardless of confidence")
    }

    func testHighConfidenceAccessibilityAutoApplies() {
        let result = BookmarksBarDetectionResult(source: .accessibility, rect: CaptureRect(x: 0, y: 0, width: 800, height: 28), confidence: 0.95)
        XCTAssertTrue(result.shouldAutoApply)
    }
}
