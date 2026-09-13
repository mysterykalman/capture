import CoreGraphics
import Foundation

/// A parsed sRGB colour with an optional alpha channel, in the 0...1 range
/// per channel. `Contrast` only deals in sRGB — the spec digest's colour
/// module also mentions Display P3/OKLCH, but WCAG 2.x contrast itself is
/// defined purely in terms of sRGB relative luminance, so that is all this
/// type needs to carry.
public struct ParsedColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red.clamped01
        self.green = green.clamped01
        self.blue = blue.clamped01
        self.alpha = alpha.clamped01
    }
}

private extension Double {
    var clamped01: Double { min(max(self, 0), 1) }
}

/// WCAG 2.x contrast math: sRGB gamma correction, relative luminance, and
/// the standard `(L1 + 0.05) / (L2 + 0.05)` contrast ratio, plus the AA/AAA
/// pass/fail thresholds for normal and large text. Real, well-defined math
/// per the WCAG 2.1 spec (§1.4.3, §1.4.6) — not an approximation.
public enum Contrast {
    public struct Result: Hashable, Sendable {
        public let ratio: Double
        public let passesAANormalText: Bool
        public let passesAALargeText: Bool
        public let passesAAANormalText: Bool
        public let passesAAALargeText: Bool

        /// - Parameter ratio: contrast ratio, always >= 1 (`1:1` is the
        ///   lowest possible, identical colours).
        init(ratio: Double) {
            self.ratio = ratio
            // WCAG 2.1 §1.4.3 (AA) / §1.4.6 (AAA).
            self.passesAANormalText = ratio >= 4.5
            self.passesAALargeText = ratio >= 3.0
            self.passesAAANormalText = ratio >= 7.0
            self.passesAAALargeText = ratio >= 4.5
        }

        /// A short label like `"18.9:1"`, matching the hover-card example
        /// in the spec digest ("Contrast 18.9:1").
        public var formattedRatio: String {
            String(format: "%.1f:1", ratio)
        }
    }

    /// Computes the WCAG contrast ratio between two colours. Ignores each
    /// colour's own alpha (contrast is defined for the two colours as
    /// they'll actually be rendered/flattened — callers that need to
    /// account for a semi-transparent foreground over a background should
    /// flatten first via `ParsedColor.flattened(over:)`).
    public static func ratio(foreground: ParsedColor, background: ParsedColor) -> Double {
        let l1 = relativeLuminance(foreground)
        let l2 = relativeLuminance(background)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    public static func evaluate(foreground: ParsedColor, background: ParsedColor) -> Result {
        Result(ratio: ratio(foreground: foreground, background: background))
    }

    /// WCAG 2.1 §1.4.3: relative luminance `L = 0.2126*R + 0.7152*G + 0.0722*B`,
    /// where R/G/B are the linearized (gamma-decoded) sRGB channel values.
    public static func relativeLuminance(_ color: ParsedColor) -> Double {
        let r = linearize(color.red)
        let g = linearize(color.green)
        let b = linearize(color.blue)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// The sRGB electro-optical transfer function's inverse (decode gamma
    /// to linear light), per the WCAG formula's own definition of `R`/`G`/`B`
    /// from `RsRGB`/`GsRGB`/`BsRGB`.
    private static func linearize(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}

extension ParsedColor {
    /// Flattens `self` (used as a foreground) over an opaque `background`,
    /// per simple alpha compositing — useful when a text colour itself has
    /// an alpha channel, since WCAG contrast is only well-defined for two
    /// fully opaque colours.
    public func flattened(over background: ParsedColor) -> ParsedColor {
        guard alpha < 1 else { return self }
        return ParsedColor(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha),
            alpha: 1
        )
    }
}

// MARK: - Parsing

public enum ColorParsingError: Error, Sendable, Equatable {
    case unrecognizedFormat(String)
    case malformedComponents(String)
}

extension ParsedColor {
    /// Parses `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, `rgb(r, g, b)` and
    /// `rgba(r, g, b, a)` — the formats `ElementEvidence.Typography.textColor`
    /// / `Appearance.backgroundColor` realistically carry (computed CSS
    /// colour values in a browser's own serialization, plus the plain hex
    /// forms used elsewhere in the app, e.g. `BookmarksBarRedactionStyle`
    /// swatches). Whitespace-tolerant; percentage `rgb()` components
    /// (`rgb(50%, 50%, 50%)`) are also accepted since some engines emit
    /// them for `getComputedStyle` results.
    public init(cssString raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            self = try Self.parseHex(trimmed)
            return
        }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("rgb(") || lowered.hasPrefix("rgba(") {
            self = try Self.parseFunctional(trimmed)
            return
        }
        throw ColorParsingError.unrecognizedFormat(raw)
    }

    private static func parseHex(_ raw: String) throws -> ParsedColor {
        let hex = Array(raw.dropFirst())
        func component(_ digits: String) -> Double? {
            guard let value = UInt8(digits, radix: 16) else { return nil }
            return Double(value) / 255
        }
        switch hex.count {
        case 3, 4: // #RGB / #RGBA — each digit is doubled (e.g. "f" -> "ff").
            func doubled(_ c: Character) -> Double? { component(String([c, c])) }
            guard
                let r = doubled(hex[0]), let g = doubled(hex[1]), let b = doubled(hex[2])
            else { throw ColorParsingError.malformedComponents(raw) }
            let a = hex.count == 4 ? (doubled(hex[3]) ?? 1) : 1
            return ParsedColor(red: r, green: g, blue: b, alpha: a)
        case 6, 8: // #RRGGBB / #RRGGBBAA
            guard
                let r = component(String(hex[0...1])),
                let g = component(String(hex[2...3])),
                let b = component(String(hex[4...5]))
            else { throw ColorParsingError.malformedComponents(raw) }
            let a: Double
            if hex.count == 8, let parsedAlpha = component(String(hex[6...7])) {
                a = parsedAlpha
            } else {
                a = 1
            }
            return ParsedColor(red: r, green: g, blue: b, alpha: a)
        default:
            throw ColorParsingError.malformedComponents(raw)
        }
    }

    private static func parseFunctional(_ raw: String) throws -> ParsedColor {
        guard
            let openParen = raw.firstIndex(of: "("),
            let closeParen = raw.lastIndex(of: ")")
        else { throw ColorParsingError.malformedComponents(raw) }
        let inner = raw[raw.index(after: openParen)..<closeParen]
        // rgb()/rgba() accept either comma- or space-separated components
        // (the modern CSS Color 4 syntax uses spaces, with `/` before
        // alpha); normalize both to a flat, comma-free token list.
        let normalized = inner.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ",", with: " ")
        let parts = normalized.split(separator: " ").map(String.init)
        guard parts.count == 3 || parts.count == 4 else {
            throw ColorParsingError.malformedComponents(raw)
        }
        func channel(_ token: String) throws -> Double {
            if token.hasSuffix("%") {
                guard let value = Double(token.dropLast()) else { throw ColorParsingError.malformedComponents(raw) }
                return value / 100
            }
            guard let value = Double(token) else { throw ColorParsingError.malformedComponents(raw) }
            return value / 255
        }
        let r = try channel(parts[0])
        let g = try channel(parts[1])
        let b = try channel(parts[2])
        let a: Double
        if parts.count == 4 {
            let token = parts[3]
            a = token.hasSuffix("%") ? (Double(token.dropLast()).map { $0 / 100 } ?? 1) : (Double(token) ?? 1)
        } else {
            a = 1
        }
        return ParsedColor(red: r, green: g, blue: b, alpha: a)
    }
}
