import CaptureEditor
import CapturePDF
import Foundation

/// Satisfies `CaptureEditor.PDFExporting` — the seam that module's own
/// `ExportRenderer.swift` doc comment describes as needing "whatever wires
/// `CaptureEditor` and `CapturePDF` together (`CaptureUI`/`CaptureApp`, at
/// the top of the dependency graph)". `CaptureUI` cannot do this itself
/// (not a declared dependency of the `CapturePDF` target — see this
/// module's final report), so `CaptureApp`, which depends on both, is
/// exactly where this belongs.
public struct PDFExportAdapter: PDFExporting {
    public init() {}

    public func exportPDF(document: EditorDocument, images: CanvasRenderer.ImageProviding, options: ExportOptions) throws -> Data {
        let renderer = ExportRenderer()
        let image = try renderer.renderImage(document: document, images: images, options: options)
        return try PDFExporter.makePDF(from: [image])
    }
}
