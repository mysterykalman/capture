import CaptureCore
import CoreGraphics
import Foundation

/// Documents the specific `Annotation.style` / `Annotation.typeData` JSON
/// keys every annotation tool reads. `CaptureCore.Annotation.style` and
/// `.typeData` are deliberately loosely-typed `JSONValue?` (see
/// `CaptureCore/Models/Annotation.swift`) rather than ~15 kind-specific
/// structs, so this is the single place that has to agree with whatever
/// `CaptureUI`'s property-panel code writes into those fields. Keep both in
/// sync by hand — there is no shared schema generator for this JSON shape.
///
/// Convention used throughout: `style` holds *presentation* properties that
/// make sense across multiple kinds (colour, thickness, line style, fill,
/// shadow, hand-drawn); `typeData` holds properties specific to exactly one
/// kind's semantics (counter format/start number, redaction mode, magnifier
/// source rect, measurement endpoints, multi-point paths).
public enum AnnotationStyleKeys {
    // MARK: Shared presentation (style)

    /// "#RRGGBB" or "#RRGGBBAA".
    public static let colour = "colour"
    /// Stroke width, in points.
    public static let thickness = "thickness"
    /// "solid" | "dashed" | "dotted" — see `LineDashStyle`.
    public static let lineStyle = "lineStyle"
    /// "#RRGGBB"/"#RRGGBBAA"; absent or null = no fill.
    public static let fillColour = "fillColour"
    /// 0...1, independent of the fill colour's own alpha channel.
    public static let fillOpacity = "fillOpacity"
    public static let shadow = "shadow"
    /// "Hand-drawn rendering style" toggle (Appendix A `03_annotations.md`).
    public static let handDrawn = "handDrawn"
    /// Stable per-object seed for `HandDrawnPath`; `Cmd+R` assigns a new
    /// random `UInt64` here and re-renders — see `HandDrawnPath`'s doc.
    public static let handDrawnSeed = "handDrawnSeed"
    /// Explicit multi-point path override for arrow(elbow/bendable)/line/
    /// freehand/polygon, as an array of `{x, y}` objects in canvas
    /// coordinates. When absent, geometry falls back to the annotation's
    /// `frame` diagonal (start = top-left, end = bottom-right).
    public static let points = "points"

    // MARK: Arrow

    /// "triangle" | "line" | "none".
    public static let headStyle = "headStyle"
    public static let curved = "curved"
    public static let doubleEnded = "doubleEnded"
    public static let tapered = "tapered"
    /// Perpendicular bow amount in points for a curved arrow; sign controls
    /// which side it bows toward.
    public static let curveBow = "curveBow"

    // MARK: Shapes (rectangle/ellipse/polygon)

    public static let cornerRadius = "cornerRadius"
    /// True circle/perfect-square constraint (vs free-drawn bounding box).
    public static let constrainedGeometry = "constrainedGeometry"
    /// Vertex count for regular polygon/star kinds stored under `.polygon`.
    public static let pointCount = "pointCount"
    /// "polygon" | "star" | "hexagon" | "bracket" | "brace" | "calloutBubble".
    public static let polygonVariant = "polygonVariant"

    // MARK: Text

    public static let fontFamily = "fontFamily"
    public static let fontSize = "fontSize"
    /// "regular" | "medium" | "semibold" | "bold".
    public static let fontWeight = "fontWeight"
    /// "normal" | "italic".
    public static let fontStyle = "fontStyle"
    /// "left" | "center" | "right".
    public static let textAlign = "textAlign"
    public static let lineHeightMultiple = "lineHeightMultiple"
    public static let letterSpacing = "letterSpacing"
    public static let textBackgroundColour = "textBackgroundColour"
    public static let textPadding = "textPadding"
    public static let textCornerRadius = "textCornerRadius"
    /// The literal text body. Stored in `typeData`, not `style`, since it is
    /// content rather than presentation.
    public static let text = "text"
    /// `{x, y}` in canvas coordinates: the point the callout pointer
    /// triangle aims at. Absent = no pointer (plain bubble/label).
    public static let calloutPointerAnchor = "calloutPointerAnchor"
    /// Array of `{x, y}` for the "multiple pointers from one callout"
    /// requirement; when present, takes precedence over the single
    /// `calloutPointerAnchor`.
    public static let calloutPointerAnchors = "calloutPointerAnchors"

    // MARK: Highlighter

    public static let smartTextHeight = "smartTextHeight"
    /// "butt" | "round" | "square".
    public static let capStyle = "capStyle"

    // MARK: Spotlight

    /// 0...1, darkness of the dimmed surrounding area.
    public static let intensity = "intensity"
    /// Edge softness, in points, of the focus-region boundary.
    public static let feather = "feather"
    public static let blurSurrounding = "blurSurrounding"
    /// "rectangle" | "ellipse".
    public static let spotlightShape = "spotlightShape"

    // MARK: Counter (typeData)

    /// "numeric" | "alphaUpper" | "alphaLower" | "roman" | "custom" — see
    /// `CounterFormat`.
    public static let counterFormat = "format"
    public static let counterStartNumber = "startNumber"
    /// Groups counters that renumber together as one sequence, independent
    /// of any other counters in the document. Counters without a
    /// `sequenceId` share one implicit default sequence.
    public static let counterSequenceId = "sequenceId"
    /// `[String]`, used when `format == "custom"`.
    public static let counterCustomLabels = "customLabels"
    /// The resolved 0-based index within its sequence, written by
    /// `CounterFormatter.renumber` and read back by the renderer — this is
    /// *derived* state, not user input, but persisting it means a project
    /// file viewed by tooling that doesn't run the renumbering algorithm
    /// still shows correct labels.
    public static let counterResolvedIndex = "resolvedIndex"
    public static let counterPointerLength = "pointerLength"

    // MARK: Magnifier / Loupe

    /// `CaptureRect`, the source region being magnified, in the SAME canvas
    /// point coordinates as `Annotation.frame` (not source-image pixel
    /// coordinates) — `Tools/AnnotationRenderer.drawMagnifier` maps this
    /// rect into the source image's own pixel space using the source
    /// image's placement on the canvas.
    public static let magnifierSourceRect = "sourceRect"
    public static let magnifierZoomFactor = "zoomFactor"
    public static let magnifierBorderWidth = "borderWidth"
    public static let magnifierShowsConnector = "showsConnector"

    // MARK: Redact (typeData)

    /// `RedactionMode.rawValue`.
    public static let redactionMode = "mode"
    /// Pixel size of each mosaic block, for `.regularMosaic`/`.secureRandomizedPixelation`.
    public static let redactionBlockSize = "blockSize"
    /// Gaussian blur radius in points, for `.gaussianBlur`.
    public static let redactionBlurRadius = "blurRadius"
    /// Stable per-annotation seed for the secure-pixelation block shuffle —
    /// see `RedactionRenderer`.
    public static let redactionRandomSeed = "randomSeed"
    /// Solid fill colour for `.solid`; defaults to opaque black.
    public static let redactionSolidColour = "solidColour"
    /// `[CaptureRect]`, already-detected glyph bounding boxes for
    /// `.textOnly`, written by an upstream OCR pass this module does not
    /// itself run — see `RedactionRenderer.drawTextOnlyRedaction`.
    public static let redactionGlyphRects = "glyphRects"

    // MARK: Measurement (typeData)

    /// "px" | "pt".
    public static let measurementUnit = "unit"
    public static let measurementStart = "start"
    public static let measurementEnd = "end"
    /// "pointToPoint" | "objectToObject".
    public static let measurementMode = "mode"

    // MARK: Stamp

    /// "check" | "cross" | "warning" | "question" | "approve" | "reject" |
    /// "bug" | "accessibility" | "performance" | "croOpportunity" | "custom".
    public static let stampSymbol = "symbol"
    /// Inline SVG source, when `symbol == "custom"`.
    public static let stampCustomSVG = "customSVG"

    // MARK: Cursor

    /// "arrow" | "hand" | "ibeam" | "crosshair" | "resize" | "custom".
    public static let cursorPointerType = "pointerType"
    public static let cursorClickHalo = "clickHalo"
}

public enum LineDashStyle: String, Sendable {
    case solid, dashed, dotted

    public init(rawValue value: String) {
        switch value {
        case "dashed": self = .dashed
        case "dotted": self = .dotted
        default: self = .solid
        }
    }

    /// `CGContext.setLineDash` pattern for a given stroke `thickness`, or
    /// `nil` for a solid line (no dash call needed).
    public func dashPattern(forThickness thickness: CGFloat) -> [CGFloat]? {
        switch self {
        case .solid:
            return nil
        case .dashed:
            return [thickness * 3, thickness * 2]
        case .dotted:
            // Paired with a round line cap, a very short dash reads as a dot.
            return [0.001, thickness * 2.2]
        }
    }

    public var lineCap: CGLineCap {
        self == .dotted ? .round : .butt
    }
}

/// Typed, defaulted accessor over an annotation's `style`/`typeData`
/// `JSONValue?` pair. Every tool renderer builds one of these and reads
/// through it instead of touching `JSONValue` subscripts directly, so a
/// missing/malformed key always resolves to a documented default rather
/// than a crash.
public struct StyleReader {
    public let style: JSONValue?
    public let typeData: JSONValue?

    public init(style: JSONValue?, typeData: JSONValue?) {
        self.style = style
        self.typeData = typeData
    }

    public init(_ annotation: Annotation) {
        self.init(style: annotation.style, typeData: annotation.typeData)
    }

    // MARK: style

    public func string(_ key: String, default def: String? = nil) -> String? {
        style?[key]?.stringValue ?? def
    }

    public func double(_ key: String, default def: Double) -> Double {
        style?[key]?.doubleValue ?? def
    }

    public func cgFloat(_ key: String, default def: CGFloat) -> CGFloat {
        style?[key]?.doubleValue.map(CGFloat.init) ?? def
    }

    public func bool(_ key: String, default def: Bool) -> Bool {
        if case .bool(let v)? = style?[key] { return v }
        return def
    }

    public func uint64(_ key: String, default def: UInt64) -> UInt64 {
        guard let d = style?[key]?.doubleValue, d >= 0 else { return def }
        return UInt64(d)
    }

    public var lineDashStyle: LineDashStyle {
        LineDashStyle(rawValue: string(AnnotationStyleKeys.lineStyle) ?? "solid")
    }

    public var strokeColour: CGColor {
        CGColor.capture_parse(hex: string(AnnotationStyleKeys.colour)) ?? CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    }

    public var fillColour: CGColor? {
        guard let hex = string(AnnotationStyleKeys.fillColour) else { return nil }
        return CGColor.capture_parse(hex: hex)?.copy(alpha: cgFloat(AnnotationStyleKeys.fillOpacity, default: 1))
    }

    public var thickness: CGFloat {
        cgFloat(AnnotationStyleKeys.thickness, default: 4)
    }

    public var hasShadow: Bool {
        bool(AnnotationStyleKeys.shadow, default: false)
    }

    public var isHandDrawn: Bool {
        bool(AnnotationStyleKeys.handDrawn, default: false)
    }

    public var handDrawnSeed: UInt64 {
        uint64(AnnotationStyleKeys.handDrawnSeed, default: 1)
    }

    /// Explicit multi-point path, if the object stores one, in canvas
    /// coordinates.
    public var explicitPoints: [CGPoint]? {
        guard case .array(let arr)? = style?[AnnotationStyleKeys.points] else { return nil }
        let points: [CGPoint] = arr.compactMap { value in
            guard case .object(let obj) = value, let x = obj["x"]?.doubleValue, let y = obj["y"]?.doubleValue else { return nil }
            return CGPoint(x: x, y: y)
        }
        return points.isEmpty ? nil : points
    }

    // MARK: typeData

    public func typeDataString(_ key: String, default def: String? = nil) -> String? {
        typeData?[key]?.stringValue ?? def
    }

    public func typeDataDouble(_ key: String, default def: Double) -> Double {
        typeData?[key]?.doubleValue ?? def
    }

    public func typeDataCGFloat(_ key: String, default def: CGFloat) -> CGFloat {
        typeData?[key]?.doubleValue.map(CGFloat.init) ?? def
    }

    public func typeDataInt(_ key: String, default def: Int) -> Int {
        typeData?[key]?.doubleValue.map { Int($0) } ?? def
    }

    public func typeDataBool(_ key: String, default def: Bool) -> Bool {
        if case .bool(let v)? = typeData?[key] { return v }
        return def
    }

    public func typeDataStringArray(_ key: String) -> [String]? {
        guard case .array(let arr)? = typeData?[key] else { return nil }
        return arr.compactMap(\.stringValue)
    }

    public func typeDataPoint(_ key: String) -> CGPoint? {
        guard case .object(let obj)? = typeData?[key], let x = obj["x"]?.doubleValue, let y = obj["y"]?.doubleValue else { return nil }
        return CGPoint(x: x, y: y)
    }

    public func typeDataUInt64(_ key: String, default def: UInt64) -> UInt64 {
        guard let d = typeData?[key]?.doubleValue, d >= 0 else { return def }
        return UInt64(d)
    }

    public func typeDataRect(_ key: String) -> CaptureRect? {
        guard case .object(let obj)? = typeData?[key],
              let x = obj["x"]?.doubleValue, let y = obj["y"]?.doubleValue,
              let w = obj["width"]?.doubleValue, let h = obj["height"]?.doubleValue else { return nil }
        return CaptureRect(x: x, y: y, width: w, height: h)
    }
}

extension CGColor {
    /// Parses "#RGB", "#RRGGBB", or "#RRGGBBAA" (case-insensitive, leading
    /// `#` optional) into a device-RGB `CGColor`. Returns `nil` for
    /// anything else rather than guessing — callers supply a documented
    /// fallback colour instead.
    public static func capture_parse(hex: String?) -> CGColor? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.allSatisfy(\.isHexDigit) else { return nil }

        func component(_ hexPair: Substring) -> CGFloat? {
            guard let v = UInt8(hexPair, radix: 16) else { return nil }
            return CGFloat(v) / 255
        }

        switch value.count {
        case 3: // RGB shorthand, each digit doubled.
            let chars = Array(value)
            let expanded = chars.flatMap { [$0, $0] }
            return capture_parse(hex: String(expanded))
        case 6:
            let chars = Array(value)
            guard let r = component(Substring(String(chars[0...1]))),
                  let g = component(Substring(String(chars[2...3]))),
                  let b = component(Substring(String(chars[4...5]))) else { return nil }
            return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
        case 8:
            let chars = Array(value)
            guard let r = component(Substring(String(chars[0...1]))),
                  let g = component(Substring(String(chars[2...3]))),
                  let b = component(Substring(String(chars[4...5]))),
                  let a = component(Substring(String(chars[6...7]))) else { return nil }
            return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }
}
