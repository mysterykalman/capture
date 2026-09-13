import CaptureCore
import CoreGraphics
import Foundation

/// Formats an `EdgeInsets` as the shortest equivalent CSS shorthand form
/// (1/2/3/4 value collapsing), e.g. `top:14 right:24 bottom:14 left:24` ->
/// `"14px 24px"` — matching the hover-card example's `Padding 14px 24px`.
extension EdgeInsets {
    func cssShorthand(unit: String = "px") -> String {
        func fmt(_ value: CGFloat) -> String {
            let doubleValue = Double(value)
            if doubleValue.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(Int(doubleValue))\(unit)"
            }
            return "\(doubleValue)\(unit)"
        }
        if top == right, right == bottom, bottom == left {
            return fmt(top)
        }
        if top == bottom, left == right {
            return "\(fmt(top)) \(fmt(right))"
        }
        if left == right {
            return "\(fmt(top)) \(fmt(right)) \(fmt(bottom))"
        }
        return "\(fmt(top)) \(fmt(right)) \(fmt(bottom)) \(fmt(left))"
    }
}

/// The compact hover-card content — see the spec digest's exact example
/// (`06_browser_inspector.md`):
/// ```text
/// button.product-form__submit
/// 328 × 48 px
///
/// Inter
/// 16 px / 600
/// line-height 20 px
///
/// Text #FFFFFF
/// Background #111111
/// Contrast 18.9:1
///
/// Padding 14px 24px
/// Radius 4px
/// Display flex
/// Gap 8px
/// ```
/// Every field is its own labeled property (not one formatted string) so
/// `CaptureUI` can lay this out in SwiftUI however it wants — grid, stack,
/// truncation, whatever the hover card design calls for. Any field the
/// evidence doesn't have is `nil`; callers should omit that row rather than
/// show a placeholder, since a hover card should "not need to expand
/// technical details unless desired" and nothing here should look like a
/// fabricated value.
public struct ForensicsCardContent: Sendable, Equatable {
    public var selector: String
    public var widthPx: Double?
    public var heightPx: Double?

    public var fontFamily: String?
    public var fontSizePx: Double?
    public var fontWeight: String?
    public var lineHeightPx: Double?

    public var textColor: String?
    public var backgroundColor: String?
    public var contrastRatio: Double?

    public var padding: String?
    public var borderRadius: String?
    public var display: String?
    public var gap: String?

    /// `"328 × 48 px"` — `nil` if either dimension is unknown.
    public var dimensionsLabel: String? {
        guard let widthPx, let heightPx else { return nil }
        return "\(Self.trimmed(widthPx)) × \(Self.trimmed(heightPx)) px"
    }

    /// `"16 px / 600"` — `nil` if size and weight aren't both known.
    public var fontSizeAndWeightLabel: String? {
        guard let fontSizePx else { return nil }
        if let fontWeight { return "\(Self.trimmed(fontSizePx)) px / \(fontWeight)" }
        return "\(Self.trimmed(fontSizePx)) px"
    }

    /// `"line-height 20 px"`.
    public var lineHeightLabel: String? {
        guard let lineHeightPx else { return nil }
        return "line-height \(Self.trimmed(lineHeightPx)) px"
    }

    /// `"18.9:1"`, matching the example exactly.
    public var contrastLabel: String? {
        guard let contrastRatio else { return nil }
        return String(format: "%.1f:1", contrastRatio)
    }

    static func trimmed(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }
}

/// The full forensic card's five sections — Identity, Geometry, Layout,
/// Appearance, CSS provenance — per `06_browser_inspector.md`'s "Full
/// forensic card sections" list. Typography is intentionally *not*
/// duplicated here in depth: the spec digest says it's "handled in depth by
/// the typography module" (`07_typography_inspector.md`), so this struct
/// only carries the same compact typography line the hover card does.
public struct FullForensicsCardContent: Sendable, Equatable {
    public struct Identity: Sendable, Equatable {
        public var selector: String
        public var role: String?
        public var accessibleName: String?
        public var textFingerprint: String?
        /// The `absolute-path` locator candidate, if the extension sent
        /// one — the closest equivalent to a "DOM path" this model carries.
        public var domPath: String?
    }

    public struct Geometry: Sendable, Equatable {
        public var rect: CaptureRect
        public var contentBox: CaptureSize?
        public var padding: EdgeInsets?
        public var border: EdgeInsets?
        public var margin: EdgeInsets?
        public var gap: String?
    }

    public struct Layout: Sendable, Equatable {
        public var display: String?
        public var flexDirection: String?
        public var position: String?
        public var zIndex: String?
        public var overflow: String?
    }

    public struct Appearance: Sendable, Equatable {
        public var textColor: String?
        public var backgroundColor: String?
        public var backgroundImage: String?
        public var borderRadius: String?
        public var boxShadow: String?
        public var opacity: Double?
        public var contrast: Contrast.Result?
    }

    /// One row of the "CSS provenance" section. Mirrors
    /// `ElementEvidence.AuthoredSource` field-for-field rather than
    /// reshaping it, so nothing here can drift from what was actually
    /// reported.
    public struct ProvenanceRow: Sendable, Equatable {
        public var property: String
        public var computedValue: String
        public var authoredDeclaration: String?
        public var selector: String?
        public var stylesheetURL: String?
        public var sourceUnavailable: Bool

        /// Per Part I §17 — "If unavailable: computed value known / source
        /// unavailable. Do not fabricate source information." This is the
        /// one and only string this type will ever produce when a source
        /// isn't known; it is never synthesized from a guess.
        public static let sourceUnavailableLabel = "computed value known, source unavailable"

        public var provenanceLabel: String {
            if sourceUnavailable {
                return Self.sourceUnavailableLabel
            }
            if let authoredDeclaration {
                if let selector {
                    return "\(authoredDeclaration) — \(selector)"
                }
                return authoredDeclaration
            }
            // No `sourceUnavailable` flag was set, but there's also no
            // authored declaration to show — still refuse to guess.
            return Self.sourceUnavailableLabel
        }
    }

    public var identity: Identity
    public var geometry: Geometry
    public var layout: Layout
    public var appearance: Appearance
    public var cssProvenance: [ProvenanceRow]
}

/// Pure transformation from `CaptureCore.ElementEvidence` to card content —
/// no I/O, no SwiftUI, fully unit-testable.
public enum ForensicsCard {
    public static func summarize(_ evidence: ElementEvidence) -> ForensicsCardContent {
        let typography = evidence.typography
        let appearance = evidence.appearance
        let boxModel = evidence.boxModel

        return ForensicsCardContent(
            selector: evidence.locator.primary,
            widthPx: Double(evidence.rect.width),
            heightPx: Double(evidence.rect.height),
            fontFamily: typography?.fontFamilyRendered ?? typography?.fontFamilyAuthored,
            fontSizePx: typography?.fontSizePx,
            fontWeight: typography?.fontWeight,
            lineHeightPx: typography?.lineHeightPx,
            textColor: typography?.textColor,
            backgroundColor: appearance?.backgroundColor,
            contrastRatio: resolvedContrastRatio(evidence),
            padding: boxModel?.padding?.cssShorthand(),
            borderRadius: appearance?.borderRadius,
            display: boxModel?.display ?? evidence.layout?.display,
            gap: boxModel?.gap
        )
    }

    public static func fullCard(_ evidence: ElementEvidence) -> FullForensicsCardContent {
        FullForensicsCardContent(
            identity: FullForensicsCardContent.Identity(
                selector: evidence.locator.primary,
                role: evidence.locator.role ?? evidence.accessibility?.role,
                accessibleName: evidence.locator.accessibleName ?? evidence.accessibility?.accessibleName,
                textFingerprint: evidence.locator.textFingerprint,
                domPath: evidence.locator.candidates.first(where: { $0.strategy == .absolutePath })?.value
            ),
            geometry: FullForensicsCardContent.Geometry(
                rect: evidence.rect,
                contentBox: evidence.boxModel?.contentBox,
                padding: evidence.boxModel?.padding,
                border: evidence.boxModel?.border,
                margin: evidence.boxModel?.margin,
                gap: evidence.boxModel?.gap
            ),
            layout: FullForensicsCardContent.Layout(
                display: evidence.layout?.display ?? evidence.boxModel?.display,
                flexDirection: evidence.layout?.flexDirection,
                position: evidence.boxModel?.position,
                zIndex: evidence.layout?.zIndex,
                overflow: evidence.layout?.overflow
            ),
            appearance: FullForensicsCardContent.Appearance(
                textColor: evidence.typography?.textColor,
                backgroundColor: evidence.appearance?.backgroundColor,
                backgroundImage: evidence.appearance?.backgroundImage,
                borderRadius: evidence.appearance?.borderRadius,
                boxShadow: evidence.appearance?.boxShadow,
                opacity: evidence.appearance?.opacity,
                contrast: resolvedContrast(evidence)
            ),
            cssProvenance: (evidence.authoredSources ?? []).map { source in
                FullForensicsCardContent.ProvenanceRow(
                    property: source.property,
                    computedValue: source.computedValue,
                    authoredDeclaration: source.authoredDeclaration,
                    selector: source.selector,
                    stylesheetURL: source.stylesheetURL,
                    sourceUnavailable: source.sourceUnavailable
                )
            }
        )
    }

    /// Prefers `accessibility.contrastRatio` when the extension already
    /// computed it (it has access to the actual composited background,
    /// including stacking/transparency this app cannot see); only falls
    /// back to computing it locally from `typography.textColor` +
    /// `appearance.backgroundColor` when both parse cleanly as opaque-ish
    /// colours. Never guesses a ratio when neither is available.
    static func resolvedContrast(_ evidence: ElementEvidence) -> Contrast.Result? {
        if let ratio = evidence.accessibility?.contrastRatio {
            return Contrast.Result(ratio: ratio)
        }
        guard
            let textColorString = evidence.typography?.textColor,
            let backgroundColorString = evidence.appearance?.backgroundColor,
            let foreground = try? ParsedColor(cssString: textColorString),
            let background = try? ParsedColor(cssString: backgroundColorString)
        else { return nil }
        return Contrast.evaluate(foreground: foreground, background: background)
    }

    static func resolvedContrastRatio(_ evidence: ElementEvidence) -> Double? {
        resolvedContrast(evidence)?.ratio
    }
}
