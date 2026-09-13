import XCTest
@testable import CaptureBrowserBridge

final class TabSessionManagerTests: XCTestCase {
    func testStartSessionCreatesAnActiveSession() {
        let manager = TabSessionManager()
        let session = manager.startSession(tabURL: "https://example.com", tabTitle: "Example")
        XCTAssertTrue(manager.isActive(session.id))
        XCTAssertEqual(manager.session(for: session.id)?.tabURL, "https://example.com")
        XCTAssertEqual(manager.session(for: session.id)?.tabTitle, "Example")
        XCTAssertEqual(manager.activeSessionCount, 1)
    }

    func testEndSessionRemovesItImmediately() {
        let manager = TabSessionManager()
        let session = manager.startSession(tabURL: "https://example.com", tabTitle: nil)
        manager.endSession(session.id)
        XCTAssertFalse(manager.isActive(session.id))
        XCTAssertNil(manager.session(for: session.id))
        XCTAssertEqual(manager.activeSessionCount, 0)
    }

    func testUnknownSessionIsNotActive() {
        let manager = TabSessionManager()
        XCTAssertFalse(manager.isActive(UUID()))
        XCTAssertNil(manager.session(for: UUID()))
    }

    func testSessionExpiresAfterIdleTimeout() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let manager = TabSessionManager(idleTimeout: 60, now: { now })
        let session = manager.startSession(tabURL: "https://example.com", tabTitle: nil)
        XCTAssertTrue(manager.isActive(session.id))

        now = now.addingTimeInterval(61)
        XCTAssertFalse(manager.isActive(session.id), "session should be expired once idle time exceeds the timeout")
        XCTAssertNil(manager.session(for: session.id))
    }

    func testTouchRefreshesActivityAndPreventsExpiry() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let manager = TabSessionManager(idleTimeout: 60, now: { now })
        let session = manager.startSession(tabURL: "https://example.com", tabTitle: nil)

        now = now.addingTimeInterval(45)
        XCTAssertTrue(manager.touch(session.id), "touch should succeed while still within the idle window")

        now = now.addingTimeInterval(45) // 90s since start, but only 45s since the touch
        XCTAssertTrue(manager.isActive(session.id), "touch should have reset the idle clock")
    }

    func testTouchOnExpiredOrUnknownSessionFails() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let manager = TabSessionManager(idleTimeout: 60, now: { now })
        let session = manager.startSession(tabURL: "https://example.com", tabTitle: nil)

        now = now.addingTimeInterval(61)
        XCTAssertFalse(manager.touch(session.id))
        XCTAssertFalse(manager.touch(UUID()))
    }

    func testPurgeExpiredEvictsOnlyExpiredSessions() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let manager = TabSessionManager(idleTimeout: 60, now: { now })
        let stale = manager.startSession(tabURL: "https://stale.example.com", tabTitle: nil)

        now = now.addingTimeInterval(120)
        let fresh = manager.startSession(tabURL: "https://fresh.example.com", tabTitle: nil)

        let purged = manager.purgeExpired()
        XCTAssertEqual(purged, [stale.id])
        XCTAssertTrue(manager.isActive(fresh.id))
        XCTAssertEqual(manager.activeSessionCount, 1)
    }

    func testEachSessionGetsAUniqueId() {
        let manager = TabSessionManager()
        let a = manager.startSession(tabURL: "https://a.example.com", tabTitle: nil)
        let b = manager.startSession(tabURL: "https://b.example.com", tabTitle: nil)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(manager.activeSessionCount, 2)
    }
}
