import CoreGraphics
import Foundation

/// Perturbs a straight segment into a hand-drawn-looking polyline by adding
/// small seeded-random perpendicular jitter at subdivided interior points —
/// endpoints are never moved, so a hand-drawn stroke still starts/ends
/// exactly where the user placed it. Matches the "supports hand-drawn
/// rendering style; `Cmd+R` randomizes hand-drawn appearance of a selected
/// supported object" behaviour (Appendix A `03_annotations.md`).
///
/// Pure geometry — produces points for `Tools/AnnotationRenderer.swift` to
/// stroke; does no drawing itself, so it's directly unit-testable.
public enum HandDrawnPath {
    /// - Parameters:
    ///   - seed: Stable per-annotation seed (`AnnotationStyleKeys.handDrawnSeed`).
    ///     `Cmd+R` re-randomizing an object means: assign it a new random
    ///     seed value and re-render, not "re-roll every frame" — that is
    ///     what makes the effect stable across redraws.
    ///   - amplitude: Maximum perpendicular offset, in points.
    ///   - subdivisions: Number of interior sample points; higher = smoother
    ///     wobble curve when stroked with line joins, at the cost of more
    ///     points to stroke.
    public static func jittered(
        from start: CGPoint,
        to end: CGPoint,
        seed: UInt64,
        amplitude: CGFloat = 1.6,
        subdivisions: Int = 8
    ) -> [CGPoint] {
        guard subdivisions > 1 else { return [start, end] }
        var generator = SeededGenerator(seed: seed)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(sqrt(dx * dx + dy * dy), 0.0001)
        let px = -dy / length
        let py = dx / length

        var points: [CGPoint] = [start]
        for i in 1..<subdivisions {
            let t = Double(i) / Double(subdivisions)
            // Taper jitter to zero at both endpoints (half-sine window) so
            // strokes still meet exactly at the user-placed anchor points.
            let taper = sin(Double.pi * t)
            let jitter = CGFloat(Double.random(in: -1...1, using: &generator)) * amplitude * CGFloat(taper)
            let baseX = start.x + dx * CGFloat(t)
            let baseY = start.y + dy * CGFloat(t)
            points.append(CGPoint(x: baseX + px * jitter, y: baseY + py * jitter))
        }
        points.append(end)
        return points
    }

    /// Jitters an already-multi-point path (e.g. a polygon's vertices)
    /// perpendicular to each local segment, for shapes where a single
    /// start/end pair isn't enough (rectangle/polygon hand-drawn outlines).
    public static func jittered(polyline: [CGPoint], seed: UInt64, amplitude: CGFloat = 1.4, subdivisionsPerSegment: Int = 4) -> [CGPoint] {
        guard polyline.count > 1 else { return polyline }
        var result: [CGPoint] = []
        for i in 0..<(polyline.count - 1) {
            // Vary the seed per segment so segments don't wobble in lockstep.
            let segmentSeed = seed &+ UInt64(i) &* 0x9E3779B1
            let segment = jittered(from: polyline[i], to: polyline[i + 1], seed: segmentSeed, amplitude: amplitude, subdivisions: subdivisionsPerSegment)
            if i == 0 {
                result.append(contentsOf: segment)
            } else {
                result.append(contentsOf: segment.dropFirst())
            }
        }
        return result
    }
}
