import Foundation

/// Mirrors `schemas/project/annotation.schema.json`. Every annotation is an
/// independent, non-destructively-editable object (Part I §11). Type-specific
/// data (Counter format, redaction mode, measurement endpoints, arrow head
/// style, ...) lives in `style`/`typeData` as loosely-typed JSON rather than
/// one giant struct with 200 optional fields — see `AnnotationStyle` and
/// `AnnotationTypeData` for the decode helpers.
public struct Annotation: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case arrow, line, rectangle, ellipse, polygon, text, freehand
        case highlighter, spotlight, counter, magnifier, redact
        case measurement, stamp, cursor
    }

    public var id: UUID
    public var type: Kind
    public var frame: CaptureRect
    public var rotation: Double
    public var opacity: Double
    public var zIndex: Int
    public var locked: Bool
    public var hidden: Bool
    public var groupId: UUID?
    public var style: JSONValue?
    public var typeData: JSONValue?
    public var anchor: Anchor

    public init(
        id: UUID = UUID(),
        type: Kind,
        frame: CaptureRect,
        rotation: Double = 0,
        opacity: Double = 1,
        zIndex: Int,
        locked: Bool = false,
        hidden: Bool = false,
        groupId: UUID? = nil,
        style: JSONValue? = nil,
        typeData: JSONValue? = nil,
        anchor: Anchor = Anchor(kind: .canvas)
    ) {
        self.id = id
        self.type = type
        self.frame = frame
        self.rotation = rotation
        self.opacity = opacity
        self.zIndex = zIndex
        self.locked = locked
        self.hidden = hidden
        self.groupId = groupId
        self.style = style
        self.typeData = typeData
        self.anchor = anchor
    }

    /// `canvas` = fixed to canvas coordinates; `pixel` = fixed to source
    /// image pixel coordinates; `domElement` = tracks a live DOM element via
    /// `ElementEvidence` and falls back to `fallbackPixelPosition` if the
    /// anchor can no longer be resolved (Part I §11, §14 anchor carry-forward).
    public struct Anchor: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable { case canvas, pixel, domElement }

        public var kind: Kind
        public var elementEvidenceId: UUID?
        public var relativeAnchor: CapturePoint?
        public var fallbackPixelPosition: CapturePoint?

        public init(kind: Kind, elementEvidenceId: UUID? = nil, relativeAnchor: CapturePoint? = nil, fallbackPixelPosition: CapturePoint? = nil) {
            self.kind = kind
            self.elementEvidenceId = elementEvidenceId
            self.relativeAnchor = relativeAnchor
            self.fallbackPixelPosition = fallbackPixelPosition
        }
    }
}
