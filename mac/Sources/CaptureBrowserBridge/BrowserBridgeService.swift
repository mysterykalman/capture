import CaptureCore
import Foundation

/// `CaptureCore.IPCError` is a plain `Codable` value type, not an `Error`.
/// Adding that conformance here (rather than in `CaptureCore`, which this
/// task must not modify) lets `BrowserBridgeService`'s outbound async
/// methods `throw` it directly instead of wrapping it. `Error` has no
/// requirements, so this cannot conflict with anything.
extension IPCError: Error {}

public enum BrowserBridgeError: Error, Sendable {
    case unknownOrExpiredTabSession(UUID)
    case notRunning
}

/// Public counterpart of the internal, wire-format `InspectActivatePayload.Mode`
/// — kept as a separate public type so the internal `IPCPayload` structs
/// (deliberately not `public`; they are implementation detail of the wire
/// format) never need to leak into this module's public API surface.
public enum InspectMode: String, Sendable {
    case hover, pinned
}

/// The public façade of `CaptureBrowserBridge`: wires `UnixSocketServer`,
/// `MessageDispatcher`, `TabSessionManager`, `ElementEvidenceStore` and
/// `TabMetadataStore` together, registers exactly one handler closure per
/// `IPCMessageType`, and exposes the operations the rest of the app needs —
/// most importantly `latestEvidence(forTabSession:)`, which is how
/// `CaptureInspection`/`CaptureUI` get from "user pinned an element in the
/// browser" to "capture it and anchor an annotation to it"
/// (docs' "First browser milestone").
public final class BrowserBridgeService: @unchecked Sendable {
    public let sessions: TabSessionManager
    public let evidenceStore: ElementEvidenceStore
    public let tabMetadata: TabMetadataStore

    /// `internal`, not `private`: lets `CaptureBrowserBridgeTests`
    /// (`@testable import`) dispatch real requests through the exact
    /// handlers registered below without needing a live socket — exercising
    /// `TAB_SESSION_EXPIRED`/`INVALID_MESSAGE` behaviour end-to-end rather
    /// than only unit-testing `MessageDispatcher` against hand-rolled fake
    /// handlers. Still not part of this module's public API surface.
    let dispatcher: MessageDispatcher
    private let server: UnixSocketServer
    private let logger: CaptureLogger
    private let appVersion: String

    public init(
        socketURL: URL = UnixSocketServer.defaultSocketURL(),
        appVersion: String = "0.1.0",
        sessions: TabSessionManager = TabSessionManager(),
        evidenceStore: ElementEvidenceStore = ElementEvidenceStore(),
        tabMetadata: TabMetadataStore = TabMetadataStore()
    ) {
        self.sessions = sessions
        self.evidenceStore = evidenceStore
        self.tabMetadata = tabMetadata
        self.appVersion = appVersion
        self.logger = CaptureLogger(category: "browser-bridge")
        self.dispatcher = MessageDispatcher()
        self.server = UnixSocketServer(socketURL: socketURL, dispatcher: dispatcher, logger: logger)
        registerHandlers()
    }

    public func start() throws {
        try server.start()
    }

    public func stop() {
        server.stop()
    }

    public var activeConnectionCount: Int { server.activeConnectionCount }

    // MARK: - Reading evidence (the ext -> app -> editor join)

    /// The latest `ElementEvidence` reported for `tabSessionId`, from
    /// either `element.pin` (user clicked to pin) or `element.evidence`
    /// (a `requestElementCapture` reply). This is what a capture/annotate
    /// flow in `CaptureUI` reads to build a DOM-anchored `Annotation`.
    public func latestEvidence(forTabSession tabSessionId: UUID) -> ElementEvidence? {
        evidenceStore.latestEvidence(forTabSession: tabSessionId)
    }

    // MARK: - App-initiated (app -> ext) operations

    public func activateInspect(tabSessionId: UUID, mode: InspectMode? = nil, timeout: TimeInterval = 5) async throws {
        let internalMode = mode.flatMap { InspectActivatePayload.Mode(rawValue: $0.rawValue) }
        try await sendAndAck(.inspectActivate, InspectActivatePayload(mode: internalMode), tabSessionId: tabSessionId, timeout: timeout)
    }

    public func deactivateInspect(tabSessionId: UUID, timeout: TimeInterval = 5) async throws {
        try await sendAndAck(.inspectDeactivate, InspectDeactivatePayload(), tabSessionId: tabSessionId, timeout: timeout)
    }

    /// Asks the content script to resolve `locator` and return fresh
    /// evidence, then awaits the follow-up `element.evidence` message —
    /// see `ElementEvidenceStore.awaitNextEvidence` for why that is a
    /// separate wait rather than the request's own correlated response.
    public func requestElementCapture(
        tabSessionId: UUID,
        locator: String,
        includeContextPaddingPx: Double? = nil,
        timeout: TimeInterval = 10
    ) async throws -> ElementEvidence {
        guard sessions.isActive(tabSessionId) else {
            throw BrowserBridgeError.unknownOrExpiredTabSession(tabSessionId)
        }
        let payload = ElementCaptureRequestPayload(locator: locator, includeContextPaddingPx: includeContextPaddingPx)
        let json = try PayloadCodec.encode(payload)
        let request = IPCRequest(type: .elementCaptureRequest, tabSessionId: tabSessionId, payload: json)

        async let evidence = evidenceStore.awaitNextEvidence(forTabSession: tabSessionId, timeout: timeout)
        let ack = try await server.sendRequest(request, toTabSession: tabSessionId, timeout: timeout)
        _ = try ack.throwingPayload() // surfaces e.g. ELEMENT_NOT_FOUND if the extension rejected the request outright
        return try await evidence
    }

    /// Asks the extension whether a previously-saved locator still
    /// resolves — used when reopening a `.capture` project (the milestone's
    /// final step: "attempt to resolve the anchor").
    public func resolveAnchor(tabSessionId: UUID, locator: ElementEvidence.Locator, timeout: TimeInterval = 5) async throws -> AnchorResolution {
        let payload = ElementResolveAnchorPayload(locator: locator)
        let json = try PayloadCodec.encode(payload)
        let request = IPCRequest(type: .elementResolveAnchor, tabSessionId: tabSessionId, payload: json)
        let response = try await server.sendRequest(request, toTabSession: tabSessionId, timeout: timeout)
        let resultPayload = try response.throwingPayload()
        let data = try CaptureCoreJSON.encoder.encode(resultPayload)
        let decoded = try CaptureCoreJSON.decoder.decode(ElementResolveAnchorResponsePayload.self, from: data)
        return AnchorResolution(resolved: decoded.resolved, confidence: decoded.confidence ?? 0, rect: decoded.rect)
    }

    private func sendAndAck<T: IPCPayload>(_ type: IPCMessageType, _ payload: T, tabSessionId: UUID, timeout: TimeInterval) async throws {
        let json = try PayloadCodec.encode(payload)
        let request = IPCRequest(type: type, tabSessionId: tabSessionId, payload: json)
        let response = try await server.sendRequest(request, toTabSession: tabSessionId, timeout: timeout)
        _ = try response.throwingPayload()
    }

    // MARK: - Handler registration (ext -> app inbound messages)

    /// Exactly one closure per `IPCMessageType` — see `MessageDispatcher`'s
    /// doc comment for why there is no generic path here. The four
    /// app-initiated types (`inspect.activate`, `inspect.deactivate`,
    /// `element.captureRequest`, `element.resolveAnchor`) are registered
    /// too, but only to explicitly refuse them if they ever arrive
    /// *inbound* — this app sends those, it never accepts them as a
    /// request from the native host.
    private func registerHandlers() {
        dispatcher.register(.sessionStart) { [sessions] request in
            switch PayloadCodec.decode(SessionStartPayload.self, from: request.payload) {
            case .failure(let error):
                return .failure(id: request.id, code: error.code, message: error.message)
            case .success(let payload):
                let session = sessions.startSession(tabURL: payload.tabUrl, tabTitle: payload.tabTitle)
                return .success(id: request.id, payload: .object(["tabSessionId": .string(session.id.uuidString)]))
            }
        }

        dispatcher.register(.sessionEnd) { [sessions, evidenceStore, tabMetadata] request in
            switch PayloadCodec.decode(EmptyPayload.self, from: request.payload) {
            case .failure(let error):
                return .failure(id: request.id, code: error.code, message: error.message)
            case .success:
                guard let tabSessionId = request.tabSessionId else {
                    return .failure(id: request.id, code: .invalidMessage, message: "session.end requires tabSessionId")
                }
                sessions.endSession(tabSessionId)
                evidenceStore.clear(forTabSession: tabSessionId)
                tabMetadata.clear(forTabSession: tabSessionId)
                return .success(id: request.id, payload: .object([:]))
            }
        }

        dispatcher.register(.sessionPing) { [appVersion] request in
            switch PayloadCodec.decode(EmptyPayload.self, from: request.payload) {
            case .failure(let error):
                return .failure(id: request.id, code: error.code, message: error.message)
            case .success:
                return .success(id: request.id, payload: .object(["appVersion": .string(appVersion)]))
            }
        }

        dispatcher.register(.inspectActivate) { request in
            .failure(id: request.id, code: .invalidMessage, message: "inspect.activate is app-initiated only; the bridge never accepts it as an inbound request")
        }
        dispatcher.register(.inspectDeactivate) { request in
            .failure(id: request.id, code: .invalidMessage, message: "inspect.deactivate is app-initiated only; the bridge never accepts it as an inbound request")
        }

        dispatcher.register(.elementPin) { [sessions, evidenceStore] request in
            Self.requireActiveSession(sessions, request) { tabSessionId in
                switch PayloadCodec.decode(ElementPinPayload.self, from: request.payload) {
                case .failure(let error):
                    return .failure(id: request.id, code: error.code, message: error.message)
                case .success(let payload):
                    evidenceStore.store(payload.evidence, forTabSession: tabSessionId)
                    return .success(id: request.id, payload: .object([:]))
                }
            }
        }

        dispatcher.register(.elementCaptureRequest) { request in
            .failure(id: request.id, code: .invalidMessage, message: "element.captureRequest is app-initiated only; the bridge never accepts it as an inbound request")
        }

        dispatcher.register(.elementEvidence) { [sessions, evidenceStore] request in
            Self.requireActiveSession(sessions, request) { tabSessionId in
                switch PayloadCodec.decode(ElementEvidencePayload.self, from: request.payload) {
                case .failure(let error):
                    return .failure(id: request.id, code: error.code, message: error.message)
                case .success(let payload):
                    evidenceStore.store(payload.evidence, forTabSession: tabSessionId)
                    return .success(id: request.id, payload: .object([:]))
                }
            }
        }

        dispatcher.register(.elementResolveAnchor) { request in
            .failure(id: request.id, code: .invalidMessage, message: "element.resolveAnchor is app-initiated only; the bridge never accepts it as an inbound request")
        }

        dispatcher.register(.tabInfo) { [sessions, tabMetadata] request in
            Self.requireActiveSession(sessions, request) { tabSessionId in
                switch PayloadCodec.decode(TabInfoPayload.self, from: request.payload) {
                case .failure(let error):
                    return .failure(id: request.id, code: error.code, message: error.message)
                case .success(let payload):
                    tabMetadata.storeTabInfo(payload, forTabSession: tabSessionId)
                    return .success(id: request.id, payload: .object([:]))
                }
            }
        }

        dispatcher.register(.bookmarksBarGeometry) { [sessions, tabMetadata] request in
            Self.requireActiveSession(sessions, request) { tabSessionId in
                switch PayloadCodec.decode(BookmarksBarGeometryPayload.self, from: request.payload) {
                case .failure(let error):
                    return .failure(id: request.id, code: error.code, message: error.message)
                case .success(let payload):
                    tabMetadata.storeBookmarksBarGeometry(payload, forTabSession: tabSessionId)
                    return .success(id: request.id, payload: .object([:]))
                }
            }
        }

        dispatcher.register(.bookmarksBarCalibrate) { [sessions, tabMetadata] request in
            Self.requireActiveSession(sessions, request) { tabSessionId in
                switch PayloadCodec.decode(BookmarksBarCalibratePayload.self, from: request.payload) {
                case .failure(let error):
                    return .failure(id: request.id, code: error.code, message: error.message)
                case .success(let payload):
                    tabMetadata.storeBookmarksBarCalibration(payload, forTabSession: tabSessionId)
                    return .success(id: request.id, payload: .object([:]))
                }
            }
        }
    }

    /// Every session-scoped inbound message shares the same precondition:
    /// a present, active `tabSessionId`. Centralized here so
    /// `TAB_SESSION_EXPIRED` is produced consistently and the touch
    /// (activity refresh) always happens on a successful, in-session
    /// request — including request-shaped validation failures, which still
    /// prove the session is alive even if the payload was bad.
    private static func requireActiveSession(_ sessions: TabSessionManager, _ request: IPCRequest, _ body: (UUID) -> IPCResponse) -> IPCResponse {
        guard let tabSessionId = request.tabSessionId, sessions.isActive(tabSessionId) else {
            return .failure(id: request.id, code: .tabSessionExpired, message: "Unknown or expired tabSessionId")
        }
        let response = body(tabSessionId)
        sessions.touch(tabSessionId)
        return response
    }
}

private extension IPCResponse {
    func throwingPayload() throws -> JSONValue {
        switch result {
        case .success(let payload): return payload
        case .failure(let error): throw error
        }
    }
}
