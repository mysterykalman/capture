import XCTest
import CaptureCore
import CoreGraphics
@testable import CaptureCapture

final class BookmarksBarDetectionCombinerTests: XCTestCase {
    func testPrefersHigherConfidenceRegardlessOfTier() {
        let accessibility = BookmarksBarDetectionResult(source: .accessibility, rect: CaptureRect(x: 0, y: 0, width: 800, height: 30), confidence: 0.5)
        let calibration = BookmarksBarDetectionResult(source: .learnedCalibration, rect: CaptureRect(x: 0, y: 0, width: 800, height: 28), confidence: 0.9)
        let result = BookmarksBarDetectionCombiner.combine(accessibility: accessibility, extensionGeometry: nil, learnedCalibration: calibration)
        XCTAssertEqual(result.source, .learnedCalibration, "a well-calibrated Tier 3 profile should outrank a shaky Tier 1 hit")
        XCTAssertEqual(result.confidence, 0.9)
    }

    func testTiesBreakByHierarchyOrder() {
        let accessibility = BookmarksBarDetectionResult(source: .accessibility, rect: CaptureRect(x: 0, y: 0, width: 800, height: 30), confidence: 0.8)
        let extensionGeometry = BookmarksBarDetectionResult(source: .extensionGeometry, rect: CaptureRect(x: 0, y: 0, width: 800, height: 30), confidence: 0.8)
        let calibration = BookmarksBarDetectionResult(source: .learnedCalibration, rect: CaptureRect(x: 0, y: 0, width: 800, height: 30), confidence: 0.8)

        let result = BookmarksBarDetectionCombiner.combine(accessibility: accessibility, extensionGeometry: extensionGeometry, learnedCalibration: calibration)
        XCTAssertEqual(result.source, .accessibility, "Tier 1 must win a tie over Tier 2/3")

        let result2 = BookmarksBarDetectionCombiner.combine(accessibility: nil, extensionGeometry: extensionGeometry, learnedCalibration: calibration)
        XCTAssertEqual(result2.source, .extensionGeometry, "Tier 2 must win a tie over Tier 3 when Tier 1 is absent")
    }

    func testAllNilProducesNoneSource() {
        let result = BookmarksBarDetectionCombiner.combine(accessibility: nil, extensionGeometry: nil, learnedCalibration: nil)
        XCTAssertEqual(result.source, .none)
        XCTAssertNil(result.rect)
        XCTAssertFalse(result.shouldAutoApply)
    }

    func testSourceNoneCandidatesAreExcludedEvenWithHighConfidence() {
        // A caller should never pass .none with a high confidence, but the
        // combiner must not be fooled into treating it as usable if it does.
        let bogus = BookmarksBarDetectionResult(source: .none, rect: CaptureRect(x: 0, y: 0, width: 800, height: 30), confidence: 0.99)
        let calibration = BookmarksBarDetectionResult(source: .learnedCalibration, rect: CaptureRect(x: 0, y: 0, width: 800, height: 28), confidence: 0.7)
        let result = BookmarksBarDetectionCombiner.combine(accessibility: bogus, extensionGeometry: nil, learnedCalibration: calibration)
        XCTAssertEqual(result.source, .learnedCalibration)
    }

    func testLowConfidenceBestResultStillReturnedButDoesNotAutoApply() {
        // Tier 4 "confidence and privacy-first behaviour": below-threshold
        // results are still surfaced (for a preview/manual prompt) rather
        // than silently discarded, but must never auto-apply.
        let weak = BookmarksBarDetectionResult(source: .extensionGeometry, rect: CaptureRect(x: 0, y: 0, width: 800, height: 30), confidence: 0.3)
        let result = BookmarksBarDetectionCombiner.combine(accessibility: nil, extensionGeometry: weak, learnedCalibration: nil)
        XCTAssertEqual(result.source, .extensionGeometry)
        XCTAssertFalse(result.shouldAutoApply)
    }

    func testHighConfidenceResultAutoApplies() {
        let strong = BookmarksBarDetectionResult(source: .accessibility, rect: CaptureRect(x: 0, y: 0, width: 800, height: 30), confidence: 0.9)
        let result = BookmarksBarDetectionCombiner.combine(accessibility: strong, extensionGeometry: nil, learnedCalibration: nil)
        XCTAssertTrue(result.shouldAutoApply)
    }
}

final class BookmarksBarCalibrationTests: XCTestCase {
    func testResolvesNormalizedRectAgainstWindowSize() {
        let profile = BookmarksBarCalibrationProfile(
            browser: "chrome",
            displayScale: 2.0,
            normalizedRect: NormalizedRect(x: 0, y: 0, width: 1.0, height: 0.03125)
        )
        let result = BookmarksBarCalibration.result(profile: profile, windowSize: CaptureSize(width: 1440, height: 900))
        XCTAssertEqual(result.source, .learnedCalibration)
        XCTAssertEqual(result.rect?.width, 1440, accuracy: 0.001)
        XCTAssertEqual(result.rect?.height, 28.125, accuracy: 0.001)
        XCTAssertEqual(result.confidence, BookmarksBarCalibration.confidence)
    }

    func testNilProfileProducesNoneSource() {
        let result = BookmarksBarCalibration.result(profile: nil, windowSize: CaptureSize(width: 1440, height: 900))
        XCTAssertEqual(result.source, .none)
        XCTAssertFalse(result.shouldAutoApply)
    }
}

final class BookmarksBarCalibrationStoreTests: XCTestCase {
    func testSaveAndLoadRoundTrip() {
        let suiteName = "com.capture.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create ephemeral UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BookmarksBarCalibrationStore(userDefaults: defaults)
        // `calibratedAt` is pinned to a whole-second `Date` deliberately:
        // `CaptureCoreJSON`'s `.iso8601` encoding strategy round-trips
        // through a formatter with no fractional-second component, so a
        // sub-second-precision `Date()` would compare unequal after
        // decode — not a bug in the store, just a JSON round-trip
        // precision limit this test avoids exercising.
        let profile = BookmarksBarCalibrationProfile(
            browser: "chrome",
            displayScale: 2.0,
            normalizedRect: NormalizedRect(x: 0, y: 0.9, width: 1.0, height: 0.03),
            calibratedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.save(profile)

        let loaded = store.profile(browser: "chrome", displayScale: 2.0)
        XCTAssertEqual(loaded, profile)

        // A different display scale for the same browser must be a
        // distinct cache entry (Part I: "per: browser; UI density/scale;
        // display scale").
        XCTAssertNil(store.profile(browser: "chrome", displayScale: 1.0))
    }

    func testRemoveProfile() {
        let suiteName = "com.capture.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create ephemeral UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BookmarksBarCalibrationStore(userDefaults: defaults)
        let profile = BookmarksBarCalibrationProfile(
            browser: "brave", displayScale: 1.0,
            normalizedRect: NormalizedRect(x: 0, y: 0, width: 1, height: 0.03),
            calibratedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.save(profile)
        store.removeProfile(browser: "brave", displayScale: 1.0)
        XCTAssertNil(store.profile(browser: "brave", displayScale: 1.0))
    }
}

final class BookmarksBarExtensionGeometryTests: XCTestCase {
    func testDerivesPlausibleBarRectFromChromeBand() {
        // outerHeight - innerHeight = 88 CSS px of browser chrome at 2x =
        // 44pt combined title+tabs+bookmarks band.
        let report = BookmarksBarExtensionGeometry.Report(
            innerWidth: 1440, innerHeight: 812, outerWidth: 1440, outerHeight: 900, devicePixelRatio: 2.0
        )
        let windowFrame = CaptureRect(x: 100, y: 100, width: 1440, height: 968)
        let result = BookmarksBarExtensionGeometry.result(report: report, browserWindowFrame: windowFrame)
        XCTAssertEqual(result.source, .extensionGeometry)
        XCTAssertEqual(result.rect?.width, 1440, accuracy: 0.001)
        XCTAssertEqual(result.confidence, 0.65)
        // Bar height is capped at 36pt even though the whole chrome band is 44pt.
        XCTAssertEqual(result.rect?.height, 36, accuracy: 0.001)
    }

    func testDegenerateGeometryProducesNoneSource() {
        let report = BookmarksBarExtensionGeometry.Report(innerWidth: 0, innerHeight: 0, outerWidth: 0, outerHeight: 0, devicePixelRatio: 2.0)
        let result = BookmarksBarExtensionGeometry.result(report: report, browserWindowFrame: .zero)
        XCTAssertEqual(result.source, .none)
    }

    func testOuterNotExceedingInnerProducesNoneSource() {
        // A malformed/adversarial report shouldn't produce a negative-height rect.
        let report = BookmarksBarExtensionGeometry.Report(innerWidth: 1440, innerHeight: 900, outerWidth: 1440, outerHeight: 900, devicePixelRatio: 1.0)
        let result = BookmarksBarExtensionGeometry.result(report: report, browserWindowFrame: .zero)
        XCTAssertEqual(result.source, .none)
    }
}

final class BookmarksBarAccessibilityHeuristicTests: XCTestCase {
    // `evaluateCandidate` is the one piece of Tier 1 that's pure geometry
    // math (no live AXUIElement needed), so it's exercised directly here
    // even though the AX tree walk itself is not unit-tested.

    func testPlausibleBarGeometryScoresAboveAutoApplyThreshold() {
        let frame = CGRect(x: 0, y: 80, width: 1440, height: 30)
        let windowFrame = CaptureRect(x: 0, y: 0, width: 1440, height: 900)
        let confidence = BookmarksBarAccessibilityDetector.evaluateCandidate(frame: frame, windowFrame: windowFrame)
        XCTAssertGreaterThanOrEqual(confidence, BookmarksBarDetectionResult.minimumConfidenceToAutoApply)
    }

    func testImplausibleHeightScoresLower() {
        let plausible = BookmarksBarAccessibilityDetector.evaluateCandidate(
            frame: CGRect(x: 0, y: 80, width: 1440, height: 30),
            windowFrame: CaptureRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let implausible = BookmarksBarAccessibilityDetector.evaluateCandidate(
            frame: CGRect(x: 0, y: 80, width: 1440, height: 400),
            windowFrame: CaptureRect(x: 0, y: 0, width: 1440, height: 900)
        )
        XCTAssertLessThan(implausible, plausible)
    }

    func testNarrowElementScoresLowerThanFullWidthElement() {
        let full = BookmarksBarAccessibilityDetector.evaluateCandidate(
            frame: CGRect(x: 0, y: 80, width: 1440, height: 30),
            windowFrame: CaptureRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let narrow = BookmarksBarAccessibilityDetector.evaluateCandidate(
            frame: CGRect(x: 0, y: 80, width: 200, height: 30),
            windowFrame: CaptureRect(x: 0, y: 0, width: 1440, height: 900)
        )
        XCTAssertLessThan(narrow, full)
    }
}
