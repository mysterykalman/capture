import CaptureCore
import Darwin
import Foundation

/// The Unix-domain-socket server side of the browser bridge, listening at
/// `~/Library/Application Support/Capture/IPC/capture.sock`
/// (docs/IPC_PROTOCOL.md). Built on raw BSD sockets (`Darwin`) rather than
/// `Network.framework`'s `NWListener` — see the note at the bottom of this
/// file for why, and flag that choice for review once this can actually be
/// built and tested on a Mac.
///
/// Responsibilities, and only these:
///  - create `~/Library/Application Support/Capture/IPC/` as a user-only
///    (0700) directory if needed;
///  - bind a `SOCK_STREAM` `AF_UNIX` socket at `capture.sock` and `chmod`
///    it to 0600 immediately after `bind()`;
///  - accept multiple concurrent connections (the native host may
///    reconnect without this app having seen the old socket close yet);
///  - frame/deframe with `CaptureCore.IPCFraming` and hand each inbound
///    frame to `MessageDispatcher.classify(_:)`/`dispatch(_:)`;
///  - route app-initiated outbound requests (`sendRequest(_:toTabSession:)`)
///    to whichever live connection most recently completed `session.start`
///    for that `tabSessionId`.
///
/// It never interprets a payload itself — that is `MessageDispatcher`'s job
/// — and it never shells out or touches the filesystem beyond the socket
/// path itself.
final class UnixSocketServer: @unchecked Sendable {
    enum ServerError: Error, Sendable {
        case alreadyRunning
        case notRunning
        case pathTooLongForUnixSocket(String)
        case socketCreationFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case chmodFailed(errno: Int32)
        case listenFailed(errno: Int32)
        case noConnectionForTabSession(UUID)
    }

    let socketURL: URL
    private let logger: CaptureLogger
    private let dispatcher: MessageDispatcher

    private let stateLock = NSLock()
    private var listenSocket: Int32 = -1
    private var isRunning = false
    private var acceptThread: Thread?

    private let routingLock = NSLock()
    private var connectionsByTabSession: [UUID: BridgeConnection] = [:]
    private var allConnections: [ObjectIdentifier: BridgeConnection] = [:]

    init(socketURL: URL, dispatcher: MessageDispatcher, logger: CaptureLogger = CaptureLogger(category: "browser-bridge.transport")) {
        self.socketURL = socketURL
        self.dispatcher = dispatcher
        self.logger = logger
    }

    /// The path from docs/IPC_PROTOCOL.md, under the real per-user
    /// Application Support directory.
    static func defaultSocketURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Capture/IPC/capture.sock")
    }

    // MARK: - Lifecycle

    func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isRunning else { throw ServerError.alreadyRunning }

        let parentDirectory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // The directory may already have existed with looser permissions
        // (e.g. created by an older build before this requirement existed)
        // — re-assert user-only every start, per docs/IPC_PROTOCOL.md.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parentDirectory.path)

        // AF_UNIX bind(2) fails with EADDRINUSE if a file already exists at
        // the path — including a stale socket file left behind by a
        // previous run that didn't shut down cleanly. Safe to remove: this
        // directory holds nothing but our own socket file.
        if FileManager.default.fileExists(atPath: socketURL.path) {
            try? FileManager.default.removeItem(at: socketURL)
        }

        let path = socketURL.path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // BSD sockaddrs carry their own length; harmless to omit for
        // bind(2) (the explicit addrLength argument below is what the
        // kernel actually relies on) but setting it matches the
        // convention the rest of Darwin's socket APIs expect.
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let maxPathBytes = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxPathBytes else {
            throw ServerError.pathTooLongForUnixSocket(path)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { rawPathPointer in
            rawPathPointer.withMemoryRebound(to: CChar.self, capacity: maxPathBytes) { cCharPointer in
                path.withCString { source in
                    strncpy(cCharPointer, source, maxPathBytes - 1)
                }
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketCreationFailed(errno: errno) }

        let addrLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { unixPointer -> Int32 in
            unixPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { genericPointer in
                Darwin.bind(fd, genericPointer, addrLength)
            }
        }
        guard bindResult == 0 else {
            let capturedErrno = errno
            Darwin.close(fd)
            throw ServerError.bindFailed(errno: capturedErrno)
        }

        // Socket file mode 0600, immediately after bind — docs/IPC_PROTOCOL.md.
        guard chmod(path, 0o600) == 0 else {
            let capturedErrno = errno
            Darwin.close(fd)
            try? FileManager.default.removeItem(atPath: path)
            throw ServerError.chmodFailed(errno: capturedErrno)
        }

        guard listen(fd, 16) == 0 else {
            let capturedErrno = errno
            Darwin.close(fd)
            try? FileManager.default.removeItem(atPath: path)
            throw ServerError.listenFailed(errno: capturedErrno)
        }

        listenSocket = fd
        isRunning = true

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "com.capture.browserbridge.accept"
        thread.start()
        acceptThread = thread

        logger.info("Listening on Unix socket at \(path)")
    }

    func stop() {
        stateLock.lock()
        guard isRunning else { stateLock.unlock(); return }
        isRunning = false
        let fd = listenSocket
        listenSocket = -1
        stateLock.unlock()

        if fd >= 0 {
            Darwin.close(fd)
        }
        try? FileManager.default.removeItem(at: socketURL)

        routingLock.lock()
        let connections = allConnections
        allConnections.removeAll()
        connectionsByTabSession.removeAll()
        routingLock.unlock()

        for (_, connection) in connections {
            connection.closeNow()
        }
    }

    // MARK: - Accepting

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let fd = listenSocket
            let running = isRunning
            stateLock.unlock()
            guard running, fd >= 0 else { return }

            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else {
                stateLock.lock()
                let stillRunning = isRunning
                stateLock.unlock()
                if stillRunning {
                    logger.warning("accept() failed: errno \(errno)")
                    continue
                } else {
                    return
                }
            }

            let connection = BridgeConnection(fileDescriptor: clientFD, logger: logger)
            connection.dispatcher = dispatcher
            connection.requestHandler = { [dispatcher] request in dispatcher.dispatch(request) }
            connection.onSessionStarted = { [weak self] tabSessionId, connection in
                self?.bind(tabSessionId: tabSessionId, to: connection)
            }
            connection.onSessionEnded = { [weak self] tabSessionId in
                self?.unbind(tabSessionId: tabSessionId)
            }
            connection.onClosed = { [weak self] closed in
                self?.forget(closed)
            }

            routingLock.lock()
            allConnections[ObjectIdentifier(connection)] = connection
            routingLock.unlock()

            connection.start()
        }
    }

    // MARK: - Routing app-initiated requests

    private func bind(tabSessionId: UUID, to connection: BridgeConnection) {
        routingLock.lock()
        connectionsByTabSession[tabSessionId] = connection
        routingLock.unlock()
    }

    private func unbind(tabSessionId: UUID) {
        routingLock.lock()
        connectionsByTabSession.removeValue(forKey: tabSessionId)
        routingLock.unlock()
    }

    private func forget(_ connection: BridgeConnection) {
        routingLock.lock()
        allConnections.removeValue(forKey: ObjectIdentifier(connection))
        connectionsByTabSession = connectionsByTabSession.filter { $0.value !== connection }
        routingLock.unlock()
    }

    /// Sends an app-initiated request (`inspect.activate`,
    /// `inspect.deactivate`, `element.captureRequest`,
    /// `element.resolveAnchor`) to whichever connection currently owns
    /// `tabSessionId`, awaiting the correlated response.
    func sendRequest(_ request: IPCRequest, toTabSession tabSessionId: UUID, timeout: TimeInterval = 5) async throws -> IPCResponse {
        routingLock.lock()
        let connection = connectionsByTabSession[tabSessionId]
        routingLock.unlock()
        guard let connection else {
            throw ServerError.noConnectionForTabSession(tabSessionId)
        }
        return try await connection.sendRequest(request, timeout: timeout)
    }

    var activeConnectionCount: Int {
        routingLock.lock()
        defer { routingLock.unlock() }
        return allConnections.count
    }
}

// MARK: - Why raw BSD sockets instead of Network.framework
//
// The task that produced this file preferred `Network.framework`'s
// `NWListener` for binding a Unix-domain-socket *listener* (as opposed to
// the well-documented client-side `NWConnection(to: .unix(path:), using:)`)
// via `NWParameters.requiredLocalEndpoint = .unix(path:)`. That shape is
// real and has been used in the wild, but this file was written in a
// sandbox with no Swift toolchain and no way to compile or run it — and
// this specific corner of `Network.framework` (listener-side AF_UNIX, as
// opposed to the much more commonly demonstrated client-side connection to
// an AF_UNIX path) is one that could not be verified from memory with real
// confidence. Everything in this file — `socket`/`bind`/`chmod`/`listen`/
// `accept`/`read`/`write` on an `AF_UNIX`/`SOCK_STREAM` socket — is
// standard, extremely well-documented POSIX behaviour, so it was chosen
// deliberately over guessing at an unverifiable Network.framework API
// surface for the piece of code this feature depends on most. If, once
// this can be built on a real Mac, `NWListener` unix-socket listening is
// confirmed to work as expected, it remains a reasonable follow-up
// refactor for its built-in backpressure handling — but it should not
// silently replace this without that verification.
