import CaptureCore
import Foundation

/// Latest `tab.info` / `bookmarksBar.geometry` / `bookmarksBar.calibrate`
/// result per tab session. These three message types exist to feed the
/// bookmarks-bar detection tiers and page-context metadata described in
/// `docs/ARCHITECTURE.md` and `CaptureCore.Redaction`'s
/// `BookmarksBarDetectionSource`; the actual detection heuristics live in
/// `CaptureCapture`. This store's job is only to hold the most recent
/// validated value for each tab session so that module can read it,
/// mirroring the shape of `ElementEvidenceStore` but simpler (no callers
/// currently need to *await* the next geometry/calibration report the way
/// `element.captureRequest` needs to await the next `element.evidence`).
public final class TabMetadataStore: @unchecked Sendable {
    public struct TabInfo: Sendable, Equatable {
        public let url: String
        public let title: String
        public let viewport: ElementEvidence.Viewport
    }

    private let lock = NSLock()
    private var tabInfoByTabSession: [UUID: TabInfo] = [:]
    private var bookmarksBarGeometryByTabSession: [UUID: BookmarksBarGeometryPayload] = [:]
    private var bookmarksBarCalibrationByTabSession: [UUID: BookmarksBarCalibrationProfile] = [:]

    public init() {}

    func storeTabInfo(_ payload: TabInfoPayload, forTabSession tabSessionId: UUID) {
        lock.lock()
        tabInfoByTabSession[tabSessionId] = TabInfo(url: payload.url, title: payload.title, viewport: payload.viewport)
        lock.unlock()
    }

    public func latestTabInfo(forTabSession tabSessionId: UUID) -> TabInfo? {
        lock.lock(); defer { lock.unlock() }
        return tabInfoByTabSession[tabSessionId]
    }

    func storeBookmarksBarGeometry(_ payload: BookmarksBarGeometryPayload, forTabSession tabSessionId: UUID) {
        lock.lock()
        bookmarksBarGeometryByTabSession[tabSessionId] = payload
        lock.unlock()
    }

    public func latestBookmarksBarGeometry(forTabSession tabSessionId: UUID) -> BookmarksBarGeometryPayload? {
        lock.lock(); defer { lock.unlock() }
        return bookmarksBarGeometryByTabSession[tabSessionId]
    }

    func storeBookmarksBarCalibration(_ payload: BookmarksBarCalibratePayload, forTabSession tabSessionId: UUID) {
        let profile = BookmarksBarCalibrationProfile(
            browser: payload.browser,
            displayScale: payload.displayScale ?? 1,
            normalizedRect: NormalizedRect(
                x: payload.normalizedRect.x,
                y: payload.normalizedRect.y,
                width: payload.normalizedRect.width,
                height: payload.normalizedRect.height
            )
        )
        lock.lock()
        bookmarksBarCalibrationByTabSession[tabSessionId] = profile
        lock.unlock()
    }

    public func latestBookmarksBarCalibration(forTabSession tabSessionId: UUID) -> BookmarksBarCalibrationProfile? {
        lock.lock(); defer { lock.unlock() }
        return bookmarksBarCalibrationByTabSession[tabSessionId]
    }

    func clear(forTabSession tabSessionId: UUID) {
        lock.lock()
        tabInfoByTabSession.removeValue(forKey: tabSessionId)
        bookmarksBarGeometryByTabSession.removeValue(forKey: tabSessionId)
        bookmarksBarCalibrationByTabSession.removeValue(forKey: tabSessionId)
        lock.unlock()
    }
}
