import CoreGraphics
import Foundation

/// Vector glyph drawing for the built-in stamp set (Part III
/// `03_editor_annotations.md`: "Stamps (useful lightweight set): check; X;
/// warning; question; approve; reject; bug; accessibility; performance; CRO
/// opportunity. Custom SVG stamps supported.").
///
/// Every built-in symbol is drawn as plain `CGPath` vector geometry sized to
/// fit `rect`, so stamps stay crisp at any export scale with no bitmap
/// assets to bundle. This keeps the glyphs intentionally simple/iconographic
/// (not pixel-accurate SF Symbols reproductions) — good enough to read at a
/// glance on a screenshot, which is the stamp's actual job.
///
/// **Known gap:** `symbol == "custom"` (arbitrary user-supplied SVG, via
/// `AnnotationStyleKeys.stampCustomSVG`) is NOT implemented here — this
/// module has no SVG parser, and none of `CaptureEditor`'s CDN/dependency
/// constraints (system frameworks only, per `docs/ARCHITECTURE.md`'s
/// coding-style rule) provide one for free. `draw` falls back to a dashed
/// placeholder square for `"custom"` and any unrecognized symbol name
/// rather than silently drawing nothing, so a missing custom stamp is
/// visually obvious instead of invisible. A real implementation should
/// probably render custom SVG via `CGPath`/`CGContext` after parsing with
/// a small bundled SVG-subset parser, or by rasterizing through
/// `NSImage(data:)` if the SVG is simple enough for AppKit's own limited
/// SVG support — left for a follow-up, not silently faked here.
public enum StampSymbols {
    public static func draw(_ symbol: String, in rect: CGRect, colour: CGColor, into context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(colour)
        context.setFillColor(colour)
        let lineWidth = max(rect.width, rect.height) * 0.08
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch symbol {
        case "check", "approve":
            if symbol == "approve" {
                drawCircleBadge(rect: rect, colour: colour, into: context)
                context.setStrokeColor(badgeTextColour(colour))
            }
            drawCheck(in: inset(rect, forBadge: symbol == "approve"), into: context)
        case "cross", "reject":
            if symbol == "reject" {
                drawCircleBadge(rect: rect, colour: colour, into: context)
                context.setStrokeColor(badgeTextColour(colour))
            }
            drawCross(in: inset(rect, forBadge: symbol == "reject"), into: context)
        case "warning":
            drawWarningTriangle(in: rect, into: context)
        case "question":
            drawCircleBadge(rect: rect, colour: colour, into: context)
            SimpleTextDrawing.drawCentered("?", in: inset(rect, forBadge: true), pointSize: rect.height * 0.5, colour: badgeTextColour(colour), into: context)
        case "bug":
            drawBug(in: rect, into: context)
        case "accessibility":
            drawAccessibility(in: rect, into: context)
        case "performance":
            drawLightningBolt(in: rect, into: context)
        case "croOpportunity":
            drawTargetArrow(in: rect, into: context)
        default: // "custom" and anything unrecognized — see doc comment above.
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(rect.insetBy(dx: lineWidth, dy: lineWidth))
        }
    }

    private static func inset(_ rect: CGRect, forBadge: Bool) -> CGRect {
        forBadge ? rect.insetBy(dx: rect.width * 0.26, dy: rect.height * 0.26) : rect
    }

    private static func drawCircleBadge(rect: CGRect, colour: CGColor, into context: CGContext) {
        context.setFillColor(colour)
        context.fillEllipse(in: rect)
    }

    private static func badgeTextColour(_ background: CGColor) -> CGColor {
        SimpleTextDrawing.readableTextColour(against: background)
    }

    private static func drawCheck(in rect: CGRect, into context: CGContext) {
        context.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.52))
        context.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.22))
        context.addLine(to: CGPoint(x: rect.minX + rect.width * 0.90, y: rect.minY + rect.height * 0.78))
        context.strokePath()
    }

    private static func drawCross(in rect: CGRect, into context: CGContext) {
        context.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.18))
        context.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.maxY - rect.height * 0.18))
        context.strokePath()
        context.move(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY + rect.height * 0.18))
        context.addLine(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.maxY - rect.height * 0.18))
        context.strokePath()
    }

    private static func drawWarningTriangle(in rect: CGRect, into context: CGContext) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()

        // Exclamation mark, drawn in white for contrast against the fill.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let stemRect = CGRect(x: rect.midX - rect.width * 0.035, y: rect.minY + rect.height * 0.42, width: rect.width * 0.07, height: rect.height * 0.28)
        context.fill(stemRect)
        let dotRect = CGRect(x: rect.midX - rect.width * 0.045, y: rect.minY + rect.height * 0.76, width: rect.width * 0.09, height: rect.width * 0.09)
        context.fillEllipse(in: dotRect)
    }

    private static func drawBug(in rect: CGRect, into context: CGContext) {
        let body = rect.insetBy(dx: rect.width * 0.28, dy: rect.height * 0.18)
        context.fillEllipse(in: body)
        // Legs.
        let legCount = 3
        for i in 0..<legCount {
            let t = CGFloat(i) / CGFloat(legCount - 1)
            let y = body.minY + body.height * (0.25 + 0.5 * t)
            context.move(to: CGPoint(x: body.minX, y: y))
            context.addLine(to: CGPoint(x: rect.minX, y: y - rect.height * 0.06))
            context.strokePath()
            context.move(to: CGPoint(x: body.maxX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y - rect.height * 0.06))
            context.strokePath()
        }
        // Antennae.
        context.move(to: CGPoint(x: body.midX - body.width * 0.15, y: body.minY))
        context.addLine(to: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY))
        context.strokePath()
        context.move(to: CGPoint(x: body.midX + body.width * 0.15, y: body.minY))
        context.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.3, y: rect.minY))
        context.strokePath()
    }

    private static func drawAccessibility(in rect: CGRect, into context: CGContext) {
        // Simplified "person in a circle" glyph.
        context.strokeEllipse(in: rect.insetBy(dx: rect.width * 0.05, dy: rect.height * 0.05))
        let headRect = CGRect(x: rect.midX - rect.width * 0.08, y: rect.minY + rect.height * 0.2, width: rect.width * 0.16, height: rect.width * 0.16)
        context.fillEllipse(in: headRect)
        // Arms (horizontal bar).
        context.move(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.midY - rect.height * 0.02))
        context.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.midY - rect.height * 0.02))
        context.strokePath()
        // Body/legs (inverted V).
        context.move(to: CGPoint(x: rect.midX, y: rect.midY))
        context.addLine(to: CGPoint(x: rect.midX - rect.width * 0.16, y: rect.maxY - rect.height * 0.15))
        context.strokePath()
        context.move(to: CGPoint(x: rect.midX, y: rect.midY))
        context.addLine(to: CGPoint(x: rect.midX + rect.width * 0.16, y: rect.maxY - rect.height * 0.15))
        context.strokePath()
    }

    private static func drawLightningBolt(in rect: CGRect, into context: CGContext) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.48, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY + rect.height * 0.42))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY + rect.height * 0.42))
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
    }

    private static func drawTargetArrow(in rect: CGRect, into context: CGContext) {
        // Concentric target rings plus an arrow hitting the bullseye, for
        // "CRO opportunity" (a metric moving in the right direction).
        context.strokeEllipse(in: rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04))
        context.strokeEllipse(in: rect.insetBy(dx: rect.width * 0.24, dy: rect.height * 0.24))
        context.fillEllipse(in: rect.insetBy(dx: rect.width * 0.42, dy: rect.height * 0.42))

        let arrowStart = CGPoint(x: rect.minX, y: rect.maxY)
        let arrowEnd = CGPoint(x: rect.midX, y: rect.midY)
        context.move(to: arrowStart)
        context.addLine(to: arrowEnd)
        context.strokePath()
        let head = ArrowGeometry.triangleHead(from: arrowStart, tip: arrowEnd, length: rect.width * 0.18, width: rect.width * 0.14)
        let headPath = CGMutablePath()
        headPath.move(to: head.apex)
        headPath.addLine(to: head.left)
        headPath.addLine(to: head.right)
        headPath.closeSubpath()
        context.addPath(headPath)
        context.fillPath()
    }
}
