import Foundation

/// Write-to-temp-then-rename helper (Part I §35 crash safety: "Projects:
/// atomic metadata writes; temporary file then replace; autosave" and
/// "Never allow a failed export to corrupt the source project.").
public enum AtomicFileWriter {
    public enum WriteError: Error, Sendable { case couldNotCreateTempFile, moveFailed(underlying: String) }

    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            throw WriteError.couldNotCreateTempFile
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw WriteError.moveFailed(underlying: error.localizedDescription)
        }
    }

    public static func writeJSON<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder = CaptureCoreJSON.encoder) throws {
        let data = try encoder.encode(value)
        try write(data, to: url)
    }
}

/// Shared `JSONEncoder`/`JSONDecoder` configuration so every module encodes
/// dates/keys identically (ISO-8601 dates matching the `date-time` format
/// used throughout `schemas/`).
public enum CaptureCoreJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
