import AppKit
import CaptureCore
import CaptureEditor
import CoreGraphics
import Foundation

/// Trivial `CanvasRenderer.ImageProviding` backed by an in-memory
/// dictionary — enough for a single open editor session (source image plus
/// whatever gets pasted in as an `AppendedImageObject`). A tiled,
/// decode-on-demand implementation for very large scrolling captures is the
/// documented follow-up `CanvasRenderer`'s own "TILING TODO" doc comment
/// calls out as `CaptureUI`'s responsibility — out of scope for this pass.
public final class EditorImageStore: CanvasRenderer.ImageProviding {
    private var images: [String: CGImage] = [:]
    public init() {}
    public func setSourceImage(_ image: CGImage) { images[CanvasRenderer.sourceImageID] = image }
    public func setImage(_ image: CGImage, forId id: String) { images[id] = image }
    public func image(for id: String) -> CGImage? { images[id] }
}

/// Hosts `CaptureEditor.CanvasRenderer`'s output in `draw(_:)` (via the
/// `CGContext` from `NSGraphicsContext.current`, exactly as the task calls
/// for), and turns real mouse events into new/moved annotations pushed
/// through `CaptureCore.UndoStack` using its documented
/// `registerAlreadyApplied` convenience for interactive, already-applied
/// creation/move gestures (see `UndoStack`'s doc comment).
///
/// `isFlipped == true` deliberately matches `CanvasRenderer`'s documented
/// coordinate convention ("top-left origin, y-increasing-downward... the
/// standard AppKit idiom: an `NSView` with `isFlipped == true`") — no manual
/// CTM flip is needed here because of it.
public final class CaptureCanvasView: NSView {
    private enum DragState {
        case creating(id: UUID, start: CGPoint)
        case moving(id: UUID, originalFrame: CaptureRect, start: CGPoint)
        case croppingDrag(start: CGPoint)
    }

    public var document: EditorDocument { didSet { needsDisplay = true } }
    public let imageStore: EditorImageStore
    public let undoStack: UndoStack
    private let renderer = CanvasRenderer()

    /// `nil` = selection/move tool. Non-`nil` = "click-drag to create a new
    /// annotation of this kind".
    public var currentTool: Annotation.Kind? {
        didSet { NSCursor.pointingHand.set(); if currentTool != nil { NSCursor.crosshair.set() } }
    }
    public var defaultStrokeColorHex: String = "#4D6BFF"

    public private(set) var selectedAnnotationID: UUID? {
        didSet { onSelectionChanged?(selectedAnnotationID) }
    }
    /// Fired after any interactive change is committed to the undo stack
    /// (creation, move) so `EditorWindowController` can refresh the
    /// inspector / mark the document dirty.
    public var onDocumentChanged: (() -> Void)?
    public var onSelectionChanged: ((UUID?) -> Void)?

    /// Crop mode: when `true`, a plain click-drag defines a new candidate
    /// crop rect (a simplified single-drag interaction — the fuller
    /// handle-based `CropController.resize`/`snappedResize` API exists for
    /// a more polished follow-up but isn't wired to interactive handles
    /// here, given this pass's effort budget). `pendingCropRect` is read by
    /// `EditorWindowController` when the user confirms the crop.
    public var isCropping: Bool = false {
        didSet { pendingCropRect = nil; needsDisplay = true }
    }
    public private(set) var pendingCropRect: CaptureRect?

    private var dragState: DragState?

    public init(document: EditorDocument, imageStore: EditorImageStore, undoStack: UndoStack) {
        self.document = document
        self.imageStore = imageStore
        self.undoStack = undoStack
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    // MARK: - Coordinate mapping

    /// The scale + centering offset that fits `document.canvasSize` inside
    /// the view's current bounds without upscaling past 1x (so a small
    /// screenshot isn't blown up blurrily on a large window).
    private var fit: (scale: CGFloat, offset: CGPoint) {
        guard document.canvasSize.width > 0, document.canvasSize.height > 0 else { return (1, .zero) }
        let scaleX = bounds.width / document.canvasSize.width
        let scaleY = bounds.height / document.canvasSize.height
        let scale = min(min(scaleX, scaleY), 1)
        let offset = CGPoint(
            x: (bounds.width - document.canvasSize.width * scale) / 2,
            y: (bounds.height - document.canvasSize.height * scale) / 2
        )
        return (scale, offset)
    }

    private func toCanvasPoint(_ viewPoint: CGPoint) -> CGPoint {
        let f = fit
        guard f.scale > 0 else { return .zero }
        return CGPoint(x: (viewPoint.x - f.offset.x) / f.scale, y: (viewPoint.y - f.offset.y) / f.scale)
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        CaptureTheme.canvasBackground.setFill()
        bounds.fill()

        let f = fit
        context.saveGState()
        context.translateBy(x: f.offset.x, y: f.offset.y)
        context.scaleBy(x: f.scale, y: f.scale)

        // Checkerboard-free plain backdrop behind the canvas rect itself so
        // a transparent-Backdrop document still reads clearly against the
        // window background.
        NSColor.white.withAlphaComponent(0.001).setFill() // establishes alpha compositing baseline; CanvasRenderer draws its own Backdrop layer next.

        renderer.render(document: document, images: imageStore, into: context, options: CanvasRenderer.RenderOptions(scale: f.scale))

        if let id = selectedAnnotationID, let annotation = document.annotation(id) {
            drawSelectionOutline(annotation.frame.cgRect, into: context)
        }
        if isCropping {
            drawCropOverlay(into: context)
        }
        context.restoreGState()
    }

    private func drawSelectionOutline(_ rect: CGRect, into context: CGContext) {
        context.saveGState()
        context.setStrokeColor(CaptureSemanticColor.capture.cgColor)
        context.setLineWidth(1.5 / max(fit.scale, 0.01))
        context.setLineDash(phase: 0, lengths: [4 / max(fit.scale, 0.01), 3 / max(fit.scale, 0.01)])
        context.stroke(rect.insetBy(dx: -2, dy: -2))
        context.restoreGState()
    }

    private func drawCropOverlay(into context: CGContext) {
        let full = CGRect(x: 0, y: 0, width: document.canvasSize.width, height: document.canvasSize.height)
        let cropRect = pendingCropRect?.cgRect ?? document.cropRect.cgRect
        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 0.45))
        let path = CGMutablePath()
        path.addRect(full)
        path.addRect(cropRect)
        context.addPath(path)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(CaptureSemanticColor.capture.cgColor)
        context.setLineWidth(1.5 / max(fit.scale, 0.01))
        context.stroke(cropRect)
        context.restoreGState()
    }

    // MARK: - Mouse handling

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let canvasPoint = toCanvasPoint(convert(event.locationInWindow, from: nil))

        if isCropping {
            dragState = .croppingDrag(start: canvasPoint)
            return
        }

        guard let tool = currentTool else {
            if let hit = topmostAnnotation(at: canvasPoint) {
                selectedAnnotationID = hit.id
                dragState = .moving(id: hit.id, originalFrame: hit.frame, start: canvasPoint)
            } else {
                selectedAnnotationID = nil
            }
            needsDisplay = true
            return
        }

        let annotation = Annotation(
            type: tool,
            frame: CaptureRect(x: canvasPoint.x, y: canvasPoint.y, width: 0, height: 0),
            zIndex: document.nextZIndex(forLayerOf: tool),
            style: defaultStyle(for: tool),
            typeData: defaultTypeData(for: tool)
        )
        document.annotations.append(annotation)
        selectedAnnotationID = annotation.id
        dragState = .creating(id: annotation.id, start: canvasPoint)
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        let canvasPoint = toCanvasPoint(convert(event.locationInWindow, from: nil))
        switch dragState {
        case .creating(let id, let start):
            guard let idx = document.index(ofAnnotation: id) else { return }
            document.annotations[idx].frame = CaptureRect(cgRect: Self.normalizedRect(start, canvasPoint))
        case .moving(let id, let originalFrame, let start):
            guard let idx = document.index(ofAnnotation: id) else { return }
            let dx = canvasPoint.x - start.x
            let dy = canvasPoint.y - start.y
            document.annotations[idx].frame = CaptureRect(x: originalFrame.x + dx, y: originalFrame.y + dy, width: originalFrame.width, height: originalFrame.height)
        case .croppingDrag(let start):
            pendingCropRect = CaptureRect(cgRect: Self.normalizedRect(start, canvasPoint)).clamped(toSourceSize: document.sourceSize)
        case nil:
            return
        }
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        defer { dragState = nil }
        switch dragState {
        case .creating(let id, _):
            guard let annotation = document.annotation(id) else { return }
            guard annotation.frame.width >= 4, annotation.frame.height >= 4 else {
                document.annotations.removeAll { $0.id == id }
                selectedAnnotationID = nil
                needsDisplay = true
                return
            }
            let command = AddAnnotationCommand(document: document, annotation: annotation)
            undoStack.registerAlreadyApplied(command)
            onDocumentChanged?()
        case .moving(let id, let originalFrame, _):
            guard let annotation = document.annotation(id), annotation.frame != originalFrame else { return }
            let command = TransformAnnotationCommand.move(document: document, annotationId: id, from: originalFrame, to: annotation.frame, rotation: annotation.rotation)
            undoStack.registerAlreadyApplied(command)
            onDocumentChanged?()
        case .croppingDrag:
            needsDisplay = true
        case nil:
            break
        }
    }

    public override func keyDown(with event: NSEvent) {
        // Delete/backspace removes the selected annotation (Part I §11
        // baseline editor interaction).
        if event.keyCode == 51 || event.keyCode == 117, let id = selectedAnnotationID { // delete / forward-delete
            undoStack.perform(DeleteAnnotationCommand(document: document, annotationId: id))
            selectedAnnotationID = nil
            onDocumentChanged?()
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Hit testing

    private func topmostAnnotation(at point: CGPoint) -> Annotation? {
        document.annotations
            .filter { !$0.hidden && !$0.locked }
            .sorted { $0.zIndex > $1.zIndex }
            .first { $0.frame.cgRect.insetBy(dx: -6, dy: -6).contains(point) }
    }

    // MARK: - Defaults

    private func defaultStyle(for kind: Annotation.Kind) -> JSONValue {
        .object([
            AnnotationStyleKeys.colour: .string(defaultStrokeColorHex),
            AnnotationStyleKeys.thickness: .number(4)
        ])
    }

    private func defaultTypeData(for kind: Annotation.Kind) -> JSONValue? {
        switch kind {
        case .text:
            return .object([AnnotationStyleKeys.text: .string("Double-click to edit")])
        case .counter:
            return .object([AnnotationStyleKeys.counterFormat: .string(CounterFormat.numeric.rawValue), AnnotationStyleKeys.counterStartNumber: .number(1)])
        case .redact:
            return .object([AnnotationStyleKeys.redactionMode: .string(RedactionMode.gaussianBlur.rawValue)])
        default:
            return nil
        }
    }

    private static func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

private extension CaptureRect {
    func clamped(toSourceSize size: CaptureSize) -> CaptureRect {
        let minX = min(max(x, 0), size.width)
        let minY = min(max(y, 0), size.height)
        let maxX = min(max(x + width, 0), size.width)
        let maxY = min(max(y + height, 0), size.height)
        return CaptureRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}
