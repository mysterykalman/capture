import Foundation

/// The closed set of `error.code` values from
/// `schemas/ipc/envelope.schema.json`. This host only ever synthesizes
/// `.internalError` itself (when Capture.app is unreachable) and
/// `.payloadTooLarge` (when a frame from Chrome is rejected before it can
/// even be parsed) — every other code is produced by `CaptureBrowserBridge`
/// after full payload validation against `schemas/ipc/messages.schema.json`
/// and simply passed through as opaque bytes by this host.
enum IPCErrorCode: String, Codable {
    case elementNotFound = "ELEMENT_NOT_FOUND"
    case invalidMessage = "INVALID_MESSAGE"
    case unsupportedType = "UNSUPPORTED_TYPE"
    case tabSessionExpired = "TAB_SESSION_EXPIRED"
    case payloadTooLarge = "PAYLOAD_TOO_LARGE"
    case permissionDenied = "PERMISSION_DENIED"
    case internalError = "INTERNAL_ERROR"
}

struct IPCErrorDetail: Codable, Equatable {
    var code: IPCErrorCode
    var message: String
}

/// The `{version, id, ok: false, error: {code, message}}` shape from
/// `schemas/ipc/envelope.schema.json`'s `errorResponse` definition — the
/// only envelope shape this host ever constructs itself. Every other
/// frame (real requests and real `ok: true` responses) is forwarded as
/// opaque, already-framed bytes without being decoded into a Swift type
/// at all; full validation and construction of those happens in
/// `CaptureBrowserBridge` on the app side.
struct IPCErrorResponse: Codable, Equatable {
    var version: Int
    var id: String
    var ok: Bool
    var error: IPCErrorDetail

    init(id: String, code: IPCErrorCode, message: String, version: Int = 1) {
        self.version = version
        self.id = id
        self.ok = false
        self.error = IPCErrorDetail(code: code, message: message)
    }

    /// JSON-encodes this response as the raw payload bytes to be handed to
    /// `StdioFraming.writeFrame`.
    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

/// Best-effort partial decode of an inbound request frame, used only to
/// recover the `id` field so a synthesized `INTERNAL_ERROR` (or
/// `PAYLOAD_TOO_LARGE`) response can echo it back correctly — the
/// extension's pending-request map on the other end matches responses to
/// requests by `id`, so getting this right is what turns a swallowed
/// failure into a promise that actually rejects.
///
/// Nothing else about the request is inspected, validated, or even
/// decoded here. Real validation against
/// `schemas/ipc/messages.schema.json` happens once in
/// `CaptureBrowserBridge`, after this host forwards the raw bytes over the
/// socket — duplicating that here would just be a second, possibly
/// drifting copy of the same rules.
struct InboundRequestIdentity: Decodable {
    var id: String

    /// Returns the request's `id`, or `nil` if `data` isn't even
    /// well-formed enough to contain one (not valid JSON, not a JSON
    /// object, or a missing/non-string `id` field).
    static func extractId(from data: Data) -> String? {
        (try? JSONDecoder().decode(InboundRequestIdentity.self, from: data))?.id
    }
}

/// A fallback id used only when an inbound frame is too malformed to
/// recover its own `id` from (e.g. not valid JSON at all, so
/// `InboundRequestIdentity.extractId` returns `nil`). This should be rare
/// in practice — the service worker side of the bridge always sends
/// well-formed envelopes — but it exists so this host still returns *a*
/// well-formed, schema-shaped error frame instead of silently dropping
/// the message or crashing.
func fallbackRequestId() -> String {
    UUID().uuidString
}
