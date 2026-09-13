import AppKit
import SwiftUI

/// The Visual Design Direction palette (spec digest "Visual Design
/// Direction": "Must NOT be austere, sterile, monochrome, aggressively
/// minimalist... rich accent colours; layered surfaces; tonal panels;
/// purposeful translucency; bold selected-tool states"). Every hex value
/// below is transcribed verbatim from the spec's "Suggested colour palette
/// (hex codes — exact)" list — do not adjust them for taste.
///
/// `CaptureUI` is the only module that imports AppKit/SwiftUI UI-facing
/// colour APIs, per `docs/ARCHITECTURE.md`'s module boundaries, so this is
/// the single source of truth every other CaptureUI file should reference
/// rather than hardcoding hex strings again.
public enum CapturePalette {
    // MARK: Raw palette (exact hex codes from the spec)

    public static let ink = NSColor(hex: 0x11131A)          // Ink / near-black
    public static let warmCanvas = NSColor(hex: 0xF7F5F2)   // Warm light canvas
    public static let electricBlue = NSColor(hex: 0x4D6BFF)
    public static let violet = NSColor(hex: 0x8557E8)
    public static let coral = NSColor(hex: 0xFF6262)
    public static let cyan = NSColor(hex: 0x22C7D6)
    public static let acidLime = NSColor(hex: 0xB9E94E)
    public static let amber = NSColor(hex: 0xF4B845)
}

/// Semantic colour mapping (spec digest: "Capture/selection: blue,
/// Inspect/DOM: violet, Measure: cyan, Privacy/redact: coral,
/// Accessibility: amber, Verified/resolved: green/lime"). Every call site
/// in `CaptureUI` that needs "the colour for this concept" should go
/// through here rather than reaching for a raw palette value directly, so
/// the mapping only ever needs to change in one place.
public enum CaptureSemanticColor {
    public static let capture = CapturePalette.electricBlue
    public static let inspect = CapturePalette.violet
    public static let measure = CapturePalette.cyan
    public static let privacy = CapturePalette.coral
    public static let accessibility = CapturePalette.amber
    public static let verified = CapturePalette.acidLime

    /// Accent colour for a given `ShortcutAction`/tool family, best-effort —
    /// used to tint toolbar buttons and menu icons so the app reads as
    /// "colourful semantic states for Capture, Inspect, Measure, Privacy,
    /// Accessibility, Diff" rather than one flat accent everywhere.
    public enum Family { case capture, inspect, measure, privacy, accessibility, verified, neutral }

    public static func color(for family: Family) -> NSColor {
        switch family {
        case .capture: return capture
        case .inspect: return inspect
        case .measure: return measure
        case .privacy: return privacy
        case .accessibility: return accessibility
        case .verified: return verified
        case .neutral: return CaptureTheme.textSecondary
        }
    }
}

/// Dynamic (light/dark/system-appearance-aware) surface + text tokens built
/// from the raw palette. `NSColor(name:dynamicProvider:)` is the standard
/// AppKit mechanism for a colour that re-resolves automatically when
/// `NSApp.effectiveAppearance` changes (including "system" following the
/// OS), so nothing here needs manual appearance-change observation.
public enum CaptureTheme {
    /// The app's warm, non-sterile canvas — used behind the editor/history/
    /// settings content areas. Dark mode uses a lifted-near-black tone
    /// rather than pure black, matching "layered surfaces" over "flat
    /// black-and-white minimalism".
    public static let canvasBackground = NSColor(name: "CaptureCanvasBackground") { appearance in
        appearance.isDark ? NSColor(hex: 0x17181F) : CapturePalette.warmCanvas
    }

    /// A raised panel/card surface (toolbars, inspector, tray), one step
    /// lighter than `canvasBackground` in both appearances — "tonal panels"
    /// rather than every surface being an identical rounded card.
    public static let panelBackground = NSColor(name: "CapturePanelBackground") { appearance in
        appearance.isDark ? NSColor(hex: 0x1F2029) : NSColor(hex: 0xFFFFFF)
    }

    /// A further-elevated surface (popovers, the command palette, the
    /// Quick Access Overlay) — a little more separation again.
    public static let elevatedBackground = NSColor(name: "CaptureElevatedBackground") { appearance in
        appearance.isDark ? NSColor(hex: 0x272834) : NSColor(hex: 0xFFFFFF)
    }

    public static let textPrimary = NSColor(name: "CaptureTextPrimary") { appearance in
        appearance.isDark ? NSColor(hex: 0xF3F2F8) : CapturePalette.ink
    }

    public static let textSecondary = NSColor(name: "CaptureTextSecondary") { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.6) : NSColor(hex: 0x11131A).withAlphaComponent(0.6)
    }

    public static let separator = NSColor(name: "CaptureSeparator") { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.1) : NSColor(hex: 0x11131A).withAlphaComponent(0.08)
    }

    /// The primary interactive accent (selection outlines, default button
    /// tint, the active-tool highlight) — Electric Blue, matching "Capture/
    /// selection: blue".
    public static let accent = CapturePalette.electricBlue
}

// MARK: - SwiftUI bridging

public extension Color {
    init(capturePalette color: NSColor) { self.init(nsColor: color) }

    static let captureCanvasBackground = Color(nsColor: CaptureTheme.canvasBackground)
    static let capturePanelBackground = Color(nsColor: CaptureTheme.panelBackground)
    static let captureElevatedBackground = Color(nsColor: CaptureTheme.elevatedBackground)
    static let captureTextPrimary = Color(nsColor: CaptureTheme.textPrimary)
    static let captureTextSecondary = Color(nsColor: CaptureTheme.textSecondary)
    static let captureSeparator = Color(nsColor: CaptureTheme.separator)
    static let captureAccent = Color(nsColor: CaptureTheme.accent)

    static let captureBlue = Color(nsColor: CapturePalette.electricBlue)
    static let captureViolet = Color(nsColor: CapturePalette.violet)
    static let captureCoral = Color(nsColor: CapturePalette.coral)
    static let captureCyan = Color(nsColor: CapturePalette.cyan)
    static let captureLime = Color(nsColor: CapturePalette.acidLime)
    static let captureAmber = Color(nsColor: CapturePalette.amber)

    static func captureSemantic(_ family: CaptureSemanticColor.Family) -> Color {
        Color(nsColor: CaptureSemanticColor.color(for: family))
    }
}

// MARK: - Helpers

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension NSColor {
    /// `0xRRGGBB` convenience — every literal above is written exactly as
    /// the spec's hex list, with no manual R/G/B decomposition to get wrong.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let r = CGFloat((hex & 0xFF0000) >> 16) / 255
        let g = CGFloat((hex & 0x00FF00) >> 8) / 255
        let b = CGFloat(hex & 0x0000FF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    /// `NSColor(name:dynamicProvider:)` wrapper that reads slightly nicer at
    /// each call site above (`appearance in ...` instead of repeating
    /// `NSAppearance`'s verbose initializer signature).
    convenience init(name: String, dynamicProvider: @escaping (NSAppearance) -> NSColor) {
        self.init(name: NSColor.Name(name), dynamicProvider: dynamicProvider)
    }
}
