import Foundation

/// Result of asking the browser bridge to re-resolve a DOM-anchored
/// annotation's `ElementEvidence.Locator` (Part I §8: "On recapture:
/// resolve candidates, calculate confidence score. If confidence
/// insufficient: 'Anchor not found'. Do not attach the annotation to the
/// wrong element."). The actual DOM matching happens in the extension
/// content script (JS DOM access); this type is the shared vocabulary for
/// the result that flows back over IPC into `CaptureCore`/`CaptureEditor`.
public struct AnchorResolution: Codable, Hashable, Sendable {
    public var resolved: Bool
    public var confidence: Double
    public var rect: CaptureRect?

    public init(resolved: Bool, confidence: Double, rect: CaptureRect?) {
        self.resolved = resolved
        self.confidence = min(max(confidence, 0), 1)
        self.rect = rect
    }

    /// Below this, the editor must show "Anchor not found" and fall back to
    /// `Annotation.Anchor.fallbackPixelPosition` rather than silently
    /// attaching to a low-confidence match.
    public static let minimumConfidence = 0.75

    public var isTrustworthy: Bool { resolved && confidence >= Self.minimumConfidence && rect != nil }
}
