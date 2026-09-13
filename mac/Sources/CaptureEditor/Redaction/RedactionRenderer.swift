import CaptureCore
import CoreGraphics
import CoreImage
import Foundation

/// Supplies the composited raster content beneath the Redactions layer
/// (Source media + Appended image objects — see
/// `Rendering/CanvasRenderer.swift`'s layer stack) so `RedactionRenderer`
/// can filter it. `CanvasRenderer` is the only intended implementer/caller
/// — it knows how to produce a pixel snapshot of what it has drawn so far
/// (see `CanvasRenderer`'s doc comment on `context.makeImage()`-based
/// snapshotting and its coordinate-flip caveat).
public protocol RedactionSourceProviding {
    /// Returns a `CGImage` covering at least `rect` (canvas points,
    /// top-left origin, y-down — see `CanvasRenderer`'s coordinate
    /// convention doc comment), padded by at least `padding` points on
    /// every side where the canvas bounds allow it (filters like Gaussian
    /// blur need surrounding context to avoid a dark/transparent fringe at
    /// the redaction's edge). Also returns the exact rect, in the same
    /// canvas-point coordinates, that the returned image covers (it may be
    /// smaller than requested near canvas edges).
    func snapshot(coveringAtLeast rect: CGRect, paddedBy padding: CGFloat) -> (image: CGImage, coveredRect: CGRect)?
}

/// Real, pixel-level redaction rendering (Part III `04_privacy_redaction.md`)
/// via CoreImage. Implements the four raster redaction modes; `.textOnly`
/// and `.objectRemoval` are documented partial implementations — see their
/// method doc comments for exactly what's missing and why.
public struct RedactionRenderer {
    private let ciContext: CIContext

    /// A caller may supply a shared `CIContext` (CoreImage recommends
    /// reusing one `CIContext` across many filter operations — it owns a
    /// Metal/GPU command queue and compiled-shader cache that's expensive
    /// to rebuild per redaction). Defaults to a private one if the caller
    /// doesn't have a shared instance handy.
    public init(ciContext: CIContext = CIContext()) {
        self.ciContext = ciContext
    }

    public func render(_ annotation: Annotation, source: RedactionSourceProviding, into context: CGContext) {
        guard !annotation.hidden else { return }
        let style = StyleReader(annotation)
        let mode = RedactionMode(rawValue: style.typeDataString(AnnotationStyleKeys.redactionMode, default: RedactionMode.gaussianBlur.rawValue) ?? RedactionMode.gaussianBlur.rawValue) ?? .gaussianBlur
        let rect = annotation.frame.cgRect

        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(CGFloat(annotation.opacity))
        applyRotation(annotation, into: context)

        switch mode {
        case .solid:
            drawSolid(rect: rect, style: style, into: context)

        case .gaussianBlur:
            let radius = style.typeDataCGFloat(AnnotationStyleKeys.redactionBlurRadius, default: 18)
            drawFiltered(rect: rect, style: style, source: source, into: context) { image in
                gaussianBlur(image, radius: radius)
            }

        case .regularMosaic:
            let blockSize = max(style.typeDataCGFloat(AnnotationStyleKeys.redactionBlockSize, default: 14), 2)
            drawFiltered(rect: rect, style: style, source: source, into: context) { image in
                pixellate(image, blockSize: blockSize)
            }

        case .secureRandomizedPixelation:
            let blockSize = max(style.typeDataCGFloat(AnnotationStyleKeys.redactionBlockSize, default: 14), 2)
            let seed = style.typeDataUInt64(AnnotationStyleKeys.redactionRandomSeed, default: 1)
            drawFiltered(rect: rect, style: style, source: source, into: context) { image in
                securePixelation(image, blockSize: blockSize, seed: seed)
            }

        case .textOnly:
            drawTextOnlyRedaction(rect: rect, style: style, into: context)

        case .objectRemoval:
            drawObjectRemovalPlaceholder(rect: rect, style: style, source: source, into: context)
        }
    }

    private func applyRotation(_ annotation: Annotation, into context: CGContext) {
        guard annotation.rotation != 0 else { return }
        let center = CGPoint(x: annotation.frame.midX, y: annotation.frame.midY)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: CGFloat(annotation.rotation * .pi / 180))
        context.translateBy(x: -center.x, y: -center.y)
    }

    // MARK: - Solid

    private func drawSolid(rect: CGRect, style: StyleReader, into context: CGContext) {
        let colour = CGColor.capture_parse(hex: style.typeDataString(AnnotationStyleKeys.redactionSolidColour)) ?? CGColor(gray: 0, alpha: 1)
        context.setFillColor(colour)
        context.fill(rect)
    }

    // MARK: - Filtered modes (blur / mosaic / secure pixelation)

    /// Common plumbing for every CoreImage-backed mode: ask `source` for a
    /// padded snapshot, run `filter`, crop back to exactly `rect`, and draw
    /// the result. Fails closed to a solid redaction on any error — a
    /// redaction must never silently leave the original pixels visible.
    private func drawFiltered(rect: CGRect, style: StyleReader, source: RedactionSourceProviding, into context: CGContext, filter: (CIImage) -> CIImage?) {
        let padding: CGFloat = 24
        guard let (rawImage, coveredRect) = source.snapshot(coveringAtLeast: rect, paddedBy: padding) else {
            drawSolid(rect: rect, style: style, into: context)
            return
        }
        let ciImage = CIImage(cgImage: rawImage)
        guard let filtered = filter(ciImage) else {
            drawSolid(rect: rect, style: style, into: context)
            return
        }

        let cropInCIImageSpace = canvasRectToCIImageSpace(rect, coveredRect: coveredRect, rawImagePixelSize: CGSize(width: rawImage.width, height: rawImage.height))
        let cropped = filtered.cropped(to: cropInCIImageSpace)
        guard let output = ciContext.createCGImage(cropped, from: cropped.extent) else {
            drawSolid(rect: rect, style: style, into: context)
            return
        }

        context.saveGState()
        context.clip(to: rect)
        context.draw(output, in: rect)
        context.restoreGState()
    }

    /// `CIImage`'s documented coordinate space has its origin at the
    /// LOWER-left, y increasing upward — unlike `CaptureRect`/canvas points,
    /// which follow the screen/DOM convention of top-left origin, y
    /// increasing downward (see `Rendering/CanvasRenderer.swift`'s
    /// coordinate-convention doc comment). This converts a canvas-point
    /// rect into the `CIImage`'s pixel space accordingly.
    ///
    /// **This is the single trickiest piece of coordinate math in this
    /// file and has NOT been validated against a real compiler/runtime**
    /// (see `docs/ARCHITECTURE.md`'s "critical environment constraint" —
    /// this whole package has never been built). Verify it on a real Mac
    /// with a deliberately asymmetric test image (e.g. a marker pixel in
    /// one corner of the source, and a redaction box placed off-center)
    /// before trusting redaction placement in production. A coordinate-flip
    /// bug here means a redaction ends up over the WRONG region of the
    /// screenshot — a privacy bug, not merely a visual one — so this is the
    /// highest-priority spot in `CaptureEditor` to hand-verify first.
    private func canvasRectToCIImageSpace(_ rect: CGRect, coveredRect: CGRect, rawImagePixelSize: CGSize) -> CGRect {
        let scaleX = rawImagePixelSize.width / max(coveredRect.width, 0.0001)
        let scaleY = rawImagePixelSize.height / max(coveredRect.height, 0.0001)
        let xInPixels = (rect.minX - coveredRect.minX) * scaleX
        let yFromTopInPixels = (rect.minY - coveredRect.minY) * scaleY
        let yInPixels = rawImagePixelSize.height - yFromTopInPixels - rect.height * scaleY
        return CGRect(x: xInPixels, y: yInPixels, width: rect.width * scaleX, height: rect.height * scaleY)
    }

    /// Gaussian blur via `CIGaussianBlur`. Blur expands the image's extent
    /// to effectively infinite; clamping to the (already padding-extended)
    /// input extent before cropping avoids sampling transparent/undefined
    /// pixels at the crop boundary, which would otherwise show up as a
    /// faint dark or transparent fringe right at the redaction's edge.
    private func gaussianBlur(_ image: CIImage, radius: CGFloat) -> CIImage? {
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        return output.clampedToExtent().cropped(to: image.extent)
    }

    /// Regular mosaic/pixelation via `CIPixellate` — every `blockSize` x
    /// `blockSize` square becomes one flat average colour.
    private func pixellate(_ image: CIImage, blockSize: CGFloat) -> CIImage? {
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(blockSize, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: image.extent.midX, y: image.extent.midY), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage else { return nil }
        return output.cropped(to: image.extent)
    }

    /// "Secure randomized pixelation": start from a regular `CIPixellate`
    /// mosaic (flat block-average colours, which already destroys
    /// glyph/edge detail within each block), then additionally shuffle
    /// block *positions* within small local neighbourhoods using a seeded
    /// permutation (`shuffleBlocks`), so the result isn't simply the
    /// original content downsampled in its original positions.
    ///
    /// This specifically targets the well-known weakness of PLAIN
    /// pixelation/mosaic redaction: because each block's colour is the
    /// true average of the pixels it covers, and blocks stay in their
    /// original grid position, an attacker who can guess the underlying
    /// content's alphabet (e.g. digits in a redacted price, characters in
    /// a short redacted word rendered in a known font) can sometimes
    /// brute-force which candidate — rendered as an image and pixellated
    /// the same way — reproduces the observed block colours in the
    /// observed positions. Shuffling block positions breaks the
    /// "positions are informative" half of that attack: even a
    /// perfectly-recovered multiset of block-average colours doesn't tell
    /// you their original spatial arrangement.
    ///
    /// **This is NOT cryptographic security and is not a formal, proven
    /// guarantee** — see `SeededGenerator`'s doc comment. It is a
    /// documented mitigation against casual/naive reconstruction attempts,
    /// matching how tools like Xnapper/Snagit market "secure" pixelation
    /// as meaningfully harder to reverse than plain pixelation, not as
    /// information-theoretically irreversible. Block AVERAGE colours
    /// remain visible (just repositioned), so very low-entropy content
    /// (e.g. an almost-uniform field with one distinctly-coloured block)
    /// can still leak coarse shape information. For genuinely sensitive
    /// content, prefer `.solid`.
    private func securePixelation(_ image: CIImage, blockSize: CGFloat, seed: UInt64) -> CIImage? {
        guard let mosaic = pixellate(image, blockSize: blockSize) else { return nil }
        guard let mosaicCGImage = ciContext.createCGImage(mosaic, from: mosaic.extent) else { return nil }
        guard let shuffled = shuffleBlocks(mosaicCGImage, blockSize: blockSize, seed: seed) else { return nil }
        return CIImage(cgImage: shuffled)
    }

    /// Swaps each `blockSize`-pixel block with a random OTHER block drawn
    /// from a small local neighbourhood (`neighbourhoodRadius` blocks in
    /// each direction), using `SeededGenerator` so the same seed always
    /// reproduces the exact same shuffle (needed for stable
    /// undo/redo/re-export — see `SeededGenerator`'s doc comment).
    /// Deliberately local rather than a fully global permutation: it's
    /// enough to break exact block-position alignment, while keeping the
    /// redacted area's overall footprint visually "roughly there" instead
    /// of scattering it into unrelated noise. Only ever swaps blocks
    /// within this one redaction's own cropped image, never with blocks
    /// from elsewhere in the screenshot.
    ///
    /// Uses a plain RGBA8 output `CGContext` (rather than trying to match
    /// the input `CGImage`'s own colour space/bitmap layout) for
    /// `CGContext.draw` compatibility — the standard, well-supported
    /// pattern for this kind of pixel-blit work.
    private func shuffleBlocks(_ image: CGImage, blockSize: CGFloat, seed: UInt64) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let block = max(Int(blockSize.rounded()), 2)
        let colsCount = max(Int(ceil(Double(width) / Double(block))), 1)
        let rowsCount = max(Int(ceil(Double(height) / Double(block))), 1)
        guard colsCount > 1 || rowsCount > 1 else { return image }

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        // NOTE: this context uses CGContext's own default (unflipped,
        // lower-left-origin) coordinate space, and `sourceRect`/`destRect`
        // below use the SAME row/col -> y mapping for both extracting each
        // source block (`image.cropping(to:)`) and placing it
        // (`context.draw(_:in:)`), so the shuffle itself is internally
        // consistent regardless of which convention is "correct" — if the
        // two conventions actually differ (a classic CGImage-vs-CGContext
        // flip gotcha), the visible symptom on real hardware would be the
        // WHOLE redacted block visibly upside-down as one piece, not
        // scrambled pixels within it, and the fix is a single `height -`
        // adjustment applied uniformly here. Verify alongside
        // `canvasRectToCIImageSpace` above.
        var generator = SeededGenerator(seed: seed)
        var order = Array(0..<(colsCount * rowsCount))
        let neighbourhoodRadius = 2
        for row in 0..<rowsCount {
            for col in 0..<colsCount {
                let index = row * colsCount + col
                let minRow = max(0, row - neighbourhoodRadius)
                let maxRow = min(rowsCount - 1, row + neighbourhoodRadius)
                let minCol = max(0, col - neighbourhoodRadius)
                let maxCol = min(colsCount - 1, col + neighbourhoodRadius)
                let swapRow = Int.random(in: minRow...maxRow, using: &generator)
                let swapCol = Int.random(in: minCol...maxCol, using: &generator)
                order.swapAt(index, swapRow * colsCount + swapCol)
            }
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        for row in 0..<rowsCount {
            for col in 0..<colsCount {
                let destIndex = row * colsCount + col
                let sourceIndex = order[destIndex]
                let sourceRow = sourceIndex / colsCount
                let sourceCol = sourceIndex % colsCount

                let destRect = CGRect(x: col * block, y: row * block, width: block, height: block).intersection(bounds)
                let sourceRect = CGRect(x: sourceCol * block, y: sourceRow * block, width: block, height: block).intersection(bounds)
                guard !destRect.isEmpty, !sourceRect.isEmpty, let piece = image.cropping(to: sourceRect) else { continue }
                context.draw(piece, in: destRect)
            }
        }
        return context.makeImage()
    }

    // MARK: - Text-only

    /// "Text-only redact: detect text, redact only glyph areas." OCR/glyph
    /// detection is deliberately NOT performed by this module —
    /// `CaptureEditor` has no text-recognition pipeline; that belongs to
    /// whichever module implements Part I §15 "OCR and Vision" (not yet
    /// built — see `docs/IMPLEMENTATION_STATUS.md`). This renderer only
    /// consumes already-detected glyph rects if an upstream OCR pass wrote
    /// them into `AnnotationStyleKeys.redactionGlyphRects` (an array of
    /// `CaptureRect`, in canvas coordinates). Absent that, it fails CLOSED
    /// — solid-redacting the entire annotation frame — rather than ever
    /// leaving the original text visible because glyph detection hasn't
    /// run yet.
    private func drawTextOnlyRedaction(rect: CGRect, style: StyleReader, into context: CGContext) {
        guard case .array(let rectsJSON)? = style.typeData?[AnnotationStyleKeys.redactionGlyphRects], !rectsJSON.isEmpty else {
            drawSolid(rect: rect, style: style, into: context)
            return
        }
        let colour = CGColor.capture_parse(hex: style.typeDataString(AnnotationStyleKeys.redactionSolidColour)) ?? CGColor(gray: 0, alpha: 1)
        context.setFillColor(colour)
        for value in rectsJSON {
            guard case .object(let obj) = value,
                  let x = obj["x"]?.doubleValue, let y = obj["y"]?.doubleValue,
                  let w = obj["width"]?.doubleValue, let h = obj["height"]?.doubleValue else { continue }
            let glyphRect = CGRect(x: x, y: y, width: w, height: h).intersection(rect)
            guard !glyphRect.isEmpty else { continue }
            context.fill(glyphRect)
        }
    }

    // MARK: - Object removal

    /// "Object removal: remove selected content and reconstruct simple
    /// background." True content-aware inpainting (seam carving, patch
    /// match, or an ML inpainting model) is a substantial standalone
    /// feature and is **NOT implemented** here. As a documented
    /// placeholder — so the underlying content is at minimum never left
    /// visible — this reuses the Gaussian blur path at a large fixed
    /// radius, which CONCEALS but does not RECONSTRUCT anything. Do not
    /// describe this mode as "reconstruction" in user-facing copy until a
    /// real inpainting implementation replaces this.
    private func drawObjectRemovalPlaceholder(rect: CGRect, style: StyleReader, source: RedactionSourceProviding, into context: CGContext) {
        drawFiltered(rect: rect, style: style, source: source, into: context) { image in
            gaussianBlur(image, radius: 48)
        }
    }
}
