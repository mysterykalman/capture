import CaptureCore
import Darwin
import Foundation

/// One accepted client connection on the Unix domain socket (in practice,
/// exactly one live `CaptureNativeHost` process, though the server accepts
/// more than one concurrently in case of a reconnect race). Owns a
/// dedicated reader thread doing blocking `read(2)` calls — simple and easy
/// to reason about correctness of for the small, infrequent, metadata-only
/// messages this protocol carries (image pixels never cross this channel;
/// see docs/ARCHITECTURE.md's "Process model").
///
/// Framing is `CaptureCore.IPCFraming`'s 4-byte little-endian length prefix,
/// shared verbatim with the Native Messaging stdio hop.
final class BridgeConnection: @unchecked Sendable {
    enum ConnectionError: Error, Sendable {
        case timedOut
        case closed
        case encodingFailed
    }

    private let fileDescriptor: Int32
    private let logger: CaptureLogger

    /// Set by `UnixSocketServer` to `dispatcher.dispatch` — the only way a
    /// request-shaped frame gets acted on.
    var requestHandler: ((IPCRequest) -> IPCResponse)?
    /// Fired after a `session.start` request this connection handled
    /// produced a successful response, so the server can route future
    /// app-initiated sends for that `tabSessionId` back to this connection.
    var onSessionStarted: ((UUID, BridgeConnection) -> Void)?
    /// Fired after this connection handled a `session.end` request.
    var onSessionEnded: ((UUID) -> Void)?
    /// Fired once, when the connection's read loop ends (EOF, error, or
    /// `closeNow()`), so the server can drop it from its routing table.
    var onClosed: ((BridgeConnection) -> Void)?

    private let writeLock = NSLock()
    private let pendingLock = NSLock()
    private var pendingResponses: [UUID: CheckedContinuation<IPCResponse, Error>] = [:]
    private var readThread: Thread?

    init(fileDescriptor: Int32, logger: CaptureLogger) {
        self.fileDescriptor = fileDescriptor
        self.logger = logger
    }

    func start() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "com.capture.browserbridge.connection"
        thread.stackSize = 256 * 1024
        thread.start()
        readThread = thread
    }

    // MARK: - Reading

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        readLoop: while true {
            let bytesRead = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fileDescriptor, base, raw.count)
            }

            switch bytesRead {
            case ..<0:
                if errno == EINTR { continue readLoop }
                logger.warning("Connection read failed: errno \(errno)")
                break readLoop
            case 0:
                // Clean EOF: peer closed the socket.
                break readLoop
            default:
                buffer.append(contentsOf: chunk[0..<bytesRead])
            }

            // Defense in depth: `docs/IPC_PROTOCOL.md` never expects image
            // bytes on this channel — metadata/locators only — so a frame
            // declaring an implausibly large length is either a bug or a
            // hostile peer, not a legitimate slow accumulation. Bail before
            // buffering further rather than growing `buffer` unbounded.
            if buffer.count > Self.maxBufferedBytes {
                logger.warning("Connection exceeded \(Self.maxBufferedBytes)-byte buffer without a complete, reasonably-sized frame; closing")
                break readLoop
            }

            while let (frame, remainder) = IPCFraming.decodeOne(from: buffer) {
                buffer = remainder
                handle(frame: frame)
            }
        }

        teardown()
    }

    /// A generous cap on unconsumed buffered bytes, well above any real
    /// `ElementEvidence` payload, purely to bound memory if a peer sends
    /// nonsense. Not the same thing as `IPCErrorCode.payloadTooLarge`,
    /// which is a clean, per-message schema-level rejection produced by
    /// `PayloadCodec` once a frame *does* parse as JSON.
    private static let maxBufferedBytes = 8 * 1024 * 1024

    private func handle(frame: Data) {
        guard let dispatcher else {
            logger.error("Dropped an inbound frame: no dispatcher attached to this connection")
            return
        }

        switch dispatcher.classify(frame) {
        case .response(let response):
            resolvePending(id: response.id, with: .success(response))

        case .rejected(let response):
            send(response)

        case .unreadable(let reason):
            logger.warning("Dropped an unreadable frame: \(reason)")

        case .request(let request):
            let response = requestHandler?(request)
                ?? .failure(id: request.id, code: .internalError, message: "Bridge is not ready to handle requests")
            send(response)
            routeSessionLifecycle(request: request, response: response)
        }
    }

    /// `MessageDispatcher.classify(_:)` needs to be reachable from here to
    /// interpret frames; `UnixSocketServer` sets this at connection-creation
    /// time (see its `accept` handling).
    var dispatcher: MessageDispatcher?

    private func routeSessionLifecycle(request: IPCRequest, response: IPCResponse) {
        switch request.type {
        case .sessionStart:
            guard
                case .success(let payload) = response.result,
                let idString = payload["tabSessionId"]?.stringValue,
                let tabSessionId = UUID(uuidString: idString)
            else { return }
            onSessionStarted?(tabSessionId, self)

        case .sessionEnd:
            guard let tabSessionId = request.tabSessionId else { return }
            onSessionEnded?(tabSessionId)

        default:
            break
        }
    }

    // MARK: - Writing / outbound requests

    func send(_ response: IPCResponse) {
        guard let data = try? CaptureCoreJSON.encoder.encode(response) else {
            logger.error("Failed to encode an outbound IPCResponse")
            return
        }
        writeFramed(data)
    }

    /// Sends an app-initiated request (e.g. `inspect.activate`,
    /// `element.resolveAnchor`) and awaits the correlated response,
    /// matched by `request.id`. Guaranteed to resume exactly once: either
    /// the real response arrives and resolves it via `resolvePending`, or
    /// the timeout fires first and resolves it via the same path — both
    /// sides atomically `removeValue`, so whichever runs first wins and
    /// the other is a safe no-op. This avoids ever leaking an unresumed
    /// `CheckedContinuation`.
    func sendRequest(_ request: IPCRequest, timeout: TimeInterval) async throws -> IPCResponse {
        let data: Data
        do {
            data = try CaptureCoreJSON.encoder.encode(request)
        } catch {
            throw ConnectionError.encodingFailed
        }

        let id = request.id
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<IPCResponse, Error>) in
            pendingLock.lock()
            pendingResponses[id] = continuation
            pendingLock.unlock()

            writeFramed(data)

            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                self?.resolvePending(id: id, with: .failure(ConnectionError.timedOut))
            }
        }
    }

    private func resolvePending(id: UUID, with result: Result<IPCResponse, Error>) {
        pendingLock.lock()
        let continuation = pendingResponses.removeValue(forKey: id)
        pendingLock.unlock()
        guard let continuation else { return }
        switch result {
        case .success(let response): continuation.resume(returning: response)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func writeFramed(_ data: Data) {
        let framed = IPCFraming.encode(data)
        writeLock.lock()
        defer { writeLock.unlock() }
        framed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fileDescriptor, base + offset, raw.count - offset)
                if n <= 0 {
                    if n < 0, errno == EINTR { continue }
                    logger.warning("Connection write failed or closed mid-frame")
                    break
                }
                offset += n
            }
        }
    }

    // MARK: - Teardown

    private func teardown() {
        pendingLock.lock()
        let waiters = pendingResponses
        pendingResponses.removeAll()
        pendingLock.unlock()
        for (_, continuation) in waiters { continuation.resume(throwing: ConnectionError.closed) }

        Darwin.close(fileDescriptor)
        onClosed?(self)
    }

    /// Forcibly closes the connection (used by `UnixSocketServer.stop()`).
    /// Safe to call from any thread; unblocks the reader thread's `read(2)`.
    func closeNow() {
        Darwin.shutdown(fileDescriptor, SHUT_RDWR)
    }
}
