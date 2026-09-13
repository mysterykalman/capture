import CaptureCore
import Foundation

/// Where a capture stands in an (optional, future) upload/share pipeline.
/// Local-first by default (Part I §2.2/§2.5) — every capture starts
/// `.none` and nothing here implies a network call happens on its own.
public enum UploadStatus: String, Codable, Sendable, CaseIterable {
    case none
    case uploading
    case uploaded
    case failed
}

/// Coarse privacy triage state for a capture (Part I §16 Privacy
/// Preflight). `.unreviewed` is the default for every new capture;
/// `HistoryStore` never promotes a row out of `.unreviewed` on its own —
/// that is the redaction/preflight module's job.
public enum PrivacyStatus: String, Codable, Sendable, CaseIterable {
    case unreviewed
    case reviewed
    case containsSensitiveData = "contains-sensitive-data"
    case redacted
}

/// One row of the local history index — the searchable, lightweight
/// metadata record for a capture. Distinct from `ProjectManifest`/
/// `CaptureMetadata` (the full `.capture` package contents): this is what
/// `HistoryStore` reads/writes and what the History browser UI renders in
/// a list. `captureType` reuses `CaptureCore.ProjectManifest.Kind` rather
/// than redefining screenshot/recording/assembly a second time.
public struct HistoryEntry: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var mediaContentHash: String
    public var captureDate: Date
    public var sourceApp: String?
    public var url: String?
    public var domain: String?
    public var pageTitle: String?
    public var projectId: UUID?
    public var captureType: ProjectManifest.Kind
    public var dimensions: CaptureSize
    public var uploadStatus: UploadStatus
    public var privacyStatus: PrivacyStatus
    public var favourite: Bool
    public var tags: [String]
    public var ocrText: String?
    public var annotationText: String?
    public var os: String?
    public var browser: String?
    public var colourScheme: String?
    public var locale: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        mediaContentHash: String,
        captureDate: Date,
        sourceApp: String? = nil,
        url: String? = nil,
        domain: String? = nil,
        pageTitle: String? = nil,
        projectId: UUID? = nil,
        captureType: ProjectManifest.Kind,
        dimensions: CaptureSize,
        uploadStatus: UploadStatus = .none,
        privacyStatus: PrivacyStatus = .unreviewed,
        favourite: Bool = false,
        tags: [String] = [],
        ocrText: String? = nil,
        annotationText: String? = nil,
        os: String? = nil,
        browser: String? = nil,
        colourScheme: String? = nil,
        locale: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.mediaContentHash = mediaContentHash
        self.captureDate = captureDate
        self.sourceApp = sourceApp
        self.url = url
        self.domain = domain
        self.pageTitle = pageTitle
        self.projectId = projectId
        self.captureType = captureType
        self.dimensions = dimensions
        self.uploadStatus = uploadStatus
        self.privacyStatus = privacyStatus
        self.favourite = favourite
        self.tags = tags
        self.ocrText = ocrText
        self.annotationText = annotationText
        self.os = os
        self.browser = browser
        self.colourScheme = colourScheme
        self.locale = locale
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Filter set for `HistoryStore.search` (Part I §25: "Required: recent
/// captures; screenshots; recordings; project filter; OCR search;
/// domain/URL search; date; tags; favourites."). All fields are ANDed
/// together with the free-text FTS query, when both are present.
public struct HistorySearchFilters: Sendable {
    public var domain: String?
    public var dateRange: ClosedRange<Date>?
    public var captureType: ProjectManifest.Kind?
    public var tags: [String]
    public var projectId: UUID?
    public var favouriteOnly: Bool

    public init(
        domain: String? = nil,
        dateRange: ClosedRange<Date>? = nil,
        captureType: ProjectManifest.Kind? = nil,
        tags: [String] = [],
        projectId: UUID? = nil,
        favouriteOnly: Bool = false
    ) {
        self.domain = domain
        self.dateRange = dateRange
        self.captureType = captureType
        self.tags = tags
        self.projectId = projectId
        self.favouriteOnly = favouriteOnly
    }
}

/// A lightweight project row (Part I §25 / spec digest §15: "Lightweight
/// logical grouping"). The richer per-project preset data (brand
/// annotation preset, Backdrop preset, browser viewports, redact rules,
/// export presets) described in the spec is out of scope for this store —
/// `HistoryStore` only owns identity, naming, and the retention override.
public struct ProjectSummary: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var retentionPolicy: RetentionPolicy?
    public var favourite: Bool

    public init(id: UUID, name: String, createdAt: Date, retentionPolicy: RetentionPolicy?, favourite: Bool) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.retentionPolicy = retentionPolicy
        self.favourite = favourite
    }
}
