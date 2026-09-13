import Foundation

/// Length-prefix wire framing shared by both hops of the bridge
/// (docs/IPC_PROTOCOL.md "Transport chain"): Chrome's Native Messaging
/// stdio channel and the Unix-domain-socket hop to Capture.app use an
/// identical format — a 4-byte little-endian `UInt32` byte count followed
/// by that many bytes of UTF-8 JSON. This mirrors
/// `CaptureCore.IPCFraming` in the main app
/// (`mac/Sources/CaptureCore/Models/IPCMessage.swift`) byte-for-byte; this
/// package keeps its own copy rather than depending on `mac/` (see
/// `native-host/Package.swift`).
enum WireFraming {
    /// Sanity bound on a single frame's payload size. Chrome's own Native
    /// Messaging implementation caps messages at 1 MB in each direction;
    /// we allow generous headroom above that (rather than hard-coding
    /// exactly 1 MB here) so this host doesn't become a second, slightly
    /// different size policy from the real one `CaptureBrowserBridge`
    /// enforces — but a length prefix far beyond any plausible message is
    /// almost certainly a corrupt or hostile frame, not a legitimate one,
    /// and we refuse to allocate a buffer for it.
    static let maxFrameBytes = 16 * 1024 * 1024 // 16 MiB

    /// Prepends the 4-byte little-endian length header to `payload`.
    static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        return framed
    }

    /// Attempts to split one complete frame off the front of `buffer`.
    /// Returns `(frame, remainder)` when `buffer` already contains a full
    /// frame, or `nil` when it doesn't yet (the caller should read more
    /// bytes and try again). Throws if the header claims a frame larger
    /// than `maxFrameBytes`.
    static func decodeOne(from buffer: Data) throws -> (frame: Data, remainder: Data)? {
        guard buffer.count >= 4 else { return nil }
        let headerStart = buffer.startIndex
        let lengthBytes = buffer.subdata(in: headerStart..<buffer.index(headerStart, offsetBy: 4))
        // `loadUnaligned` (rather than `load(as:)`) because a `Data` slice
        // produced by repeated `append`/`subdata` calls is not guaranteed
        // to be 4-byte aligned at its start.
        let length = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard length <= maxFrameBytes else {
            throw FramingError.frameTooLarge(length)
        }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let frameStart = buffer.index(headerStart, offsetBy: 4)
        let frameEnd = buffer.index(headerStart, offsetBy: total)
        let frame = buffer.subdata(in: frameStart..<frameEnd)
        let remainder = buffer.subdata(in: frameEnd..<buffer.endIndex)
        return (frame, remainder)
    }
}

enum FramingError: Error, CustomStringConvertible {
    /// The peer closed the stream in the middle of a frame (after some
    /// bytes of it had already arrived) rather than cleanly between
    /// frames.
    case endOfStream
    /// A length prefix claimed a frame bigger than `WireFraming.maxFrameBytes`.
    case frameTooLarge(UInt32)

    var description: String {
        switch self {
        case .endOfStream:
            return "stream ended in the middle of a frame"
        case .frameTooLarge(let declared):
            return "frame declares \(declared) bytes, exceeding the \(WireFraming.maxFrameBytes)-byte limit"
        }
    }
}

/// Anything that can hand back the next chunk of available bytes, or empty
/// `Data` on clean end-of-stream. Abstracts `FileHandle.availableData` so
/// `FrameReader` can be exercised in tests against a synthetic, exactly
/// scripted byte source instead of a real pipe.
protocol ByteSource {
    func nextChunk() -> Data
}

extension FileHandle: ByteSource {
    func nextChunk() -> Data {
        availableData
    }
}

/// Stateful reader that accumulates bytes from a `ByteSource` and hands
/// back one complete frame at a time.
///
/// A single read from a pipe (Chrome's stdin to this process, or this
/// process's socket to Capture.app) is **not** guaranteed to return
/// exactly one frame's worth of bytes — it may return a partial header,
/// a partial payload, or several whole frames' worth in one call. This
/// type loops over `nextChunk()`, buffering, until a full frame can be
/// carved off the front.
final class FrameReader {
    private let source: ByteSource
    private var buffer = Data()

    init(source: ByteSource) {
        self.source = source
    }

    convenience init(handle: FileHandle) {
        self.init(source: handle)
    }

    /// Returns the next complete frame's payload, or `nil` on a clean EOF
    /// at a frame boundary (nothing partially buffered — the peer closed
    /// the stream between messages, e.g. Chrome disconnected the native
    /// messaging port). Throws `FramingError.endOfStream` if EOF happens
    /// mid-frame, and `FramingError.frameTooLarge` if a header claims an
    /// unreasonable size.
    func readFrame() throws -> Data? {
        while true {
            if let (frame, remainder) = try WireFraming.decodeOne(from: buffer) {
                buffer = remainder
                return frame
            }
            let chunk = source.nextChunk()
            if chunk.isEmpty {
                if buffer.isEmpty {
                    return nil
                }
                throw FramingError.endOfStream
            }
            buffer.append(chunk)
        }
    }
}

/// Read/write helpers for the stdin/stdout hop specifically (Chrome <->
/// this process). `FrameReader` above does the actual accumulation; this
/// just wires it to the standard file handles and provides the write
/// side.
enum StdioFraming {
    /// Writes one length-prefixed frame to `output`, looping internally
    /// (via `FileHandle.write(contentsOf:)`) until every byte is written.
    static func writeFrame(_ payload: Data, to output: FileHandle) throws {
        let framed = WireFraming.encode(payload)
        try output.write(contentsOf: framed)
    }
}
