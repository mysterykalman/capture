import CaptureCore
import XCTest
@testable import CaptureBrowserBridge

final class MessageDispatcherClassifyTests: XCTestCase {
    func testClassifyRecognizesAWellFormedRequest() {
        let dispatcher = MessageDispatcher()
        let data = Fixtures.requestFrame(type: "session.ping")
        switch dispatcher.classify(data) {
        case .request(let request):
            XCTAssertEqual(request.type, .sessionPing)
        default:
            XCTFail("expected .request")
        }
    }

    func testClassifyRecognizesAResponseEnvelope() throws {
        let dispatcher = MessageDispatcher()
        let response = IPCResponse.success(id: UUID(), payload: .object(["appVersion": .string("1.0")]))
        let data = try CaptureCoreJSON.encoder.encode(response)
        switch dispatcher.classify(data) {
        case .response(let decoded):
            XCTAssertEqual(decoded.id, response.id)
        default:
            XCTFail("expected .response")
        }
    }

    func testClassifyRejectsUnknownMessageTypeWithUnsupportedType() {
        let dispatcher = MessageDispatcher()
        let data = Fixtures.requestFrame(type: "element.teleport")
        switch dispatcher.classify(data) {
        case .rejected(let response):
            guard case .failure(let error) = response.result else { return XCTFail("expected a failure response") }
            XCTAssertEqual(error.code, .unsupportedType)
        default:
            XCTFail("expected .rejected")
        }
    }

    func testClassifyRejectsWrongEnvelopeVersion() {
        let dispatcher = MessageDispatcher()
        let id = UUID()
        let data = try! JSONSerialization.data(withJSONObject: [
            "version": 2,
            "id": id.uuidString,
            "type": "session.ping",
            "payload": [String: Any]()
        ])
        switch dispatcher.classify(data) {
        case .rejected(let response):
            guard case .failure(let error) = response.result else { return XCTFail("expected a failure response") }
            XCTAssertEqual(error.code, .invalidMessage)
            XCTAssertEqual(response.id, id)
        default:
            XCTFail("expected .rejected")
        }
    }

    func testClassifyRejectsUnexpectedTopLevelField() {
        let dispatcher = MessageDispatcher()
        let id = UUID()
        let data = try! JSONSerialization.data(withJSONObject: [
            "version": 1,
            "id": id.uuidString,
            "type": "session.ping",
            "payload": [String: Any](),
            "extraField": "should not be here"
        ])
        switch dispatcher.classify(data) {
        case .rejected(let response):
            guard case .failure(let error) = response.result else { return XCTFail("expected a failure response") }
            XCTAssertEqual(error.code, .invalidMessage)
        default:
            XCTFail("expected .rejected")
        }
    }

    func testClassifyIsUnreadableWhenThereIsNoId() {
        let dispatcher = MessageDispatcher()
        let data = try! JSONSerialization.data(withJSONObject: [
            "version": 1,
            "type": "session.ping",
            "payload": [String: Any]()
        ])
        switch dispatcher.classify(data) {
        case .unreadable:
            break
        default:
            XCTFail("expected .unreadable")
        }
    }

    func testClassifyIsUnreadableForNonJSONGarbage() {
        let dispatcher = MessageDispatcher()
        let data = Data("not json at all".utf8)
        switch dispatcher.classify(data) {
        case .unreadable:
            break
        default:
            XCTFail("expected .unreadable")
        }
    }

    func testClassifyDoesNotCrashOnOversizedOrDeeplyNestedPayload() {
        let dispatcher = MessageDispatcher()
        // A payload with many keys shouldn't crash classification — it's
        // still a well-formed envelope; per-message size limits are
        // enforced later by PayloadCodec against the specific schema.
        var bigPayload: [String: Any] = [:]
        for i in 0..<5000 { bigPayload["key\(i)"] = "value" }
        let data = Fixtures.requestFrame(type: "tab.info", payload: bigPayload)
        switch dispatcher.classify(data) {
        case .request(let request):
            XCTAssertEqual(request.type, .tabInfo)
        default:
            XCTFail("expected .request even for a large payload object")
        }
    }
}

final class MessageDispatcherDispatchTests: XCTestCase {
    func testDispatchRoutesToTheRegisteredHandlerForItsType() {
        let dispatcher = MessageDispatcher()
        var calledWithType: IPCMessageType?
        dispatcher.register(.sessionPing) { request in
            calledWithType = request.type
            return .success(id: request.id, payload: .object([:]))
        }
        let request = IPCRequest(type: .sessionPing, payload: .object([:]))
        _ = dispatcher.dispatch(request)
        XCTAssertEqual(calledWithType, .sessionPing)
    }

    func testDispatchDoesNotInvokeAHandlerRegisteredForADifferentType() {
        let dispatcher = MessageDispatcher()
        var pingCalled = false
        var startCalled = false
        dispatcher.register(.sessionPing) { request in pingCalled = true; return .success(id: request.id, payload: .object([:])) }
        dispatcher.register(.sessionStart) { request in startCalled = true; return .success(id: request.id, payload: .object([:])) }

        _ = dispatcher.dispatch(IPCRequest(type: .sessionStart, payload: .object(["tabUrl": .string("https://example.com")])))

        XCTAssertTrue(startCalled)
        XCTAssertFalse(pingCalled)
    }

    func testDispatchWithNoRegisteredHandlerReturnsUnsupportedType() {
        let dispatcher = MessageDispatcher()
        let request = IPCRequest(type: .sessionPing, payload: .object([:]))
        let response = dispatcher.dispatch(request)
        guard case .failure(let error) = response.result else { return XCTFail("expected a failure response") }
        XCTAssertEqual(error.code, .unsupportedType)
    }

    func testRegisteringTwiceReplacesThePreviousHandler() {
        let dispatcher = MessageDispatcher()
        dispatcher.register(.sessionPing) { request in .success(id: request.id, payload: .object(["appVersion": .string("old")])) }
        dispatcher.register(.sessionPing) { request in .success(id: request.id, payload: .object(["appVersion": .string("new")])) }

        let response = dispatcher.dispatch(IPCRequest(type: .sessionPing, payload: .object([:])))
        guard case .success(let payload) = response.result else { return XCTFail("expected success") }
        XCTAssertEqual(payload["appVersion"]?.stringValue, "new")
    }
}
