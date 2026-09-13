import CaptureCore
@testable import CaptureEditor
import CoreGraphics
import Foundation
import XCTest

final class ExportFilenameTests: XCTestCase {
    private let renderer = ExportRenderer()
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z

    func testFilenameAppendsFormatExtension() {
        let context = FilenameTemplateContext(date: fixedDate, app: "Capture", counter: 1)
        let png = renderer.filename(context: context, options: ExportOptions(format: .png))
        let jpeg = renderer.filename(context: context, options: ExportOptions(format: .jpeg))
        let tiff = renderer.filename(context: context, options: ExportOptions(format: .tiff))

        XCTAssertTrue(png.hasSuffix(".png"))
        XCTAssertTrue(jpeg.hasSuffix(".jpg"))
        XCTAssertTrue(tiff.hasSuffix(".tiff"))
    }

    func testFilenameUsesCustomTemplateTokens() {
        let context = FilenameTemplateContext(date: fixedDate, domain: "example.com", app: "Capture", counter: 7)
        let options = ExportOptions(format: .png, filenameTemplate: "{app}-{domain}-{counter}")
        let name = renderer.filename(context: context, options: options)
        XCTAssertEqual(name, "Capture-example.com-007.png")
    }

    func testFilenameSanitizesUnsafeCharactersFromPageTitle() {
        let context = FilenameTemplateContext(date: fixedDate, pageTitle: "Weird/Title:With*Chars", app: "Capture")
        let options = ExportOptions(format: .png, filenameTemplate: "{pageTitle}")
        let name = renderer.filename(context: context, options: options)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("*"))
        XCTAssertTrue(name.hasSuffix(".png"))
    }

    func testDefaultTemplateProducesNonEmptyFilename() {
        let context = FilenameTemplateContext(date: fixedDate, app: "Capture", counter: 1)
        let name = renderer.filename(context: context, options: ExportOptions(format: .jpeg))
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(name.hasSuffix(".jpg"))
    }

    func testJPEGSupportsLossyQualityButPNGAndTIFFDoNot() {
        XCTAssertTrue(ExportImageFormat.jpeg.supportsLossyQuality)
        XCTAssertFalse(ExportImageFormat.png.supportsLossyQuality)
        XCTAssertFalse(ExportImageFormat.tiff.supportsLossyQuality)
    }

    func testPDFExportWithoutAnExporterFailsExplicitly() throws {
        let document = EditorDocument(sourceSize: CaptureSize(width: 10, height: 10))
        struct EmptyImageProvider: CanvasRenderer.ImageProviding {
            func image(for id: String) -> CGImage? { nil }
        }
        XCTAssertThrowsError(try renderer.exportPDFData(document: document, images: EmptyImageProvider(), options: ExportOptions(), exporter: nil)) { error in
            XCTAssertEqual(error as? ExportRenderer.ExportError, .pdfExporterNotProvided)
        }
    }
}
