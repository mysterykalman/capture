import CaptureCore
import CoreGraphics
import Foundation

/// In-memory, mutable editor state that `Undo/EditorCommands.swift`'s
/// `CaptureCore.UndoCommand` implementations operate on.
///
/// This is deliberately a plain reference type distinct from
/// `CaptureCore.CaptureProjectDocument` (the on-disk `.capture` package
/// model, which is a value type meant for atomic encode/decode). Keeping
/// them separate means undo/redo can mutate `EditorDocument` cheaply, many
/// times a second during a drag, without round-tripping through JSON or
/// forcing every intermediate drag frame onto disk. `CaptureUI` is expected
/// to own exactly one `EditorDocument` per open editor window and to
/// translate to/from `CaptureProjectDocument` at load/save boundaries via
/// `snapshot()`/`init(loading:)`.
public final class EditorDocument {
    public var annotations: [Annotation]
    public var appendedImageObjects: [AppendedImageObject]
    public var cropRect: CaptureRect
    public var canvasSize: CaptureSize
    public var sourceSize: CaptureSize
    public var backdrop: BackdropSettings

    public init(
        annotations: [Annotation] = [],
        appendedImageObjects: [AppendedImageObject] = [],
        cropRect: CaptureRect,
        canvasSize: CaptureSize,
        sourceSize: CaptureSize,
        backdrop: BackdropSettings = BackdropSettings()
    ) {
        self.annotations = annotations
        self.appendedImageObjects = appendedImageObjects
        self.cropRect = cropRect
        self.canvasSize = canvasSize
        self.sourceSize = sourceSize
        self.backdrop = backdrop
    }

    /// Convenience initializer that starts a fresh editor session from a
    /// freshly captured/loaded source image, uncropped (crop == full
    /// source), with canvas matching source size (Backdrop collapsed).
    public convenience init(sourceSize: CaptureSize) {
        self.init(
            cropRect: CaptureRect(x: 0, y: 0, width: sourceSize.width, height: sourceSize.height),
            canvasSize: sourceSize,
            sourceSize: sourceSize
        )
    }

    public func index(ofAnnotation id: UUID) -> Int? {
        annotations.firstIndex { $0.id == id }
    }

    public func annotation(_ id: UUID) -> Annotation? {
        guard let idx = index(ofAnnotation: id) else { return nil }
        return annotations[idx]
    }

    public func index(ofAppendedImage id: UUID) -> Int? {
        appendedImageObjects.firstIndex { $0.id == id }
    }

    /// Next available zIndex within a given annotation's own render group
    /// (see `Rendering/CanvasRenderer.swift` for why zIndex is scoped to a
    /// fixed architectural layer, not global across the whole document).
    public func nextZIndex(forLayerOf kind: Annotation.Kind) -> Int {
        let group = RenderLayerGroup.group(for: kind)
        let existing = annotations.filter { RenderLayerGroup.group(for: $0.type) == group }
        return (existing.map(\.zIndex).max() ?? -1) + 1
    }

    public var nextAppendedImageZIndex: Int {
        (appendedImageObjects.map(\.zIndex).max() ?? -1) + 1
    }
}

/// Which fixed layer in the Part I §12 rendering stack an `Annotation.Kind`
/// belongs to. `.redact` and `.measurement` are their own architectural
/// layers; everything else is "Vector annotations". Used both by the
/// renderer (to decide draw-group order) and by z-index bookkeeping (a new
/// annotation's zIndex only needs to beat siblings in its own group, since
/// group order itself is fixed and not user-reorderable).
public enum RenderLayerGroup: Int, CaseIterable, Sendable {
    case redactions
    case measurements
    case vectorAnnotations

    public static func group(for kind: Annotation.Kind) -> RenderLayerGroup {
        switch kind {
        case .redact: return .redactions
        case .measurement: return .measurements
        default: return .vectorAnnotations
        }
    }
}

/// Part I §12 "Appended image objects" layer — an image (another
/// screenshot, image file, clipboard image, PDF page) pasted onto the
/// canvas as its own transformable object, distinct from the single Source
/// media layer and from the vector annotation layer.
///
/// `CaptureCore.Annotation.Kind` has no case for this (it models
/// vector/redaction/measurement annotation objects only, not appended
/// raster objects), so this type lives here in `CaptureEditor` rather than
/// `CaptureCore`. If a future revision needs to share it with
/// `CaptureHistory`/project-format code, promote it to `CaptureCore` then.
public struct AppendedImageObject: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Key resolved through `CanvasRenderer.ImageProviding`.
    public var imageId: String
    public var frame: CaptureRect
    public var rotation: Double
    public var opacity: Double
    public var zIndex: Int
    /// Non-destructive crop relative to the object's own pixel space (Part
    /// III appendix: "Crop ... operate ONLY on the base raster — NOT on
    /// appended captures ... until Rasterize Image" describes Shottr's
    /// *limitation*; Capture's own spec explicitly asks for crop/blur/erase
    /// support on appended objects, so this field exists to support that).
    public var cropRect: CaptureRect?
    public var cornerRadius: CGFloat
    public var shadowOpacity: Double
    public var locked: Bool
    public var hidden: Bool

    public init(
        id: UUID = UUID(),
        imageId: String,
        frame: CaptureRect,
        rotation: Double = 0,
        opacity: Double = 1,
        zIndex: Int,
        cropRect: CaptureRect? = nil,
        cornerRadius: CGFloat = 0,
        shadowOpacity: Double = 0,
        locked: Bool = false,
        hidden: Bool = false
    ) {
        self.id = id
        self.imageId = imageId
        self.frame = frame
        self.rotation = rotation
        self.opacity = opacity
        self.zIndex = zIndex
        self.cropRect = cropRect
        self.cornerRadius = cornerRadius
        self.shadowOpacity = shadowOpacity
        self.locked = locked
        self.hidden = hidden
    }
}

/// Resolved, renderer-facing Backdrop model (Part III `03_editor_annotations.md`
/// "Backdrop" section). Only the fields `CanvasRenderer` needs to draw the
/// Backdrop layer live here; presets, "auto-apply preset", and per-side
/// padding *authoring* UI are `CaptureUI` concerns that resolve down to this
/// shape before rendering.
public struct BackdropSettings: Hashable, Sendable {
    public enum Fill: Hashable, Sendable {
        case transparent
        case solid(colorHex: String)
        case gradient(colorHexes: [String], angleDegrees: Double)
        case blurredDesktopImage(imageId: String, radius: CGFloat)
        case image(imageId: String)
    }

    public var fill: Fill
    /// Independent padding per side between the Backdrop's edge and the
    /// Source media's placed rect.
    public var insets: EdgeInsets
    public var cornerRadius: CGFloat
    public var shadowRadius: CGFloat
    public var shadowOpacity: Double
    public var shadowOffset: CGSize

    public init(
        fill: Fill = .transparent,
        insets: EdgeInsets = .zero,
        cornerRadius: CGFloat = 0,
        shadowRadius: CGFloat = 0,
        shadowOpacity: Double = 0,
        shadowOffset: CGSize = .zero
    ) {
        self.fill = fill
        self.insets = insets
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.shadowOffset = shadowOffset
    }
}
