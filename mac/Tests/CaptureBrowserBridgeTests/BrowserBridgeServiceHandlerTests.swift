import CaptureCore
import XCTest
@testable import CaptureBrowserBridge

/// End-to-end tests of the *dispatch* side (no socket): drives real
/// requests through `BrowserBridgeService`'s actual registered handlers via
/// its `dispatcher`, exercising the full validate -> session-check ->
/// store -> respond path exactly as a live connection would, but without
/// needing one. This is what proves `element.pin` really does reach
/// `latestEvidence(forTabSession:)` — the join the whole module exists for.
final class BrowserBridgeServiceHandlerTests: XCTestCase {
    private func makeService() -> BrowserBridgeService {
        // A throwaway, per-test socket path keeps `start()`/`stop()` out of
        // these tests entirely — they only exercise `dispatcher.dispatch`.
        let tempSocket = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-test-\(UUID().uuidString).sock")
        return BrowserBridgeService(socketURL: tempSocket, appVersion: "9.9.9")
    }

    func testSessionStartThenElementPinMakesEvidenceReadable() throws {
        let service = makeService()

        let startResponse = service.dispatcher.dispatch(
            IPCRequest(type: .sessionStart, payload: .object(["tabUrl": .string("https://example.com/products/x")]))
        )
        guard case .success(let startPayload) = startResponse.result,
              let tabSessionIdString = startPayload["tabSessionId"]?.stringValue,
              let tabSessionId = UUID(uuidString: tabSessionIdString)
        else { return XCTFail("expected session.start to succeed with a tabSessionId") }

        XCTAssertNil(service.latestEvidence(forTabSession: tabSessionId), "no evidence pinned yet")

        let evidence = Fixtures.elementEvidence()
        let pinResponse = service.dispatcher.dispatch(
            IPCRequest(
                type: .elementPin,
                tabSessionId: tabSessionId,
                payload: .object(["evidence": try Fixtures.evidencePayloadJSON(evidence)])
            )
        )
        guard case .success = pinResponse.result else { return XCTFail("expected element.pin to succeed") }

        let stored = service.latestEvidence(forTabSession: tabSessionId)
        XCTAssertEqual(stored?.id, evidence.id)
        XCTAssertEqual(stored?.locator.primary, evidence.locator.primary)
    }

    func testElementPinWithoutASessionIsRejectedAsTabSessionExpired() throws {
        let service = makeService()
        let evidence = Fixtures.elementEvidence()

        let response = service.dispatcher.dispatch(
            IPCRequest(
                type: .elementPin,
                tabSessionId: UUID(), // never created via session.start
                payload: .object(["evidence": try Fixtures.evidencePayloadJSON(evidence)])
            )
        )
        guard case .failure(let error) = response.result else { return XCTFail("expected a failure response") }
        XCTAssertEqual(error.code, .tabSessionExpired)
    }

    func testElementPinWithoutATabSessionIdAtAllIsRejected() throws {
        let service = makeService()
        let evidence = Fixtures.elementEvidence()
        let response = service.dispatcher.dispatch(
            IPCRequest(type: .elementPin, payload: .object(["evidence": try Fixtures.evidencePayloadJSON(evidence)]))
        )
        guard case .failure(let error) = response.result else { return XCTFail("expected a failure response") }
        XCTAssertEqual(error.code, .tabSessionExpired)
    }

    func testSessionEndClearsBothTheSessionAndItsEvidence() throws {
        let service = makeService()
        let startResponse = service.dispatcher.dispatch(
            IPCRequest(type: .sessionStart, payload: .object(["tabUrl": .string("https://example.com")]))
        )
        guard case .success(let payload) = startResponse.result,
              let tabSessionId = (payload["tabSessionId"]?.stringValue).flatMap(UUID.init(uuidString:))
        else { return XCTFail("expected session.start to succeed") }

        let evidence = Fixtures.elementEvidence()
        _ = service.dispatcher.dispatch(IPCRequest(
            type: .elementPin, tabSessionId: tabSessionId,
            payload: .object(["evidence": try Fixtures.evidencePayloadJSON(evidence)])
        ))
        XCTAssertNotNil(service.latestEvidence(forTabSession: tabSessionId))

        let endResponse = service.dispatcher.dispatch(IPCRequest(type: .sessionEnd, tabSessionId: tabSessionId, payload: .object([:])))
        guard case .success = endResponse.result else { return XCTFail("expected session.end to succeed") }

        XCTAssertNil(service.latestEvidence(forTabSession: tabSessionId), "evidence should be cleared on session.end")
        XCTAssertFalse(service.sessions.isActive(tabSessionId))
    }

    func testSessionPingReturnsTheConfiguredAppVersion() {
        let service = makeService()
        let response = service.dispatcher.dispatch(IPCRequest(type: .sessionPing, payload: .object([:])))
        guard case .success(let payload) = response.result else { return XCTFail("expected success") }
        XCTAssertEqual(payload["appVersion"]?.stringValue, "9.9.9")
    }

    /// The four app-initiated message types must never be *accepted* as
    /// inbound requests, even though they are legitimate `IPCMessageType`
    /// values with registered handlers (per-type, not a generic fallback).
    func testAppInitiatedTypesAreRefusedIfTheyArriveInbound() {
        let service = makeService()
        for type: IPCMessageType in [.inspectActivate, .inspectDeactivate, .elementCaptureRequest, .elementResolveAnchor] {
            let response = service.dispatcher.dispatch(IPCRequest(type: type, payload: .object([:])))
            guard case .failure(let error) = response.result else {
                XCTFail("expected \(type.rawValue) to be refused inbound")
                continue
            }
            XCTAssertEqual(error.code, .invalidMessage, "\(type.rawValue) should be refused as invalid, not silently accepted")
        }
    }

    func testMalformedElementPinPayloadIsRejectedWithoutCrashingAndWithoutStoringAnything() throws {
        let service = makeService()
        let startResponse = service.dispatcher.dispatch(
            IPCRequest(type: .sessionStart, payload: .object(["tabUrl": .string("https://example.com")]))
        )
        guard case .success(let payload) = startResponse.result,
              let tabSessionId = (payload["tabSessionId"]?.stringValue).flatMap(UUID.init(uuidString:))
        else { return XCTFail("expected session.start to succeed") }

        let response = service.dispatcher.dispatch(
            IPCRequest(type: .elementPin, tabSessionId: tabSessionId, payload: .object(["evidence": .string("not an object")]))
        )
        guard case .failure(let error) = response.result else { return XCTFail("expected a failure response") }
        XCTAssertEqual(error.code, .invalidMessage)
        XCTAssertNil(service.latestEvidence(forTabSession: tabSessionId))
    }
}
