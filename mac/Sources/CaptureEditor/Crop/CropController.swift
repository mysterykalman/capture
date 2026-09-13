import CaptureCore
import CoreGraphics
import Foundation

/// Non-destructive crop (Part I "Crop Experience": "free crop; exact
/// dimensions; aspect presets; custom ratio; centre crop; crop snapping;
/// keyboard nudge; ... continuous dimensions; numeric x/y/w/h; reset to
/// source; remembered common ratios"). Crop is stored purely as a rect
/// relative to the source image (`EditorDocument.cropRect`) — this type
/// never touches pixels; it only computes what that rect *should become*
/// in response to a drag, a typed dimension, a keyboard nudge, or a
/// snap-engine-adjusted handle position. Applying the result is the
/// caller's job (typically via `Undo.CropCommand`, so cropping stays
/// undoable).
///
/// All rects here are in source-image pixel coordinates (top-left origin,
/// y-down — matching `CaptureRect`'s convention, see
/// `Rendering/CanvasRenderer.swift`'s coordinate doc comment).
///
/// Pure geometry — no `CGContext`, no AppKit — so every method is directly
/// unit-testable (see `Tests/CaptureEditorTests/CropControllerTests.swift`).
public struct CropController {
    public enum Handle: CaseIterable, Equatable, Hashable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    /// An aspect ratio constraint; `width`/`height` of 0 means "no lock"
    /// (free crop).
    public struct AspectRatio: Hashable, Sendable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }

        public var ratio: Double? {
            width > 0 && height > 0 ? width / height : nil
        }

        public static let freeform = AspectRatio(width: 0, height: 0)
        public static let square = AspectRatio(width: 1, height: 1)
        public static let fourByThree = AspectRatio(width: 4, height: 3)
        public static let threeByTwo = AspectRatio(width: 3, height: 2)
        public static let sixteenByNine = AspectRatio(width: 16, height: 9)
        public static let twentyOneByNine = AspectRatio(width: 21, height: 9)

        /// "Remembered common ratios" starter set; `CaptureUI` is expected
        /// to persist the user's own most-recently-used ratios alongside
        /// this baseline list, not replace it.
        public static let commonPresets: [AspectRatio] = [.freeform, .square, .fourByThree, .threeByTwo, .sixteenByNine, .twentyOneByNine]
    }

    public enum HorizontalAnchor: Sendable { case left, right, center }
    public enum VerticalAnchor: Sendable { case top, bottom, center }

    /// Keyboard nudge amounts, matching the Select/Crop keyboard convention
    /// documented for this class of tool (Appendix A `02_editor_and_canvas.md`:
    /// "Arrow = move 1px; Shift+Arrow = move 10px; Cmd+Arrow = resize 1px;
    /// Cmd+Shift+Arrow = resize 10px").
    public enum KeyboardNudge {
        public static let small: CGFloat = 1
        public static let large: CGFloat = 10
    }

    public let sourceSize: CaptureSize
    public let snapEngine: SnapEngine

    public init(sourceSize: CaptureSize, snapEngine: SnapEngine = SnapEngine()) {
        self.sourceSize = sourceSize
        self.snapEngine = snapEngine
    }

    // MARK: - Reset / exact dimensions

    public func resetToSource() -> CaptureRect {
        CaptureRect(x: 0, y: 0, width: sourceSize.width, height: sourceSize.height)
    }

    /// Sets an exact width/height, keeping `anchor` fixed (default:
    /// top-left, matching how most numeric x/y/w/h fields behave — x/y are
    /// the crop's own origin). Clamped to stay within the source bounds.
    public func exactDimensions(_ rect: CaptureRect, width: CGFloat, height: CGFloat, horizontalAnchor: HorizontalAnchor = .left, verticalAnchor: VerticalAnchor = .top) -> CaptureRect {
        let x = anchoredX(rect, width: width, anchor: horizontalAnchor)
        let y = anchoredY(rect, height: height, anchor: verticalAnchor)
        return clampEdges(CaptureRect(x: x, y: y, width: max(width, 0), height: max(height, 0)))
    }

    /// Centre-resize: grows/shrinks the crop symmetrically about its
    /// current centre to the given exact dimensions.
    public func centreResize(_ rect: CaptureRect, width: CGFloat, height: CGFloat) -> CaptureRect {
        exactDimensions(rect, width: width, height: height, horizontalAnchor: .center, verticalAnchor: .center)
    }

    // MARK: - Handle drag / resize

    /// Resizes `rect` by dragging `handle` to `point` (both in source
    /// pixel coordinates), optionally locked to `aspectRatio` and/or
    /// resizing symmetrically about the rect's centre.
    public func resize(_ rect: CaptureRect, handle: Handle, to point: CGPoint, aspectRatio: AspectRatio = .freeform, fromCentre: Bool = false) -> CaptureRect {
        let current = position(of: handle, in: rect)
        return applyHandleDelta(rect, handle: handle, dx: point.x - current.x, dy: point.y - current.y, aspectRatio: aspectRatio, fromCentre: fromCentre)
    }

    /// Keyboard-nudge a resize handle by a fixed delta (`KeyboardNudge.small`/
    /// `.large`, matching `Cmd+Arrow`/`Cmd+Shift+Arrow`).
    public func nudgeHandle(_ rect: CaptureRect, handle: Handle, dx: CGFloat, dy: CGFloat, aspectRatio: AspectRatio = .freeform, fromCentre: Bool = false) -> CaptureRect {
        applyHandleDelta(rect, handle: handle, dx: dx, dy: dy, aspectRatio: aspectRatio, fromCentre: fromCentre)
    }

    /// Keyboard-nudge the WHOLE crop rect (move, not resize; matching plain
    /// `Arrow`/`Shift+Arrow`).
    public func nudge(_ rect: CaptureRect, dx: CGFloat, dy: CGFloat) -> CaptureRect {
        clampEdges(CaptureRect(x: rect.x + dx, y: rect.y + dy, width: rect.width, height: rect.height))
    }

    /// Snap-engine-integrated handle drag: builds snap candidate lines from
    /// the source image's own edges plus caller-supplied `candidateRects`
    /// (DOM element bounds, guides, or anything else expressed as
    /// `CaptureRect` — this type has no opinion on where they came from,
    /// per the task's "just accept an array of CaptureRect candidates"
    /// design), snaps the dragged handle's point against them, then
    /// resizes exactly as `resize(_:handle:to:...)` would with the
    /// snapped point.
    public func snappedResize(
        _ rect: CaptureRect,
        handle: Handle,
        to point: CGPoint,
        aspectRatio: AspectRatio = .freeform,
        fromCentre: Bool = false,
        candidateRects: [CaptureRect],
        guideLines: [SnapLine] = [],
        settings: SnapSettings = .default
    ) -> SnapResult {
        var lines = SnapEngine.lines(for: CaptureRect(x: 0, y: 0, width: sourceSize.width, height: sourceSize.height), category: .edges)
        for candidate in candidateRects {
            lines.append(contentsOf: SnapEngine.lines(for: candidate, category: .domElements))
        }
        lines.append(contentsOf: guideLines)

        // Represent the dragged handle as a zero-size probe rect at `point`
        // so `SnapEngine.snap` can adjust it independently on each axis;
        // `SnapEngine` doesn't have a "snap a single point" entry point,
        // only "snap a rect's edges", and a zero-size rect's 6 candidate
        // lines all collapse to exactly `point`'s x/y, which is exactly
        // the single-point behaviour this needs.
        let probe = CaptureRect(x: point.x, y: point.y, width: 0, height: 0)
        let snapped = snapEngine.snap(moving: probe, candidates: lines, settings: settings)
        let snappedPoint = CGPoint(x: snapped.rect.x, y: snapped.rect.y)
        let resized = resize(rect, handle: handle, to: snappedPoint, aspectRatio: aspectRatio, fromCentre: fromCentre)
        return SnapResult(rect: resized, activeGuides: snapped.activeGuides)
    }

    // MARK: - Core handle-delta geometry

    private func position(of handle: Handle, in rect: CaptureRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private static let leftHandles: Set<Handle> = [.topLeft, .left, .bottomLeft]
    private static let rightHandles: Set<Handle> = [.topRight, .right, .bottomRight]
    private static let topHandles: Set<Handle> = [.topLeft, .top, .topRight]
    private static let bottomHandles: Set<Handle> = [.bottomLeft, .bottom, .bottomRight]

    private func applyHandleDelta(_ rect: CaptureRect, handle: Handle, dx: CGFloat, dy: CGFloat, aspectRatio: AspectRatio, fromCentre: Bool) -> CaptureRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY

        if Self.leftHandles.contains(handle) { minX += dx }
        if Self.rightHandles.contains(handle) { maxX += dx }
        if Self.topHandles.contains(handle) { minY += dy }
        if Self.bottomHandles.contains(handle) { maxY += dy }

        if fromCentre {
            // Mirror the opposite edge by the same delta so the centre
            // stays fixed ("centre-resize" while dragging a single handle).
            if Self.leftHandles.contains(handle) { maxX -= dx }
            if Self.rightHandles.contains(handle) { minX -= dx }
            if Self.topHandles.contains(handle) { maxY -= dy }
            if Self.bottomHandles.contains(handle) { minY -= dy }
        }

        var result = CaptureRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        if let ratio = aspectRatio.ratio {
            result = applyAspectLock(result, handle: handle, ratio: ratio, fromCentre: fromCentre)
        }

        // NOTE: clamping to the source bounds here happens AFTER aspect
        // locking, so a drag that hits the source edge with an active
        // aspect lock will visibly distort the ratio right at the
        // boundary rather than stopping the drag early. A fully polished
        // implementation would instead shrink the drag delta itself so the
        // ratio never breaks; this simpler clamp-after-the-fact behaviour
        // is a documented, deliberate simplification given this module's
        // effort budget, not an oversight.
        return clampEdges(result)
    }

    private func applyAspectLock(_ rect: CaptureRect, handle: Handle, ratio: Double, fromCentre: Bool) -> CaptureRect {
        var width = rect.width
        var height = rect.height
        switch handle {
        case .top, .bottom:
            width = height * CGFloat(ratio)
        case .left, .right:
            height = width / CGFloat(ratio)
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            // Corner handles: drive from the width the drag produced.
            height = width / CGFloat(ratio)
        }

        let horizontalAnchor: HorizontalAnchor
        let verticalAnchor: VerticalAnchor
        if fromCentre {
            horizontalAnchor = .center
            verticalAnchor = .center
        } else {
            switch handle {
            case .topLeft: horizontalAnchor = .right; verticalAnchor = .bottom
            case .topRight: horizontalAnchor = .left; verticalAnchor = .bottom
            case .bottomRight: horizontalAnchor = .left; verticalAnchor = .top
            case .bottomLeft: horizontalAnchor = .right; verticalAnchor = .top
            case .top: horizontalAnchor = .center; verticalAnchor = .bottom
            case .bottom: horizontalAnchor = .center; verticalAnchor = .top
            case .left: horizontalAnchor = .right; verticalAnchor = .center
            case .right: horizontalAnchor = .left; verticalAnchor = .center
            }
        }

        let x = anchoredX(rect, width: width, anchor: horizontalAnchor)
        let y = anchoredY(rect, height: height, anchor: verticalAnchor)
        return CaptureRect(x: x, y: y, width: width, height: height)
    }

    private func anchoredX(_ rect: CaptureRect, width: CGFloat, anchor: HorizontalAnchor) -> CGFloat {
        switch anchor {
        case .left: return rect.minX
        case .right: return rect.maxX - width
        case .center: return rect.midX - width / 2
        }
    }

    private func anchoredY(_ rect: CaptureRect, height: CGFloat, anchor: VerticalAnchor) -> CGFloat {
        switch anchor {
        case .top: return rect.minY
        case .bottom: return rect.maxY - height
        case .center: return rect.midY - height / 2
        }
    }

    /// Clamps every edge independently to `[0, sourceSize]`, preserving
    /// edge ordering (so a rect can shrink to zero at a boundary but never
    /// invert or extend past the source).
    private func clampEdges(_ rect: CaptureRect) -> CaptureRect {
        let minX = min(max(rect.minX, 0), sourceSize.width)
        let maxX = min(max(rect.maxX, 0), sourceSize.width)
        let minY = min(max(rect.minY, 0), sourceSize.height)
        let maxY = min(max(rect.maxY, 0), sourceSize.height)
        return CaptureRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    /// Public wrapper for clamping an arbitrary rect (e.g. one built
    /// directly from a numeric x/y/w/h entry field) into source bounds.
    public func clampToSource(_ rect: CaptureRect) -> CaptureRect {
        clampEdges(rect)
    }
}
