import XCTest
@testable import CaptureCore

final class ProjectDocumentTests: XCTestCase {
    func testSaveAndReloadRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".capture")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifest = ProjectManifest(
            kind: .screenshot,
            title: "Test Capture",
            source: .init(relativePath: "source/original.png", contentHash: "sha256:placeholder")
        )
        var document = CaptureProjectDocument(manifest: manifest)
        document.annotations = [Annotation(type: .rectangle, frame: CaptureRect(x: 0, y: 0, width: 10, height: 10), zIndex: 0)]

        let sourceData = Data("fake-png-bytes".utf8)
        try document.save(to: tempDir, sourceData: sourceData, sourceRelativePath: "source/original.png")

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("source/original.png").path))

        let reloaded = try CaptureProjectDocument.load(from: tempDir)
        XCTAssertEqual(reloaded.manifest.title, "Test Capture")
        XCTAssertEqual(reloaded.annotations.count, 1)
        XCTAssertEqual(reloaded.manifest.source.contentHash, "sha256:" + sourceData.sha256Hex())
        // Redactions/measurements were never written (empty arrays) — must
        // load as empty, not throw.
        XCTAssertEqual(reloaded.redactions.count, 0)
    }

    func testLoadingNonPackageThrows() {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("hi".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        XCTAssertThrowsError(try CaptureProjectDocument.load(from: fileURL))
    }
}

final class IPCFramingTests: XCTestCase {
    func testEncodeDecodeRoundTrip() {
        let payload = Data("{\"hello\":\"world\"}".utf8)
        let framed = IPCFraming.encode(payload)
        guard let (frame, remainder) = IPCFraming.decodeOne(from: framed) else {
            return XCTFail("expected a decodable frame")
        }
        XCTAssertEqual(frame, payload)
        XCTAssertTrue(remainder.isEmpty)
    }

    func testIncompleteFrameReturnsNil() {
        let payload = Data("{\"hello\":\"world\"}".utf8)
        let framed = IPCFraming.encode(payload)
        let truncated = framed.prefix(framed.count - 2)
        XCTAssertNil(IPCFraming.decodeOne(from: Data(truncated)))
    }

    func testHandlesTwoConcatenatedFrames() {
        let a = IPCFraming.encode(Data("first".utf8))
        let b = IPCFraming.encode(Data("second".utf8))
        var buffer = a
        buffer.append(b)
        guard let (frame1, remainder1) = IPCFraming.decodeOne(from: buffer) else { return XCTFail() }
        XCTAssertEqual(String(data: frame1, encoding: .utf8), "first")
        guard let (frame2, remainder2) = IPCFraming.decodeOne(from: remainder1) else { return XCTFail() }
        XCTAssertEqual(String(data: frame2, encoding: .utf8), "second")
        XCTAssertTrue(remainder2.isEmpty)
    }
}

final class IPCResponseCodingTests: XCTestCase {
    func testSuccessRoundTrip() throws {
        let response = IPCResponse.success(id: UUID(), payload: .object(["ok": .bool(true)]))
        let data = try CaptureCoreJSON.encoder.encode(response)
        let decoded = try CaptureCoreJSON.decoder.decode(IPCResponse.self, from: data)
        guard case .success(let payload) = decoded.result else { return XCTFail("expected success") }
        XCTAssertEqual(payload["ok"]?.stringValue, nil) // it's a bool, not a string
    }

    func testFailureRoundTrip() throws {
        let response = IPCResponse.failure(id: UUID(), code: .elementNotFound, message: "gone")
        let data = try CaptureCoreJSON.encoder.encode(response)
        let decoded = try CaptureCoreJSON.decoder.decode(IPCResponse.self, from: data)
        guard case .failure(let error) = decoded.result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.code, .elementNotFound)
        XCTAssertEqual(error.message, "gone")
    }
}
