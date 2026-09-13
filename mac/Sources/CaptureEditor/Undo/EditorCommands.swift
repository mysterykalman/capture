import CaptureCore
import Foundation

/// Concrete `CaptureCore.UndoCommand` implementations operating on
/// `Document/EditorDocument.swift`'s `EditorDocument`, per Part I §11's
/// "Use command-based undo/redo rather than storing full bitmap
/// snapshots." Every command here stores only the small piece of state it
/// needs to compute a true inverse (an id, a before/after frame, a
/// before/after style) — never a full-document or bitmap snapshot — and
/// `apply()`/`undo()` are written as exact opposites of each other so
/// `CaptureCore.UndoStack.undo()` followed by `.redo()` always leaves the
/// document byte-for-byte where it started (see
/// `Tests/CaptureEditorTests/EditorCommandsTests.swift`).
///
/// Every command is a `final class` conforming to `UndoCommand` (which
/// requires `Sendable`) as `@unchecked Sendable`: each one holds a
/// reference to the shared `EditorDocument` — itself intentionally not
/// `Sendable`, since (per `CaptureCore.UndoStack`'s own doc comment)
/// "not thread-safe by design — callers must invoke from the editor's
/// owning actor/main thread" — plus, for a few commands, a `var` or two
/// that's filled in once at first `apply()` (e.g. what `Delete` removed).
/// `@unchecked Sendable` is the correct escape hatch for exactly this
/// pattern (single-threaded-by-construction, verified by convention rather
/// than by the type system) rather than fighting Swift's sendability
/// checker on a type that is, by explicit design, main-thread-only.
///
/// Wherever a command's "before" state is already known at construction
/// time (`TransformAnnotationCommand`, `RestyleAnnotationCommand`,
/// `CropChangeCommand`, `ReorderZIndexCommand`), it's captured as `let` and
/// the class holds no other mutable state at all.

// MARK: - Add / Delete

/// Adds `annotation` on `apply()`, removes it by id on `undo()`. If the
/// annotation is a Counter, both directions re-run
/// `CounterFormatter.renumber` afterward so sibling counters' resolved
/// indices stay correct immediately, matching "auto-renumber after
/// insert/delete."
public final class AddAnnotationCommand: UndoCommand, @unchecked Sendable {
    public let name = "Add"
    private let document: EditorDocument
    private let annotation: Annotation

    public init(document: EditorDocument, annotation: Annotation) {
        self.document = document
        self.annotation = annotation
    }

    public func apply() {
        document.annotations.append(annotation)
        renumberIfNeeded()
    }

    public func undo() {
        document.annotations.removeAll { $0.id == annotation.id }
        renumberIfNeeded()
    }

    private func renumberIfNeeded() {
        guard annotation.type == .counter else { return }
        document.annotations = CounterFormatter.renumber(document.annotations)
    }
}

/// Removes the annotation with `annotationId` on `apply()`, reinserts the
/// exact removed value at its original array index on `undo()`.
public final class DeleteAnnotationCommand: UndoCommand, @unchecked Sendable {
    public let name = "Delete"
    private let document: EditorDocument
    private let annotationId: UUID
    private var removed: Annotation?
    private var removedAtIndex: Int?

    public init(document: EditorDocument, annotationId: UUID) {
        self.document = document
        self.annotationId = annotationId
    }

    public func apply() {
        guard let idx = document.index(ofAnnotation: annotationId) else { return }
        removed = document.annotations[idx]
        removedAtIndex = idx
        document.annotations.remove(at: idx)
        renumberIfNeeded()
    }

    public func undo() {
        guard let removed else { return }
        let insertAt = min(removedAtIndex ?? document.annotations.count, document.annotations.count)
        document.annotations.insert(removed, at: insertAt)
        renumberIfNeeded()
    }

    private func renumberIfNeeded() {
        guard removed?.type == .counter else { return }
        document.annotations = CounterFormatter.renumber(document.annotations)
    }
}

// MARK: - Move / Resize / Rotate

/// Covers move, resize, and rotate uniformly — all three ultimately change
/// only `Annotation.frame`/`.rotation`, and a drag gesture (e.g. a corner
/// handle that both moves and resizes at once) can legitimately change
/// both together. `name` is caller-supplied so the undo menu can still say
/// "Undo Move"/"Undo Resize"/"Undo Rotate" distinctly.
public final class TransformAnnotationCommand: UndoCommand, @unchecked Sendable {
    public let name: String
    private let document: EditorDocument
    private let annotationId: UUID
    private let beforeFrame: CaptureRect
    private let beforeRotation: Double
    private let afterFrame: CaptureRect
    private let afterRotation: Double

    public init(
        name: String = "Transform",
        document: EditorDocument,
        annotationId: UUID,
        beforeFrame: CaptureRect,
        beforeRotation: Double,
        afterFrame: CaptureRect,
        afterRotation: Double
    ) {
        self.name = name
        self.document = document
        self.annotationId = annotationId
        self.beforeFrame = beforeFrame
        self.beforeRotation = beforeRotation
        self.afterFrame = afterFrame
        self.afterRotation = afterRotation
    }

    /// Convenience for a pure move (frame origin changes, size/rotation don't).
    public static func move(document: EditorDocument, annotationId: UUID, from: CaptureRect, to: CaptureRect, rotation: Double) -> TransformAnnotationCommand {
        TransformAnnotationCommand(name: "Move", document: document, annotationId: annotationId, beforeFrame: from, beforeRotation: rotation, afterFrame: to, afterRotation: rotation)
    }

    /// Convenience for a pure resize (rotation unchanged).
    public static func resize(document: EditorDocument, annotationId: UUID, from: CaptureRect, to: CaptureRect, rotation: Double) -> TransformAnnotationCommand {
        TransformAnnotationCommand(name: "Resize", document: document, annotationId: annotationId, beforeFrame: from, beforeRotation: rotation, afterFrame: to, afterRotation: rotation)
    }

    /// Convenience for a pure rotate (frame unchanged).
    public static func rotate(document: EditorDocument, annotationId: UUID, frame: CaptureRect, from: Double, to: Double) -> TransformAnnotationCommand {
        TransformAnnotationCommand(name: "Rotate", document: document, annotationId: annotationId, beforeFrame: frame, beforeRotation: from, afterFrame: frame, afterRotation: to)
    }

    public func apply() { setFrame(afterFrame, rotation: afterRotation) }
    public func undo() { setFrame(beforeFrame, rotation: beforeRotation) }

    private func setFrame(_ frame: CaptureRect, rotation: Double) {
        guard let idx = document.index(ofAnnotation: annotationId) else { return }
        document.annotations[idx].frame = frame
        document.annotations[idx].rotation = rotation
    }
}

// MARK: - Restyle

/// Swaps `Annotation.style`/`.typeData` between a before/after pair —
/// covers colour/thickness/line-style changes, counter format changes,
/// redaction mode changes, and everything else that lives in those two
/// `JSONValue?` fields (see `Tools/AnnotationStyleDecoding.swift`).
public final class RestyleAnnotationCommand: UndoCommand, @unchecked Sendable {
    public let name = "Restyle"
    private let document: EditorDocument
    private let annotationId: UUID
    private let beforeStyle: JSONValue?
    private let beforeTypeData: JSONValue?
    private let afterStyle: JSONValue?
    private let afterTypeData: JSONValue?

    public init(
        document: EditorDocument,
        annotationId: UUID,
        beforeStyle: JSONValue?,
        beforeTypeData: JSONValue?,
        afterStyle: JSONValue?,
        afterTypeData: JSONValue?
    ) {
        self.document = document
        self.annotationId = annotationId
        self.beforeStyle = beforeStyle
        self.beforeTypeData = beforeTypeData
        self.afterStyle = afterStyle
        self.afterTypeData = afterTypeData
    }

    public func apply() { setStyle(afterStyle, afterTypeData) }
    public func undo() { setStyle(beforeStyle, beforeTypeData) }

    private func setStyle(_ style: JSONValue?, _ typeData: JSONValue?) {
        guard let idx = document.index(ofAnnotation: annotationId) else { return }
        document.annotations[idx].style = style
        document.annotations[idx].typeData = typeData
    }
}

// MARK: - Reorder z-index

/// Pure logic for computing a z-index reorder plan — no document mutation,
/// directly unit-testable. Reordering only ever happens within one
/// annotation's own fixed architectural render-layer group (see
/// `RenderLayerGroup` in `Document/EditorDocument.swift`); siblings outside that group are
/// never touched or included in the returned mapping.
public enum ZIndexReorder {
    public enum Operation: Sendable { case bringToFront, sendToBack, moveUp, moveDown }

    /// Returns `(before, after)` zIndex mappings for every sibling in
    /// `targetId`'s render-layer group, reflecting `operation` applied to
    /// `targetId`'s position among them. Returns `nil` if `targetId`
    /// doesn't exist, or if the operation is a no-op (e.g. `moveUp` on the
    /// item already on top).
    public static func plan(_ annotations: [Annotation], targetId: UUID, operation: Operation) -> (before: [UUID: Int], after: [UUID: Int])? {
        guard let target = annotations.first(where: { $0.id == targetId }) else { return nil }
        let group = RenderLayerGroup.group(for: target.type)
        let siblings = annotations.filter { RenderLayerGroup.group(for: $0.type) == group }.sorted { $0.zIndex < $1.zIndex }
        guard let currentPosition = siblings.firstIndex(where: { $0.id == targetId }) else { return nil }

        var order = siblings.map(\.id)
        switch operation {
        case .bringToFront:
            guard currentPosition != order.count - 1 else { return nil }
            order.remove(at: currentPosition)
            order.append(targetId)
        case .sendToBack:
            guard currentPosition != 0 else { return nil }
            order.remove(at: currentPosition)
            order.insert(targetId, at: 0)
        case .moveUp:
            guard currentPosition < order.count - 1 else { return nil }
            order.swapAt(currentPosition, currentPosition + 1)
        case .moveDown:
            guard currentPosition > 0 else { return nil }
            order.swapAt(currentPosition, currentPosition - 1)
        }

        let before = Dictionary(uniqueKeysWithValues: siblings.map { ($0.id, $0.zIndex) })
        // Reassign contiguous zIndex values starting at the group's own
        // lowest existing value, so annotations in OTHER groups (never
        // part of `siblings`) are untouched by this renumbering.
        let base = siblings.map(\.zIndex).min() ?? 0
        var after: [UUID: Int] = [:]
        for (position, id) in order.enumerated() {
            after[id] = base + position
        }
        return (before, after)
    }
}

public final class ReorderZIndexCommand: UndoCommand, @unchecked Sendable {
    public let name = "Reorder"
    private let document: EditorDocument
    private let beforeZIndices: [UUID: Int]
    private let afterZIndices: [UUID: Int]

    public init(document: EditorDocument, beforeZIndices: [UUID: Int], afterZIndices: [UUID: Int]) {
        self.document = document
        self.beforeZIndices = beforeZIndices
        self.afterZIndices = afterZIndices
    }

    /// Convenience: builds the command directly from `ZIndexReorder.plan`;
    /// returns `nil` when the plan itself is a no-op/invalid, so callers
    /// can skip pushing a useless command onto the undo stack.
    public static func make(document: EditorDocument, targetId: UUID, operation: ZIndexReorder.Operation) -> ReorderZIndexCommand? {
        guard let plan = ZIndexReorder.plan(document.annotations, targetId: targetId, operation: operation) else { return nil }
        return ReorderZIndexCommand(document: document, beforeZIndices: plan.before, afterZIndices: plan.after)
    }

    public func apply() { applyZIndices(afterZIndices) }
    public func undo() { applyZIndices(beforeZIndices) }

    private func applyZIndices(_ mapping: [UUID: Int]) {
        for (id, z) in mapping {
            guard let idx = document.index(ofAnnotation: id) else { continue }
            document.annotations[idx].zIndex = z
        }
    }
}

// MARK: - Crop

public final class CropChangeCommand: UndoCommand, @unchecked Sendable {
    public let name = "Crop"
    private let document: EditorDocument
    private let beforeCropRect: CaptureRect
    private let afterCropRect: CaptureRect

    public init(document: EditorDocument, before: CaptureRect, after: CaptureRect) {
        self.document = document
        self.beforeCropRect = before
        self.afterCropRect = after
    }

    public func apply() { document.cropRect = afterCropRect }
    public func undo() { document.cropRect = beforeCropRect }
}

// MARK: - Group / Ungroup

/// Wraps an optional `UUID` so it can live as a `Dictionary` VALUE without
/// hitting the classic Swift footgun where `dict[key] = nil` (assigning an
/// `Optional<Value>`-typed `nil`) REMOVES the entry instead of storing a
/// present-but-nil value, when `Value` is itself `Optional`.
private struct GroupIDBox {
    let value: UUID?
}

public final class GroupAnnotationsCommand: UndoCommand, @unchecked Sendable {
    public let name = "Group"
    private let document: EditorDocument
    private let annotationIds: [UUID]
    private let groupId: UUID
    private var previousGroupIds: [UUID: GroupIDBox] = [:]

    public init(document: EditorDocument, annotationIds: [UUID], groupId: UUID = UUID()) {
        self.document = document
        self.annotationIds = annotationIds
        self.groupId = groupId
    }

    public func apply() {
        previousGroupIds.removeAll()
        for id in annotationIds {
            guard let idx = document.index(ofAnnotation: id) else { continue }
            previousGroupIds[id] = GroupIDBox(value: document.annotations[idx].groupId)
            document.annotations[idx].groupId = groupId
        }
    }

    public func undo() {
        for id in annotationIds {
            guard let idx = document.index(ofAnnotation: id) else { continue }
            document.annotations[idx].groupId = previousGroupIds[id]?.value ?? nil
        }
    }
}

public final class UngroupAnnotationsCommand: UndoCommand, @unchecked Sendable {
    public let name = "Ungroup"
    private let document: EditorDocument
    private let groupId: UUID
    private var previousMembers: [UUID] = []

    public init(document: EditorDocument, groupId: UUID) {
        self.document = document
        self.groupId = groupId
    }

    public func apply() {
        previousMembers = document.annotations.filter { $0.groupId == groupId }.map(\.id)
        for id in previousMembers {
            guard let idx = document.index(ofAnnotation: id) else { continue }
            document.annotations[idx].groupId = nil
        }
    }

    public func undo() {
        for id in previousMembers {
            guard let idx = document.index(ofAnnotation: id) else { continue }
            document.annotations[idx].groupId = groupId
        }
    }
}

// MARK: - Composite

/// Bundles several commands into one undo-stack entry — e.g. "restyle all
/// 4 selected annotations" should undo as one step, not four. `undo()`
/// runs the wrapped commands in reverse order, matching how nested
/// transactions unwind.
public final class CompositeCommand: UndoCommand, @unchecked Sendable {
    public let name: String
    private let commands: [UndoCommand]

    public init(name: String, commands: [UndoCommand]) {
        self.name = name
        self.commands = commands
    }

    public func apply() { commands.forEach { $0.apply() } }
    public func undo() { commands.reversed().forEach { $0.undo() } }
}
