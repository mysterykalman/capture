import CaptureCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportImageFormat: String, CaseIterable, Sendable {
    case png, jpeg, tiff

    public var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        }
    }

    public var supportsLossyQuality: Bool { self == .jpeg }
}

public struct ExportOptions: Sendable {
    public var format: ExportImageFormat
    /// 1x/2x/3x — export resolution relative to the document's canvas size
    /// in points (Part I §26 "Export"). 2x/3x matches how Retina export is
    /// usually offered (export at the display's backing scale, or a fixed
    /// multiplier independent of it).
    public var scale: CGFloat
    /// 0...1, only consulted for `.jpeg`.
    public var jpegQuality: CGFloat
    /// See `ExportRenderer`'s doc comment on metadata handling — this
    /// renderer's own flattened output never carries EXIF/GPS to begin
    /// with, so this flag mainly documents intent/is forwarded to
    /// `exportImageData`'s properties dictionary for forward-compatibility
    /// with a future metadata-carrying export path.
    public var stripMetadata: Bool
    public var filenameTemplate: String

    public init(
        format: ExportImageFormat = .png,
        scale: CGFloat = 1,
        jpegQuality: CGFloat = 0.9,
        stripMetadata: Bool = true,
        filenameTemplate: String = FilenameTemplate.defaultTemplate
    ) {
        self.format = format
        self.scale = scale
        self.jpegQuality = jpegQuality
        self.stripMetadata = stripMetadata
        self.filenameTemplate = filenameTemplate
    }
}

/// Renders and encodes the final flattened export image (Part I §26
/// "Export"). Delegates all document composition to `CanvasRenderer` — this
/// type only owns turning that into pixels at a target scale and then
/// bytes on disk in a chosen format, plus filename resolution via
/// `CaptureCore.FilenameTemplate`.
///
/// ## Metadata stripping
/// "Metadata stripping (export option): remove EXIF; remove GPS; remove
/// original filename; remove author; remove application metadata" (Part
/// III `04_privacy_redaction.md`). For the path this type actually
/// implements — flattening `EditorDocument` into a brand-new `CGImage` via
/// an offscreen `CGContext` — there IS no EXIF/GPS/author metadata to strip
/// in the first place: that metadata lives on ORIGINAL image files
/// (`CGImageSourceCreateWithData` reads it), and a freshly rendered
/// `CGContext`'s `makeImage()` output never carries any of it forward. So
/// `exportImageData` is metadata-safe by construction for everything it
/// draws itself (Source media, annotations, redactions, Backdrop).
///
/// The one place this ISN'T automatically true: if `AppendedImageObject`s
/// (imported photos with their own real EXIF/GPS) are ever drawn by
/// reading their ORIGINAL `CGImageSource` metadata forward instead of just
/// their pixels — this module's `CanvasRenderer.ImageProviding` only
/// vends already-decoded `CGImage`s with no metadata channel, so as
/// currently wired that can't happen either. Flagged explicitly rather
/// than silently assumed solved, since "strip metadata" as a user-facing
/// checkbox should keep meaning exactly that if the pipeline ever changes.
public struct ExportRenderer {
    public enum ExportError: Error, Sendable, Equatable {
        case couldNotCreateContext
        case couldNotCreateDestination
        case renderFailed
        case pdfExporterNotProvided
    }

    private let canvasRenderer: CanvasRenderer

    public init(canvasRenderer: CanvasRenderer = CanvasRenderer()) {
        self.canvasRenderer = canvasRenderer
    }

    /// Renders `document` into a flattened `CGImage` at `options.scale`,
    /// independent of file format. Establishes the same y-down "canvas
    /// point" coordinate convention every other `CaptureEditor` renderer
    /// assumes (see `Rendering/CanvasRenderer.swift`'s coordinate
    /// convention doc comment) on a fresh offscreen bitmap context, then
    /// hands off to `CanvasRenderer`.
    public func renderImage(document: EditorDocument, images: CanvasRenderer.ImageProviding, options: ExportOptions) throws -> CGImage {
        let scale = max(options.scale, 0.01)
        let pixelWidth = max(Int((document.canvasSize.width * scale).rounded()), 1)
        let pixelHeight = max(Int((document.canvasSize.height * scale).rounded()), 1)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ExportError.couldNotCreateContext
        }

        context.interpolationQuality = .high
        // Flip: canvas-point (0,0) is top-left, y-down; this bitmap
        // context's own default CTM is bottom-left, y-up. See
        // `CanvasRenderer`'s coordinate-convention doc comment — this is
        // exactly the flip it says callers are responsible for.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)

        canvasRenderer.render(document: document, images: images, into: context, options: CanvasRenderer.RenderOptions(scale: scale))

        guard let image = context.makeImage() else { throw ExportError.renderFailed }
        return image
    }

    /// Renders and encodes `document` to `options.format`'s file bytes via
    /// `CGImageDestination`.
    public func exportImageData(document: EditorDocument, images: CanvasRenderer.ImageProviding, options: ExportOptions) throws -> Data {
        let image = try renderImage(document: document, images: images, options: options)
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, options.format.utType.identifier as CFString, 1, nil) else {
            throw ExportError.couldNotCreateDestination
        }

        var properties: [CFString: Any] = [:]
        if options.format.supportsLossyQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = Double(min(max(options.jpegQuality, 0), 1))
        }
        // No EXIF/GPS/author keys are ever added to `properties` — see this
        // type's doc comment on why that alone is sufficient for a
        // freshly-rendered `CGImage` with no originating `CGImageSource`.

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.renderFailed }
        return mutableData as Data
    }

    /// Resolves the export filename (including extension) via
    /// `CaptureCore.FilenameTemplate`.
    public func filename(context: FilenameTemplateContext, options: ExportOptions) -> String {
        let base = FilenameTemplate.render(options.filenameTemplate, context: context)
        return "\(base).\(options.format.fileExtension)"
    }

    /// Renders, encodes, and atomically writes the export to
    /// `directory/filename(context:options:)`, returning the final URL.
    /// Uses `CaptureCore.AtomicFileWriter` (temp file + rename) so a failed
    /// export can never corrupt a previous file at the same path — matches
    /// Part I §35's "Never allow a failed export to corrupt the source
    /// project" crash-safety principle, applied to exports too.
    @discardableResult
    public func exportToFile(
        document: EditorDocument,
        images: CanvasRenderer.ImageProviding,
        directory: URL,
        context: FilenameTemplateContext,
        options: ExportOptions
    ) throws -> URL {
        let data = try exportImageData(document: document, images: images, options: options)
        let url = directory.appendingPathComponent(filename(context: context, options: options))
        try AtomicFileWriter.write(data, to: url)
        return url
    }
}

/// Extension point for PDF export (Part III `18_export_share_collaboration.md`:
/// "PDF support"). `CaptureEditor` deliberately does NOT import PDFKit or
/// depend on `CapturePDF` — per `docs/ARCHITECTURE.md`'s module boundaries,
/// `CapturePDF` depends on `CaptureCore` only, and nothing in the
/// `CaptureEditor` layer is supposed to reach sideways into it. This
/// protocol is the seam: whatever wires `CaptureEditor` and `CapturePDF`
/// together (`CaptureUI`/`CaptureApp`, at the top of the dependency graph)
/// supplies a `PDFExporting` implementation backed by `CapturePDF`;
/// `CaptureEditor` only needs to know it can ask for PDF bytes given a
/// document and an image provider.
public protocol PDFExporting {
    func exportPDF(document: EditorDocument, images: CanvasRenderer.ImageProviding, options: ExportOptions) throws -> Data
}

extension ExportRenderer {
    /// Convenience that fails with `.pdfExporterNotProvided` rather than
    /// silently no-op'ing when no `PDFExporting` implementation is wired up
    /// yet (`CapturePDF` is scaffold-only per `docs/ARCHITECTURE.md`).
    public func exportPDFData(document: EditorDocument, images: CanvasRenderer.ImageProviding, options: ExportOptions, exporter: PDFExporting?) throws -> Data {
        guard let exporter else { throw ExportError.pdfExporterNotProvided }
        return try exporter.exportPDF(document: document, images: images, options: options)
    }
}
