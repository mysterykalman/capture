import CaptureCore
import Foundation

/// The one-click "copy" actions from `06_browser_inspector.md`'s
/// "Copy actions (one-click)" list — the subset that's pure text
/// transformation of an `ElementEvidence` (selector/CSS/JSON/issue
/// handoff). Every function here is a pure, deterministic string builder:
/// no I/O, no pasteboard access (that belongs in `CaptureUI`, which calls
/// these and puts the result on `NSPasteboard` itself).
public enum CopyFormatters {
    /// "Copy selector" — `locator.primary`, the same robust selector
    /// string `AnchorResolution` re-resolution starts from.
    public static func copySelector(_ evidence: ElementEvidence) -> String {
        evidence.locator.primary
    }

    /// "Copy as JSON" — the evidence object itself, re-serialized through
    /// the one shared `CaptureCoreJSON` configuration the rest of the app
    /// uses (ISO-8601 dates, sorted keys) so this is byte-for-byte what
    /// would be written into `browser/elements.json` in a `.capture`
    /// project.
    public static func copyAsJSON(_ evidence: ElementEvidence) throws -> String {
        let data = try CaptureCoreJSON.encoder.encode(evidence)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CopyFormatterError.encodingFailed
        }
        return string
    }

    /// "Copy CSS" — a plausible reconstructed rule block from the
    /// computed/authored properties this evidence actually carries.
    /// Properties the evidence doesn't have are simply omitted — this
    /// never invents a value to fill out the block.
    public static func copyCSS(_ evidence: ElementEvidence) -> String {
        var declarations: [String] = []

        func add(_ property: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            declarations.append("  \(property): \(value);")
        }

        add("width", pixelValue(Double(evidence.rect.width)))
        add("height", pixelValue(Double(evidence.rect.height)))

        if let typography = evidence.typography {
            add("font-family", typography.fontFamilyAuthored ?? typography.fontFamilyRendered)
            add("font-size", typography.fontSizePx.map(pixelValue))
            add("font-weight", typography.fontWeight)
            add("font-style", typography.fontStyle)
            add("line-height", typography.lineHeightPx.map(pixelValue))
            add("letter-spacing", typography.letterSpacing)
            add("text-align", typography.textAlign)
            add("color", typography.textColor)
        }

        if let appearance = evidence.appearance {
            add("background-color", appearance.backgroundColor)
            add("background-image", appearance.backgroundImage)
            add("border-radius", appearance.borderRadius)
            add("box-shadow", appearance.boxShadow)
            add("opacity", appearance.opacity.map { String($0) })
        }

        if let boxModel = evidence.boxModel {
            add("display", boxModel.display)
            add("position", boxModel.position)
            add("padding", boxModel.padding?.cssShorthand())
            add("border-width", boxModel.border?.cssShorthand())
            add("margin", boxModel.margin?.cssShorthand())
            add("gap", boxModel.gap)
        }

        if let layout = evidence.layout {
            if evidence.boxModel?.display == nil { add("display", layout.display) }
            add("flex-direction", layout.flexDirection)
            add("z-index", layout.zIndex)
            add("overflow", layout.overflow)
        }

        let body = declarations.isEmpty ? "  /* no computed properties available */" : declarations.joined(separator: "\n")
        return "\(evidence.locator.primary) {\n\(body)\n}"
    }

    /// "Copy issue evidence" — a Markdown block combining selector, key
    /// measurements, and URL, matching the shape of the "Developer
    /// handoff copy format" example in `17_documentation_audit_mode.md`
    /// (`URL: … / Viewport: … / Selector: … / Evidence: … / CSS: …`). That
    /// example is for a numbered `AuditFinding`, which carries a title
    /// this bare `ElementEvidence` does not — the title line is omitted
    /// here rather than invented; a caller building an actual finding
    /// (`CaptureCore.AuditFinding`) can prepend one.
    public static func copyIssueEvidence(_ evidence: ElementEvidence) -> String {
        var lines: [String] = []
        lines.append("URL: \(evidence.url)")
        lines.append("Viewport: \(Int(evidence.viewport.width))×\(Int(evidence.viewport.height))")
        lines.append("Selector: \(evidence.locator.primary)")
        lines.append("Evidence: \(evidenceSummaryLine(evidence))")
        lines.append("CSS: \(inlineCSS(evidence))")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func pixelValue(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))px" : "\(value)px"
    }

    /// A single-line, human-readable summary of the same measurements the
    /// compact hover card shows — used inside `copyIssueEvidence`'s
    /// `Evidence:` line so a pasted issue report doesn't need the full CSS
    /// block to be legible at a glance.
    private static func evidenceSummaryLine(_ evidence: ElementEvidence) -> String {
        let card = ForensicsCard.summarize(evidence)
        var parts: [String] = []
        if let dimensions = card.dimensionsLabel { parts.append(dimensions) }
        if let font = card.fontFamily, let sizeWeight = card.fontSizeAndWeightLabel {
            parts.append("\(font) \(sizeWeight)")
        } else if let sizeWeight = card.fontSizeAndWeightLabel {
            parts.append(sizeWeight)
        }
        if let text = card.textColor, let background = card.backgroundColor {
            var colorPart = "Text \(text) on \(background)"
            if let contrastLabel = card.contrastLabel { colorPart += " (\(contrastLabel))" }
            parts.append(colorPart)
        }
        return parts.isEmpty ? "(no computed properties available)" : parts.joined(separator: " · ")
    }

    /// A single-line, semicolon-separated rendering of `copyCSS`'s
    /// declarations, for the `CSS:` line of `copyIssueEvidence` (the full
    /// multi-line block is available separately via `copyCSS`).
    private static func inlineCSS(_ evidence: ElementEvidence) -> String {
        let block = copyCSS(evidence)
        let declarationLines = block
            .split(separator: "\n")
            .dropFirst() // selector + "{"
            .dropLast()  // "}"
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        return declarationLines.isEmpty ? "(none)" : declarationLines.joined(separator: " ")
    }
}

public enum CopyFormatterError: Error, Sendable {
    case encodingFailed
}
