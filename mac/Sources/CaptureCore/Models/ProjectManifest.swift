import Foundation

/// Mirrors `schemas/project/capture-project-manifest.schema.json` — the
/// `manifest.json` at the root of a `.capture` package. See
/// `docs/PROJECT_FORMAT.md`.
public struct ProjectManifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public enum Kind: String, Codable, Sendable { case screenshot, recording, assembly }

    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var appVersion: String?
    public var kind: Kind
    public var title: String?
    public var source: Source
    public var captureMetadata: CaptureMetadata?
    public var files: Files
    public var outputSettings: OutputSettings?

    public init(
        schemaVersion: Int = ProjectManifest.currentSchemaVersion,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        appVersion: String? = nil,
        kind: Kind,
        title: String? = nil,
        source: Source,
        captureMetadata: CaptureMetadata? = nil,
        files: Files = Files(),
        outputSettings: OutputSettings? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.appVersion = appVersion
        self.kind = kind
        self.title = title
        self.source = source
        self.captureMetadata = captureMetadata
        self.files = files
        self.outputSettings = outputSettings
    }

    public struct Source: Codable, Hashable, Sendable {
        public var relativePath: String
        public var contentHash: String
        public var pixelWidth: Int?
        public var pixelHeight: Int?
        public var colorSpace: String?

        public init(relativePath: String, contentHash: String, pixelWidth: Int? = nil, pixelHeight: Int? = nil, colorSpace: String? = nil) {
            self.relativePath = relativePath
            self.contentHash = contentHash
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.colorSpace = colorSpace
        }
    }

    public struct Files: Codable, Hashable, Sendable {
        public var annotations: String
        public var measurements: String
        public var redactions: String
        public var browserElements: String
        public var browserPage: String
        public var recordingTimeline: String?

        public init(
            annotations: String = "annotations.json",
            measurements: String = "measurements.json",
            redactions: String = "redactions.json",
            browserElements: String = "browser/elements.json",
            browserPage: String = "browser/page.json",
            recordingTimeline: String? = nil
        ) {
            self.annotations = annotations
            self.measurements = measurements
            self.redactions = redactions
            self.browserElements = browserElements
            self.browserPage = browserPage
            self.recordingTimeline = recordingTimeline
        }
    }

    public struct OutputSettings: Codable, Hashable, Sendable {
        public var exportScale: Double?
        public var exportFormat: String?
        public var filenameTemplate: String?

        public init(exportScale: Double? = nil, exportFormat: String? = nil, filenameTemplate: String? = nil) {
            self.exportScale = exportScale
            self.exportFormat = exportFormat
            self.filenameTemplate = filenameTemplate
        }
    }
}

/// Sidecar record captured alongside every screenshot/recording (Part III §1
/// "capture metadata" example). Stored both in `ProjectManifest` and as a
/// row in the local history SQLite index.
public struct CaptureMetadata: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var sourceApp: String
    public var url: String?
    public var pageTitle: String?
    public var viewport: [Double]?
    public var devicePixelRatio: Double?
    public var scrollPosition: [Double]?
    public var browser: String?
    public var os: String
    public var colourScheme: String?
    public var locale: String?

    public init(
        timestamp: Date = Date(), sourceApp: String, url: String? = nil, pageTitle: String? = nil,
        viewport: [Double]? = nil, devicePixelRatio: Double? = nil, scrollPosition: [Double]? = nil,
        browser: String? = nil, os: String, colourScheme: String? = nil, locale: String? = nil
    ) {
        self.timestamp = timestamp; self.sourceApp = sourceApp; self.url = url; self.pageTitle = pageTitle
        self.viewport = viewport; self.devicePixelRatio = devicePixelRatio; self.scrollPosition = scrollPosition
        self.browser = browser; self.os = os; self.colourScheme = colourScheme; self.locale = locale
    }
}
