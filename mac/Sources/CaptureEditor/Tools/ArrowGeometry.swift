import CoreGraphics
import Foundation

/// Pure geometry for arrow/line-head rendering — point math only, no
/// `CGContext` drawing calls, so it is unit-testable without a real graphics
/// context (see `Tests/CaptureEditorTests/ArrowGeometryTests.swift`).
/// `Tools/AnnotationRenderer.swift` turns this into actual fill/stroke calls.
public enum ArrowGeometry {
    public struct Head: Equatable {
        public var apex: CGPoint
        public var left: CGPoint
        public var right: CGPoint
    }

    /// The triangular arrowhead for a segment arriving at `tip` from
    /// `from`'s direction. `length`/`width` are in points.
    public static func triangleHead(from: CGPoint, tip: CGPoint, length: CGFloat, width: CGFloat) -> Head {
        let (ux, uy) = unitVector(from: from, to: tip)
        // Perpendicular unit vector (90 degrees counter-clockwise).
        let px = -uy
        let py = ux
        let base = shaftEnd(from: from, tip: tip, headLength: length)
        let left = CGPoint(x: base.x + px * (width / 2), y: base.y + py * (width / 2))
        let right = CGPoint(x: base.x - px * (width / 2), y: base.y - py * (width / 2))
        return Head(apex: tip, left: left, right: right)
    }

    /// The point where a filled arrowhead's base sits, i.e. where a stroked
    /// shaft should stop so it doesn't poke out through/behind the solid
    /// head shape.
    public static func shaftEnd(from: CGPoint, tip: CGPoint, headLength: CGFloat) -> CGPoint {
        let (ux, uy) = unitVector(from: from, to: tip)
        return CGPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)
    }

    /// Quadratic-Bezier control point for a "curved" arrow, bowed by `bow`
    /// points perpendicular to the straight start->end line at its midpoint.
    /// Positive `bow` bows to the left of the start->end direction.
    public static func curveControlPoint(start: CGPoint, end: CGPoint, bow: CGFloat) -> CGPoint {
        let mx = (start.x + end.x) / 2
        let my = (start.y + end.y) / 2
        let (ux, uy) = unitVector(from: start, to: end)
        let px = -uy
        let py = ux
        return CGPoint(x: mx + px * bow, y: my + py * bow)
    }

    /// The tangent direction of a quadratic Bezier at `t == 1` (i.e. at the
    /// end point), used so a curved arrow's head points along the curve
    /// rather than along the straight start->end chord.
    public static func quadraticEndTangent(start: CGPoint, control: CGPoint, end: CGPoint) -> CGPoint {
        // d/dt B(t) at t=1 for a quadratic Bezier is 2*(end - control).
        CGPoint(x: end.x + (end.x - control.x), y: end.y + (end.y - control.y))
    }

    /// Recommended head size scaled from stroke thickness, matching common
    /// annotation-tool proportions (head length grows with thickness but is
    /// clamped so very thin/very thick strokes still get a usable head).
    public static func recommendedHeadSize(forThickness thickness: CGFloat) -> (length: CGFloat, width: CGFloat) {
        let length = min(max(thickness * 3.2, 10), 42)
        return (length, length * 0.72)
    }

    /// Three-point elbow/bendable path (start -> corner -> end) where the
    /// corner sits at the intersection implied by `bendRatio` (0 = corner at
    /// start's horizontal, 1 = corner at end's horizontal), matching the
    /// common "L-shaped connector" callout style.
    public static func elbowCorner(start: CGPoint, end: CGPoint, bendRatio: CGFloat, horizontalFirst: Bool) -> CGPoint {
        let t = min(max(bendRatio, 0), 1)
        if horizontalFirst {
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y)
        } else {
            return CGPoint(x: start.x, y: start.y + (end.y - start.y) * t)
        }
    }

    private static func unitVector(from: CGPoint, to: CGPoint) -> (CGFloat, CGFloat) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = max(sqrt(dx * dx + dy * dy), 0.0001)
        return (dx / distance, dy / distance)
    }
}
