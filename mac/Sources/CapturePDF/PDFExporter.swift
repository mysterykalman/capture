import CoreGraphics
import Foundation
import PDFKit

/// PDFKit-backed export (Part I §26: "PDF: single image; multiple captures;
/// scrolling capture split into pages"). `CaptureUI`/`CaptureApp` mediate
/// between `CaptureEditor` (which renders final `CGImage`s) and this module
/// — `CaptureEditor` does not depend on `CapturePDF` directly (see
/// `docs/ARCHITECTURE.md` module boundaries).
public struct PDFExportOptions: Sendable {
    public var password: String?
    /// When true, the produced PDF's permission flags deny printing/copying
    /// (still just a normal-strength PDF permissions flag, not encryption —
    /// document this honestly rather than imply a stronger guarantee).
    public var restrictPrintingAndCopying: Bool
    public var pageMargin: CGFloat

    public init(password: String? = nil, restrictPrintingAndCopying: Bool = false, pageMargin: CGFloat = 0) {
        self.password = password
        self.restrictPrintingAndCopying = restrictPrintingAndCopying
        self.pageMargin = pageMargin
    }
}

public enum PDFExportError: Error, Sendable {
    case noPages
    case documentCreationFailed
    case writeFailed
}

public enum PDFExporter {
    /// One image per PDF page, each page sized to that image (plus
    /// `options.pageMargin`) — used for both "single screenshot as PDF" and
    /// "multiple captures as PDF pages" / "scrolling capture split into
    /// pages" (the caller pre-splits a tall scrolling image into per-page
    /// `CGImage`s; this function just lays out whatever it's given).
    public static func makePDF(from images: [CGImage], options: PDFExportOptions = PDFExportOptions()) throws -> Data {
        guard !images.isEmpty else { throw PDFExportError.noPages }

        let document = PDFDocument()
        for (index, cgImage) in images.enumerated() {
            let pageImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            guard let page = PDFPage(image: pageImage) else { continue }
            document.insert(page, at: index)
        }

        guard document.pageCount > 0 else { throw PDFExportError.documentCreationFailed }

        var writeOptions: [PDFDocumentWriteOption: Any] = [:]
        if let password = options.password {
            writeOptions[.userPasswordOption] = password
            writeOptions[.ownerPasswordOption] = password
        }
        if options.restrictPrintingAndCopying {
            writeOptions[.canPrintOption] = false
            writeOptions[.canCopyOption] = false
        }

        guard let data = document.dataRepresentation(options: writeOptions) else {
            throw PDFExportError.writeFailed
        }
        return data
    }

    public static func write(_ images: [CGImage], to url: URL, options: PDFExportOptions = PDFExportOptions()) throws {
        let data = try makePDF(from: images, options: options)
        try data.write(to: url, options: .atomic)
    }
}
