import CaptureCore
import CoreGraphics
import Foundation

/// Draws every `Annotation.Kind` except `.redact` and `.measurement` (those
/// have their own dedicated renderers — `Redaction/RedactionRenderer.swift`
/// and `drawMeasurement` below respectively — called directly by
/// `Rendering/CanvasRenderer.swift` as their own fixed architectural layer,
/// see `Document/EditorDocument.RenderLayerGroup`).
///
/// Every method here takes a `CGContext` already positioned in canvas
/// coordinates (i.e. `context.saveGState()`/coordinate setup is the caller's
/// job) and leaves the context's state as it found it (`saveGState`/
/// `restoreGState` bracket every method's own transform/style changes).
public struct AnnotationRenderer {
    public init() {}

    /// Supplies pixel content for tools that need to read the rendered
    /// canvas beneath them (currently only `.magnifier`, which needs the
    /// *source image* pixels it is zooming into — not arbitrary composited
    /// canvas content, which would need a snapshot-based approach; see
    /// `RedactionRenderer` for that pattern).
    public struct SourceContext {
        public var sourceImage: CGImage?
        /// The rect, in canvas coordinates, that `sourceImage` occupies
        /// (i.e. where pixel (0,0) of the source lands after crop/placement).
        public var sourcePlacement: CaptureRect

        public init(sourceImage: CGImage?, sourcePlacement: CaptureRect) {
            self.sourceImage = sourceImage
            self.sourcePlacement = sourcePlacement
        }
    }

    public func draw(_ annotation: Annotation, canvasSize: CaptureSize, source: SourceContext, into context: CGContext) {
        guard !annotation.hidden else { return }
        context.saveGState()
        defer { context.restoreGState() }

        context.setAlpha(CGFloat(annotation.opacity))
        applyRotation(annotation, into: context)
        let style = StyleReader(annotation)

        switch annotation.type {
        case .arrow: drawArrow(annotation, style: style, into: context)
        case .line: drawLine(annotation, style: style, into: context)
        case .rectangle: drawRectangle(annotation, style: style, into: context)
        case .ellipse: drawEllipse(annotation, style: style, into: context)
        case .polygon: drawPolygon(annotation, style: style, into: context)
        case .freehand: drawFreehand(annotation, style: style, into: context)
        case .highlighter: drawHighlighter(annotation, style: style, into: context)
        case .spotlight: drawSpotlight(annotation, style: style, canvasSize: canvasSize, into: context)
        case .counter: drawCounter(annotation, style: style, into: context)
        case .magnifier: drawMagnifier(annotation, style: style, source: source, into: context)
        case .stamp: drawStamp(annotation, style: style, into: context)
        case .cursor: drawCursor(annotation, style: style, into: context)
        case .text: TextAnnotationRenderer().draw(annotation, style: style, into: context)
        case .redact, .measurement:
            break // Rendered by their own dedicated layer passes.
        }
    }

    /// Called directly by `CanvasRenderer` for the Measurements layer.
    public func drawMeasurement(_ annotation: Annotation, into context: CGContext) {
        guard !annotation.hidden else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(CGFloat(annotation.opacity))

        let style = StyleReader(annotation)
        let start = style.typeDataPoint(AnnotationStyleKeys.measurementStart) ?? CGPoint(x: annotation.frame.minX, y: annotation.frame.minY)
        let end = style.typeDataPoint(AnnotationStyleKeys.measurementEnd) ?? CGPoint(x: annotation.frame.maxX, y: annotation.frame.maxY)
        let colour = style.strokeColour
        let unit = style.typeDataString(AnnotationStyleKeys.measurementUnit, default: "px") ?? "px"

        context.setStrokeColor(colour)
        context.setLineWidth(1.5)
        context.setLineCap(.round)

        // Main measurement line with small perpendicular end-caps, matching
        // the ruler/callipers look used by PixelSnap-style measurement tools.
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        drawEndCap(at: start, towards: end, into: context)
        drawEndCap(at: end, towards: start, into: context)

        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let label = "\(String(format: "%.0f", distance)) \(unit)"
        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        SimpleTextDrawing.drawPill(label, centeredAt: midpoint, backgroundColour: colour, into: context)
    }

    private func drawEndCap(at point: CGPoint, towards other: CGPoint, into context: CGContext) {
        let dx = other.x - point.x
        let dy = other.y - point.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.0001)
        let px = -dy / length
        let py = dx / length
        let half: CGFloat = 5
        context.move(to: CGPoint(x: point.x + px * half, y: point.y + py * half))
        context.addLine(to: CGPoint(x: point.x - px * half, y: point.y - py * half))
        context.strokePath()
    }

    // MARK: - Rotation

    private func applyRotation(_ annotation: Annotation, into context: CGContext) {
        guard annotation.rotation != 0 else { return }
        let center = CGPoint(x: annotation.frame.midX, y: annotation.frame.midY)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: CGFloat(annotation.rotation * .pi / 180))
        context.translateBy(x: -center.x, y: -center.y)
    }

    // MARK: - Endpoint resolution

    /// Resolves an annotation's logical start/end points: an explicit
    /// `style.points` override (multi-point arrows/lines) takes precedence;
    /// otherwise the two opposite corners of `frame` are used (top-left ->
    /// bottom-right), matching how these tools are drag-created.
    private func endpoints(_ annotation: Annotation, style: StyleReader) -> (CGPoint, CGPoint) {
        if let points = style.explicitPoints, points.count >= 2 {
            return (points.first!, points.last!)
        }
        let frame = annotation.frame.cgRect
        return (CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.maxY))
    }

    // MARK: - Arrow

    private func drawArrow(_ annotation: Annotation, style: StyleReader, into context: CGContext) {
        let (rawStart, rawEnd) = endpoints(annotation, style: style)
        let thickness = style.thickness
        let colour = style.strokeColour
        let curved = style.bool(AnnotationStyleKeys.curved, default: false)
        let doubleEnded = style.bool(AnnotationStyleKeys.doubleEnded, default: false)
        let tapered = style.bool(AnnotationStyleKeys.tapered, default: false)
        let headStyle = style.string(AnnotationStyleKeys.headStyle, default: "triangle") ?? "triangle"
        let dash = style.lineDashStyle

        context.setStrokeColor(colour)
        context.setFillColor(colour)
        context.setLineCap(dash.lineCap)
        context.setLineJoin(.round)
        if let pattern = dash.dashPattern(forThickness: thickness) { context.setLineDash(phase: 0, lengths: pattern) }
        // NOTE: `setShadow` must precede the fill/stroke calls it should
        // affect — CGContext shadows apply to subsequent painting, they are
        // not retroactive — so this is set here, before any drawing below,
        // not after (a mistake easy to make and easy to miss without being
        // able to render and eyeball the result in this sandbox).
        if style.hasShadow { applyShadowPass(context) }

        let headSize = ArrowGeometry.recommendedHeadSize(forThickness: thickness)
        let hasHeadAtEnd = headStyle != "none"
        let hasHeadAtStart = doubleEnded && headStyle != "none"

        if curved {
            let bow = style.cgFloat(AnnotationStyleKeys.curveBow, default: 28)
            let control = ArrowGeometry.curveControlPoint(start: rawStart, end: rawEnd, bow: bow)
            let shaftEnd = hasHeadAtEnd ? ArrowGeometry.shaftEnd(from: control, tip: rawEnd, headLength: headSize.length) : rawEnd
            let shaftStart = hasHeadAtStart ? ArrowGeometry.shaftEnd(from: control, tip: rawStart, headLength: headSize.length) : rawStart

            strokeTapered(context: context, thickness: thickness, tapered: tapered) {
                context.move(to: shaftStart)
                context.addQuadCurve(to: shaftEnd, control: control)
                context.strokePath()
            }
            if hasHeadAtEnd {
                let tangentFrom = ArrowGeometry.quadraticEndTangent(start: rawStart, control: control, end: rawEnd)
                drawHead(style: headStyle, from: control, tip: rawEnd, tangentHint: tangentFrom, size: headSize, into: context)
            }
            if hasHeadAtStart {
                // Mirror: tangent at the start end of the curve.
                let tangentFrom = ArrowGeometry.quadraticEndTangent(start: rawEnd, control: control, end: rawStart)
                drawHead(style: headStyle, from: control, tip: rawStart, tangentHint: tangentFrom, size: headSize, into: context)
            }
        } else {
            let path = style.explicitPoints ?? [rawStart, rawEnd]
            let points = style.isHandDrawn ? HandDrawnPath.jittered(polyline: path, seed: style.handDrawnSeed) : path
            var shaftPoints = points
            if hasHeadAtEnd, shaftPoints.count >= 2 {
                shaftPoints[shaftPoints.count - 1] = ArrowGeometry.shaftEnd(from: shaftPoints[shaftPoints.count - 2], tip: rawEnd, headLength: headSize.length)
            }
            if hasHeadAtStart, shaftPoints.count >= 2 {
                shaftPoints[0] = ArrowGeometry.shaftEnd(from: shaftPoints[1], tip: rawStart, headLength: headSize.length)
            }
            strokeTapered(context: context, thickness: thickness, tapered: tapered) {
                context.addLines(between: shaftPoints)
                context.strokePath()
            }
            if hasHeadAtEnd { drawHead(style: headStyle, from: rawStart, tip: rawEnd, tangentHint: nil, size: headSize, into: context) }
            if hasHeadAtStart { drawHead(style: headStyle, from: rawEnd, tip: rawStart, tangentHint: nil, size: headSize, into: context) }
        }
    }

    private func drawHead(style headStyle: String, from: CGPoint, tip: CGPoint, tangentHint: CGPoint?, size: (length: CGFloat, width: CGFloat), into context: CGContext) {
        let approachPoint = tangentHint ?? from
        switch headStyle {
        case "line":
            let head = ArrowGeometry.triangleHead(from: approachPoint, tip: tip, length: size.length, width: size.width)
            context.move(to: head.left)
            context.addLine(to: head.apex)
            context.addLine(to: head.right)
            context.strokePath()
        default: // "triangle"
            let head = ArrowGeometry.triangleHead(from: approachPoint, tip: tip, length: size.length, width: size.width)
            context.move(to: head.apex)
            context.addLine(to: head.left)
            context.addLine(to: head.right)
            context.closePath()
            context.fillPath()
        }
    }

    /// A simple tapered-stroke approximation: strokes the same path twice at
    /// two widths with different alphas isn't a true variable-width path, so
    /// instead we thin the line width toward one end by stroking several
    /// segments of decreasing width. Full variable-width bezier stroking
    /// would need `CGPath` outline construction; this segment approach is a
    /// pragmatic, documented approximation good enough for the "tapered
    /// arrow" visual style.
    private func strokeTapered(context: CGContext, thickness: CGFloat, tapered: Bool, draw: () -> Void) {
        guard tapered else {
            context.setLineWidth(thickness)
            draw()
            return
        }
        // Without decomposing the path here (draw() only emits path
        // commands), approximate tapering by simply using a slightly
        // thinner overall stroke width plus a soft round cap, which reads
        // as "narrower/tapered" next to the non-tapered default without
        // requiring this method to know the path's point list. A precise
        // per-segment taper is left as a documented follow-up alongside the
        // tiling TODO in `CanvasRenderer`.
        context.setLineWidth(thickness * 0.78)
        context.setLineCap(.round)
        draw()
    }

    // MARK: - Line

    private func drawLine(_ annotation: Annotation, style: StyleReader, into context: CGContext) {
        let (start, end) = endpoints(annotation, style: style)
        let thickness = style.thickness
        let dash = style.lineDashStyle

        context.setStrokeColor(style.strokeColour)
        context.setLineWidth(thickness)
        context.setLineCap(dash.lineCap)
        if let pattern = dash.dashPattern(forThickness: thickness) { context.setLineDash(phase: 0, lengths: pattern) }
        if style.hasShadow { applyShadowPass(context) }

        let points = style.isHandDrawn ? HandDrawnPath.jittered(from: start, to: end, seed: style.handDrawnSeed) : [start, end]
        context.addLines(between: points)
        context.strokePath()
    }

    // MARK: - Rectangle

    private func drawRectangle(_ annotation: Annotation, style: StyleReader, into context: CGContext) {
        let rect = annotation.frame.cgRect
        let radius = style.cgFloat(AnnotationStyleKeys.cornerRadius, default: 0)
        let path: CGPath
        if style.isHandDrawn {
            let corners = [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.minY)
            ]
            let jittered = HandDrawnPath.jittered(polyline: corners, seed: style.handDrawnSeed)
            path = ShapeGeometry.closedPath(jittered)
        } else {
            path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        strokeAndFill(path, style: style, into: context)
    }

    // MARK: - Ellipse

    private func drawEllipse(_ annotation: Annotation, style: StyleReader, into context: CGContext) {
        let rect = annotation.frame.cgRect
        let path: CGPath
        if style.isHandDrawn {
            // Approximate a wobbly ellipse outline by jittering points
            // sampled around a true ellipse, rather than jittering a
            // 4-corner box (which would look like a rounded rectangle).
            let samples = 24
            var points: [CGPoint] = []
            for i in 0...samples {
                let t = 2 * Double.pi * Double(i) / Double(samples)
                points.append(CGPoint(x: rect.midX + (rect.width / 2) * CGFloat(cos(t)), y: rect.midY + (rect.height / 2) * CGFloat(sin(t))))
            }
            let jittered = HandDrawnPath.jittered(polyline: points, seed: style.handDrawnSeed, amplitude: 1.2, subdivisionsPerSegment: 1)
            path = ShapeGeometry.closedPath(jittered)
        } else {
            path = CGPath(ellipseIn: rect, transform: nil)
        }
        strokeAndFill(path, style: style, into: context)
    }

    // MARK: - Polygon (polygon / star / hexagon / bracket / brace)

    private func drawPolygon(_ annotation: Annotation, style: StyleReader, into context: CGContext) {
        let rect = annotation.frame.cgRect
        let variant = style.string(AnnotationStyleKeys.polygonVariant, default: "polygon") ?? "polygon"

        switch variant {
        case "star":
            let points = style.typeDataInt(AnnotationStyleKeys.pointCount, default: 5)
            let path = ShapeGeometry.closedPath(ShapeGeometry.starPoints(in: rect, points: max(points, 3)))
            strokeAndFill(path, style: style, into: context)
        case "hexagon":
            let path = ShapeGeometry.closedPath(ShapeGeometry.regularPolygonPoints(in: rect, sides: 6))
            strokeAndFill(path, style: style, into: context)
        case "bracket":
            let path = ShapeGeometry.bracketPath(in: rect, opensRight: true, tickLength: min(rect.width, 24))
            context.addPath(path)
            context.setStrokeColor(style.strokeColour)
            context.setLineWidth(style.thickness)
            context.strokePath()
        case "brace":
            let path = ShapeGeometry.bracePath(in: rect, opensRight: true, pointDepth: min(rect.width, 20))
            context.addPath(path)
            context.setStrokeColor(style.strokeColour)
            context.setLineWidth(style.thickness)
            context.strokePath()
        case "calloutBubble":
            drawCalloutBubble(rect: rect, style: style, into: context)
        default: // free/regular polygon
            let explicit = style.explicitPoints
            let points = explicit ?? ShapeGeometry.regularPolygonPoints(in: rect, sides: max(style.typeDataInt(AnnotationStyleKeys.pointCount, default: 5), 3))
            let path = ShapeGeometry.closedPath(points)
            strokeAndFill(path, style: style, into: context)
        }
    }

    private func drawCalloutBubble(rect: CGRect, style: StyleReader, into context: CGContext) {
        let radius = style.cgFloat(AnnotationStyleKeys.cornerRadius, default: 10)
        let bubblePath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let mutable = CGMutablePath()
        mutable.addPath(bubblePath)
        if let anchor = style.typeDataPoint(AnnotationStyleKeys.calloutPointerAnchor) {
            mutable.addPath(CalloutPointer.trianglePath(bubbleRect: rect, pointerTarget: anchor))
        }
        strokeAndFill(mutable, style: style, into: context)
    }

    private func strokeAndFill(_ path: CGPath, style: StyleReader, into context: CGContext) {
        if style.hasShadow {
            // Cast the drop shadow from whichever pass runs first (fill, or
            // the stroke itself if there's no fill) and explicitly clear it
            // before the second pass so an outlined-and-filled shape
            // doesn't cast a doubled-up shadow from both passes.
            applyShadowPass(context)
        }
        if let fill = style.fillColour {
            context.addPath(path)
            context.setFillColor(fill)
            context.fillPath()
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
        context.addPath(path)
        context.setStrokeColor(style.strokeColour)
        context.setLineWidth(style.thickness)
        let dash = style.lineDashStyle
        context.setLineCap(dash.lineCap)
        context.setLineJoin(.round)
        if let pattern = dash.dashPattern(forThickness: style.thickness) { context.setLineDash(phase: 0, lengths: pattern) }
        context.strokePath()
    }

    // MARK: - Freehand

    private func drawFreehand(_ annotation: Annotation, style: StyleReader, into context: CGContext) {
        guard let points = style.explicitPoints, points.count > 1 else { return }
        context.setStrokeColor(style.strokeColour)
        context.setLineWidth(style.thickness)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if style.hasShadow { applyShadowPass(context) }
        context.addLines(between: points)
        context.strokePath()
    }

    // MARK: - Highlighter

    private func drawHighlighter(_ annotation: Annotation, style: StyleReader, into context: CGContext) {
        // A translucent marker stroke: the spec calls for a fixed marker
        // opacity feel independent of the object's own `opacity` field
        // (which still applies on top via the outer `context.setAlpha`
        // already pushed in `draw(_:canvasSize:source:into:)`).
        let markerOpacity: CGFloat = 0.38
        let capStyleRaw = style.string(AnnotationStyleKeys.capStyle, default: "round") ?? "round"
        let cap: CGLineCap = capStyleRaw == "square" ? .square : (capStyleRaw == "butt" ? .butt : .round)

        context.setBlendMode(.multiply)
        context.setStrokeColor(style.strokeColour.copy(alpha: markerOpacity) ?? style.strokeColour)
        context.setLineCap(cap)
        context.setLineJoin(.round)

        let smartTextHeight = style.bool(AnnotationStyleKeys.smartTextHeight, default: true)
        let thickness = smartTextHeight ? max(annotation.frame.height, style.thickness) : style.thickness
        context.setLineWidth(thickness)

        if let points = style.explicitPoints, points.count > 1 {
            context.addLines(between: points)
        } else {
            let rect = annotation.frame.cgRect
            let y = rect.midY
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.strokePath()
    }

    // MARK: - Spotlight

    /// Opposite model of highlight: the focus region (`annotation.frame`)
    /// stays normal; everything else on the canvas dims (and optionally
    /// blurs). Implemented as an even-odd filled overlay covering the whole
    /// canvas with a hole cut out at the focus region, rather than trying to
    /// "un-dim" a rect after dimming everything — this way there's exactly
    /// one dim layer and no double-compositing seam at the focus edge.
    private func drawSpotlight(_ annotation: Annotation, style: StyleReader, canvasSize: CaptureSize, into context: CGContext) {
        let intensity = style.double(AnnotationStyleKeys.intensity, default: 0.55)
        let feather = style.cgFloat(AnnotationStyleKeys.feather, default: 24)
        let shape = style.string(AnnotationStyleKeys.spotlightShape, default: "rectangle") ?? "rectangle"
        let canvasRect = CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
        let focusRect = annotation.frame.cgRect

        context.saveGState()
        let outerPath = CGMutablePath()
        outerPath.addRect(canvasRect)
        let holePath: CGPath = shape == "ellipse" ? CGPath(ellipseIn: focusRect, transform: nil) : CGPath(rect: focusRect, transform: nil)
        outerPath.addPath(holePath)

        if feather > 0 {
            // Feathering the hard cutout is approximated with a radial
            // gradient mask around the focus rect's edge rather than a true
            // Gaussian-blurred alpha mask (which would need an offscreen
            // pass) — see the CanvasRenderer tiling TODO for the general
            // note about offscreen-pass-heavy effects in this renderer.
            context.addPath(outerPath)
            context.clip(using: .evenOdd)
            context.setFillColor(CGColor(gray: 0, alpha: CGFloat(intensity)))
            context.fill(canvasRect)
            drawFeatheredRing(around: focusRect, shape: shape, feather: feather, intensity: intensity, into: context)
        } else {
            context.addPath(outerPath)
            context.setFillColor(CGColor(gray: 0, alpha: CGFloat(intensity)))
            context.fillPath(using: .evenOdd)
        }
        context.restoreGState()
    }

    private func drawFeatheredRing(around rect: CGRect, shape: String, feather: CGFloat, intensity: Double, into context: CGContext) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceGray(),
            colors: [CGColor(gray: 0, alpha: CGFloat(intensity)), CGColor(gray: 0, alpha: 0)] as CFArray,
            locations: [0, 1]
        ) else { return }

        context.saveGState()
        let outerRect = rect.insetBy(dx: -feather, dy: -feather)
        let ringPath = CGMutablePath()
        if shape == "ellipse" {
            ringPath.addEllipse(in: outerRect)
            ringPath.addEllipse(in: rect)
        } else {
            ringPath.addRect(outerRect)
            ringPath.addRect(rect)
        }
        context.addPath(ringPath)
        context.clip(using: .evenOdd)
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: min(rect.width, rect.height) / 2,
            endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: max(outerRect.width, outerRect.height) / 2,
            options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    // MARK: - Counter

    private func drawCounter(_ annotation: Annotation, style: StyleReader, into context: CGContext) {
        let format = CounterFormat(rawValue: style.typeDataString(AnnotationStyleKeys.counterFormat, default: "numeric") ?? "numeric") ?? .numeric
        let start = style.typeDataInt(AnnotationStyleKeys.counterStartNumber, default: 1)
        let resolvedIndex = style.typeDataInt(AnnotationStyleKeys.counterResolvedIndex, default: 0)
        let customLabels = style.typeDataStringArray(AnnotationStyleKeys.counterCustomLabels)
        let label = CounterFormatter.label(format: format, startNumber: start, zeroBasedIndex: resolvedIndex, customLabels: customLabels)

        let rect = annotation.frame.cgRect
        let fill = style.fillColour ?? style.strokeColour
        context.setFillColor(fill)
        context.addPath(CGPath(ellipseIn: rect, transform: nil))
        context.fillPath()

        if style.thickness > 0, style.string(AnnotationStyleKeys.lineStyle) != nil {
            context.addPath(CGPath(ellipseIn: rect, transform: nil))
            context.setStrokeColor(style.strokeColour)
            context.setLineWidth(style.thickness)
            context.strokePath()
        }

        let textColour = SimpleTextDrawing.readableTextColour(against: fill)
        SimpleTextDrawing.drawCentered(label, in: rect, pointSize: rect.height * 0.55, colour: textColour, into: context)
    }

    // MARK: - Magnifier / Loupe

    private func drawMagnifier(_ annotation: Annotation, style: StyleReader, source: SourceContext, into context: CGContext) {
        let lensRect = annotation.frame.cgRect
        let zoom = style.typeDataCGFloat(AnnotationStyleKeys.magnifierZoomFactor, default: 2)
        let borderWidth = style.typeDataCGFloat(AnnotationStyleKeys.magnifierBorderWidth, default: 3)
        let showsConnector = style.typeDataBool(AnnotationStyleKeys.magnifierShowsConnector, default: true)
        let sourceRegion = style.typeDataRect(AnnotationStyleKeys.magnifierSourceRect) ?? CaptureRect(
            x: annotation.frame.midX - annotation.frame.width / (2 * zoom),
            y: annotation.frame.midY - annotation.frame.height / (2 * zoom),
            width: annotation.frame.width / zoom,
            height: annotation.frame.height / zoom
        )

        context.saveGState()
        let clipPath = CGPath(ellipseIn: lensRect, transform: nil)
        context.addPath(clipPath)
        context.clip()

        if let sourceImage = source.sourceImage {
            // Map sourceRegion (in canvas coords, relative to where the
            // source image is placed) to the source image's own pixel
            // space, then draw that crop scaled up to fill lensRect.
            //
            // NOTE on coordinate convention: `CGImage.cropping(to:)` takes
            // its rect in the image's own top-left-origin, y-down pixel
            // space — the SAME convention `CaptureRect`/canvas points use
            // (see `Rendering/CanvasRenderer.swift`'s coordinate doc
            // comment) — unlike `CIImage`, which is bottom-left-origin/
            // y-up (see `RedactionRenderer.canvasRectToCIImageSpace`'s doc
            // comment for that contrast). So, unlike the redaction path,
            // no y-flip is applied here. Still worth a real-device sanity
            // check alongside the redaction coordinate math, since this
            // whole package has never been compiled (see
            // `docs/ARCHITECTURE.md`'s "critical environment constraint").
            let placement = source.sourcePlacement
            let scaleX = CGFloat(sourceImage.width) / max(placement.width, 1)
            let scaleY = CGFloat(sourceImage.height) / max(placement.height, 1)
            let cropInImagePixels = CGRect(
                x: (sourceRegion.x - placement.x) * scaleX,
                y: (sourceRegion.y - placement.y) * scaleY,
                width: sourceRegion.width * scaleX,
                height: sourceRegion.height * scaleY
            ).integral

            if let cropped = sourceImage.cropping(to: cropInImagePixels.intersection(CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height))) {
                context.draw(cropped, in: lensRect)
            } else {
                context.setFillColor(CGColor(gray: 0.5, alpha: 1))
                context.fill(lensRect)
            }
        } else {
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(lensRect)
        }
        context.restoreGState()

        if showsConnector {
            context.saveGState()
            context.setStrokeColor(style.strokeColour.copy(alpha: 0.6) ?? style.strokeColour)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.move(to: CGPoint(x: sourceRegion.midX, y: sourceRegion.midY))
            context.addLine(to: CGPoint(x: lensRect.midX, y: lensRect.midY))
            context.strokePath()
            context.restoreGState()
        }

        if style.hasShadow { applyShadowPass(context) }
        context.addPath(clipPath)
        context.setStrokeColor(style.strokeColour)
        context.setLineWidth(borderWidth)
        context.strokePath()
    }

    // MARK: - Stamp

    private func drawStamp(_ annotation: Annotation, style: StyleReader, into context: CGContext) {
        let symbol = style.typeDataString(AnnotationStyleKeys.stampSymbol, default: "check") ?? "check"
        StampSymbols.draw(symbol, in: annotation.frame.cgRect, colour: style.strokeColour, into: context)
    }

    // MARK: - Cursor

    private func drawCursor(_ annotation: Annotation, style: StyleReader, into context: CGContext) {
        let pointerType = style.typeDataString(AnnotationStyleKeys.cursorPointerType, default: "arrow") ?? "arrow"
        let clickHalo = style.typeDataBool(AnnotationStyleKeys.cursorClickHalo, default: false)
        let rect = annotation.frame.cgRect

        if clickHalo {
            context.saveGState()
            context.setFillColor(style.strokeColour.copy(alpha: 0.25) ?? style.strokeColour)
            let haloRect = rect.insetBy(dx: -rect.width * 0.4, dy: -rect.height * 0.4)
            context.addPath(CGPath(ellipseIn: haloRect, transform: nil))
            context.fillPath()
            context.restoreGState()
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(1)

        let path = CGMutablePath()
        switch pointerType {
        case "hand", "ibeam", "crosshair", "resize", "custom":
            // Simplified generic pointer glyph shared by every non-arrow
            // type for now — distinct per-type glyph art is a documented
            // follow-up (these are cosmetic stand-ins, not semantic data).
            path.addRect(rect.insetBy(dx: rect.width * 0.3, dy: 0))
        default: // "arrow" — classic macOS cursor silhouette, simplified.
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.62))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.68))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.maxY))
            path.closeSubpath()
        }
        context.addPath(path)
        context.fillPath()
        context.addPath(path)
        context.strokePath()
    }

    // MARK: - Shadow

    private func applyShadowPass(_ context: CGContext) {
        context.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4, color: CGColor(gray: 0, alpha: 0.35))
    }
}
