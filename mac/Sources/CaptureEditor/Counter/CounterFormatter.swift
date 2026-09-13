import CaptureCore
import Foundation

/// Counter label formats (Part III `03_editor_annotations.md`: "Counter —
/// formats: 1,2,3 / A,B,C / a,b,c / I,II,III / custom labels").
public enum CounterFormat: String, Sendable, CaseIterable {
    case numeric
    case alphaUpper
    case alphaLower
    case roman
    case custom
}

/// Pure logic for Counter annotation labelling: formatting a single label,
/// and the "auto-renumber after insert/delete" algorithm. No `CGContext`/
/// AppKit dependency at all, so it's directly unit-testable (see
/// `Tests/CaptureEditorTests/CounterFormatterTests.swift`) without any
/// rendering. `Tools/AnnotationRenderer.swift` reads the already-resolved
/// `AnnotationStyleKeys.counterResolvedIndex` written by `renumber` rather
/// than recomputing sequence position at draw time, so a single counter can
/// be drawn in isolation without needing its sibling counters in scope.
public enum CounterFormatter {
    /// Renders one counter's label given its format, explicit start number,
    /// and its already-resolved 0-based position within its sequence.
    public static func label(format: CounterFormat, startNumber: Int, zeroBasedIndex: Int, customLabels: [String]?) -> String {
        guard zeroBasedIndex >= 0 else { return "" }
        if format == .custom {
            guard let customLabels, zeroBasedIndex < customLabels.count else {
                // Fall back to numeric so a counter never renders as an
                // empty/broken label just because its custom label list ran
                // out — matches "auto-renumber" staying useful even with a
                // mismatched custom-label count.
                return String(startNumber + zeroBasedIndex)
            }
            return customLabels[zeroBasedIndex]
        }

        let n = startNumber + zeroBasedIndex
        switch format {
        case .numeric:
            return String(n)
        case .alphaUpper:
            return alphaLabel(n: n, uppercase: true)
        case .alphaLower:
            return alphaLabel(n: n, uppercase: false)
        case .roman:
            return romanNumeral(n) ?? String(n)
        case .custom:
            return String(n) // unreachable, handled above.
        }
    }

    /// Bijective base-26 numeral ("A", "B", ... "Z", "AA", "AB", ...) for
    /// `n >= 1`. Ordinary base-26 would render 26 as "A0"/collide with 1 as
    /// leading-zero-free representations don't exist in plain base-26;
    /// bijective numeration is the standard fix (same system spreadsheet
    /// column letters use).
    static func alphaLabel(n: Int, uppercase: Bool) -> String {
        guard n >= 1 else { return uppercase ? "A" : "a" }
        var remaining = n
        var letters: [Character] = []
        let base: UInt8 = uppercase ? 65 : 97 // ASCII 'A' / 'a'
        while remaining > 0 {
            remaining -= 1
            let rem = remaining % 26
            letters.append(Character(UnicodeScalar(base + UInt8(rem))))
            remaining /= 26
        }
        return String(letters.reversed())
    }

    /// Standard subtractive-notation Roman numeral for `1...3999`; returns
    /// `nil` outside that range (Roman numerals have no conventional
    /// representation for 0 or numbers >= 4000) so callers fall back to
    /// plain numeric rather than render nothing.
    static func romanNumeral(_ n: Int) -> String? {
        guard n > 0, n < 4000 else { return nil }
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
        ]
        var remainder = n
        var result = ""
        for (value, symbol) in table {
            guard remainder >= value else { continue }
            let count = remainder / value
            result += String(repeating: symbol, count: count)
            remainder -= value * count
        }
        return result
    }

    /// Default sequence id used for counters that don't set an explicit
    /// `AnnotationStyleKeys.counterSequenceId` — they all renumber together
    /// as one implicit sequence.
    public static let defaultSequenceID = "default"

    /// Re-derives each counter annotation's `counterResolvedIndex` (its
    /// 0-based position within its sequence) from the current set of
    /// `.counter` annotations, grouped by `counterSequenceId` and ordered by
    /// `zIndex` (insertion order — counters are drawn/added in click order,
    /// and `zIndex` strictly increases as annotations are added, matching
    /// the "auto-renumber after insert/delete" requirement: delete counter
    /// #2 of 4 and the remaining three become #1/#2/#3, not #1/#3/#4).
    ///
    /// Non-counter annotations pass through completely untouched (same
    /// instances, same order) — only `.counter` entries may have their
    /// `typeData.resolvedIndex` field rewritten, and only when it actually
    /// changed, so this is safe to call after every annotation add/delete
    /// without perturbing unrelated document state or unnecessarily
    /// invalidating anything keyed on annotation equality.
    public static func renumber(_ annotations: [Annotation]) -> [Annotation] {
        var result = annotations
        let counterIndices = result.indices.filter { result[$0].type == .counter }
        guard !counterIndices.isEmpty else { return result }

        let grouped = Dictionary(grouping: counterIndices) { idx -> String in
            StyleReader(result[idx]).typeDataString(AnnotationStyleKeys.counterSequenceId, default: defaultSequenceID) ?? defaultSequenceID
        }

        for (_, indices) in grouped {
            let ordered = indices.sorted { result[$0].zIndex < result[$1].zIndex }
            for (position, idx) in ordered.enumerated() {
                result[idx] = withResolvedIndex(result[idx], position)
            }
        }
        return result
    }

    private static func withResolvedIndex(_ annotation: Annotation, _ index: Int) -> Annotation {
        let reader = StyleReader(annotation)
        guard reader.typeDataInt(AnnotationStyleKeys.counterResolvedIndex, default: -1) != index else {
            return annotation // No-op when unchanged, per the doc comment above.
        }
        var updated = annotation
        var dict: [String: JSONValue]
        if case .object(let existing)? = updated.typeData {
            dict = existing
        } else {
            dict = [:]
        }
        dict[AnnotationStyleKeys.counterResolvedIndex] = .number(Double(index))
        updated.typeData = .object(dict)
        return updated
    }
}
