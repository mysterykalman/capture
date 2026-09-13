import Foundation

/// Reads and writes a `.capture` package directory. See
/// `docs/PROJECT_FORMAT.md` for the on-disk layout. This type owns no
/// AppKit `NSDocument` lifecycle (that lives in `CaptureUI`) — it is the
/// pure encode/decode + migration layer so it can be unit-tested directly.
public struct CaptureProjectDocument: Sendable {
    public var manifest: ProjectManifest
    public var annotations: [Annotation]
    public var measurements: [JSONValue]
    public var redactions: [Annotation]
    public var browserElements: [ElementEvidence]

    public init(
        manifest: ProjectManifest,
        annotations: [Annotation] = [],
        measurements: [JSONValue] = [],
        redactions: [Annotation] = [],
        browserElements: [ElementEvidence] = []
    ) {
        self.manifest = manifest
        self.annotations = annotations
        self.measurements = measurements
        self.redactions = redactions
        self.browserElements = browserElements
    }

    public enum LoadError: Error, Sendable {
        case notAPackage
        case missingManifest
        case unsupportedSchemaVersion(Int)
    }

    /// Loads a package at `packageURL`. Missing optional sidecar files
    /// (measurements/redactions/browser/*) are treated as empty arrays, not
    /// errors, per `docs/PROJECT_FORMAT.md`.
    public static func load(from packageURL: URL) throws -> CaptureProjectDocument {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LoadError.notAPackage
        }
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw LoadError.missingManifest
        }
        var manifest = try CaptureCoreJSON.decoder.decode(ProjectManifest.self, from: manifestData)
        manifest = try ProjectFormatMigrator.migrate(manifest)

        func decodeArray<T: Decodable>(_ relativePath: String, as type: T.Type) -> [T] {
            let url = packageURL.appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? CaptureCoreJSON.decoder.decode([T].self, from: data)) ?? []
        }

        return CaptureProjectDocument(
            manifest: manifest,
            annotations: decodeArray(manifest.files.annotations, as: Annotation.self),
            measurements: decodeArray(manifest.files.measurements, as: JSONValue.self),
            redactions: decodeArray(manifest.files.redactions, as: Annotation.self),
            browserElements: decodeArray(manifest.files.browserElements, as: ElementEvidence.self)
        )
    }

    /// Writes every changed file atomically. Per Part I §9/§35, `updatedAt`
    /// advances and this touches only the sidecar JSON files — never
    /// `source/` — unless `sourceData` is explicitly supplied (e.g. initial
    /// project creation).
    public func save(to packageURL: URL, sourceData: Data? = nil, sourceRelativePath: String? = nil) throws {
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        var manifestToWrite = manifest
        manifestToWrite.updatedAt = Date()

        if let sourceData, let sourceRelativePath {
            let sourceURL = packageURL.appendingPathComponent(sourceRelativePath)
            try AtomicFileWriter.write(sourceData, to: sourceURL)
            manifestToWrite.source.contentHash = "sha256:" + sourceData.sha256Hex()
            manifestToWrite.source.relativePath = sourceRelativePath
        }

        try AtomicFileWriter.writeJSON(manifestToWrite, to: packageURL.appendingPathComponent("manifest.json"))
        try AtomicFileWriter.writeJSON(annotations, to: packageURL.appendingPathComponent(manifest.files.annotations))
        try AtomicFileWriter.writeJSON(measurements, to: packageURL.appendingPathComponent(manifest.files.measurements))
        try AtomicFileWriter.writeJSON(redactions, to: packageURL.appendingPathComponent(manifest.files.redactions))
        if !browserElements.isEmpty {
            // Deliberately asymmetric with annotations/measurements/redactions
            // above (which are always written, even as `[]`): a plain
            // pixel-only screenshot project should never gain an empty
            // `browser/` directory it has no other reason to have. Readers
            // must still treat a missing browserElements file as "none" —
            // see docs/PROJECT_FORMAT.md.
            try AtomicFileWriter.writeJSON(browserElements, to: packageURL.appendingPathComponent(manifest.files.browserElements))
        }
    }
}

/// Schema-version migration chain (Part I §9: "schema version; migrations").
/// Currently a no-op pass-through since `currentSchemaVersion == 1` and no
/// prior version exists yet; future migrations are added as numbered cases
/// here, never by mutating old migration steps in place.
public enum ProjectFormatMigrator {
    public static func migrate(_ manifest: ProjectManifest) throws -> ProjectManifest {
        guard manifest.schemaVersion <= ProjectManifest.currentSchemaVersion else {
            throw CaptureProjectDocument.LoadError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        return manifest
    }
}
