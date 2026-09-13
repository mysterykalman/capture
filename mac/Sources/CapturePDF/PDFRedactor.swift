import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// Semantic (burn-in) PDF redaction (Part I §16: "PDF: semantic permanent
/// redaction when PDFKit workflow permits").
///
/// PDFKit does not expose a content-stream API to selectively delete text
/// runs/glyphs under a rect — `PDFAnnotation`s only draw an overlay and the
/// original text remains selectable/extractable underneath, which is
/// exactly the "trivially-restorable" failure mode Part I §16 warns against
/// ("Redactions must be flattened... Do not accidentally include original
/// hidden pixels/layers in an export marketed as secure"). The only
/// approach that is actually safe with PDFKit alone is to **rasterize** any
/// page containing a redaction: render the full page to a bitmap at a
/// specified resolution, paint the redaction rects solid, and replace that
/// page's content with the flattened image. This necessarily also
/// rasterizes any text elsewhere on that same page (it stops being
/// selectable/copyable) — that is a real, disclosed trade-off, not a
/// limitation to hide from the user; `CaptureUI` should say so before this
/// runs (e.g. "Pages with redactions will no longer have selectable text").
public struct PDFRedactionRect: Sendable {
    public var pageIndex: Int
    /// In PDF page space (points, origin bottom-left), matching
    /// `PDFPage.bounds(for:)`.
    public var rect: CGRect

    public init(pageIndex: Int, rect: CGRect) {
        self.pageIndex = pageIndex
        self.rect = rect
    }
}

public enum PDFRedactionError: Error, Sendable {
    case invalidPageIndex
    case rasterizationFailed
}

public enum PDFRedactor {
    /// Returns a new `PDFDocument` where every page referenced by
    /// `redactions` has been rasterized with the given rects painted solid
    /// black, and pages with no redactions are left untouched (still
    /// vector/selectable).
    public static func applyRedactions(
        to document: PDFDocument,
        redactions: [PDFRedactionRect],
        scale: CGFloat = 2.0
    ) throws -> PDFDocument {
        let byPage = Dictionary(grouping: redactions, by: \.pageIndex)
        let output = PDFDocument()
        var outputIndex = 0

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            if let rectsForPage = byPage[pageIndex], !rectsForPage.isEmpty {
                let flattenedImage = try rasterize(page: page, redactions: rectsForPage.map(\.rect), scale: scale)
                guard let newPage = PDFPage(image: flattenedImage) else { throw PDFRedactionError.rasterizationFailed }
                output.insert(newPage, at: outputIndex)
            } else {
                // No redaction on this page — keep it as-is (still vector).
                output.insert(page.copy() as! PDFPage, at: outputIndex)
            }
            outputIndex += 1
        }
        return output
    }

    private static func rasterize(page: PDFPage, redactions: [CGRect], scale: CGFloat) throws -> NSImage {
        let pageBounds = page.bounds(for: .mediaBox)
        let pixelSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(pixelSize.width),
                height: Int(pixelSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw PDFRedactionError.rasterizationFailed
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pixelSize))

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        // Paint redaction rects solid black, converting from PDF page space
        // (already matches the pre-scale coordinate system used above).
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for rect in redactions {
            context.fill(rect)
        }

        guard let cgImage = context.makeImage() else { throw PDFRedactionError.rasterizationFailed }
        return NSImage(cgImage: cgImage, size: pageBounds.size)
    }
}
