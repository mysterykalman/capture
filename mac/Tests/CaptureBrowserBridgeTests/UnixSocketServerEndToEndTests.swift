import CaptureCore
import Darwin
import XCTest
@testable import CaptureBrowserBridge

/// A genuine end-to-end test of `UnixSocketServer`: start the real
/// listener, connect a real client socket, send a real framed
/// `session.ping` request, and assert a real framed response comes back —
/// plus the two hard security requirements from docs/IPC_PROTOCOL.md
/// (parent directory user-only, socket file mode 0600).
///
/// Confidence note (per this task's instructions to be explicit rather than
/// guess): `UnixSocketServer` is built on raw BSD sockets
/// (`socket`/`bind`/`chmod`/`listen`/`accept`/`read`/`write` from
/// `Darwin`), chosen specifically because that surface is standard,
/// extremely well-documented POSIX behaviour I can write with real
/// confidence even without a Swift toolchain to compile against here (see
/// the comment at the bottom of `Transport/UnixSocketServer.swift`). This
/// test's client side uses the exact same primitives, so I *am* reasonably
/// confident this test is both correct Swift and would pass on a real Mac
/// — but it has not actually been compiled or run anywhere, in this sandbox
/// or otherwise, so treat a first run of it on real hardware as the actual
/// verification, not a formality. If it fails, the most likely culprits
/// are exact-offset mistakes in the `sockaddr_un`/`strncpy` plumbing shared
/// between `UnixSocketServer.start()` and this test's `connectClient(to:)`
/// — both were written by hand against my own recollection of the C API,
/// not copied from a compiler-checked source.
final class UnixSocketServerEndToEndTests: XCTestCase {
    private var socketURL: URL!
    private var server: UnixSocketServer!

    override func setUpWithError() throws {
        // AF_UNIX paths are capped at `sizeof(sockaddr_un.sun_path)` — 104
        // bytes on Darwin — and `NSTemporaryDirectory()` (especially under
        // `/var/folders/...`) already eats a good chunk of that budget, so
        // this deliberately uses a short 8-character subdirectory name and
        // a short socket filename rather than a full UUID, unlike
        // `BrowserBridgeService`'s real default path under
        // `~/Library/Application Support/Capture/IPC/`.
        let shortId = UUID().uuidString.prefix(8)
        socketURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-\(shortId)", isDirectory: true)
            .appendingPathComponent("s.sock")
    }

    override func tearDownWithError() throws {
        server?.stop()
        if let parent = socketURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    func testStartAcceptSendReceiveRoundTrip() throws {
        let dispatcher = MessageDispatcher()
        dispatcher.register(.sessionPing) { request in
            .success(id: request.id, payload: .object(["appVersion": .string("test-1.0")]))
        }
        server = UnixSocketServer(socketURL: socketURL, dispatcher: dispatcher)
        try server.start()

        // --- Security requirements from docs/IPC_PROTOCOL.md ---
        let parentPath = socketURL.deletingLastPathComponent().path
        let parentAttributes = try FileManager.default.attributesOfItem(atPath: parentPath)
        XCTAssertEqual((parentAttributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o700, "IPC directory must be user-only")

        let socketAttributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        XCTAssertEqual((socketAttributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o600, "socket file must be mode 0600")

        // --- Real round trip over the real socket ---
        let clientFD = try connectClient(to: socketURL.path)
        defer { close(clientFD) }

        let requestId = UUID()
        let requestData = try CaptureCoreJSON.encoder.encode(
            IPCRequest(id: requestId, type: .sessionPing, payload: .object([:]))
        )
        try writeFramed(requestData, to: clientFD)

        let responseData = try readFramed(from: clientFD, timeoutSeconds: 5)
        let response = try CaptureCoreJSON.decoder.decode(IPCResponse.self, from: responseData)

        XCTAssertEqual(response.id, requestId)
        guard case .success(let payload) = response.result else {
            return XCTFail("expected a successful session.ping response")
        }
        XCTAssertEqual(payload["appVersion"]?.stringValue, "test-1.0")
    }

    func testConcurrentConnectionsAreBothAccepted() throws {
        let dispatcher = MessageDispatcher()
        dispatcher.register(.sessionPing) { request in
            .success(id: request.id, payload: .object(["appVersion": .string("test-1.0")]))
        }
        server = UnixSocketServer(socketURL: socketURL, dispatcher: dispatcher)
        try server.start()

        let clientA = try connectClient(to: socketURL.path)
        let clientB = try connectClient(to: socketURL.path)
        defer { close(clientA); close(clientB) }

        for clientFD in [clientA, clientB] {
            let requestId = UUID()
            let requestData = try CaptureCoreJSON.encoder.encode(IPCRequest(id: requestId, type: .sessionPing, payload: .object([:])))
            try writeFramed(requestData, to: clientFD)
            let responseData = try readFramed(from: clientFD, timeoutSeconds: 5)
            let response = try CaptureCoreJSON.decoder.decode(IPCResponse.self, from: responseData)
            XCTAssertEqual(response.id, requestId)
        }

        XCTAssertEqual(server.activeConnectionCount, 2)
    }

    func testStopRemovesTheSocketFile() throws {
        let dispatcher = MessageDispatcher()
        server = UnixSocketServer(socketURL: socketURL, dispatcher: dispatcher)
        try server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    // MARK: - Minimal raw-socket client helpers (mirrors UnixSocketServer's own primitives)

    private enum ClientError: Error { case socketCreationFailed, connectFailed, pathTooLong, timedOut, closed }

    private func connectClient(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.socketCreationFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathBytes = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxPathBytes else {
            close(fd)
            throw ClientError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { rawPathPointer in
            rawPathPointer.withMemoryRebound(to: CChar.self, capacity: maxPathBytes) { cCharPointer in
                path.withCString { source in
                    strncpy(cCharPointer, source, maxPathBytes - 1)
                }
            }
        }

        let addrLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { unixPointer -> Int32 in
            unixPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { genericPointer in
                connect(fd, genericPointer, addrLength)
            }
        }
        guard result == 0 else {
            close(fd)
            throw ClientError.connectFailed
        }
        return fd
    }

    private func writeFramed(_ data: Data, to fd: Int32) throws {
        let framed = IPCFraming.encode(data)
        try framed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                guard n > 0 else { throw ClientError.closed }
                offset += n
            }
        }
    }

    private func readFramed(from fd: Int32, timeoutSeconds: Int, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let (frame, _) = IPCFraming.decodeOne(from: buffer) {
                return frame
            }
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            guard n > 0 else { throw ClientError.timedOut }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}
