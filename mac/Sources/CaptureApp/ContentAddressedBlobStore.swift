import CaptureCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// **Gap this file fills, and why it lives in `CaptureApp` rather than
/// `CaptureHistory`:** `CaptureHistory.HistoryStore`/`HistoryEntry` index
/// capture *metadata* (Part I §10's "local history store"), and
/// `CaptureCore.Utilities/Hashing.swift`'s own doc comment names the
/// intended design explicitly — "history-store dedupe (Part I §10, §20:
/// 'Content-addressed assets: SHA256 -> one underlying blob')" — but no
/// module in this build actually owns writing/reading that underlying blob:
/// `HistoryEntry` has a `mediaContentHash` field and nothing else that
/// locates the pixels on disk (no path, no bookmark data), and
/// `CaptureProjectDocument`/`CaptureProjectDocument.save` only knows how to
/// write inside an already-chosen `.capture` package directory, not a
/// content-addressed store keyed by hash. Since `HistoryStore`'s real API
/// has no field for this and `CaptureCore`/`CaptureHistory` must not be
/// modified, this is exactly the "genuinely missing, write a small local
/// seam" case: a plain content-addressed PNG blob store plus a small
/// UserDefaults-backed index of which `.capture` project (if any) a given
/// hash was last saved to, both owned entirely by `CaptureApp`. See this
/// module's final report for the full explanation.
///
/// Layout: `~/Library/Application Support/Capture/Blobs/<sha256>.png` — a
/// sibling of `history.sqlite` and the browser-bridge `IPC/` socket
/// directory `docs/ARCHITECTURE.md` already documents living under
/// `~/Library/Application Support/Capture/`.
public final class ContentAddressedBlobStore {
    public enum StoreError: Error { case encodingFailed }

    private let blobsDirectory: URL
    private let projectIndexDefaultsKey = "com.capture.app.projectIndexByHash.v1"
    private let userDefaults: UserDefaults

    public init(applicationSupportDirectory: URL, userDefaults: UserDefaults = .standard) {
        self.blobsDirectory = applicationSupportDirectory.appendingPathComponent("Blobs", isDirectory: true)
        self.userDefaults = userDefaults
        try? FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Blob storage

    public func blobURL(forHash hash: String) -> URL {
        blobsDirectory.appendingPathComponent("\(hash).png")
    }

    /// Encodes `image` as PNG, writes it atomically to the content-addressed
    /// path, and returns the hash used (so the caller — `CapturePipeline` —
    /// can pass the exact same hash to `HistoryStore.insertCapture`'s
    /// `mediaHash` parameter, keeping the two stores in lockstep).
    @discardableResult
    public func store(_ image: CGImage) throws -> (hash: String, url: URL) {
        guard let data = Self.pngData(from: image) else { throw StoreError.encodingFailed }
        let hash = data.sha256Hex()
        let url = blobURL(forHash: hash)
        if !FileManager.default.fileExists(atPath: url.path) {
            try AtomicFileWriter.write(data, to: url)
        }
        return (hash, url)
    }

    public func loadImage(forHash hash: String) -> CGImage? {
        let url = blobURL(forHash: hash)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - "Which `.capture` project was this hash last saved to" index

    public func recordProjectURL(_ url: URL, forHash hash: String) {
        var index = loadProjectIndex()
        index[hash] = url.path
        saveProjectIndex(index)
    }

    public func projectURL(forHash hash: String) -> URL? {
        guard let path = loadProjectIndex()[hash] else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func loadProjectIndex() -> [String: String] {
        (userDefaults.dictionary(forKey: projectIndexDefaultsKey) as? [String: String]) ?? [:]
    }

    private func saveProjectIndex(_ index: [String: String]) {
        userDefaults.set(index, forKey: projectIndexDefaultsKey)
    }

    private static func pngData(from image: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
