import CaptureCore
import Foundation

/// The result of classifying one raw inbound frame, before any dispatch
/// happens. Kept transport-agnostic (plain `Data` in, no socket/`NWConnection`
/// involved) so it is fully unit-testable — see
/// `Tests/CaptureBrowserBridgeTests/MessageDispatcherTests.swift`.
enum InboundFrame {
    /// A well-formed request envelope for one of the twelve known
    /// message types. Still needs `MessageDispatcher.dispatch(_:)` to
    /// validate/decode its `payload` against the specific shape for
    /// `request.type`.
    case request(IPCRequest)
    /// A well-formed `{ok, ...}` response envelope — the reply to a
    /// request `BrowserBridgeService` sent (e.g. an `inspect.activate`
    /// ack, or an `element.resolveAnchor` result). The transport layer
    /// routes these to whichever caller is awaiting that `id`.
    case response(IPCResponse)
    /// Parsed far enough to recover an `id` (and therefore can be
    /// answered), but invalid in some way the sender should be told
    /// about: wrong envelope version, unknown `type`, disallowed
    /// top-level field, or a `payload` that doesn't even decode as an
    /// object. Carries the exact `IPCResponse` to send back.
    case rejected(IPCResponse)
    /// Not even parseable as JSON, or missing the `id` needed to answer
    /// it at all. Per the envelope schema every response requires an
    /// `id`, so there is no way to reply to this — the transport layer
    /// should log it and drop it, never partially act on it.
    case unreadable(reason: String)
}

/// Validates every inbound frame against `schemas/ipc/envelope.schema.json`
/// and `messages.schema.json` before it reaches any handler, and routes
/// each validated request to exactly one explicitly-registered handler
/// closure per `IPCMessageType`. This is the security-critical trust
/// boundary described in docs/IPC_PROTOCOL.md: everything arriving here
/// originates, transitively, from an arbitrary web page's content script.
/// There is intentionally no generic "execute this message" path — an
/// unregistered or unrecognized `type` is rejected with `UNSUPPORTED_TYPE`,
/// never silently ignored or passed through.
final class MessageDispatcher: @unchecked Sendable {
    typealias Handler = @Sendable (IPCRequest) -> IPCResponse

    private let lock = NSLock()
    private var handlers: [IPCMessageType: Handler] = [:]

    /// Envelope-level keys `schemas/ipc/envelope.schema.json`'s `request`
    /// definition allows (`additionalProperties: false`).
    private static let allowedEnvelopeKeys: Set<String> = ["version", "id", "type", "tabSessionId", "payload"]

    init() {}

    /// Registers the one handler for `type`. Calling this again for the
    /// same type replaces the previous handler (used only at startup
    /// wiring time in `BrowserBridgeService`, never per-request).
    func register(_ type: IPCMessageType, handler: @escaping Handler) {
        lock.lock()
        handlers[type] = handler
        lock.unlock()
    }

    /// Stage 1: figure out, from as little trust as possible, what kind of
    /// envelope this frame is. Never throws — every failure mode becomes an
    /// `InboundFrame` case the caller can act on safely.
    func classify(_ data: Data) -> InboundFrame {
        guard let header = try? CaptureCoreJSON.decoder.decode(EnvelopeHeader.self, from: data) else {
            return .unreadable(reason: "Frame did not parse as a JSON object with recognizable envelope fields")
        }

        if let ok = header.ok {
            // Response-shaped envelope: this is a reply to a request we
            // (the app) sent, not a new inbound request to dispatch.
            guard header.version == 1 else {
                return .unreadable(reason: "Response envelope has unsupported version \(header.version.map(String.init) ?? "nil")")
            }
            guard let response = try? CaptureCoreJSON.decoder.decode(IPCResponse.self, from: data) else {
                return .unreadable(reason: "Frame declared ok=\(ok) but did not match the response/errorResponse schema")
            }
            return .response(response)
        }

        guard let id = header.id else {
            return .unreadable(reason: "Frame has neither 'ok' nor a usable 'id' — cannot be answered")
        }

        guard header.version == 1 else {
            return .rejected(.failure(id: id, code: .invalidMessage, message: "Unsupported envelope version"))
        }

        guard let typeString = header.type else {
            return .rejected(.failure(id: id, code: .invalidMessage, message: "Request envelope is missing 'type'"))
        }

        guard IPCMessageType(rawValue: typeString) != nil else {
            return .rejected(.failure(id: id, code: .unsupportedType, message: "Unknown message type '\(typeString)'"))
        }

        guard
            let topLevel = try? CaptureCoreJSON.decoder.decode(JSONValue.self, from: data),
            case .object(let topLevelFields) = topLevel
        else {
            return .rejected(.failure(id: id, code: .invalidMessage, message: "Envelope must be a JSON object"))
        }

        let extraKeys = Set(topLevelFields.keys).subtracting(Self.allowedEnvelopeKeys)
        guard extraKeys.isEmpty else {
            return .rejected(.failure(
                id: id,
                code: .invalidMessage,
                message: "Envelope has unexpected field(s): \(extraKeys.sorted().joined(separator: ", "))"
            ))
        }

        guard let request = try? CaptureCoreJSON.decoder.decode(IPCRequest.self, from: data) else {
            return .rejected(.failure(id: id, code: .invalidMessage, message: "Envelope did not match the request schema"))
        }

        return .request(request)
    }

    /// Stage 2: route an already-classified `.request` to its one
    /// registered handler. The handler itself is responsible for
    /// validating/decoding `request.payload` via `PayloadCodec` against
    /// the specific shape for its type — `dispatch` never inspects the
    /// payload itself, it only routes by `type`.
    func dispatch(_ request: IPCRequest) -> IPCResponse {
        lock.lock()
        let handler = handlers[request.type]
        lock.unlock()

        guard let handler else {
            // Defensive: every case of IPCMessageType is registered by
            // BrowserBridgeService at startup, so this only fires if a
            // future message type is added to the enum without a
            // corresponding handler — still answered explicitly, never a
            // silent no-op.
            return .failure(id: request.id, code: .unsupportedType, message: "No handler registered for '\(request.type.rawValue)'")
        }
        return handler(request)
    }
}
