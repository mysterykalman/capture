import Darwin
import Foundation

/// Errors from the raw Unix-domain-socket hop to Capture.app
/// (docs/IPC_PROTOCOL.md "Unix socket").
enum SocketClientError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case socketCreateFailed(errno: Int32)
    case connectFailed(errno: Int32)
    case sendFailed(errno: Int32)
    case receiveFailed(errno: Int32)
    case unexpectedEOF

    var description: String {
        switch self {
        case .pathTooLong(let path):
            return "socket path too long for sockaddr_un (max 103 bytes): \(path)"
        case .socketCreateFailed(let e):
            return "socket() failed: \(String(cString: strerror(e))) (errno \(e))"
        case .connectFailed(let e):
            return "connect() failed: \(String(cString: strerror(e))) (errno \(e))"
        case .sendFailed(let e):
            return "send() failed: \(String(cString: strerror(e))) (errno \(e))"
        case .receiveFailed(let e):
            return "recv() failed: \(String(cString: strerror(e))) (errno \(e))"
        case .unexpectedEOF:
            return "socket closed before a complete frame was received"
        }
    }
}

/// A minimal blocking Unix-domain-socket client for the app-side hop of
/// the bridge. Deliberately raw BSD sockets (`import Darwin`) rather than
/// `Network.framework`: this binary is launched fresh by Chrome per
/// native-messaging connection and exchanges a request/response (or a
/// short handful) per process lifetime, so the extra machinery of an
/// async connection framework buys nothing here and would only slow down
/// the "fast-launching standalone binary" this package is meant to be
/// (see `native-host/Package.swift`).
///
/// Framing on this hop is identical to the stdio hop — see `WireFraming`
/// in `StdioFraming.swift`, which this type reuses directly.
final class SocketClient {
    private var fd: Int32 = -1

    deinit {
        close()
    }

    /// Connects to the Unix-domain socket at `path`
    /// (`~/Library/Application Support/Capture/IPC/capture.sock`).
    /// Throws immediately if nothing is listening there yet (typically
    /// `ENOENT` if the socket file doesn't exist, or `ECONNREFUSED` if a
    /// stale socket file is present but nothing is bound to it) — callers
    /// implement their own launch/retry policy around this (see
    /// `main.swift`), since a freshly-launched Capture.app may take a
    /// moment to stand its socket listener up.
    func connect(path: String, receiveTimeout: TimeInterval = 10) throws {
        let newFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFd >= 0 else {
            throw SocketClientError.socketCreateFailed(errno: errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let maxPathBytes = MemoryLayout.size(ofValue: addr.sun_path) - 1 // room for the NUL terminator
        guard pathBytes.count <= maxPathBytes else {
            Darwin.close(newFd)
            throw SocketClientError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buf = rawPtr.bindMemory(to: CChar.self)
            for (index, byte) in pathBytes.enumerated() {
                buf[index] = CChar(bitPattern: byte)
            }
            buf[pathBytes.count] = 0
        }
#if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
#endif

        let connectResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(newFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let connectErrno = errno
            Darwin.close(newFd)
            throw SocketClientError.connectFailed(errno: connectErrno)
        }

        // Bound how long a single recv() can block so a wedged or
        // misbehaving app can't hang this process (and thus Chrome's
        // pending `chrome.runtime.sendMessage` call) forever.
        var timeout = timeval(tv_sec: Int(receiveTimeout), tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(newFd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        self.fd = newFd
    }

    /// Sends one length-prefixed frame, looping over partial `send()`
    /// writes.
    func sendFrame(_ payload: Data) throws {
        let framed = WireFraming.encode(payload)
        try framed.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let base = rawBuffer.baseAddress, rawBuffer.count > 0 else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let n = Darwin.send(fd, base + offset, rawBuffer.count - offset, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketClientError.sendFailed(errno: errno)
                }
                if n == 0 {
                    throw SocketClientError.unexpectedEOF
                }
                offset += n
            }
        }
    }

    /// Reads exactly one framed response, looping over partial `recv()`
    /// reads (same rationale as `FrameReader` on the stdio side: a single
    /// `recv()` is not guaranteed to return a whole frame).
    func receiveFrame() throws -> Data {
        var buffer = Data()
        while true {
            if let (frame, _) = try WireFraming.decodeOne(from: buffer) {
                return frame
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = chunk.withUnsafeMutableBytes { rawBuffer -> Int in
                Darwin.recv(fd, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketClientError.receiveFailed(errno: errno)
            }
            if n == 0 {
                throw SocketClientError.unexpectedEOF
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}
