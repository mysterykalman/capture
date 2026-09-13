import CaptureBrowserBridge
import CaptureCore
import Foundation

/// The one place `CaptureInspection` actually uses its `CaptureBrowserBridge`
/// dependency (declared in `Package.swift`: "Design Forensics Card
/// rendering ... (browser-bridge dependent)"). Everything else in this
/// module is pure `ElementEvidence -> card content` transformation and
/// deliberately doesn't need to know where the evidence came from; these
/// two convenience entry points are the seam `CaptureUI` calls for the
/// "First browser milestone" flow — hover/pin in the browser sends
/// `ElementEvidence` to `BrowserBridgeService`, and the forensics panel
/// reads it back out through here.
extension ForensicsCard {
    public static func summarizeLatestEvidence(forTabSession tabSessionId: UUID, in service: BrowserBridgeService) -> ForensicsCardContent? {
        service.latestEvidence(forTabSession: tabSessionId).map(summarize)
    }

    public static func fullCardForLatestEvidence(forTabSession tabSessionId: UUID, in service: BrowserBridgeService) -> FullForensicsCardContent? {
        service.latestEvidence(forTabSession: tabSessionId).map(fullCard)
    }
}
