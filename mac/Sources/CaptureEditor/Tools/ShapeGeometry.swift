import CoreGraphics
import Foundation

/// Pure geometry for the non-primitive shapes under `Annotation.Kind.polygon`
/// (regular polygon, star, hexagon) — point math only, unit-testable without
/// a `CGContext`. `Tools/AnnotationRenderer.swift` turns the output into an
/// actual fill/stroke path.
public enum ShapeGeometry {
    /// Vertices of a regular N-gon inscribed in `rect`, point-up by default
    /// (first vertex at the top), rotated by `rotationDegrees` about the
    /// shape's own centre in addition to that.
    public static func regularPolygonPoints(in rect: CGRect, sides: Int, rotationDegrees: Double = 0) -> [CGPoint] {
        guard sides >= 3 else { return [] }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        let startAngle = -Double.pi / 2 + rotationDegrees * .pi / 180
        return (0..<sides).map { i in
            let angle = startAngle + 2 * .pi * Double(i) / Double(sides)
            return CGPoint(x: center.x + radiusX * CGFloat(cos(angle)), y: center.y + radiusY * CGFloat(sin(angle)))
        }
    }

    /// Vertices of a `points`-pointed star inscribed in `rect`, alternating
    /// outer/inner radius. `innerRadiusRatio` (0...1) controls how deep the
    /// star's notches cut in; 0.5 is a typical 5-point-star look.
    public static func starPoints(in rect: CGRect, points: Int, innerRadiusRatio: CGFloat = 0.5, rotationDegrees: Double = 0) -> [CGPoint] {
        guard points >= 3 else { return [] }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerX = rect.width / 2
        let outerY = rect.height / 2
        let innerX = outerX * innerRadiusRatio
        let innerY = outerY * innerRadiusRatio
        let startAngle = -Double.pi / 2 + rotationDegrees * .pi / 180
        let step = Double.pi / Double(points)
        var result: [CGPoint] = []
        for i in 0..<(points * 2) {
            let angle = startAngle + step * Double(i)
            let isOuter = i % 2 == 0
            let rx = isOuter ? outerX : innerX
            let ry = isOuter ? outerY : innerY
            result.append(CGPoint(x: center.x + rx * CGFloat(cos(angle)), y: center.y + ry * CGFloat(sin(angle))))
        }
        return result
    }

    /// A `CGPath` connecting `points` as a closed polygon.
    public static func closedPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// A simplified square-bracket path: two horizontal ticks joined by a
    /// vertical spine, e.g. `[` or `]` depending on `opensRight`. This is a
    /// documented approximation, not a typographically-matched bracket glyph
    /// — good enough for "bracket the following region" annotation use.
    public static func bracketPath(in rect: CGRect, opensRight: Bool, tickLength: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let x = opensRight ? rect.minX : rect.maxX
        let tickDirection: CGFloat = opensRight ? 1 : -1
        path.move(to: CGPoint(x: x + tickDirection * tickLength, y: rect.minY))
        path.addLine(to: CGPoint(x: x, y: rect.minY))
        path.addLine(to: CGPoint(x: x, y: rect.maxY))
        path.addLine(to: CGPoint(x: x + tickDirection * tickLength, y: rect.maxY))
        return path
    }

    /// A simplified brace (`{`/`}`) path built from two cubic curves meeting
    /// at a centre point-tick — again a documented visual approximation.
    public static func bracePath(in rect: CGRect, opensRight: Bool, pointDepth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let x = opensRight ? rect.minX : rect.maxX
        let direction: CGFloat = opensRight ? 1 : -1
        let midY = rect.midY
        let tipX = x + direction * pointDepth

        path.move(to: CGPoint(x: x, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: tipX, y: midY - (rect.height * 0.08)),
            control1: CGPoint(x: x, y: rect.minY + rect.height * 0.25),
            control2: CGPoint(x: tipX, y: midY - rect.height * 0.3)
        )
        path.addLine(to: CGPoint(x: tipX + direction * pointDepth * 0.6, y: midY))
        path.addLine(to: CGPoint(x: tipX, y: midY + (rect.height * 0.08)))
        path.addCurve(
            to: CGPoint(x: x, y: rect.maxY),
            control1: CGPoint(x: tipX, y: midY + rect.height * 0.3),
            control2: CGPoint(x: x, y: rect.maxY - rect.height * 0.25)
        )
        return path
    }
}
