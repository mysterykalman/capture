import CaptureCore
import CoreGraphics
import Foundation

/// Persists the last-used area-capture region so "Capture Repeat Area"
/// (`ShortcutAction.captureRepeatArea`) can re-capture it instantly without
/// redrawing a selection — `01_capture_engine.md`: "Repeat Area: persists
/// coordinates; display; target window relationship where possible; capture
/// ratio."
///
/// Only depends on `Foundation`/`CaptureCore`/`CoreGraphics` (the latter
/// only for the `CGDirectDisplayID` type alias) — no AppKit/ScreenCaptureKit
/// — so the round-trip logic is directly unit-testable with an in-memory
/// `UserDefaults` suite.
public struct RepeatAreaRegion: Codable, Hashable, Sendable {
    /// AppKit screen-coordinate space (origin bottom-left of the primary
    /// display, Y up) — the same space `ScreenCaptureEngine.captureArea`
    /// expects, so a saved region can be replayed directly.
    public var rect: CaptureRect
    public var displayID: CGDirectDisplayID?
    public var capturedAt: Date

    public init(rect: CaptureRect, displayID: CGDirectDisplayID? = nil, capturedAt: Date = Date()) {
        self.rect = rect
        self.displayID = displayID
        self.capturedAt = capturedAt
    }

    /// Width:height ratio, derived rather than separately persisted so it
    /// can never drift out of sync with `rect`.
    public var captureRatio: Double {
        rect.height == 0 ? 0 : Double(rect.width / rect.height)
    }
}

public final class RepeatAreaStore {
    private let userDefaults: UserDefaults
    private let key: String

    public init(userDefaults: UserDefaults = .standard, key: String = "com.capture.repeatArea.v1") {
        self.userDefaults = userDefaults
        self.key = key
    }

    /// Called after every successful area capture (not just explicit
    /// "Repeat Area" invocations) so the very next "Capture Repeat Area"
    /// always targets the most recent region, per the spec's "repeat
    /// previous exact region" wording.
    public func save(_ region: RepeatAreaRegion) {
        guard let data = try? CaptureCoreJSON.encoder.encode(region) else { return }
        userDefaults.set(data, forKey: key)
    }

    public func load() -> RepeatAreaRegion? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try? CaptureCoreJSON.decoder.decode(RepeatAreaRegion.self, from: data)
    }

    public func clear() {
        userDefaults.removeObject(forKey: key)
    }
}
