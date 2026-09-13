import Foundation

/// Redaction modes (Part I §16, Part III §04). A redaction is stored as an
/// `Annotation` with `type == .redact`; `mode` lives in `Annotation.typeData`
/// under the `"mode"` key so redactions share the general annotation
/// lifecycle (non-destructive, movable, resizable, deletable).
public enum RedactionMode: String, Codable, Sendable, CaseIterable {
    case secureRandomizedPixelation
    case regularMosaic
    case gaussianBlur
    case solid
    case textOnly
    case objectRemoval
}

/// The Browser Bookmarks Bar Privacy Rule (hard requirement, default ON).
public enum BookmarksBarRedactionStyle: String, Codable, Sendable, CaseIterable {
    case softBlur, pixelate, solid

    public static let `default` = BookmarksBarRedactionStyle.softBlur
}

/// A learned calibration profile (detection Tier 3) — see
/// `docs/ARCHITECTURE.md` and Part I bookmarks-bar rule. Persisted keyed by
/// `(browser, displayScale)` so the same browser at a different display
/// scale gets its own calibration.
public struct BookmarksBarCalibrationProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var browser: String
    public var displayScale: Double
    public var normalizedRect: NormalizedRect
    public var calibratedAt: Date

    public init(id: UUID = UUID(), browser: String, displayScale: Double, normalizedRect: NormalizedRect, calibratedAt: Date = Date()) {
        self.id = id
        self.browser = browser
        self.displayScale = displayScale
        self.normalizedRect = normalizedRect
        self.calibratedAt = calibratedAt
    }

    public static func cacheKey(browser: String, displayScale: Double) -> String {
        "\(browser.lowercased())@\(displayScale)"
    }
}

/// Confidence tier for bookmarks-bar detection, per the 4-tier hierarchy in
/// Part I. `CaptureCapture.BookmarksBarDetector` produces this; `CaptureCore`
/// only defines the shared vocabulary so both the detector and the editor's
/// "Auto Privacy Rule" redaction UI agree on it.
public enum BookmarksBarDetectionSource: String, Codable, Sendable {
    case accessibility          // Tier 1: AXUIElement inspection
    case extensionGeometry      // Tier 2: innerWidth/outerWidth/etc.
    case learnedCalibration     // Tier 3: stored NormalizedRect
    case none                   // No reliable detector — do not blindly blur
}

public struct BookmarksBarDetectionResult: Codable, Hashable, Sendable {
    public var source: BookmarksBarDetectionSource
    public var rect: CaptureRect?
    public var confidence: Double

    public init(source: BookmarksBarDetectionSource, rect: CaptureRect?, confidence: Double) {
        self.source = source
        self.rect = rect
        self.confidence = min(max(confidence, 0), 1)
    }

    /// Per Part I "confidence and privacy-first behaviour": below this
    /// threshold, do not blindly blur a random strip — surface a one-click
    /// privacy warning / calibration prompt instead.
    public static let minimumConfidenceToAutoApply = 0.6

    public var shouldAutoApply: Bool {
        source != .none && confidence >= Self.minimumConfidenceToAutoApply && rect != nil
    }
}
