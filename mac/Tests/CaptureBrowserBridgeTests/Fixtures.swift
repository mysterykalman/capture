import CaptureCore
import Foundation
@testable import CaptureBrowserBridge

/// Shared test fixtures so each test file doesn't hand-roll its own
/// minimal `ElementEvidence`/envelope JSON.
enum Fixtures {
    static func elementEvidence(url: String = "https://example.com/products/x") -> ElementEvidence {
        ElementEvidence(
            url: url,
            title: "Product X",
            viewport: .init(width: 1440, height: 900, devicePixelRatio: 2, scrollX: 0, scrollY: 1620),
            locator: .init(
                primary: "[data-product-form] button[type='submit']",
                candidates: [
                    .init(strategy: .dataAttribute, value: "[data-product-form] button[type='submit']", confidence: 0.95)
                ],
                role: "button",
                accessibleName: "Add to cart",
                textFingerprint: "Add to cart"
            ),
            rect: .init(x: 812, y: 540, width: 328, height: 48),
            boxModel: .init(
                padding: .init(top: 14, right: 24, bottom: 14, left: 24),
                gap: "8px",
                display: "flex"
            ),
            typography: .init(
                fontFamilyAuthored: "Inter",
                fontFamilyRendered: "Inter",
                fontSizePx: 16,
                fontWeight: "600",
                lineHeightPx: 20,
                textColor: "#FFFFFF"
            ),
            appearance: .init(backgroundColor: "#111111", borderRadius: "4px")
        )
    }

    /// Builds the raw JSON `Data` for a well-formed request envelope, for
    /// tests that exercise `MessageDispatcher.classify(_:)` directly
    /// against bytes rather than an already-constructed `IPCRequest`.
    static func requestFrame(id: UUID = UUID(), type: String, tabSessionId: UUID? = nil, payload: [String: Any] = [:]) -> Data {
        var object: [String: Any] = [
            "version": 1,
            "id": id.uuidString,
            "type": type,
            "payload": payload
        ]
        if let tabSessionId {
            object["tabSessionId"] = tabSessionId.uuidString
        }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func evidencePayloadJSON(_ evidence: ElementEvidence) throws -> JSONValue {
        let data = try CaptureCoreJSON.encoder.encode(evidence)
        return try CaptureCoreJSON.decoder.decode(JSONValue.self, from: data)
    }
}
