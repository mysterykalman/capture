import Foundation
import os

/// Structured local logging (Part I §34). Default mode avoids noisy
/// logging; `debug` level is only emitted when explicitly enabled. Never
/// log screenshot pixels, OCR text, URLs, or browsing content at any level
/// above `debug`, and never include them in the diagnostic bundle exporter
/// (`CaptureApp.DiagnosticsBundleExporter`) unless the user explicitly
/// opts in — see `docs/PERMISSIONS.md`.
public struct CaptureLogger: Sendable {
    public enum Level: Int, Sendable, Comparable {
        case debug = 0, info, warning, error
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private let logger: Logger
    public static let minimumLevel = Level.info

    public init(subsystem: String = "com.capture.app", category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func log(_ level: Level, _ message: String) {
        guard level >= Self.minimumLevel else { return }
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }

    public func debug(_ message: String) { log(.debug, message) }
    public func info(_ message: String) { log(.info, message) }
    public func warning(_ message: String) { log(.warning, message) }
    public func error(_ message: String) { log(.error, message) }
}
