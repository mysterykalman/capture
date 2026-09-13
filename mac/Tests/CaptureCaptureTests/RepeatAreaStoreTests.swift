import XCTest
import CaptureCore
@testable import CaptureCapture

final class RepeatAreaStoreTests: XCTestCase {
    private func makeStore() -> (RepeatAreaStore, String) {
        let suiteName = "com.capture.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (RepeatAreaStore(userDefaults: defaults, key: "test.repeatArea"), suiteName)
    }

    func testSaveAndLoadRoundTrip() {
        let (store, suiteName) = makeStore()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let region = RepeatAreaRegion(
            rect: CaptureRect(x: 10, y: 20, width: 400, height: 300),
            displayID: 69732800,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.save(region)

        let loaded = store.load()
        XCTAssertEqual(loaded, region)
    }

    func testLoadWithNothingSavedReturnsNil() {
        let (store, suiteName) = makeStore()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        XCTAssertNil(store.load())
    }

    func testClearRemovesTheSavedRegion() {
        let (store, suiteName) = makeStore()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        store.save(RepeatAreaRegion(rect: CaptureRect(x: 0, y: 0, width: 100, height: 100)))
        store.clear()
        XCTAssertNil(store.load())
    }

    func testMostRecentSaveWins() {
        let (store, suiteName) = makeStore()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        store.save(RepeatAreaRegion(rect: CaptureRect(x: 0, y: 0, width: 100, height: 100), capturedAt: Date(timeIntervalSince1970: 1)))
        let second = RepeatAreaRegion(rect: CaptureRect(x: 5, y: 5, width: 50, height: 50), capturedAt: Date(timeIntervalSince1970: 2))
        store.save(second)
        XCTAssertEqual(store.load(), second)
    }

    func testCaptureRatioIsDerivedFromRect() {
        let region = RepeatAreaRegion(rect: CaptureRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertEqual(region.captureRatio, 2.0, accuracy: 0.0001)
    }

    func testCaptureRatioIsZeroForZeroHeight() {
        let region = RepeatAreaRegion(rect: CaptureRect(x: 0, y: 0, width: 400, height: 0))
        XCTAssertEqual(region.captureRatio, 0)
    }
}
