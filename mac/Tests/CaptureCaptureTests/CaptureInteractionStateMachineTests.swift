import XCTest
import CaptureCore
@testable import CaptureCapture

/// Exercises `CaptureInteractionReducer` directly — no AppKit/live windows
/// involved, matching the task's "structure the code so the parts that
/// need real OS state are thin wrappers around the pure logic you can
/// test" instruction.
final class CaptureInteractionStateMachineTests: XCTestCase {
    // MARK: Area flow

    func testAreaDragCommitsOnMouseUp() {
        var state = CaptureInteractionState.idle
        state = CaptureInteractionReducer.reduce(state, .shortcutTriggered(mode: .area))
        XCTAssertEqual(state, .ready(.area))

        state = CaptureInteractionReducer.reduce(state, .dragBegan(at: CapturePoint(x: 10, y: 10)))
        guard case .areaDragging(let origin, let current) = state else { return XCTFail("expected areaDragging") }
        XCTAssertEqual(origin, CapturePoint(x: 10, y: 10))
        XCTAssertEqual(current, CapturePoint(x: 10, y: 10))

        state = CaptureInteractionReducer.reduce(state, .dragChanged(to: CapturePoint(x: 110, y: 60)))
        guard case .areaDragging(_, let current2) = state else { return XCTFail("expected areaDragging") }
        XCTAssertEqual(current2, CapturePoint(x: 110, y: 60))

        state = CaptureInteractionReducer.reduce(state, .dragEnded(at: CapturePoint(x: 110, y: 60)))
        guard case .captured(.area(let rect)) = state else { return XCTFail("expected captured(.area)") }
        XCTAssertEqual(rect, CaptureRect(x: 10, y: 10, width: 100, height: 50))
    }

    func testAreaDragNormalizesRectRegardlessOfDragDirection() {
        // Dragging from bottom-right up to top-left should still produce a
        // positive-width/height rect with the correct origin.
        var state = CaptureInteractionState.ready(.area)
        state = CaptureInteractionReducer.reduce(state, .dragBegan(at: CapturePoint(x: 200, y: 200)))
        state = CaptureInteractionReducer.reduce(state, .dragEnded(at: CapturePoint(x: 50, y: 100)))
        guard case .captured(.area(let rect)) = state else { return XCTFail("expected captured(.area)") }
        XCTAssertEqual(rect, CaptureRect(x: 50, y: 100, width: 150, height: 100))
    }

    // MARK: Space toggling (the "Mac-Like Area-to-Window" requirement)

    func testSpaceMidDragTogglesToWindowModeAndDiscardsDrag() {
        var state = CaptureInteractionState.ready(.area)
        state = CaptureInteractionReducer.reduce(state, .dragBegan(at: CapturePoint(x: 0, y: 0)))
        state = CaptureInteractionReducer.reduce(state, .dragChanged(to: CapturePoint(x: 40, y: 40)))
        state = CaptureInteractionReducer.reduce(state, .spaceKeyPressed)
        XCTAssertEqual(state, .ready(.window), "Space mid-drag must toggle to window mode")
    }

    func testSpaceTogglesBackToAreaModeFromReady() {
        var state = CaptureInteractionState.ready(.window)
        state = CaptureInteractionReducer.reduce(state, .spaceKeyPressed)
        XCTAssertEqual(state, .ready(.area))
    }

    func testSpaceTogglesBackToAreaModeFromWindowHovering() {
        var state = CaptureInteractionState.ready(.window)
        state = CaptureInteractionReducer.reduce(state, .pointerMoved(hoveredWindow: 42))
        XCTAssertEqual(state, .windowHovering(windowID: 42))
        state = CaptureInteractionReducer.reduce(state, .spaceKeyPressed)
        XCTAssertEqual(state, .ready(.area), "pressing Space again must toggle back to Area mode")
    }

    func testDoubleSpaceTogglesBackToAreaFromInitialCrosshair() {
        // Space should also be honored before any drag has started.
        var state = CaptureInteractionState.ready(.area)
        state = CaptureInteractionReducer.reduce(state, .spaceKeyPressed)
        XCTAssertEqual(state, .ready(.window))
        state = CaptureInteractionReducer.reduce(state, .spaceKeyPressed)
        XCTAssertEqual(state, .ready(.area))
    }

    // MARK: Window hover + click, with/without shadow modifier

    func testWindowHoverUpdatesOnEachPointerMove() {
        var state = CaptureInteractionState.ready(.window)
        state = CaptureInteractionReducer.reduce(state, .pointerMoved(hoveredWindow: 7))
        XCTAssertEqual(state, .windowHovering(windowID: 7))
        state = CaptureInteractionReducer.reduce(state, .pointerMoved(hoveredWindow: 9))
        XCTAssertEqual(state, .windowHovering(windowID: 9))
        state = CaptureInteractionReducer.reduce(state, .pointerMoved(hoveredWindow: nil))
        XCTAssertEqual(state, .windowHovering(windowID: nil), "hovering the desktop clears the highlighted window")
    }

    func testPlainClickCapturesWindowWithShadow() {
        var state = CaptureInteractionState.windowHovering(windowID: 55)
        state = CaptureInteractionReducer.reduce(state, .windowClicked(windowID: 55, modifiers: []))
        guard case .captured(.window(let windowID, let withoutShadow)) = state else { return XCTFail("expected captured(.window)") }
        XCTAssertEqual(windowID, 55)
        XCTAssertFalse(withoutShadow)
    }

    func testOptionClickCapturesWindowWithoutShadow() {
        var state = CaptureInteractionState.windowHovering(windowID: 55)
        state = CaptureInteractionReducer.reduce(state, .windowClicked(windowID: 55, modifiers: [.option]))
        guard case .captured(.window(_, let withoutShadow)) = state else { return XCTFail("expected captured(.window)") }
        XCTAssertTrue(withoutShadow)
    }

    func testConfiguredShadowlessModifierIsRespected() {
        // A user could remap the "without shadow" modifier away from
        // Option; the reducer must honor whatever is configured, not a
        // hardcoded Option check.
        var state = CaptureInteractionState.windowHovering(windowID: 1)
        state = CaptureInteractionReducer.reduce(state, .windowClicked(windowID: 1, modifiers: [.control]), shadowlessModifier: .control)
        guard case .captured(.window(_, let withoutShadow)) = state else { return XCTFail("expected captured(.window)") }
        XCTAssertTrue(withoutShadow)
    }

    // MARK: Escape cancels from anywhere

    func testEscapeCancelsFromReadyArea() {
        let state = CaptureInteractionReducer.reduce(.ready(.area), .escapeKeyPressed)
        XCTAssertEqual(state, .cancelled)
    }

    func testEscapeCancelsMidAreaDrag() {
        var state = CaptureInteractionState.ready(.area)
        state = CaptureInteractionReducer.reduce(state, .dragBegan(at: .zero))
        state = CaptureInteractionReducer.reduce(state, .escapeKeyPressed)
        XCTAssertEqual(state, .cancelled)
    }

    func testEscapeCancelsWhileWindowHovering() {
        var state = CaptureInteractionState.ready(.window)
        state = CaptureInteractionReducer.reduce(state, .pointerMoved(hoveredWindow: 3))
        state = CaptureInteractionReducer.reduce(state, .escapeKeyPressed)
        XCTAssertEqual(state, .cancelled)
    }

    func testEscapeIsANoOpOnceAlreadyTerminal() {
        // Terminal states should not transition further, guarding against
        // a stray extra key event racing the overlay's teardown.
        let captured = CaptureInteractionState.captured(.area(rect: .zero))
        XCTAssertEqual(CaptureInteractionReducer.reduce(captured, .escapeKeyPressed), captured)
        XCTAssertEqual(CaptureInteractionReducer.reduce(.cancelled, .escapeKeyPressed), .cancelled)
    }

    // MARK: Defensive: unmatched events are ignored, not crashes

    func testUnrelatedEventInIdleStateIsIgnored() {
        let state = CaptureInteractionReducer.reduce(.idle, .dragChanged(to: .zero))
        XCTAssertEqual(state, .idle)
    }

    func testStrayDragEventAfterCaptureIsIgnored() {
        let captured = CaptureInteractionState.captured(.window(windowID: 1, withoutShadow: false))
        let state = CaptureInteractionReducer.reduce(captured, .dragChanged(to: CapturePoint(x: 1, y: 1)))
        XCTAssertEqual(state, captured)
    }
}
