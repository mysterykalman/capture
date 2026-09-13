import CryptoKit
import Foundation

/// Content hashing for `manifest.json.source.contentHash` (Part I §9) and
/// history-store dedupe (Part I §10, §20: "Content-addressed assets: SHA256
/// -> one underlying blob"). `CryptoKit` is a system framework (macOS
/// 10.15+) so this adds no external package dependency, per Part I §37
/// ("prefer system framework if practical").
public extension Data {
    func sha256Hex() -> String {
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
