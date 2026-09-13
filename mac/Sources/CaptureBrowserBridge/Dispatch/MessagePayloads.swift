import CaptureCore
import Foundation

/// Hand-written mirrors of every `*.request` definition in
/// `schemas/ipc/messages.schema.json`. Content-script-originated payloads
/// are untrusted input (docs/IPC_PROTOCOL.md, Part I §5.6) so every type
/// here is deliberately closed: `allowedKeys`/`requiredKeys` reproduce the
/// schema's `additionalProperties: false` + `required` behaviour (which
/// `Decodable` alone does not enforce — an extra, unexpected field would
/// otherwise decode silently), and `validateConstraints()` reproduces the
/// schema's `maxLength`/`minimum`/`maximum`/`enum` constraints that
/// `Decodable` also cannot express. See `PayloadCodec.decode` for how these
/// three checks are applied together, in schema order, before dispatch.
///
/// These are also reused (as `Codable`, not just `Decodable`) to *encode*
/// the payloads `BrowserBridgeService` sends for the app-initiated message
/// types (`inspect.activate`, `inspect.deactivate`, `element.captureRequest`,
/// `element.resolveAnchor`) so there is exactly one Swift type per wire
/// shape in each direction.
protocol IPCPayload: Codable {
    /// Every JSON key the schema's `properties` allows. A payload with any
    /// other top-level key is rejected before it is ever decoded into this
    /// type, mirroring `"additionalProperties": false`.
    static var allowedKeys: Set<String> { get }
    /// The subset of `allowedKeys` the schema's `required` array lists.
    static var requiredKeys: Set<String> { get }
    /// Constraints `Decodable` cannot express (string length, numeric
    /// range, cross-field rules). Default: no extra constraints.
    func validateConstraints() throws
}

extension IPCPayload {
    func validateConstraints() throws {}
}

/// Thrown by `validateConstraints()`. `.tooLarge` maps to
/// `IPCErrorCode.payloadTooLarge`; every other case maps to
/// `IPCErrorCode.invalidMessage` — see `PayloadCodec.decode`.
enum PayloadValidationError: Error, CustomStringConvertible {
    case tooLarge(String)
    case outOfRange(String)
    case invalid(String)

    var description: String {
        switch self {
        case .tooLarge(let message), .outOfRange(let message), .invalid(let message):
            return message
        }
    }
}

// MARK: - session.start

struct SessionStartPayload: IPCPayload {
    var tabUrl: String
    var tabTitle: String?

    static let allowedKeys: Set<String> = ["tabUrl", "tabTitle"]
    static let requiredKeys: Set<String> = ["tabUrl"]

    func validateConstraints() throws {
        guard tabUrl.utf8.count <= 4096 else {
            throw PayloadValidationError.tooLarge("tabUrl exceeds the 4096-byte maximum")
        }
        if let tabTitle, tabTitle.utf8.count > 1024 {
            throw PayloadValidationError.tooLarge("tabTitle exceeds the 1024-byte maximum")
        }
    }
}

struct SessionStartResponsePayload: Codable {
    var tabSessionId: UUID
}

// MARK: - session.end / session.ping

/// `session.end.request` and `session.ping.request` are both
/// `{"type":"object","additionalProperties":false,"properties":{}}` —
/// i.e. the payload must be exactly `{}`.
struct EmptyPayload: IPCPayload {
    static let allowedKeys: Set<String> = []
    static let requiredKeys: Set<String> = []
}

struct SessionPingResponsePayload: Codable {
    var appVersion: String
}

// MARK: - inspect.activate / inspect.deactivate (app -> ext)

struct InspectActivatePayload: IPCPayload {
    enum Mode: String, Codable, Sendable { case hover, pinned }
    var mode: Mode?

    static let allowedKeys: Set<String> = ["mode"]
    static let requiredKeys: Set<String> = []
}

typealias InspectDeactivatePayload = EmptyPayload

// MARK: - element.pin / element.evidence (ext -> app)

struct ElementPinPayload: IPCPayload {
    var evidence: ElementEvidence

    static let allowedKeys: Set<String> = ["evidence"]
    static let requiredKeys: Set<String> = ["evidence"]
}

struct ElementEvidencePayload: IPCPayload {
    var evidence: ElementEvidence

    static let allowedKeys: Set<String> = ["evidence"]
    static let requiredKeys: Set<String> = ["evidence"]
}

// MARK: - element.captureRequest (app -> ext)

/// NOTE: unlike `element.resolveAnchor.request`, this `locator` is the
/// plain `locator.primary` selector *string* — see
/// `messages.schema.json`'s `element.captureRequest.request` definition.
/// Do not confuse the two; they are genuinely different shapes.
struct ElementCaptureRequestPayload: IPCPayload {
    var locator: String
    var includeContextPaddingPx: Double?

    static let allowedKeys: Set<String> = ["locator", "includeContextPaddingPx"]
    static let requiredKeys: Set<String> = ["locator"]

    func validateConstraints() throws {
        guard locator.utf8.count <= 2048 else {
            throw PayloadValidationError.tooLarge("locator exceeds the 2048-byte maximum")
        }
        if let padding = includeContextPaddingPx, !(0...512).contains(padding) {
            throw PayloadValidationError.outOfRange("includeContextPaddingPx must be within 0...512")
        }
    }
}

// MARK: - element.resolveAnchor (app -> ext)

/// The *full* ranked `Locator` object (primary + candidates + role +
/// accessibleName + textFingerprint + ancestryFingerprint) — see
/// `element-evidence.schema.json#/properties/locator`, which this
/// `$ref`s. Re-resolution needs the whole ranked candidate set, not just
/// the primary selector string `element.captureRequest` uses.
struct ElementResolveAnchorPayload: IPCPayload {
    var locator: ElementEvidence.Locator

    static let allowedKeys: Set<String> = ["locator"]
    static let requiredKeys: Set<String> = ["locator"]
}

struct ElementResolveAnchorResponsePayload: Codable {
    var resolved: Bool
    var confidence: Double?
    var rect: CaptureRect?
}

// MARK: - tab.info (ext -> app)

struct TabInfoPayload: IPCPayload {
    var url: String
    var title: String
    var viewport: ElementEvidence.Viewport

    static let allowedKeys: Set<String> = ["url", "title", "viewport"]
    static let requiredKeys: Set<String> = ["url", "title", "viewport"]

    func validateConstraints() throws {
        guard url.utf8.count <= 4096 else {
            throw PayloadValidationError.tooLarge("url exceeds the 4096-byte maximum")
        }
        guard title.utf8.count <= 1024 else {
            throw PayloadValidationError.tooLarge("title exceeds the 1024-byte maximum")
        }
    }
}

// MARK: - bookmarksBar.geometry (ext -> app)

struct BookmarksBarGeometryPayload: IPCPayload {
    enum Browser: String, Codable, Sendable {
        case chrome, chromium, edge, brave, arc, unknown
    }

    var innerWidth: Double
    var innerHeight: Double
    var outerWidth: Double
    var outerHeight: Double
    var screenX: Double
    var screenY: Double
    var devicePixelRatio: Double
    var browser: Browser?

    static let allowedKeys: Set<String> = [
        "innerWidth", "innerHeight", "outerWidth", "outerHeight",
        "screenX", "screenY", "devicePixelRatio", "browser"
    ]
    static let requiredKeys: Set<String> = [
        "innerWidth", "innerHeight", "outerWidth", "outerHeight",
        "screenX", "screenY", "devicePixelRatio"
    ]
}

// MARK: - bookmarksBar.calibrate (app -> ext ack; ext -> app result)

struct BookmarksBarCalibratePayload: IPCPayload {
    struct NormalizedRectPayload: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    var browser: String
    var displayScale: Double?
    var normalizedRect: NormalizedRectPayload

    static let allowedKeys: Set<String> = ["browser", "displayScale", "normalizedRect"]
    static let requiredKeys: Set<String> = ["browser", "normalizedRect"]

    func validateConstraints() throws {
        for (label, value) in [
            ("normalizedRect.x", normalizedRect.x),
            ("normalizedRect.y", normalizedRect.y),
            ("normalizedRect.width", normalizedRect.width),
            ("normalizedRect.height", normalizedRect.height)
        ] where !(0...1).contains(value) {
            throw PayloadValidationError.outOfRange("\(label) must be within 0...1")
        }
    }
}

// MARK: - Minimal envelope peek used before committing to a full decode

/// A lenient, best-effort peek at the top-level envelope fields, used by
/// `MessageDispatcher.classify(_:)` to decide, from as little parsing as
/// possible, whether a frame is a request, a response, or unreadable —
/// see that method for why this two-stage approach exists.
struct EnvelopeHeader: Decodable {
    var version: Int?
    var id: UUID?
    var type: String?
    var ok: Bool?
}
