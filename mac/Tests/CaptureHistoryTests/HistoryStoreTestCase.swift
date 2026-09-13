import CaptureCore
import XCTest
@testable import CaptureHistory

/// Shared fixture: a fresh `HistoryStore` backed by a temporary on-disk
/// SQLite file (rather than `:memory:`) so tests exercise the same
/// open-file/WAL-mode path production code uses. Every subclass gets its
/// own temp file, created in `setUp` and removed (including any `-wal`/
/// `-shm` sidecar files WAL mode creates) in `tearDown`.
class HistoryStoreTestCase: XCTestCase {
    var databaseURL: URL!
    var store: HistoryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("history.sqlite")
        store = try HistoryStore(path: databaseURL.path)
    }

    override func tearDownWithError() throws {
        store.close()
        store = nil
        let directory = databaseURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
        databaseURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    func makeMetadata(
        sourceApp: String = "com.google.Chrome",
        url: String? = "https://www.example.com/products/acme-widget",
        pageTitle: String? = "Acme Widget — Example Store",
        os: String = "macOS 15.0"
    ) -> CaptureMetadata {
        CaptureMetadata(timestamp: Date(), sourceApp: sourceApp, url: url, pageTitle: pageTitle, os: os)
    }

    @discardableResult
    func insertSampleCapture(
        mediaHash: String = UUID().uuidString,
        url: String? = "https://www.example.com/products/acme-widget",
        pageTitle: String? = "Acme Widget — Example Store",
        projectId: UUID? = nil,
        captureType: ProjectManifest.Kind = .screenshot,
        tags: [String] = [],
        ocrText: String? = nil,
        annotationText: String? = nil,
        allowDuplicate: Bool = false
    ) throws -> UUID {
        try store.insertCapture(
            metadata: makeMetadata(url: url, pageTitle: pageTitle),
            mediaHash: mediaHash,
            projectId: projectId,
            captureType: captureType,
            dimensions: CaptureSize(width: 1440, height: 900),
            tags: tags,
            ocrText: ocrText,
            annotationText: annotationText,
            allowDuplicate: allowDuplicate
        )
    }
}
