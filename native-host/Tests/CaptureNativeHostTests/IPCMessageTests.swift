import Foundation
import XCTest
@testable import CaptureNativeHost

final class InboundRequestIdentityTests: XCTestCase {
    func testExtractsIdFromWellFormedRequest() {
        let json = """
        {"version":1,"id":"3fa85f64-5717-4562-b3fc-2c963f66afa6","type":"session.ping","payload":{}}
        """
        let data = Data(json.utf8)
        XCTAssertEqual(InboundRequestIdentity.extractId(from: data), "3fa85f64-5717-4562-b3fc-2c963f66afa6")
    }

    func testExtractsIdEvenWhenOtherFieldsAreUnexpected() {
        // The host doesn't validate the rest of the envelope — only `id`
        // needs to be recoverable, per messages.schema.json validation
        // living in CaptureBrowserBridge, not here.
        let json = """
        {"id":"some-id","somethingElse":123,"nested":{"a":[1,2,3]}}
        """
        XCTAssertEqual(InboundRequestIdentity.extractId(from: Data(json.utf8)), "some-id")
    }

    func testReturnsNilForInvalidJSON() {
        let data = Data("not json at all {{{".utf8)
        XCTAssertNil(InboundRequestIdentity.extractId(from: data))
    }

    func testReturnsNilWhenIdFieldMissing() {
        let json = #"{"version":1,"type":"session.ping","payload":{}}"#
        XCTAssertNil(InboundRequestIdentity.extractId(from: Data(json.utf8)))
    }

    func testReturnsNilWhenIdIsNotAString() {
        let json = #"{"id":12345}"#
        XCTAssertNil(InboundRequestIdentity.extractId(from: Data(json.utf8)))
    }

    func testReturnsNilForEmptyData() {
        XCTAssertNil(InboundRequestIdentity.extractId(from: Data()))
    }

    func testReturnsNilForTopLevelJSONArray() {
        // A JSON array isn't a JSON object, so it can't decode into
        // InboundRequestIdentity's keyed container.
        let json = "[1,2,3]"
        XCTAssertNil(InboundRequestIdentity.extractId(from: Data(json.utf8)))
    }
}

final class FallbackRequestIdTests: XCTestCase {
    func testProducesAWellFormedUUIDString() {
        let id = fallbackRequestId()
        XCTAssertNotNil(UUID(uuidString: id), "fallbackRequestId() should produce a valid UUID string, got: \(id)")
    }

    func testProducesDistinctValuesOnEachCall() {
        XCTAssertNotEqual(fallbackRequestId(), fallbackRequestId())
    }
}

final class IPCErrorResponseTests: XCTestCase {
    func testEncodedShapeMatchesEnvelopeSchema() throws {
        let response = IPCErrorResponse(
            id: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            code: .internalError,
            message: "Capture.app is not reachable over the IPC socket."
        )
        let data = try response.encoded()

        // Decode as a loose JSON object and check exactly the shape
        // required by schemas/ipc/envelope.schema.json's `errorResponse`
        // definition: {version, id, ok, error: {code, message}}, with
        // `additionalProperties: false` and `ok` fixed to `false`.
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(raw.keys), ["version", "id", "ok", "error"])
        XCTAssertEqual(raw["version"] as? Int, 1)
        XCTAssertEqual(raw["id"] as? String, "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        XCTAssertEqual(raw["ok"] as? Bool, false)

        let error = try XCTUnwrap(raw["error"] as? [String: Any])
        XCTAssertEqual(Set(error.keys), ["code", "message"])
        XCTAssertEqual(error["code"] as? String, "INTERNAL_ERROR")
        XCTAssertEqual(error["message"] as? String, "Capture.app is not reachable over the IPC socket.")
    }

    func testEveryErrorCodeRawValueMatchesTheSchemasClosedEnum() {
        // schemas/ipc/envelope.schema.json's error.code enum, verbatim.
        let schemaCodes: Set<String> = [
            "ELEMENT_NOT_FOUND",
            "INVALID_MESSAGE",
            "UNSUPPORTED_TYPE",
            "TAB_SESSION_EXPIRED",
            "PAYLOAD_TOO_LARGE",
            "PERMISSION_DENIED",
            "INTERNAL_ERROR"
        ]
        let allCases: [IPCErrorCode] = [
            .elementNotFound, .invalidMessage, .unsupportedType,
            .tabSessionExpired, .payloadTooLarge, .permissionDenied, .internalError
        ]
        XCTAssertEqual(Set(allCases.map(\.rawValue)), schemaCodes)
    }

    func testRoundTripsThroughDecoding() throws {
        let original = IPCErrorResponse(id: "req-1", code: .payloadTooLarge, message: "too big")
        let data = try original.encoded()
        let decoded = try JSONDecoder().decode(IPCErrorResponse.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
