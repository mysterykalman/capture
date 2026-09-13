import CaptureCore
@testable import CaptureEditor
import XCTest

final class EditorCommandsTests: XCTestCase {
    private func makeDocument() -> EditorDocument {
        EditorDocument(
            cropRect: CaptureRect(x: 0, y: 0, width: 800, height: 600),
            canvasSize: CaptureSize(width: 800, height: 600),
            sourceSize: CaptureSize(width: 800, height: 600)
        )
    }

    private func makeAnnotation(kind: Annotation.Kind = .arrow, zIndex: Int = 0, frame: CaptureRect = CaptureRect(x: 10, y: 10, width: 20, height: 20)) -> Annotation {
        Annotation(type: kind, frame: frame, zIndex: zIndex)
    }

    // MARK: - Add / Delete

    func testAddAnnotationCommandAppliesAndUndoes() {
        let document = makeDocument()
        let annotation = makeAnnotation()
        let command = AddAnnotationCommand(document: document, annotation: annotation)

        command.apply()
        XCTAssertEqual(document.annotations.map(\.id), [annotation.id])

        command.undo()
        XCTAssertTrue(document.annotations.isEmpty)
    }

    func testDeleteAnnotationCommandAppliesAndUndoes() {
        let document = makeDocument()
        let annotation = makeAnnotation()
        document.annotations = [annotation]

        let command = DeleteAnnotationCommand(document: document, annotationId: annotation.id)
        command.apply()
        XCTAssertTrue(document.annotations.isEmpty)

        command.undo()
        XCTAssertEqual(document.annotations, [annotation])
    }

    func testDeleteAnnotationCommandReinsertsAtOriginalIndex() {
        let document = makeDocument()
        let first = makeAnnotation(zIndex: 0)
        let middle = makeAnnotation(zIndex: 1)
        let last = makeAnnotation(zIndex: 2)
        document.annotations = [first, middle, last]

        let command = DeleteAnnotationCommand(document: document, annotationId: middle.id)
        command.apply()
        XCTAssertEqual(document.annotations.map(\.id), [first.id, last.id])

        command.undo()
        XCTAssertEqual(document.annotations.map(\.id), [first.id, middle.id, last.id])
    }

    func testAddThenDeleteCounterRenumbersCorrectly() {
        let document = makeDocument()
        let counterA = Annotation(type: .counter, frame: .zero, zIndex: 0)
        let counterB = Annotation(type: .counter, frame: .zero, zIndex: 1)
        let addA = AddAnnotationCommand(document: document, annotation: counterA)
        let addB = AddAnnotationCommand(document: document, annotation: counterB)
        addA.apply()
        addB.apply()

        func resolvedIndex(_ id: UUID) -> Int? {
            guard let annotation = document.annotation(id) else { return nil }
            return StyleReader(annotation).typeData?[AnnotationStyleKeys.counterResolvedIndex]?.doubleValue.map { Int($0) }
        }
        XCTAssertEqual(resolvedIndex(counterA.id), 0)
        XCTAssertEqual(resolvedIndex(counterB.id), 1)

        let deleteA = DeleteAnnotationCommand(document: document, annotationId: counterA.id)
        deleteA.apply()
        XCTAssertEqual(resolvedIndex(counterB.id), 0) // shifted down after A's removal

        deleteA.undo()
        XCTAssertEqual(resolvedIndex(counterA.id), 0)
        XCTAssertEqual(resolvedIndex(counterB.id), 1)
    }

    // MARK: - Transform

    func testTransformCommandMoveIsATrueInverse() {
        let document = makeDocument()
        let annotation = makeAnnotation(frame: CaptureRect(x: 0, y: 0, width: 10, height: 10))
        document.annotations = [annotation]

        let to = CaptureRect(x: 50, y: 60, width: 10, height: 10)
        let command = TransformAnnotationCommand.move(document: document, annotationId: annotation.id, from: annotation.frame, to: to, rotation: 0)

        command.apply()
        XCTAssertEqual(document.annotation(annotation.id)?.frame, to)

        command.undo()
        XCTAssertEqual(document.annotation(annotation.id)?.frame, annotation.frame)
    }

    func testTransformCommandRotateIsATrueInverse() {
        let document = makeDocument()
        let annotation = makeAnnotation()
        document.annotations = [annotation]

        let command = TransformAnnotationCommand.rotate(document: document, annotationId: annotation.id, frame: annotation.frame, from: 0, to: 45)
        command.apply()
        XCTAssertEqual(document.annotation(annotation.id)?.rotation, 45)
        command.undo()
        XCTAssertEqual(document.annotation(annotation.id)?.rotation, 0)
    }

    // MARK: - Restyle

    func testRestyleCommandIsATrueInverse() {
        let document = makeDocument()
        var annotation = makeAnnotation()
        annotation.style = .object(["colour": .string("#FF0000")])
        document.annotations = [annotation]

        let afterStyle: JSONValue = .object(["colour": .string("#00FF00")])
        let command = RestyleAnnotationCommand(
            document: document,
            annotationId: annotation.id,
            beforeStyle: annotation.style,
            beforeTypeData: nil,
            afterStyle: afterStyle,
            afterTypeData: nil
        )

        command.apply()
        XCTAssertEqual(document.annotation(annotation.id)?.style, afterStyle)

        command.undo()
        XCTAssertEqual(document.annotation(annotation.id)?.style, annotation.style)
    }

    // MARK: - Reorder z-index

    func testZIndexReorderPlanBringToFront() {
        let a = makeAnnotation(zIndex: 0)
        let b = makeAnnotation(zIndex: 1)
        let c = makeAnnotation(zIndex: 2)
        let plan = ZIndexReorder.plan([a, b, c], targetId: a.id, operation: .bringToFront)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.after[a.id], 2)
        XCTAssertEqual(plan?.after[b.id], 0)
        XCTAssertEqual(plan?.after[c.id], 1)
    }

    func testZIndexReorderPlanIsNilWhenAlreadyOnTop() {
        let a = makeAnnotation(zIndex: 0)
        let b = makeAnnotation(zIndex: 1)
        let plan = ZIndexReorder.plan([a, b], targetId: b.id, operation: .bringToFront)
        XCTAssertNil(plan)
    }

    func testZIndexReorderOnlyAffectsSameLayerGroup() {
        // Redactions and vector annotations are different render-layer
        // groups (see `EditorDocument.RenderLayerGroup`) — reordering a
        // vector annotation must never touch a redaction's zIndex, even if
        // their raw zIndex values collide.
        let redaction = Annotation(type: .redact, frame: .zero, zIndex: 5)
        let vectorA = makeAnnotation(zIndex: 5)
        let vectorB = makeAnnotation(zIndex: 6)
        let plan = ZIndexReorder.plan([redaction, vectorA, vectorB], targetId: vectorA.id, operation: .bringToFront)
        XCTAssertNotNil(plan)
        XCTAssertNil(plan?.before[redaction.id])
        XCTAssertNil(plan?.after[redaction.id])
    }

    func testReorderZIndexCommandApplyAndUndo() {
        let document = makeDocument()
        let a = makeAnnotation(zIndex: 0)
        let b = makeAnnotation(zIndex: 1)
        document.annotations = [a, b]

        guard let command = ReorderZIndexCommand.make(document: document, targetId: a.id, operation: .bringToFront) else {
            return XCTFail("expected a valid reorder plan")
        }
        command.apply()
        XCTAssertEqual(document.annotation(a.id)?.zIndex, 1)
        XCTAssertEqual(document.annotation(b.id)?.zIndex, 0)

        command.undo()
        XCTAssertEqual(document.annotation(a.id)?.zIndex, 0)
        XCTAssertEqual(document.annotation(b.id)?.zIndex, 1)
    }

    // MARK: - Crop

    func testCropChangeCommandIsATrueInverse() {
        let document = makeDocument()
        let before = document.cropRect
        let after = CaptureRect(x: 10, y: 10, width: 400, height: 300)
        let command = CropChangeCommand(document: document, before: before, after: after)

        command.apply()
        XCTAssertEqual(document.cropRect, after)
        command.undo()
        XCTAssertEqual(document.cropRect, before)
    }

    // MARK: - Group / Ungroup

    func testGroupAndUngroupRoundTrip() {
        let document = makeDocument()
        let a = makeAnnotation()
        let b = makeAnnotation()
        document.annotations = [a, b]

        let groupCommand = GroupAnnotationsCommand(document: document, annotationIds: [a.id, b.id])
        groupCommand.apply()
        let groupId = document.annotation(a.id)?.groupId
        XCTAssertNotNil(groupId)
        XCTAssertEqual(document.annotation(b.id)?.groupId, groupId)

        groupCommand.undo()
        XCTAssertNil(document.annotation(a.id)?.groupId)
        XCTAssertNil(document.annotation(b.id)?.groupId)
    }

    func testUngroupCommandIsATrueInverse() {
        let document = makeDocument()
        let groupId = UUID()
        var a = makeAnnotation()
        var b = makeAnnotation()
        a.groupId = groupId
        b.groupId = groupId
        document.annotations = [a, b]

        let command = UngroupAnnotationsCommand(document: document, groupId: groupId)
        command.apply()
        XCTAssertNil(document.annotation(a.id)?.groupId)
        XCTAssertNil(document.annotation(b.id)?.groupId)

        command.undo()
        XCTAssertEqual(document.annotation(a.id)?.groupId, groupId)
        XCTAssertEqual(document.annotation(b.id)?.groupId, groupId)
    }

    // MARK: - UndoStack round trip (real CaptureCore.UndoStack integration)

    func testUndoStackRoundTripLeavesDocumentUnchanged() {
        let document = makeDocument()
        let stack = UndoStack()
        let annotation = makeAnnotation()

        stack.perform(AddAnnotationCommand(document: document, annotation: annotation))
        XCTAssertEqual(document.annotations.count, 1)

        let moveCommand = TransformAnnotationCommand.move(document: document, annotationId: annotation.id, from: annotation.frame, to: CaptureRect(x: 99, y: 99, width: 20, height: 20), rotation: 0)
        stack.perform(moveCommand)
        XCTAssertEqual(document.annotation(annotation.id)?.frame.x, 99)

        stack.undo() // undo move
        XCTAssertEqual(document.annotation(annotation.id)?.frame, annotation.frame)
        stack.undo() // undo add
        XCTAssertTrue(document.annotations.isEmpty)

        stack.redo() // redo add
        stack.redo() // redo move
        XCTAssertEqual(document.annotation(annotation.id)?.frame.x, 99)
    }

    // MARK: - Composite

    func testCompositeCommandUndoesInReverseOrder() {
        let document = makeDocument()
        let a = makeAnnotation(zIndex: 0)
        document.annotations = [a]

        let restyle = RestyleAnnotationCommand(document: document, annotationId: a.id, beforeStyle: nil, beforeTypeData: nil, afterStyle: .object(["colour": .string("#000000")]), afterTypeData: nil)
        let move = TransformAnnotationCommand.move(document: document, annotationId: a.id, from: a.frame, to: CaptureRect(x: 5, y: 5, width: 20, height: 20), rotation: 0)
        let composite = CompositeCommand(name: "Restyle and Move", commands: [restyle, move])

        composite.apply()
        XCTAssertEqual(document.annotation(a.id)?.frame.x, 5)
        XCTAssertNotNil(document.annotation(a.id)?.style)

        composite.undo()
        XCTAssertEqual(document.annotation(a.id)?.frame, a.frame)
        XCTAssertNil(document.annotation(a.id)?.style)
    }
}
