import CaptureCore
import XCTest
@testable import CaptureBrowserBridge

final class ElementEvidenceStoreTests: XCTestCase {
    func testStoreAndRetrieveLatestEvidence() {
        let store = ElementEvidenceStore()
        let tabSessionId = UUID()
        XCTAssertNil(store.latestEvidence(forTabSession: tabSessionId))

        let evidence = Fixtures.elementEvidence()
        store.store(evidence, forTabSession: tabSessionId)
        XCTAssertEqual(store.latestEvidence(forTabSession: tabSessionId)?.id, evidence.id)
    }

    func testLatestEvidenceIsPerTabSession() {
        let store = ElementEvidenceStore()
        let tabA = UUID()
        let tabB = UUID()
        let evidenceA = Fixtures.elementEvidence(url: "https://a.example.com")
        store.store(evidenceA, forTabSession: tabA)
        XCTAssertNotNil(store.latestEvidence(forTabSession: tabA))
        XCTAssertNil(store.latestEvidence(forTabSession: tabB))
    }

    func testClearRemovesStoredEvidence() {
        let store = ElementEvidenceStore()
        let tabSessionId = UUID()
        store.store(Fixtures.elementEvidence(), forTabSession: tabSessionId)
        store.clear(forTabSession: tabSessionId)
        XCTAssertNil(store.latestEvidence(forTabSession: tabSessionId))
    }

    /// Models the real `element.captureRequest` -> `element.evidence` flow:
    /// a caller starts waiting *before* the evidence arrives, and the
    /// eventual `store(_:forTabSession:)` call (from the `element.evidence`
    /// handler) is what resolves it.
    func testAwaitNextEvidenceResolvesWhenEvidenceArrivesLater() async throws {
        let store = ElementEvidenceStore()
        let tabSessionId = UUID()
        let expectedEvidence = Fixtures.elementEvidence()

        let waiterTask = Task {
            try await store.awaitNextEvidence(forTabSession: tabSessionId, timeout: 5)
        }

        // Give the waiter a moment to register before the evidence arrives,
        // so this genuinely exercises the "wait first, resolve later" path
        // rather than a race that happens to work either order.
        try await Task.sleep(nanoseconds: 50_000_000)
        store.store(expectedEvidence, forTabSession: tabSessionId)

        let received = try await waiterTask.value
        XCTAssertEqual(received.id, expectedEvidence.id)
    }

    func testAwaitNextEvidenceTimesOutWhenNothingArrives() async {
        let store = ElementEvidenceStore()
        let tabSessionId = UUID()

        do {
            _ = try await store.awaitNextEvidence(forTabSession: tabSessionId, timeout: 0.05)
            XCTFail("expected a timeout error")
        } catch let error as ElementEvidenceStoreError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("expected ElementEvidenceStoreError.timedOut, got \(error)")
        }
    }

    func testMultipleWaitersForTheSameTabSessionAllResolve() async throws {
        let store = ElementEvidenceStore()
        let tabSessionId = UUID()
        let expectedEvidence = Fixtures.elementEvidence()

        async let first = store.awaitNextEvidence(forTabSession: tabSessionId, timeout: 5)
        async let second = store.awaitNextEvidence(forTabSession: tabSessionId, timeout: 5)

        try await Task.sleep(nanoseconds: 50_000_000)
        store.store(expectedEvidence, forTabSession: tabSessionId)

        let (a, b) = try await (first, second)
        XCTAssertEqual(a.id, expectedEvidence.id)
        XCTAssertEqual(b.id, expectedEvidence.id)
    }
}

extension ElementEvidenceStoreError: Equatable {
    public static func == (lhs: ElementEvidenceStoreError, rhs: ElementEvidenceStoreError) -> Bool {
        switch (lhs, rhs) {
        case (.timedOut, .timedOut), (.cancelled, .cancelled): return true
        default: return false
        }
    }
}
