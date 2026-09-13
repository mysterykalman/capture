import CaptureCore
import Foundation

/// The result of a failed payload decode/validate, carrying the exact
/// `IPCErrorCode` the caller should put on the wire.
struct PayloadDecodeFailure: Error {
    let code: IPCErrorCode
    let message: String
}

/// Decodes and validates an inbound `IPCRequest.payload` (a
/// `CaptureCore.JSONValue`) into one specific `IPCPayload` type, per
/// docs/IPC_PROTOCOL.md: "validates every message against
/// schemas/ipc/messages.schema.json ... before dispatch". There is
/// deliberately no generic "decode whatever the caller asks for and hope"
/// path — every message-type handler in `BrowserBridgeService` calls this
/// with its own concrete `IPCPayload` type, so a payload can only ever be
/// interpreted as the one shape that type expects.
enum PayloadCodec {
    /// Order matches the schema's own validation order: shape, then
    /// closed key set, then required keys, then a real decode, then the
    /// constraints `Decodable` cannot express.
    static func decode<T: IPCPayload>(_ type: T.Type, from payload: JSONValue) -> Result<T, PayloadDecodeFailure> {
        guard case .object(let fields) = payload else {
            return .failure(PayloadDecodeFailure(code: .invalidMessage, message: "\(shortName(T.self)) payload must be a JSON object"))
        }

        let presentKeys = Set(fields.keys)
        let disallowed = presentKeys.subtracting(T.allowedKeys)
        guard disallowed.isEmpty else {
            return .failure(PayloadDecodeFailure(
                code: .invalidMessage,
                message: "\(shortName(T.self)) payload has unexpected field(s): \(disallowed.sorted().joined(separator: ", "))"
            ))
        }

        let missing = T.requiredKeys.subtracting(presentKeys)
        guard missing.isEmpty else {
            return .failure(PayloadDecodeFailure(
                code: .invalidMessage,
                message: "\(shortName(T.self)) payload is missing required field(s): \(missing.sorted().joined(separator: ", "))"
            ))
        }

        let decoded: T
        do {
            // JSONValue -> Data -> T. This is a re-encode through the
            // shared CaptureCoreJSON configuration (ISO-8601 dates, so
            // ElementEvidence.capturedAt round-trips correctly) rather than
            // a bespoke JSONValue -> Swift-type converter, so there is
            // exactly one JSON reader/writer pair in the whole app.
            let data = try CaptureCoreJSON.encoder.encode(payload)
            decoded = try CaptureCoreJSON.decoder.decode(T.self, from: data)
        } catch {
            return .failure(PayloadDecodeFailure(
                code: .invalidMessage,
                message: "\(shortName(T.self)) payload did not match the expected shape: \(String(describing: error))"
            ))
        }

        do {
            try decoded.validateConstraints()
        } catch let validationError as PayloadValidationError {
            let code: IPCErrorCode
            if case .tooLarge = validationError { code = .payloadTooLarge } else { code = .invalidMessage }
            return .failure(PayloadDecodeFailure(code: code, message: validationError.description))
        } catch {
            return .failure(PayloadDecodeFailure(code: .invalidMessage, message: String(describing: error)))
        }

        return .success(decoded)
    }

    /// Encodes an outbound app-initiated payload (e.g. `inspect.activate`)
    /// into the `JSONValue` an `IPCRequest` carries.
    static func encode<T: IPCPayload>(_ value: T) throws -> JSONValue {
        let data = try CaptureCoreJSON.encoder.encode(value)
        return try CaptureCoreJSON.decoder.decode(JSONValue.self, from: data)
    }

    private static func shortName(_ type: (some Any).Type) -> String {
        String(describing: type)
    }
}
