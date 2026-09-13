import ApplicationServices
import CaptureCore
import CoreGraphics
import Foundation

/// Browser Bookmarks Bar Privacy Rule — hard requirement, default ON (see
/// `docs/PERMISSIONS.md` and the spec digest's "Browser Bookmarks Bar
/// Privacy Rule"). This file implements:
///   - Tier 1: macOS Accessibility (`AXUIElement`) inspection, Chromium-
///     family browsers only (`BookmarksBarAccessibilityDetector`).
///   - Tier 3: learned calibration, scaling a stored
///     `CaptureCore.BookmarksBarCalibrationProfile` via
///     `NormalizedRect.resolved(in:)` (`BookmarksBarCalibration`).
///   - The tier-combining logic (`BookmarksBarDetectionCombiner`), which
///     picks the highest-confidence available result, tie-broken by
///     hierarchy order.
/// Tier 2 (extension-reported geometry) is *produced* by
/// `CaptureBrowserBridge` from IPC payloads (out of this module's scope per
/// `docs/ARCHITECTURE.md`'s module boundaries) — this file only exposes
/// where a caller hands that already-resolved Tier 2 result in
/// (`BookmarksBarDetector.combinedResult(accessibility:extensionGeometry:...)`),
/// plus an optional real implementation of the page-geometry math
/// (`BookmarksBarExtensionGeometry`) a caller may use to build that result
/// from raw `innerWidth`/`outerHeight`/etc. payload fields, since leaving
/// that math entirely unwritten seemed like under-delivering against "real
/// logic, not stubs" — but the required integration point is the
/// already-resolved-result parameter, not this helper.

// MARK: - Supported browsers

public enum SupportedBrowser: String, Sendable, CaseIterable {
    case chrome, chromium, edge, brave, arc, safari

    /// Bundle identifiers recognized as this browser, so a caller can map
    /// a frontmost/target `NSRunningApplication.bundleIdentifier` to a
    /// `SupportedBrowser` before choosing a Tier 1 adapter (Part I: "Keep
    /// detection adapters browser-specific where necessary").
    public var bundleIdentifiers: [String] {
        switch self {
        case .chrome: return ["com.google.Chrome"]
        case .chromium: return ["org.chromium.Chromium"]
        case .edge: return ["com.microsoft.edgemac"]
        case .brave: return ["com.brave.Browser"]
        case .arc: return ["company.thebrowser.Browser"]
        case .safari: return ["com.apple.Safari"]
        }
    }

    public static func from(bundleIdentifier: String) -> SupportedBrowser? {
        allCases.first { $0.bundleIdentifiers.contains(bundleIdentifier) }
    }

    /// Chrome/Chromium/Edge/Brave/Arc share Chromium's Views-based UI
    /// toolkit and (per the spec) "comparable UI exposed" in the
    /// accessibility tree; Safari's AppKit-native chrome needs its own
    /// adapter and is explicitly "(later)" in the spec.
    var usesChromiumAXAdapter: Bool {
        switch self {
        case .chrome, .chromium, .edge, .brave, .arc: return true
        case .safari: return false
        }
    }
}

// MARK: - Tier 1: Accessibility

/// AXUIElement-tree inspection to locate a Chromium-family browser
/// window's bookmarks bar. Not unit-testable in this sandbox (needs a live
/// Accessibility server + real browser window; no Xcode/macOS runtime
/// here) — kept as a thin wrapper whose only branching of real
/// consequence (candidate scoring) is factored into `evaluateCandidate`,
/// documented below as a pure-enough heuristic that a future test target
/// *could* exercise given synthetic `CGRect`s, even though the AX tree
/// walk itself cannot be.
public final class BookmarksBarAccessibilityDetector {
    /// Bounded so a pathological/very deep Chromium AX tree can't cause an
    /// unbounded walk; six levels comfortably reaches a toolbar-level
    /// element from a browser's top-level window element in every
    /// Chromium build observed in training data.
    private let maxWalkDepth = 6

    public init() {}

    /// Convenience: resolves the frontmost/focused window `AXUIElement` for
    /// a running app, so a caller only needs a `pid_t`. Requires
    /// Accessibility permission to return anything meaningful; returns
    /// `nil` (not a crash) when the app has no focused window or
    /// permission is missing.
    public static func focusedWindowElement(forProcessID pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success else {
            return nil
        }
        // AXUIElement is a CF type; force-cast is safe once the .success
        // check above has confirmed a value of the requested attribute's
        // expected type was returned.
        return (value as! AXUIElement)
    }

    /// - Parameters:
    ///   - windowElement: the browser window's `AXUIElement`, typically
    ///     from `focusedWindowElement(forProcessID:)`.
    ///   - browser: which adapter to use.
    ///   - windowFrame: the window's on-screen frame in Quartz/AX global
    ///     coordinates (origin top-left of the primary display, Y down —
    ///     the space `AXUIElementCopyAttributeValue(kAXPositionAttribute)`
    ///     itself reports in, NOT `LiveWindowGeometryProvider`'s AppKit-
    ///     space output; convert before calling if needed).
    public func detect(windowElement: AXUIElement, browser: SupportedBrowser, windowFrame: CaptureRect) -> BookmarksBarDetectionResult {
        guard AXIsProcessTrusted() else {
            return BookmarksBarDetectionResult(source: .none, rect: nil, confidence: 0)
        }
        guard browser.usesChromiumAXAdapter else {
            // Safari: no adapter yet, per spec ("later"). Tier 2/3 handle
            // the fallback automatically (docs/PERMISSIONS.md).
            return BookmarksBarDetectionResult(source: .none, rect: nil, confidence: 0)
        }
        guard let candidate = findBookmarksBarCandidate(in: windowElement, depth: 0),
              let frame = axFrame(candidate) else {
            return BookmarksBarDetectionResult(source: .none, rect: nil, confidence: 0)
        }
        let confidence = Self.evaluateCandidate(frame: frame, windowFrame: windowFrame)
        return BookmarksBarDetectionResult(source: .accessibility, rect: CaptureRect(cgRect: frame), confidence: confidence)
    }

    // MARK: AX tree walk

    private func findBookmarksBarCandidate(in root: AXUIElement, depth: Int) -> AXUIElement? {
        if Self.isLikelyBookmarksBarElement(root) { return root }
        guard depth < maxWalkDepth else { return nil }
        for child in axChildren(root) {
            if let match = findBookmarksBarCandidate(in: child, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    /// Heuristic role/name matching. CONFIDENCE NOTE: Chromium's exact AX
    /// tree shape for the bookmarks bar (role `AXToolbar` vs. a plain
    /// `AXGroup`, and the exact description/identifier strings it exposes)
    /// was not verified against a live, running Chrome build in this
    /// sandbox — transcribed from training-data familiarity with
    /// Chromium's accessibility tree conventions. Validate with Xcode's
    /// Accessibility Inspector against a real Chrome window before
    /// shipping, and be ready to loosen/tighten this matcher.
    static func isLikelyBookmarksBarElement(_ element: AXUIElement) -> Bool {
        let role = axString(element, kAXRoleAttribute as String) ?? ""
        let description = (axString(element, kAXDescriptionAttribute as String) ?? "").lowercased()
        let title = (axString(element, kAXTitleAttribute as String) ?? "").lowercased()
        let identifier = (axString(element, "AXIdentifier") ?? "").lowercased()

        let nameMentionsBookmarks = [description, title, identifier].contains { $0.contains("bookmark") }
        let roleIsToolbarLike = role == (kAXToolbarRole as String) || role == (kAXGroupRole as String)
        return nameMentionsBookmarks && roleIsToolbarLike
    }

    /// Scores a matched candidate by how well its geometry matches "a
    /// short horizontal strip near the top of the window, immediately
    /// above the page content" (Part I). Deliberately conservative —
    /// starts below `BookmarksBarDetectionResult.minimumConfidenceToAutoApply`
    /// (0.6) so a role/name match with implausible geometry does not
    /// auto-apply a wrong mask.
    static func evaluateCandidate(frame: CGRect, windowFrame: CaptureRect) -> Double {
        var confidence = 0.5

        let plausibleHeight = (18...52).contains(Int(frame.height.rounded()))
        if plausibleHeight { confidence += 0.2 }

        let widthRatio = windowFrame.width > 0 ? Double(frame.width / windowFrame.width) : 0
        if widthRatio > 0.5 { confidence += 0.15 }

        // Both `frame` and `windowFrame` are expected in the same
        // top-left/Y-down space here (see `detect(windowElement:...)`'s
        // doc comment), so a small vertical offset from the window's own
        // top edge indicates "near the top, below the tab/toolbar strip".
        let verticalOffsetFromWindowTop = frame.origin.y - windowFrame.y
        if (0...160).contains(verticalOffsetFromWindowTop) { confidence += 0.1 }

        return min(confidence, 0.95)
    }

    // MARK: AX attribute helpers

    private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionAXValue = positionValue, CFGetTypeID(positionAXValue) == AXValueGetTypeID(),
              let sizeAXValue = sizeValue, CFGetTypeID(sizeAXValue) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeAXValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

// MARK: - Tier 2: extension-reported geometry (consumed here, produced elsewhere)

/// Optional real implementation of the page-geometry math a caller (most
/// naturally `CaptureBrowserBridge`, which owns the IPC payload types) may
/// use to turn a raw extension report into the `BookmarksBarDetectionResult`
/// this module's `combinedResult` expects for its `extensionGeometry:`
/// parameter. Pure — no AppKit/AX/ScreenCaptureKit — directly unit-tested.
public enum BookmarksBarExtensionGeometry {
    public struct Report: Sendable, Equatable {
        public var innerWidth: Double
        public var innerHeight: Double
        public var outerWidth: Double
        public var outerHeight: Double
        public var devicePixelRatio: Double

        public init(innerWidth: Double, innerHeight: Double, outerWidth: Double, outerHeight: Double, devicePixelRatio: Double) {
            self.innerWidth = innerWidth
            self.innerHeight = innerHeight
            self.outerWidth = outerWidth
            self.outerHeight = outerHeight
            self.devicePixelRatio = devicePixelRatio
        }
    }

    /// `browserWindowFrame` is the native browser window's on-screen frame
    /// (whatever coordinate space the caller's other geometry is in — this
    /// function only ever adds/subtracts within that one space, so it's
    /// space-agnostic as long as the caller is consistent).
    ///
    /// The chrome band above the page (`outerHeight - innerHeight`, in CSS
    /// px, scaled to points by `devicePixelRatio`) covers title bar + tab
    /// strip + bookmarks bar combined — page JS has no visibility into
    /// where the bookmarks bar specifically starts within that band. Part
    /// I explicitly warns "do not assume a universal fixed toolbar
    /// height", so rather than assume a fixed offset within the band, we
    /// take the bottom slice of the band (immediately above page content,
    /// per "location immediately above webpage content") up to a plausible
    /// bookmarks-bar height. This is necessarily an approximation, which is
    /// why it's returned at a middling confidence.
    public static func result(report: Report, browserWindowFrame: CaptureRect) -> BookmarksBarDetectionResult {
        guard report.innerWidth > 0, report.innerHeight > 0, report.outerHeight > report.innerHeight, report.devicePixelRatio > 0 else {
            return BookmarksBarDetectionResult(source: .none, rect: nil, confidence: 0)
        }
        let chromeBandPoints = (report.outerHeight - report.innerHeight) / report.devicePixelRatio
        let approximateBarHeight = min(chromeBandPoints, 36)
        guard approximateBarHeight > 0 else {
            return BookmarksBarDetectionResult(source: .none, rect: nil, confidence: 0)
        }
        let rect = CaptureRect(
            x: browserWindowFrame.x,
            y: browserWindowFrame.y + (chromeBandPoints - approximateBarHeight),
            width: browserWindowFrame.width,
            height: approximateBarHeight
        )
        return BookmarksBarDetectionResult(source: .extensionGeometry, rect: rect, confidence: 0.65)
    }
}

// MARK: - Tier 3: learned calibration

/// `UserDefaults`-backed store for calibration profiles, keyed per
/// `BookmarksBarCalibrationProfile.cacheKey(browser:displayScale:)` (Part I:
/// "Store calibrated normalized region per: browser; UI density/scale;
/// display scale").
public final class BookmarksBarCalibrationStore {
    private let userDefaults: UserDefaults
    private let keyPrefix: String

    public init(userDefaults: UserDefaults = .standard, keyPrefix: String = "com.capture.bookmarksBar.calibration.") {
        self.userDefaults = userDefaults
        self.keyPrefix = keyPrefix
    }

    public func profile(browser: String, displayScale: Double) -> BookmarksBarCalibrationProfile? {
        let key = keyPrefix + BookmarksBarCalibrationProfile.cacheKey(browser: browser, displayScale: displayScale)
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try? CaptureCoreJSON.decoder.decode(BookmarksBarCalibrationProfile.self, from: data)
    }

    public func save(_ profile: BookmarksBarCalibrationProfile) {
        let key = keyPrefix + BookmarksBarCalibrationProfile.cacheKey(browser: profile.browser, displayScale: profile.displayScale)
        guard let data = try? CaptureCoreJSON.encoder.encode(profile) else { return }
        userDefaults.set(data, forKey: key)
    }

    public func removeProfile(browser: String, displayScale: Double) {
        let key = keyPrefix + BookmarksBarCalibrationProfile.cacheKey(browser: browser, displayScale: displayScale)
        userDefaults.removeObject(forKey: key)
    }
}

/// Pure Tier 3 application: scale a stored calibration to the current
/// window size. No AppKit/AX dependency — unit-tested directly.
public enum BookmarksBarCalibration {
    /// Fixed rather than recency-decayed confidence: the spec does not
    /// specify a decay curve for stale profiles, so we do not invent one —
    /// flagged here as a reasonable future refinement (e.g. a profile
    /// calibrated many browser-version-updates ago could plausibly count
    /// for less).
    public static let confidence = 0.8

    public static func result(profile: BookmarksBarCalibrationProfile?, windowSize: CaptureSize) -> BookmarksBarDetectionResult {
        guard let profile else {
            return BookmarksBarDetectionResult(source: .none, rect: nil, confidence: 0)
        }
        let rect = profile.normalizedRect.resolved(in: windowSize)
        return BookmarksBarDetectionResult(source: .learnedCalibration, rect: rect, confidence: confidence)
    }
}

// MARK: - Combining tiers into one result

/// Picks the best available detection result across tiers. Ranking is
/// primarily by confidence (Part I "Confidence and privacy-first
/// behaviour": a highly-confident lower-priority tier — e.g. a
/// well-calibrated Tier 3 profile — should win over a shaky higher-priority
/// tier result rather than being discarded outright), tie-broken by
/// hierarchy order (accessibility > extensionGeometry > learnedCalibration)
/// when two results report equal confidence. Pure — directly unit-tested.
public enum BookmarksBarDetectionCombiner {
    private static let tierPriority: [BookmarksBarDetectionSource: Int] = [
        .accessibility: 0,
        .extensionGeometry: 1,
        .learnedCalibration: 2,
        .none: 3
    ]

    public static func combine(
        accessibility: BookmarksBarDetectionResult?,
        extensionGeometry: BookmarksBarDetectionResult?,
        learnedCalibration: BookmarksBarDetectionResult?
    ) -> BookmarksBarDetectionResult {
        let candidates = [accessibility, extensionGeometry, learnedCalibration]
            .compactMap { $0 }
            .filter { $0.source != .none && $0.rect != nil }

        guard let best = candidates.max(by: { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
            let lhsPriority = tierPriority[lhs.source] ?? Int.max
            let rhsPriority = tierPriority[rhs.source] ?? Int.max
            // Equal confidence: the element with the *worse* (higher-
            // numbered) priority should be considered "less than" so
            // `max(by:)` keeps the higher-priority tier.
            return lhsPriority > rhsPriority
        }) else {
            return BookmarksBarDetectionResult(source: .none, rect: nil, confidence: 0)
        }
        return best
    }
}

// MARK: - Top-level orchestrator

/// The single entry point most callers (`CaptureUI`'s capture pipeline)
/// use: runs/collects Tier 1 and Tier 3, accepts an already-resolved Tier 2
/// result from `CaptureBrowserBridge`, and combines them respecting
/// `BookmarksBarDetectionResult.shouldAutoApply`/`minimumConfidenceToAutoApply`
/// — callers must check `shouldAutoApply` themselves before wiring up an
/// automatic redaction; this type never does that wiring itself, so there
/// is no code path here that can blindly apply a low-confidence redaction.
public final class BookmarksBarDetector {
    private let accessibilityDetector = BookmarksBarAccessibilityDetector()
    private let calibrationStore: BookmarksBarCalibrationStore

    public init(calibrationStore: BookmarksBarCalibrationStore = BookmarksBarCalibrationStore()) {
        self.calibrationStore = calibrationStore
    }

    /// Tier 1 only, exposed separately since it needs a live AXUIElement
    /// the caller must have already obtained (e.g. via
    /// `BookmarksBarAccessibilityDetector.focusedWindowElement(forProcessID:)`).
    public func detectAccessibility(windowElement: AXUIElement, browser: SupportedBrowser, windowFrame: CaptureRect) -> BookmarksBarDetectionResult {
        accessibilityDetector.detect(windowElement: windowElement, browser: browser, windowFrame: windowFrame)
    }

    /// Combines a fresh Tier 1 result (or `nil` if not run/available), an
    /// already-resolved Tier 2 result from `CaptureBrowserBridge` (or `nil`
    /// if no extension connection exists for this browser/tab), and the
    /// stored Tier 3 calibration profile (looked up here so callers don't
    /// each need their own `BookmarksBarCalibrationStore`) into one final
    /// result.
    public func combinedResult(
        accessibility: BookmarksBarDetectionResult?,
        extensionGeometry: BookmarksBarDetectionResult?,
        browser: SupportedBrowser,
        displayScale: Double,
        windowSize: CaptureSize
    ) -> BookmarksBarDetectionResult {
        let profile = calibrationStore.profile(browser: browser.rawValue, displayScale: displayScale)
        let tier3 = BookmarksBarCalibration.result(profile: profile, windowSize: windowSize)
        return BookmarksBarDetectionCombiner.combine(
            accessibility: accessibility,
            extensionGeometry: extensionGeometry,
            learnedCalibration: tier3
        )
    }

    public func saveCalibration(_ profile: BookmarksBarCalibrationProfile) {
        calibrationStore.save(profile)
    }
}
