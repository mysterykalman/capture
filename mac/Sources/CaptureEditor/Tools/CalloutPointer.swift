import CoreGraphics
import Foundation

/// Geometry for the small triangular "pointer" connecting a text bubble (or
/// callout-bubble shape) to an anchor point elsewhere on the canvas — Part
/// III `03_editor_annotations.md`: "text background; padding; radius;
/// shadow; callout pointer; multiple pointers." Drawn as plain vector
/// geometry, not an image asset, so it always matches the bubble's current
/// fill colour and scales cleanly at any export resolution.
public enum CalloutPointer {
    /// A triangle from the edge of `bubbleRect` nearest `pointerTarget`,
    /// out to `pointerTarget` itself. The triangle's base sits on the
    /// bubble's boundary (picking whichever of the 4 edges the target is
    /// most directly outside of) so it reads as attached to the bubble
    /// rather than floating independently.
    public static func trianglePath(bubbleRect: CGRect, pointerTarget: CGPoint, baseWidth: CGFloat = 14) -> CGPath {
        let path = CGMutablePath()
        guard !bubbleRect.contains(pointerTarget) else { return path }

        let center = CGPoint(x: bubbleRect.midX, y: bubbleRect.midY)
        let dx = pointerTarget.x - center.x
        let dy = pointerTarget.y - center.y

        // Decide which edge to attach to by comparing how far outside each
        // axis the target is, relative to that axis's half-extent.
        let horizontalRatio = abs(dx) / max(bubbleRect.width / 2, 0.0001)
        let verticalRatio = abs(dy) / max(bubbleRect.height / 2, 0.0001)

        let baseCenter: CGPoint
        let baseAxisIsHorizontal: Bool
        if horizontalRatio >= verticalRatio {
            // Attach to left or right edge.
            baseAxisIsHorizontal = false
            let edgeX = dx >= 0 ? bubbleRect.maxX : bubbleRect.minX
            let clampedY = min(max(pointerTarget.y, bubbleRect.minY + baseWidth), bubbleRect.maxY - baseWidth)
            baseCenter = CGPoint(x: edgeX, y: bubbleRect.height > baseWidth * 2 ? clampedY : bubbleRect.midY)
        } else {
            baseAxisIsHorizontal = true
            let edgeY = dy >= 0 ? bubbleRect.maxY : bubbleRect.minY
            let clampedX = min(max(pointerTarget.x, bubbleRect.minX + baseWidth), bubbleRect.maxX - baseWidth)
            baseCenter = CGPoint(x: bubbleRect.width > baseWidth * 2 ? clampedX : bubbleRect.midX, y: edgeY)
        }

        let half = baseWidth / 2
        let baseA: CGPoint
        let baseB: CGPoint
        if baseAxisIsHorizontal {
            baseA = CGPoint(x: baseCenter.x - half, y: baseCenter.y)
            baseB = CGPoint(x: baseCenter.x + half, y: baseCenter.y)
        } else {
            baseA = CGPoint(x: baseCenter.x, y: baseCenter.y - half)
            baseB = CGPoint(x: baseCenter.x, y: baseCenter.y + half)
        }

        path.move(to: baseA)
        path.addLine(to: pointerTarget)
        path.addLine(to: baseB)
        path.closeSubpath()
        return path
    }
}
