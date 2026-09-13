import Foundation
import XCTest
@testable import CaptureNativeHost

final class WireFramingTests: XCTestCase {
    func testEncodeProducesFourByteLittleEndianLengthPrefix() {
        let payload = Data("hi".utf8) // 2 bytes
        let framed = WireFraming.encode(payload)

        XCTAssertEqual(framed.count, 4 + payload.count)
        // Little-endian UInt32(2) => bytes [0x02, 0x00, 0x00, 0x00]
        XCTAssertEqual(Array(framed.prefix(4)), [0x02, 0x00, 0x00, 0x00])
        XCTAssertEqual(framed.suffix(from: 4), payload)
    }

    func testEncodeDecodeRoundTrip() throws {
        let payload = Data(#"{"version":1,"id":"abc","type":"session.ping","payload":{}}"#.utf8)
        let framed = WireFraming.encode(payload)

        let decoded = try WireFraming.decodeOne(from: framed)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frame, payload)
        XCTAssertEqual(decoded?.remainder, Data())
    }

    func testDecodeOneReturnsNilWhenHeaderIncomplete() throws {
        // Only 2 of the 4 header bytes present.
        let partial = Data([0x05, 0x00])
        XCTAssertNil(try WireFraming.decodeOne(from: partial))
    }

    func testDecodeOneReturnsNilWhenPayloadIncomplete() throws {
        let payload = Data("hello world".utf8) // 11 bytes
        var framed = WireFraming.encode(payload)
        framed.removeLast(3) // truncate the payload
        XCTAssertNil(try WireFraming.decodeOne(from: framed))
    }

    func testDecodeOneLeavesRemainderForNextFrame() throws {
        let first = Data("first".utf8)
        let second = Data("second-message".utf8)
        var combined = WireFraming.encode(first)
        combined.append(WireFraming.encode(second))

        guard let (frame1, remainder1) = try WireFraming.decodeOne(from: combined) else {
            return XCTFail("expected a decodable first frame")
        }
        XCTAssertEqual(frame1, first)

        guard let (frame2, remainder2) = try WireFraming.decodeOne(from: remainder1) else {
            return XCTFail("expected a decodable second frame in the remainder")
        }
        XCTAssertEqual(frame2, second)
        XCTAssertEqual(remainder2, Data())
    }

    func testDecodeOneThrowsOnOversizedFrame() {
        let hugeLength = UInt32(WireFraming.maxFrameBytes) + 1
        // Build the 4-byte little-endian header by hand (rather than an
        // unsafe pointer store) so this test doesn't depend on any
        // particular alignment of `Data`'s backing storage.
        let le = hugeLength.littleEndian
        let oversizedHeader = Data([
            UInt8(le & 0xFF),
            UInt8((le >> 8) & 0xFF),
            UInt8((le >> 16) & 0xFF),
            UInt8((le >> 24) & 0xFF)
        ])

        XCTAssertThrowsError(try WireFraming.decodeOne(from: oversizedHeader)) { error in
            guard case FramingError.frameTooLarge(let declared) = error else {
                return XCTFail("expected frameTooLarge, got \(error)")
            }
            XCTAssertEqual(declared, hugeLength)
        }
    }

    func testEmptyPayloadRoundTrips() throws {
        let framed = WireFraming.encode(Data())
        let decoded = try WireFraming.decodeOne(from: framed)
        XCTAssertEqual(decoded?.frame, Data())
        XCTAssertEqual(decoded?.remainder, Data())
    }
}

// MARK: - FrameReader (partial-read simulation)

/// A deterministic, synthetic `ByteSource` that hands back pre-scripted
/// chunks one at a time on each call to `nextChunk()` — used to simulate
/// exactly where a real pipe read might split a frame (mid-header,
/// mid-payload, multiple frames in one read, etc.) without depending on
/// real OS scheduling/timing, which would make such a test flaky.
final class ScriptedByteSource: ByteSource {
    private var chunks: [Data]
    private(set) var callCount = 0

    /// `chunks` is the sequence of chunks to return, one per call. Once
    /// exhausted, every subsequent call returns empty `Data` (simulating
    /// EOF), matching `FileHandle.availableData`'s behavior after the
    /// peer closes its end.
    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func nextChunk() -> Data {
        callCount += 1
        guard !chunks.isEmpty else { return Data() }
        return chunks.removeFirst()
    }
}

final class FrameReaderTests: XCTestCase {
    func testReadFrameAssemblesFrameSplitAcrossManyTinyChunks() throws {
        let payload = Data(#"{"id":"1234"}"#.utf8)
        let framed = WireFraming.encode(payload)

        // Feed it back one byte at a time — the most adversarial partial-read
        // pattern possible.
        let byteChunks = framed.map { Data([$0]) }
        let source = ScriptedByteSource(chunks: byteChunks)
        let reader = FrameReader(source: source)

        let result = try reader.readFrame()
        XCTAssertEqual(result, payload)
        XCTAssertEqual(source.callCount, framed.count)
    }

    func testReadFrameHandlesHeaderAndPayloadSplitArbitrarily() throws {
        let payload = Data(String(repeating: "x", count: 100).utf8)
        let framed = WireFraming.encode(payload)

        // Split: 2 bytes of header, 2 bytes of header, 30 bytes of
        // payload, rest of payload.
        let chunks = [
            framed.subdata(in: 0..<2),
            framed.subdata(in: 2..<4),
            framed.subdata(in: 4..<34),
            framed.subdata(in: 34..<framed.count)
        ]
        let source = ScriptedByteSource(chunks: chunks)
        let reader = FrameReader(source: source)

        let result = try reader.readFrame()
        XCTAssertEqual(result, payload)
    }

    func testReadFrameHandlesMultipleFramesDeliveredInOneChunk() throws {
        let first = Data("one".utf8)
        let second = Data("two".utf8)
        var combined = WireFraming.encode(first)
        combined.append(WireFraming.encode(second))

        let source = ScriptedByteSource(chunks: [combined])
        let reader = FrameReader(source: source)

        XCTAssertEqual(try reader.readFrame(), first)
        XCTAssertEqual(try reader.readFrame(), second)
        // Nothing buffered and no more chunks scripted => clean EOF.
        XCTAssertNil(try reader.readFrame())
    }

    func testReadFrameReturnsNilOnCleanEOFAtBoundary() throws {
        let source = ScriptedByteSource(chunks: []) // immediately EOF
        let reader = FrameReader(source: source)
        XCTAssertNil(try reader.readFrame())
    }

    func testReadFrameThrowsOnEOFMidFrame() throws {
        let payload = Data("truncated".utf8)
        var framed = WireFraming.encode(payload)
        framed.removeLast(4) // pretend the stream died partway through the payload

        let source = ScriptedByteSource(chunks: [framed]) // then EOF
        let reader = FrameReader(source: source)

        XCTAssertThrowsError(try reader.readFrame()) { error in
            guard case FramingError.endOfStream = error else {
                return XCTFail("expected endOfStream, got \(error)")
            }
        }
    }

    func testReadFrameOverRealPipeEndToEnd() throws {
        // Integration-style sanity check with a genuine OS pipe (in
        // addition to the deterministic ScriptedByteSource tests above,
        // which are what actually pin down partial-read correctness).
        let pipe = Pipe()
        let payload = Data(#"{"hello":"world"}"#.utf8)
        let framed = WireFraming.encode(payload)

        let writeQueue = DispatchQueue(label: "test.pipe.writer")
        writeQueue.async {
            // Dribble it out in a few separate writes so the reader is
            // likely to see more than one partial chunk.
            let midpoint = framed.count / 2
            let first = framed.subdata(in: 0..<midpoint)
            let second = framed.subdata(in: midpoint..<framed.count)
            try? pipe.fileHandleForWriting.write(contentsOf: first)
            usleep(5_000)
            try? pipe.fileHandleForWriting.write(contentsOf: second)
            try? pipe.fileHandleForWriting.close()
        }

        let reader = FrameReader(handle: pipe.fileHandleForReading)
        let result = try reader.readFrame()
        XCTAssertEqual(result, payload)

        // Stream is now closed by the writer => clean EOF.
        XCTAssertNil(try reader.readFrame())
    }
}
