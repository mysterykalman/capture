import Foundation

/// Mirrors `schemas/ipc/envelope.schema.json` and `messages.schema.json`.
/// Used by `CaptureBrowserBridge` (the Unix-socket server side) and shared
/// with `native-host` conceptually (that package keeps its own copy — see
/// `docs/decisions/0001` on why it's a separate, dependency-free SPM
/// package — but the wire format below is authoritative and both must
/// match `schemas/ipc/`).
public enum IPCMessageType: String, Codable, Sendable, CaseIterable {
    case sessionStart = "session.start"
    case sessionEnd = "session.end"
    case sessionPing = "session.ping"
    case inspectActivate = "inspect.activate"
    case inspectDeactivate = "inspect.deactivate"
    case elementPin = "element.pin"
    case elementCaptureRequest = "element.captureRequest"
    case elementEvidence = "element.evidence"
    case elementResolveAnchor = "element.resolveAnchor"
    case tabInfo = "tab.info"
    case bookmarksBarGeometry = "bookmarksBar.geometry"
    case bookmarksBarCalibrate = "bookmarksBar.calibrate"
}

public enum IPCErrorCode: String, Codable, Sendable {
    case elementNotFound = "ELEMENT_NOT_FOUND"
    case invalidMessage = "INVALID_MESSAGE"
    case unsupportedType = "UNSUPPORTED_TYPE"
    case tabSessionExpired = "TAB_SESSION_EXPIRED"
    case payloadTooLarge = "PAYLOAD_TOO_LARGE"
    case permissionDenied = "PERMISSION_DENIED"
    case internalError = "INTERNAL_ERROR"
}

public struct IPCRequest: Codable, Sendable {
    public var version: Int
    public var id: UUID
    public var type: IPCMessageType
    public var tabSessionId: UUID?
    public var payload: JSONValue

    public init(version: Int = 1, id: UUID = UUID(), type: IPCMessageType, tabSessionId: UUID? = nil, payload: JSONValue) {
        self.version = version
        self.id = id
        self.type = type
        self.tabSessionId = tabSessionId
        self.payload = payload
    }
}

public struct IPCError: Codable, Sendable {
    public var code: IPCErrorCode
    public var message: String

    public init(code: IPCErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// A response is `{ok: true, payload}` or `{ok: false, error}`. Swift's
/// `Codable` doesn't synthesize this "one of two shapes keyed by a sibling
/// boolean field" pattern automatically, so encode/decode are hand-written.
public struct IPCResponse: Sendable {
    public var version: Int
    public var id: UUID
    public var result: Result<JSONValue, IPCError>

    public init(id: UUID, version: Int = 1, result: Result<JSONValue, IPCError>) {
        self.version = version
        self.id = id
        self.result = result
    }

    public static func success(id: UUID, payload: JSONValue) -> IPCResponse {
        IPCResponse(id: id, result: .success(payload))
    }

    public static func failure(id: UUID, code: IPCErrorCode, message: String) -> IPCResponse {
        IPCResponse(id: id, result: .failure(IPCError(code: code, message: message)))
    }
}

extension IPCResponse: Codable {
    private enum CodingKeys: String, CodingKey { case version, id, ok, payload, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        id = try c.decode(UUID.self, forKey: .id)
        let ok = try c.decode(Bool.self, forKey: .ok)
        if ok {
            result = .success(try c.decode(JSONValue.self, forKey: .payload))
        } else {
            result = .failure(try c.decode(IPCError.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        switch result {
        case .success(let payload):
            try c.encode(true, forKey: .ok)
            try c.encode(payload, forKey: .payload)
        case .failure(let error):
            try c.encode(false, forKey: .ok)
            try c.encode(error, forKey: .error)
        }
    }
}

/// Length-prefixed framing used on the Native Messaging stdio channel
/// (a 4-byte little-endian `UInt32` byte count, per Chrome's protocol) and
/// re-used verbatim for the Unix-socket hop so both hops share one framer.
public enum IPCFraming {
    public static func encode(_ data: Data) -> Data {
        var length = UInt32(data.count).littleEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(data)
        return framed
    }

    /// Attempts to split one complete frame off the front of `buffer`.
    /// Returns `(frame, remainder)` or `nil` if the buffer doesn't yet
    /// contain a full frame.
    public static func decodeOne(from buffer: Data) -> (frame: Data, remainder: Data)? {
        guard buffer.count >= 4 else { return nil }
        let lengthBytes = buffer.prefix(4)
        // `loadUnaligned` (not `load`) because `buffer.prefix(4)`'s backing
        // storage is not guaranteed 4-byte aligned — `Data` built up via
        // repeated `append`/`subdata` (exactly how this buffer arrives from
        // a socket/pipe read loop) offers no alignment guarantee, and
        // `load(as:)` is undefined behaviour on an unaligned pointer.
        let length = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let frame = buffer.subdata(in: 4..<total)
        let remainder = buffer.subdata(in: total..<buffer.count)
        return (frame, remainder)
    }
}
