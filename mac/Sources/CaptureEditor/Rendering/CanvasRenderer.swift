import CaptureCore
import CoreGraphics
import Foundation

/// Renders the full layered document model (Part I §12 "Editor Rendering
/// Architecture") into a caller-supplied `CGContext` at an arbitrary scale.
/// The same entry point is meant to drive both the live screen preview
/// (`CaptureUI` hands in a view-backed `CGContext` each frame) and the
/// flattened export pipeline (`Export/ExportRenderer.swift` hands in an
/// off-screen bitmap context at 1x/2x/3x).
///
/// **Fixed layer order (back to front) — not user-reorderable:**
/// ```text
/// Canvas
/// ├── Backdrop
/// ├── Source media
/// ├── Appended image objects
/// ├── Redactions
/// ├── Measurements
/// └── Vector annotations
/// ```
/// A given `Annotation`'s own `zIndex` only orders it against siblings
/// *within* its architectural layer (see `Document/EditorDocument.swift`'s
/// `RenderLayerGroup`) — e.g. two redactions can be reordered relative to
/// each other, but a redaction can never be drawn on top of a vector
/// annotation, because the spec fixes that stacking, not the user.
///
/// ## Coordinate convention (read this before touching any drawing code)
/// Every geometry type this renderer consumes (`CaptureRect`,
/// `Annotation.frame`, `EditorDocument.cropRect`/`canvasSize`) uses a
/// **top-left origin, y-increasing-downward** convention — the same one
/// `CaptureCore.ElementEvidence.rect` uses for DOM element bounds, and the
/// same one raw image/bitmap pixel data uses (row 0 = top row). This
/// renderer assumes the `CGContext` it is handed has ALREADY been set up so
/// that its current transform matches that convention (the standard AppKit
/// idiom: an `NSView` with `isFlipped == true`, or an explicitly
/// flipped CTM — `context.translateBy(x: 0, y: height);
/// context.scaleBy(x: 1, y: -1)` — established once by the caller before
/// `render(document:images:into:)` is invoked). `CanvasRenderer` itself
/// never flips or un-flips anything; it just draws directly using the
/// coordinates on the annotation/document models. Getting this flip set up
/// correctly is `CaptureUI`'s (live preview) and `ExportRenderer`'s
/// (offscreen bitmap) responsibility, not this type's.
public struct CanvasRenderer {
    /// Well-known image id for the primary captured/loaded source image,
    /// resolved through `ImageProviding`.
    public static let sourceImageID = "source"

    public struct RenderOptions {
        public var scale: CGFloat
        public var showSnapGuides: [SnapLine]
        public var renderHiddenAnnotations: Bool

        public init(scale: CGFloat = 1, showSnapGuides: [SnapLine] = [], renderHiddenAnnotations: Bool = false) {
            self.scale = scale
            self.showSnapGuides = showSnapGuides
            self.renderHiddenAnnotations = renderHiddenAnnotations
        }
    }

    /// Supplies decoded raster content for the Source media and Appended
    /// image object layers. `CaptureEditor` doesn't own image decoding or
    /// caching (that's `CaptureCapture`/`CaptureUI` territory, and for very
    /// large sources needs the tiled decode-on-demand approach called out
    /// in the TILING TODO below) — it only asks this protocol for a
    /// `CGImage` given an id.
    public protocol ImageProviding {
        func image(for id: String) -> CGImage?
    }

    private let redactionRenderer: RedactionRenderer
    private let annotationRenderer: AnnotationRenderer

    public init(redactionRenderer: RedactionRenderer = RedactionRenderer(), annotationRenderer: AnnotationRenderer = AnnotationRenderer()) {
        self.redactionRenderer = redactionRenderer
        self.annotationRenderer = annotationRenderer
    }

    /// Renders `document` into `context`.
    ///
    /// **TILING TODO** (Part I §12: "For extremely large scrolling
    /// captures: tile source image; decode visible regions only; maintain
    /// vector overlays independently; generate export in chunks if needed.
    /// Do not force a 400,000 px-tall image into one GPU texture."): this
    /// implementation renders the whole source image and every annotation
    /// in a single pass into whatever `CGContext` it is handed. That is
    /// correct and sufficient for ordinary screenshots, and it is also
    /// sufficient for CHUNKED EXPORT of a huge image — `ExportRenderer` can
    /// call this method repeatedly with `clipRect` set to one tile at a
    /// time and a correspondingly translated CTM, since every draw call
    /// here already respects `context`'s current clip — but there is no
    /// *viewport-driven, decode-on-demand* tile cache for a LIVE scrolling-
    /// capture editor view of a 400,000px source image. That needs an
    /// `ImageProviding` implementation backed by a real tile grid (e.g.
    /// `CGImageSourceCreateThumbnailAtIndex`/incremental region decode
    /// keyed by which tiles are currently visible) plus a
    /// `CATiledLayer`-style view, both of which are `CaptureUI` concerns
    /// informed by this renderer's fixed layer order — not something
    /// `CanvasRenderer` itself can own, since it has no notion of "what's
    /// currently visible" or a live view hierarchy. Left as a documented,
    /// load-bearing follow-up, not silently dropped.
    public func render(
        document: EditorDocument,
        images: ImageProviding,
        into context: CGContext,
        clipRect: CaptureRect? = nil,
        options: RenderOptions = RenderOptions()
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        if let clipRect {
            context.clip(to: clipRect.cgRect)
        }

        drawCanvas(document: document, into: context)
        drawBackdrop(document: document, into: context)
        let sourcePlacement = drawSourceMedia(document: document, images: images, into: context)
        drawAppendedImageObjects(document: document, images: images, into: context)
        drawRedactions(document: document, into: context)
        drawMeasurements(document: document, into: context)
        drawVectorAnnotations(document: document, images: images, sourcePlacement: sourcePlacement, options: options, into: context)

        if !options.showSnapGuides.isEmpty {
            drawSnapGuides(options.showSnapGuides, canvasSize: document.canvasSize, into: context)
        }
    }

    // MARK: - Canvas

    private func drawCanvas(document: EditorDocument, into context: CGContext) {
        // The Canvas layer itself is the expandable working area (Part III
        // "Canvas: expandable in all directions; transparent; configurable
        // colour..."). Its own fill is whatever the Backdrop paints next;
        // Canvas here just establishes there IS a bounded region — nothing
        // to draw yet beyond that the caller's `clipRect`/view bounds
        // already constrain drawing to `document.canvasSize`.
    }

    // MARK: - Backdrop

    private func drawBackdrop(document: EditorDocument, into context: CGContext) {
        let backdrop = document.backdrop
        let rect = CGRect(x: 0, y: 0, width: document.canvasSize.width, height: document.canvasSize.height)

        context.saveGState()
        defer { context.restoreGState() }

        switch backdrop.fill {
        case .transparent:
            break
        case .solid(let hex):
            guard let colour = CGColor.capture_parse(hex: hex) else { break }
            context.setFillColor(colour)
            context.fill(rect)
        case .gradient(let hexes, let angleDegrees):
            drawGradientBackdrop(rect: rect, hexes: hexes, angleDegrees: angleDegrees, into: context)
        case .blurredDesktopImage, .image:
            // Both need a decoded image via `ImageProviding`, which this
            // method doesn't currently receive (Backdrop drawing happens
            // before `drawSourceMedia` resolves `images`). Documented
            // follow-up: thread `images` through here too and, for
            // `.blurredDesktopImage`, reuse `RedactionRenderer`'s
            // `CIGaussianBlur` plumbing on the desktop snapshot. Falls back
            // to transparent rather than guessing at a placeholder colour.
            break
        }
    }

    private func drawGradientBackdrop(rect: CGRect, hexes: [String], angleDegrees: Double, into context: CGContext) {
        let colours = hexes.compactMap { CGColor.capture_parse(hex: $0) }
        guard colours.count >= 2, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours as CFArray, locations: nil) else { return }
        let radians = angleDegrees * .pi / 180
        let dx = CGFloat(cos(radians))
        let dy = CGFloat(sin(radians))
        let length = max(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = CGPoint(x: center.x - dx * length / 2, y: center.y - dy * length / 2)
        let end = CGPoint(x: center.x + dx * length / 2, y: center.y + dy * length / 2)
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
        context.restoreGState()
    }

    // MARK: - Source media

    /// Draws the (cropped) source image and returns the canvas rect it
    /// occupies, for later layers (`.magnifier`'s lens sampling,
    /// `RedactionRenderer`'s underlying-content snapshot) to map their own
    /// canvas-coordinate regions back into the source image's pixel space.
    @discardableResult
    private func drawSourceMedia(document: EditorDocument, images: ImageProviding, into context: CGContext) -> CaptureRect {
        let placement = sourcePlacement(for: document)
        guard let sourceImage = images.image(for: Self.sourceImageID) else { return placement }

        // `document.cropRect` is in the source image's own pixel space
        // (top-left origin, y-down — matching `CGImage.cropping(to:)`'s
        // convention, see `Tools/AnnotationRenderer.drawMagnifier`'s note
        // on that same convention).
        let cropRect = document.cropRect.cgRect
        let imageBounds = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        guard let cropped = sourceImage.cropping(to: cropRect.intersection(imageBounds)) else {
            context.saveGState()
            context.setFillColor(CGColor(gray: 0.8, alpha: 1))
            context.fill(placement.cgRect)
            context.restoreGState()
            return placement
        }

        context.saveGState()
        context.interpolationQuality = .high
        context.draw(cropped, in: placement.cgRect)
        context.restoreGState()
        return placement
    }

    /// Where the cropped source image lands on the canvas: anchored at the
    /// Backdrop's insets, top-left aligned, drawn at its natural (cropped)
    /// size. Centring/auto-balance within extra canvas space is a
    /// `CaptureUI` layout decision layered on top of `BackdropSettings` —
    /// this is the simplest placement rule that satisfies "Canvas:
    /// expandable... free positioning" without inventing alignment options
    /// `CaptureCore` doesn't model.
    private func sourcePlacement(for document: EditorDocument) -> CaptureRect {
        let insets = document.backdrop.insets
        return CaptureRect(
            x: insets.left,
            y: insets.top,
            width: document.cropRect.width,
            height: document.cropRect.height
        )
    }

    // MARK: - Appended image objects

    private func drawAppendedImageObjects(document: EditorDocument, images: ImageProviding, into context: CGContext) {
        let ordered = document.appendedImageObjects.filter { !$0.hidden }.sorted { $0.zIndex < $1.zIndex }
        for object in ordered {
            guard let image = images.image(for: object.imageId) else { continue }
            context.saveGState()
            context.setAlpha(CGFloat(object.opacity))
            if object.rotation != 0 {
                let center = CGPoint(x: object.frame.midX, y: object.frame.midY)
                context.translateBy(x: center.x, y: center.y)
                context.rotate(by: CGFloat(object.rotation * .pi / 180))
                context.translateBy(x: -center.x, y: -center.y)
            }

            let drawable: CGImage
            if let cropRect = object.cropRect, let cropped = image.cropping(to: cropRect.cgRect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))) {
                drawable = cropped
            } else {
                drawable = image
            }

            if object.cornerRadius > 0 {
                context.addPath(CGPath(roundedRect: object.frame.cgRect, cornerWidth: object.cornerRadius, cornerHeight: object.cornerRadius, transform: nil))
                context.clip()
            }
            if object.shadowOpacity > 0 {
                context.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: CGColor(gray: 0, alpha: CGFloat(object.shadowOpacity)))
            }
            context.draw(drawable, in: object.frame.cgRect)
            context.restoreGState()
        }
    }

    // MARK: - Redactions

    /// Snapshots `context`'s current contents (Source media + Appended
    /// image objects, already drawn by this point) so `RedactionRenderer`
    /// can filter them. Requires `context` to be a `CGBitmapContext` (true
    /// for `ExportRenderer`'s offscreen contexts always; true for a live
    /// preview only if `CaptureUI` renders into an offscreen buffer per
    /// frame rather than drawing directly into a `CALayer`-backed view's
    /// context — flagged clearly so that constraint isn't missed).
    private struct ContextSnapshotSource: RedactionSourceProviding {
        let context: CGContext
        let canvasSize: CaptureSize

        func snapshot(coveringAtLeast rect: CGRect, paddedBy padding: CGFloat) -> (image: CGImage, coveredRect: CGRect)? {
            guard let image = context.makeImage() else { return nil }
            let covered = CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
            return (image, covered)
        }
    }

    private func drawRedactions(document: EditorDocument, into context: CGContext) {
        let redactions = document.annotations
            .filter { $0.type == .redact }
            .sorted { $0.zIndex < $1.zIndex }
        guard !redactions.isEmpty else { return }

        let source = ContextSnapshotSource(context: context, canvasSize: document.canvasSize)
        for redaction in redactions {
            redactionRenderer.render(redaction, source: source, into: context)
        }
    }

    // MARK: - Measurements

    private func drawMeasurements(document: EditorDocument, into context: CGContext) {
        let measurements = document.annotations
            .filter { $0.type == .measurement }
            .sorted { $0.zIndex < $1.zIndex }
        for measurement in measurements {
            annotationRenderer.drawMeasurement(measurement, into: context)
        }
    }

    // MARK: - Vector annotations

    private func drawVectorAnnotations(document: EditorDocument, images: ImageProviding, sourcePlacement: CaptureRect, options: RenderOptions, into context: CGContext) {
        let sourceImage = images.image(for: Self.sourceImageID)
        let sourceContext = AnnotationRenderer.SourceContext(sourceImage: sourceImage, sourcePlacement: sourcePlacement)

        let vectors = document.annotations
            .filter { RenderLayerGroup.group(for: $0.type) == .vectorAnnotations }
            .filter { options.renderHiddenAnnotations || !$0.hidden }
            .sorted { $0.zIndex < $1.zIndex }

        for annotation in vectors {
            annotationRenderer.draw(annotation, canvasSize: document.canvasSize, source: sourceContext, into: context)
        }
    }

    // MARK: - Snap guides (debug/interactive overlay, not part of export)

    private func drawSnapGuides(_ guides: [SnapLine], canvasSize: CaptureSize, into context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(CGColor(red: 0.98, green: 0.29, blue: 0.55, alpha: 0.9))
        context.setLineWidth(1)
        for guide in guides {
            switch guide.axis {
            case .vertical:
                let range = guide.extent ?? 0...canvasSize.height
                context.move(to: CGPoint(x: guide.position, y: range.lowerBound))
                context.addLine(to: CGPoint(x: guide.position, y: range.upperBound))
            case .horizontal:
                let range = guide.extent ?? 0...canvasSize.width
                context.move(to: CGPoint(x: range.lowerBound, y: guide.position))
                context.addLine(to: CGPoint(x: range.upperBound, y: guide.position))
            }
            context.strokePath()
        }
    }
}
