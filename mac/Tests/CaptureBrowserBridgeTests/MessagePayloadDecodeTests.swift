import CaptureCore
import XCTest
@testable import CaptureBrowserBridge

/// Payload-level validation/decode tests — the part of the trust boundary
/// that never needs a live socket: a valid payload decodes into the exact
/// typed struct expected, and a malformed/oversized/wrong-shaped payload
/// produces `INVALID_MESSAGE` (or `PAYLOAD_TOO_LARGE` for length
/// violations) rather than crashing or silently passing through.
final class MessagePayloadDecodeTests: XCTestCase {
    // MARK: - session.start

    func testSessionStartDecodesAValidPayload() {
        let payload: JSONValue = .object(["tabUrl": .string("https://example.com/products/x"), "tabTitle": .string("Product X")])
        switch PayloadCodec.decode(SessionStartPayload.self, from: payload) {
        case .success(let decoded):
            XCTAssertEqual(decoded.tabUrl, "https://example.com/products/x")
            XCTAssertEqual(decoded.tabTitle, "Product X")
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testSessionStartAllowsOmittingOptionalTabTitle() {
        let payload: JSONValue = .object(["tabUrl": .string("https://example.com")])
        switch PayloadCodec.decode(SessionStartPayload.self, from: payload) {
        case .success(let decoded):
            XCTAssertNil(decoded.tabTitle)
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testSessionStartRejectsMissingRequiredTabUrl() {
        let payload: JSONValue = .object(["tabTitle": .string("Product X")])
        assertInvalidMessage(PayloadCodec.decode(SessionStartPayload.self, from: payload))
    }

    func testSessionStartRejectsUnexpectedField() {
        let payload: JSONValue = .object(["tabUrl": .string("https://example.com"), "sneaky": .string("rm -rf /")])
        assertInvalidMessage(PayloadCodec.decode(SessionStartPayload.self, from: payload))
    }

    func testSessionStartRejectsWrongType() {
        let payload: JSONValue = .array([.string("not an object")])
        assertInvalidMessage(PayloadCodec.decode(SessionStartPayload.self, from: payload))
    }

    func testSessionStartRejectsOversizedTabUrlAsPayloadTooLarge() {
        let oversized = String(repeating: "a", count: 4097)
        let payload: JSONValue = .object(["tabUrl": .string(oversized)])
        switch PayloadCodec.decode(SessionStartPayload.self, from: payload) {
        case .success:
            XCTFail("expected a failure for an oversized tabUrl")
        case .failure(let error):
            XCTAssertEqual(error.code, .payloadTooLarge)
        }
    }

    // MARK: - session.end / session.ping (empty payload)

    func testEmptyPayloadAcceptsAnEmptyObject() {
        switch PayloadCodec.decode(EmptyPayload.self, from: .object([:])) {
        case .success: break
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    func testEmptyPayloadRejectsAnyField() {
        assertInvalidMessage(PayloadCodec.decode(EmptyPayload.self, from: .object(["unexpected": .bool(true)])))
    }

    // MARK: - element.pin / element.evidence (full ElementEvidence)

    func testElementPinDecodesAValidEvidencePayload() throws {
        let evidence = Fixtures.elementEvidence()
        let payload: JSONValue = .object(["evidence": try Fixtures.evidencePayloadJSON(evidence)])
        switch PayloadCodec.decode(ElementPinPayload.self, from: payload) {
        case .success(let decoded):
            XCTAssertEqual(decoded.evidence.id, evidence.id)
            XCTAssertEqual(decoded.evidence.locator.primary, evidence.locator.primary)
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testElementPinRejectsMissingEvidence() {
        assertInvalidMessage(PayloadCodec.decode(ElementPinPayload.self, from: .object([:])))
    }

    func testElementPinRejectsMalformedEvidenceShape() {
        // "evidence" present, but not itself a well-formed ElementEvidence
        // object (missing every required field) — must not crash.
        let payload: JSONValue = .object(["evidence": .object(["nonsense": .bool(true)])])
        assertInvalidMessage(PayloadCodec.decode(ElementPinPayload.self, from: payload))
    }

    // MARK: - element.captureRequest (locator is a plain string here)

    func testElementCaptureRequestDecodesLocatorString() {
        let payload: JSONValue = .object(["locator": .string("button.submit"), "includeContextPaddingPx": .number(16)])
        switch PayloadCodec.decode(ElementCaptureRequestPayload.self, from: payload) {
        case .success(let decoded):
            XCTAssertEqual(decoded.locator, "button.submit")
            XCTAssertEqual(decoded.includeContextPaddingPx, 16)
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testElementCaptureRequestRejectsOversizedLocator() {
        let oversized = String(repeating: "x", count: 2049)
        let payload: JSONValue = .object(["locator": .string(oversized)])
        switch PayloadCodec.decode(ElementCaptureRequestPayload.self, from: payload) {
        case .success:
            XCTFail("expected a failure for an oversized locator")
        case .failure(let error):
            XCTAssertEqual(error.code, .payloadTooLarge)
        }
    }

    func testElementCaptureRequestRejectsOutOfRangePadding() {
        let payload: JSONValue = .object(["locator": .string("button"), "includeContextPaddingPx": .number(9999)])
        assertInvalidMessage(PayloadCodec.decode(ElementCaptureRequestPayload.self, from: payload))
    }

    // MARK: - element.resolveAnchor (locator is the FULL Locator object, not a string)

    func testElementResolveAnchorDecodesFullLocatorObject() {
        // NOTE: `ancestryFingerprint` is included even though
        // `schemas/project/element-evidence.schema.json` does not list it
        // as required — `CaptureCore.ElementEvidence.Locator.ancestryFingerprint`
        // is a non-optional `[String]` with no custom `Decodable` handling,
        // so Swift's synthesized decode requires the key even though the
        // schema doesn't. See this task's final report for the suspected
        // CaptureCore mismatch this implies for schema-valid-but-key-omitting
        // real-world payloads.
        let payload: JSONValue = .object([
            "locator": .object([
                "primary": .string("button.submit"),
                "candidates": .array([]),
                "ancestryFingerprint": .array([])
            ])
        ])
        switch PayloadCodec.decode(ElementResolveAnchorPayload.self, from: payload) {
        case .success(let decoded):
            XCTAssertEqual(decoded.locator.primary, "button.submit")
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testElementResolveAnchorRejectsAPlainStringLocator() {
        // This is the exact mistake the schema distinguishes:
        // element.captureRequest.locator is a string, but
        // element.resolveAnchor.locator must be the full Locator object.
        let payload: JSONValue = .object(["locator": .string("button.submit")])
        assertInvalidMessage(PayloadCodec.decode(ElementResolveAnchorPayload.self, from: payload))
    }

    // MARK: - tab.info

    func testTabInfoDecodesAValidPayload() {
        let payload: JSONValue = .object([
            "url": .string("https://example.com"),
            "title": .string("Example"),
            "viewport": .object([
                "width": .number(1440), "height": .number(900),
                "devicePixelRatio": .number(2), "scrollX": .number(0), "scrollY": .number(0)
            ])
        ])
        switch PayloadCodec.decode(TabInfoPayload.self, from: payload) {
        case .success(let decoded):
            XCTAssertEqual(decoded.url, "https://example.com")
            XCTAssertEqual(decoded.viewport.width, 1440)
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testTabInfoRejectsMissingViewport() {
        let payload: JSONValue = .object(["url": .string("https://example.com"), "title": .string("Example")])
        assertInvalidMessage(PayloadCodec.decode(TabInfoPayload.self, from: payload))
    }

    // MARK: - bookmarksBar.geometry

    func testBookmarksBarGeometryDecodesAValidPayload() {
        let payload: JSONValue = .object([
            "innerWidth": .number(1440), "innerHeight": .number(837),
            "outerWidth": .number(1440), "outerHeight": .number(900),
            "screenX": .number(0), "screenY": .number(0),
            "devicePixelRatio": .number(2), "browser": .string("chrome")
        ])
        switch PayloadCodec.decode(BookmarksBarGeometryPayload.self, from: payload) {
        case .success(let decoded):
            XCTAssertEqual(decoded.browser, .chrome)
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testBookmarksBarGeometryRejectsUnknownBrowserEnumValue() {
        let payload: JSONValue = .object([
            "innerWidth": .number(1440), "innerHeight": .number(837),
            "outerWidth": .number(1440), "outerHeight": .number(900),
            "screenX": .number(0), "screenY": .number(0),
            "devicePixelRatio": .number(2), "browser": .string("netscape-navigator")
        ])
        assertInvalidMessage(PayloadCodec.decode(BookmarksBarGeometryPayload.self, from: payload))
    }

    func testBookmarksBarGeometryRejectsMissingRequiredField() {
        let payload: JSONValue = .object([
            "innerWidth": .number(1440), "innerHeight": .number(837),
            "outerWidth": .number(1440), "outerHeight": .number(900),
            "screenX": .number(0)
            // missing screenY and devicePixelRatio
        ])
        assertInvalidMessage(PayloadCodec.decode(BookmarksBarGeometryPayload.self, from: payload))
    }

    // MARK: - bookmarksBar.calibrate

    func testBookmarksBarCalibrateDecodesAValidPayload() {
        let payload: JSONValue = .object([
            "browser": .string("chrome"),
            "displayScale": .number(2),
            "normalizedRect": .object(["x": .number(0), "y": .number(0), "width": .number(0.5), "height": .number(0.05)])
        ])
        switch PayloadCodec.decode(BookmarksBarCalibratePayload.self, from: payload) {
        case .success(let decoded):
            XCTAssertEqual(decoded.browser, "chrome")
            XCTAssertEqual(decoded.normalizedRect.width, 0.5)
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testBookmarksBarCalibrateRejectsOutOfRangeNormalizedRect() {
        let payload: JSONValue = .object([
            "browser": .string("chrome"),
            "normalizedRect": .object(["x": .number(0), "y": .number(0), "width": .number(1.5), "height": .number(0.05)])
        ])
        assertInvalidMessage(PayloadCodec.decode(BookmarksBarCalibratePayload.self, from: payload))
    }

    // MARK: - Helpers

    private func assertInvalidMessage<T>(_ result: Result<T, PayloadDecodeFailure>, file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success:
            XCTFail("expected a failure", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error.code, .invalidMessage, file: file, line: line)
        }
    }
}
