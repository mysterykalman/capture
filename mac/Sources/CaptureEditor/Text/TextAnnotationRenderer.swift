import AppKit
import CaptureCore
import CoreGraphics
import CoreText
import Foundation

/// Renders `Annotation.Kind.text` — multi-line, per-object typography
/// (font family/size/weight/style/colour/alignment/line-height/letter-
/// spacing), an optional background bubble, and an optional callout pointer
/// triangle connecting the bubble to an anchor point (Part III
/// `03_editor_annotations.md` "Text" section).
///
/// Layout uses CoreText directly (`CTFramesetter`/`CTFrame`) rather than
/// `NSAttributedString.draw(in:)`, because `draw(in:)` relies on
/// `NSGraphicsContext.current` being set up around an `NSView`'s context;
/// this renderer also has to draw into an offscreen bitmap `CGContext`
/// during export (`Export/ExportRenderer.swift`), where there may be no
/// current `NSGraphicsContext` at all. CoreText draws directly against any
/// `CGContext`, so the same code path works for live preview and export.
public struct TextAnnotationRenderer {
    public init() {}

    public func draw(_ annotation: Annotation, style: StyleReader, into context: CGContext) {
        let rect = annotation.frame.cgRect
        let text = style.typeDataString(AnnotationStyleKeys.text, default: "") ?? ""
        let padding = style.cgFloat(AnnotationStyleKeys.textPadding, default: 8)
        let cornerRadius = style.cgFloat(AnnotationStyleKeys.textCornerRadius, default: 6)

        drawBackgroundAndPointer(rect: rect, style: style, cornerRadius: cornerRadius, into: context)

        guard !text.isEmpty else { return }
        let attributed = attributedString(for: text, style: style)
        let textRect = rect.insetBy(dx: padding, dy: padding)
        drawAttributed(attributed, in: textRect, into: context)
    }

    private func drawBackgroundAndPointer(rect: CGRect, style: StyleReader, cornerRadius: CGFloat, into context: CGContext) {
        guard let backgroundHex = style.string(AnnotationStyleKeys.textBackgroundColour),
              let background = CGColor.capture_parse(hex: backgroundHex) else { return }

        let bubblePath = CGMutablePath()
        bubblePath.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        for anchor in pointerAnchors(style: style) {
            bubblePath.addPath(CalloutPointer.trianglePath(bubbleRect: rect, pointerTarget: anchor))
        }

        context.saveGState()
        if style.hasShadow {
            context.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 5, color: CGColor(gray: 0, alpha: 0.35))
        }
        context.addPath(bubblePath)
        context.setFillColor(background)
        context.fillPath(using: .winding)
        context.restoreGState()
    }

    /// "multiple pointers from one callout" (typeData array) takes
    /// precedence over the single-anchor key when both happen to be set.
    private func pointerAnchors(style: StyleReader) -> [CGPoint] {
        if case .array(let arr)? = style.typeData?[AnnotationStyleKeys.calloutPointerAnchors] {
            let points: [CGPoint] = arr.compactMap { value in
                guard case .object(let obj) = value, let x = obj["x"]?.doubleValue, let y = obj["y"]?.doubleValue else { return nil }
                return CGPoint(x: x, y: y)
            }
            if !points.isEmpty { return points }
        }
        if let single = style.typeDataPoint(AnnotationStyleKeys.calloutPointerAnchor) { return [single] }
        return []
    }

    private func attributedString(for text: String, style: StyleReader) -> NSAttributedString {
        let family = style.string(AnnotationStyleKeys.fontFamily)
        let size = style.cgFloat(AnnotationStyleKeys.fontSize, default: 17)
        let weight = fontWeight(style.string(AnnotationStyleKeys.fontWeight, default: "regular") ?? "regular")
        let italic = (style.string(AnnotationStyleKeys.fontStyle, default: "normal") ?? "normal") == "italic"

        var font: NSFont
        if let family, let named = NSFontManager.shared.font(withFamily: family, traits: italic ? .italicFontMask : [], weight: weightIndex(weight), size: size) {
            font = named
        } else {
            // Fall back to the system font rather than failing outright —
            // "actual installed fonts" per the spec is a `CaptureUI`
            // font-picker concern; this renderer just needs *a* usable font
            // for any family name it doesn't recognize (e.g. project opened
            // on a machine missing that font).
            font = NSFont.systemFont(ofSize: size, weight: weight)
            if italic {
                let converted = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                font = converted
            }
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment(style.string(AnnotationStyleKeys.textAlign, default: "left") ?? "left")
        paragraph.lineHeightMultiple = style.cgFloat(AnnotationStyleKeys.lineHeightMultiple, default: 1.15)

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: style.strokeColour) ?? NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let letterSpacingPt = style.double(AnnotationStyleKeys.letterSpacing, default: 0)
        if letterSpacingPt != 0 { attributes[.kern] = letterSpacingPt }

        return NSAttributedString(string: text, attributes: attributes)
    }

    private func fontWeight(_ raw: String) -> NSFont.Weight {
        switch raw {
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        default: return .regular
        }
    }

    /// `NSFontManager`'s weight scale runs roughly 0 (lightest) ... 15
    /// (boldest), with 5 as the conventional "regular" midpoint. Mapping
    /// our coarse 4-step `fontWeight` enum onto it is necessarily
    /// approximate — different font families expose different actual
    /// weight steps, and `NSFontManager` picks the closest match it has.
    private func weightIndex(_ weight: NSFont.Weight) -> Int {
        switch weight {
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        default: return 5
        }
    }

    private func textAlignment(_ raw: String) -> NSTextAlignment {
        switch raw {
        case "center": return .center
        case "right": return .right
        default: return .left
        }
    }

    private func drawAttributed(_ attributed: NSAttributedString, in rect: CGRect, into context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }

        let path = CGPath(rect: rect, transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        CTFrameDraw(frame, context)
    }
}

/// Small text-drawing helper shared by tools that need a single line of
/// centered plain text without the full `TextAnnotationRenderer` bubble
/// machinery — Counter badges, Stamp labels, Measurement distance labels.
public enum SimpleTextDrawing {
    public static func drawCentered(_ text: String, in rect: CGRect, pointSize: CGFloat, colour: CGColor, into context: CGContext) {
        guard rect.width > 0, rect.height > 0, !text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: colour) ?? NSColor.white,
            .paragraphStyle: paragraph
        ])

        context.saveGState()
        defer { context.restoreGState() }
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let origin = CGPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2 - bounds.origin.y)
        context.textPosition = origin
        CTLineDraw(line, context)
    }

    /// A small rounded "pill" filled with `backgroundColour`, with `text`
    /// centered inside, centered at `point` — used for measurement distance
    /// labels floating on the midpoint of a measurement line.
    public static func drawPill(_ text: String, centeredAt point: CGPoint, backgroundColour: CGColor, into context: CGContext, fontSize: CGFloat = 11) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white
        ])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 3
        let pillRect = CGRect(
            x: point.x - bounds.width / 2 - horizontalPadding,
            y: point.y - bounds.height / 2 - verticalPadding,
            width: bounds.width + horizontalPadding * 2,
            height: bounds.height + verticalPadding * 2
        )

        context.saveGState()
        context.addPath(CGPath(roundedRect: pillRect, cornerWidth: pillRect.height / 2, cornerHeight: pillRect.height / 2, transform: nil))
        context.setFillColor(backgroundColour)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        defer { context.restoreGState() }
        context.textPosition = CGPoint(x: point.x - bounds.width / 2, y: point.y - bounds.height / 2 - bounds.origin.y)
        CTLineDraw(line, context)
    }

    /// Picks black or white, whichever reads better against `background`,
    /// using the standard relative-luminance heuristic (WCAG-style, not a
    /// full contrast-ratio computation).
    public static func readableTextColour(against background: CGColor) -> CGColor {
        let components = background.components ?? [0, 0, 0, 1]
        let r = components.count > 0 ? components[0] : 0
        let g = components.count > 1 ? components[1] : 0
        let b = components.count > 2 ? components[2] : 0
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.6 ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
    }
}
