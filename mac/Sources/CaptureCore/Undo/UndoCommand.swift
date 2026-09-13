import Foundation

/// Command-based undo/redo (Part I §11: "Use command-based undo/redo rather
/// than storing full bitmap snapshots"). `CaptureEditor` supplies concrete
/// `UndoCommand` implementations (add/move/resize/restyle annotation, crop,
/// etc.); this stack is generic and reusable by any editing surface.
public protocol UndoCommand: Sendable {
    var name: String { get }
    func apply()
    func undo()
}

/// Not thread-safe by design — callers must invoke from the editor's owning
/// actor/main thread, matching how AppKit editing already works.
public final class UndoStack {
    private var undoCommands: [UndoCommand] = []
    private var redoCommands: [UndoCommand] = []
    public private(set) var isApplying = false

    public var canUndo: Bool { !undoCommands.isEmpty }
    public var canRedo: Bool { !redoCommands.isEmpty }
    public var undoActionName: String? { undoCommands.last?.name }
    public var redoActionName: String? { redoCommands.last?.name }

    public init() {}

    /// Applies `command.apply()` immediately and pushes it onto the undo
    /// stack, clearing any redo history (standard editor semantics).
    public func perform(_ command: UndoCommand) {
        isApplying = true
        command.apply()
        isApplying = false
        undoCommands.append(command)
        redoCommands.removeAll()
    }

    /// Registers a command that has already been applied (e.g. the initial
    /// creation of an object where "apply" already happened as part of
    /// interactive creation) without re-invoking `apply()`.
    public func registerAlreadyApplied(_ command: UndoCommand) {
        undoCommands.append(command)
        redoCommands.removeAll()
    }

    public func undo() {
        guard let command = undoCommands.popLast() else { return }
        isApplying = true
        command.undo()
        isApplying = false
        redoCommands.append(command)
    }

    public func redo() {
        guard let command = redoCommands.popLast() else { return }
        isApplying = true
        command.apply()
        isApplying = false
        undoCommands.append(command)
    }

    public func removeAll() {
        undoCommands.removeAll()
        redoCommands.removeAll()
    }
}
