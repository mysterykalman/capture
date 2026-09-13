import CaptureCore
import Foundation

/// Pure state machine implementing the exact "Mac-Like Area-to-Window
/// Capture Interaction" flow from the spec:
///
/// 1. Trigger Capture Area via its shortcut -> crosshair (`.ready(.area)`).
/// 2. User drags a region (`.areaDragging`).
/// 3. Space mid-drag toggles to Window Capture mode (`.ready(.window)`) —
///    the in-progress drag rect is discarded, matching native macOS
///    Screenshot's own Space-to-toggle behaviour.
/// 4. Hovering a window highlights it (`.windowHovering`).
/// 5. Clicking captures it (`.captured(.window)`).
/// 6. Space again toggles back to Area mode.
/// 7. Escape cancels from anywhere (`.cancelled`).
/// 8. The configured modifier (Option by default) held during the window
///    click captures without the window's drop shadow.
///
/// No AppKit/ScreenCaptureKit import — this file only depends on
/// `CaptureCore` and `Foundation`, so it is directly unit-testable. The
/// AppKit-facing `AreaToWindowCaptureController` translates real
/// `NSEvent`/live-window-geometry input into the `CaptureInteractionEvent`s
/// this reducer consumes, and translates `CaptureCommand` output into real
/// ScreenCaptureKit calls — neither of those translation steps has any
/// branching logic of its own worth unit-testing beyond what's covered
/// here.

/// Which sub-mode "ready" (armed, cursor shown, nothing selected yet) is in.
public enum InteractionMode: Equatable, Sendable {
    case area
    case window
}

/// Mirrors `CGWindowID`'s underlying representation (`UInt32`) without this
/// pure file needing to `import CoreGraphics` for a type alias.
public typealias CaptureWindowToken = UInt32

/// The result of a finished interaction, handed to the (untestable)
/// ScreenCaptureKit-backed engine to actually rasterize.
public enum CaptureCommand: Equatable, Sendable {
    case area(rect: CaptureRect)
    case window(windowID: CaptureWindowToken, withoutShadow: Bool)
}

public enum CaptureInteractionState: Equatable, Sendable {
    /// No interaction in progress; nothing armed.
    case idle
    /// Armed for `mode`: crosshair cursor (area) or window-selector cursor
    /// (window), waiting for the first drag/hover/click.
    case ready(InteractionMode)
    /// Dragging an area selection; `origin` is the fixed corner (where the
    /// drag began), `current` is the live opposite corner.
    case areaDragging(origin: CapturePoint, current: CapturePoint)
    /// In window-select mode, hovering (or not) a window under the cursor.
    case windowHovering(windowID: CaptureWindowToken?)
    /// Escape was pressed; the UI layer should tear down its overlay with
    /// no capture taken.
    case cancelled
    /// A capture command was produced; the UI layer should tear down its
    /// overlay and hand `command` to `ScreenCaptureEngine`.
    case captured(CaptureCommand)

    var isTerminal: Bool {
        switch self {
        case .cancelled, .captured: return true
        default: return false
        }
    }
}

public enum CaptureInteractionEvent: Equatable, Sendable {
    /// Fired once, by the global shortcut handler, to arm the overlay.
    /// `.area` for the "Capture Area" action's native flow;
    /// direct `.window` for the standalone "Capture Window" action, which
    /// skips straight to window-hover/click with no drag phase at all.
    case shortcutTriggered(mode: InteractionMode)
    case dragBegan(at: CapturePoint)
    /// `to` is expected to already be snap-adjusted by the caller
    /// (`AreaToWindowCaptureController` wires `CaptureCore.SnapEngine` in
    /// before calling this) — the reducer itself has no opinion on
    /// snapping, it just tracks whatever point it's given.
    case dragChanged(to: CapturePoint)
    case dragEnded(at: CapturePoint)
    /// `nil` when the cursor is over no capturable window (e.g. the desktop).
    case pointerMoved(hoveredWindow: CaptureWindowToken?)
    case windowClicked(windowID: CaptureWindowToken, modifiers: ShortcutModifiers)
    case spaceKeyPressed
    case escapeKeyPressed
}

public enum CaptureInteractionReducer {
    /// Advances `state` by `event`. Unmatched (state, event) combinations —
    /// e.g. a stray `dragChanged` after the interaction already finished —
    /// are ignored and return `state` unchanged rather than trapping, since
    /// event delivery from AppKit monitors can race a just-finished
    /// interaction (the overlay window closing is not perfectly
    /// synchronous with monitor teardown).
    ///
    /// - Parameter shadowlessModifier: the "configurable modifier" from the
    ///   spec (Option by default) that, held during a window click, omits
    ///   the window's drop shadow from the capture.
    public static func reduce(
        _ state: CaptureInteractionState,
        _ event: CaptureInteractionEvent,
        shadowlessModifier: ShortcutModifiers = .option
    ) -> CaptureInteractionState {
        if event == .escapeKeyPressed, !state.isTerminal {
            return .cancelled
        }

        switch (state, event) {
        case (.idle, .shortcutTriggered(let mode)):
            return .ready(mode)

        case (.ready(.area), .dragBegan(let point)):
            return .areaDragging(origin: point, current: point)

        case (.areaDragging(let origin, _), .dragChanged(let point)):
            return .areaDragging(origin: origin, current: point)

        case (.areaDragging(let origin, _), .dragEnded(let point)):
            return .captured(.area(rect: normalizedRect(origin, point)))

        case (.areaDragging, .spaceKeyPressed), (.ready(.area), .spaceKeyPressed):
            // Discard any in-progress drag; native macOS Screenshot does
            // the same when toggling mid-drag.
            return .ready(.window)

        case (.ready(.window), .spaceKeyPressed), (.windowHovering, .spaceKeyPressed):
            return .ready(.area)

        case (.ready(.window), .pointerMoved(let windowID)), (.windowHovering, .pointerMoved(let windowID)):
            return .windowHovering(windowID: windowID)

        case (.windowHovering, .windowClicked(let windowID, let modifiers)),
             (.ready(.window), .windowClicked(let windowID, let modifiers)):
            return .captured(.window(windowID: windowID, withoutShadow: modifiers.contains(shadowlessModifier)))

        default:
            return state
        }
    }

    private static func normalizedRect(_ a: CapturePoint, _ b: CapturePoint) -> CaptureRect {
        CaptureRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
