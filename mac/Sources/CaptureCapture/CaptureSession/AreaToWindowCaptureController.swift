import AppKit
import CaptureCore
import CoreGraphics
import Foundation

/// Live window/display geometry the pure `CaptureInteractionReducer` needs
/// but must not query itself (that would make it untestable without a real
/// display). Production code backs this with Quartz Window Services
/// (`LiveWindowGeometryProvider`); tests inject a scripted fake.
public protocol WindowGeometryProviding: AnyObject {
    /// The frontmost capturable window under `point`, if any, excluding
    /// Capture's own overlay window(s).
    func window(at point: CapturePoint) -> (id: CaptureWindowToken, frame: CaptureRect)?
    /// All on-screen window frames (excluding Capture's own), used to build
    /// snap candidate lines while area-dragging.
    func allWindowFrames() -> [CaptureRect]
    /// The frame (in the same coordinate space as `point`) of the display
    /// `point` falls on, used to build screen-edge snap candidate lines.
    func screenFrame(containing point: CapturePoint) -> CaptureRect
}

/// Drives `CaptureInteractionReducer` from real `NSEvent`-sourced input,
/// wiring in `CaptureCore.SnapEngine` for area-drag edge snapping (Universal
/// Snap Engine requirement — capture-region snapping to screen/window
/// edges) and live window geometry for hover/click hit-testing. Owns no
/// visual overlay itself (crosshair rendering, window highlight, etc. are
/// `CaptureUI`'s job) — this is purely the interaction/event-routing layer.
///
/// Must be constructed and driven from the main thread/queue, matching the
/// rest of AppKit's event-handling surface.
public final class AreaToWindowCaptureController {
    public struct Configuration: Sendable {
        /// The "configurable modifier" from the spec (Option by default)
        /// that, held during a window click, captures without shadow.
        public var shadowlessModifier: ShortcutModifiers
        public var snapSettings: SnapSettings

        public init(shadowlessModifier: ShortcutModifiers = .option, snapSettings: SnapSettings = .default) {
            self.shadowlessModifier = shadowlessModifier
            self.snapSettings = snapSettings
        }
    }

    public private(set) var state: CaptureInteractionState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Fired on every state transition, for the overlay UI to redraw
    /// (crosshair vs. window-selector cursor, highlighted window, live
    /// drag rect).
    public var onStateChange: ((CaptureInteractionState) -> Void)?
    /// Fired exactly once when an interaction finishes with a capture to
    /// perform; the receiver is expected to hand `command` to
    /// `ScreenCaptureEngine` and tear down the overlay.
    public var onCaptured: ((CaptureCommand) -> Void)?
    /// Fired exactly once when Escape cancels the interaction.
    public var onCancelled: (() -> Void)?

    private let geometry: WindowGeometryProviding
    private let snapEngine = SnapEngine()
    private var configuration: Configuration

    public init(geometry: WindowGeometryProviding, configuration: Configuration = Configuration()) {
        self.geometry = geometry
        self.configuration = configuration
    }

    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Arms the overlay. `mode` is `.area` for the "Capture Area" shortcut's
    /// native crosshair-first flow, or `.window` for the standalone
    /// "Capture Window" shortcut, which skips straight to hover/click.
    public func begin(mode: InteractionMode = .area) {
        guard state == .idle else { return }
        apply(.shortcutTriggered(mode: mode))
    }

    // MARK: Mouse input (screen coordinates, top-left or bottom-left origin
    // consistent throughout — `CaptureUI` is responsible for feeding this
    // controller a single consistent coordinate space; the reducer and this
    // controller are agnostic to which).

    public func mouseDown(at point: CapturePoint, modifiers: ShortcutModifiers) {
        switch state {
        case .ready(.area):
            apply(.dragBegan(at: point))
        case .ready(.window), .windowHovering:
            if let hit = geometry.window(at: point) {
                apply(.windowClicked(windowID: hit.id, modifiers: modifiers))
            }
        default:
            break
        }
    }

    public func mouseDragged(to rawPoint: CapturePoint) {
        guard case .areaDragging(let origin, _) = state else { return }
        apply(.dragChanged(to: snappedDragPoint(rawPoint, origin: origin)))
    }

    public func mouseUp(at point: CapturePoint) {
        guard case .areaDragging = state else { return }
        apply(.dragEnded(at: point))
    }

    public func mouseMoved(to point: CapturePoint) {
        switch state {
        case .ready(.window), .windowHovering:
            apply(.pointerMoved(hoveredWindow: geometry.window(at: point)?.id))
        default:
            break
        }
    }

    // MARK: Keyboard input

    public func keyDown(keyCode: UInt16) {
        switch keyCode {
        case CarbonKeyCode.space:
            apply(.spaceKeyPressed)
        case CarbonKeyCode.escape:
            apply(.escapeKeyPressed)
        default:
            break
        }
    }

    // MARK: NSEvent monitor convenience

    /// Wires this controller directly to a raw `NSEvent`, for `CaptureUI`
    /// code that drives the overlay via `NSEvent.addLocalMonitorForEvents`
    /// rather than overriding `mouseDown(with:)`/`keyDown(with:)` etc. on a
    /// custom `NSView`. Both wiring styles are valid; this is purely a
    /// convenience translator, not the only supported input path — the
    /// per-gesture methods above (`mouseDown(at:modifiers:)` etc.) are
    /// what to call from view-override-style event handling instead.
    /// Always returns `event` unmodified; the caller's own monitor closure
    /// decides whether to swallow it (return `nil`) or pass it through.
    @discardableResult
    public func handle(_ event: NSEvent) -> NSEvent {
        let point = CapturePoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
        let modifiers = ShortcutModifiers(nsEventModifierFlags: event.modifierFlags)
        switch event.type {
        case .leftMouseDown:
            mouseDown(at: point, modifiers: modifiers)
        case .leftMouseDragged:
            mouseDragged(to: point)
        case .leftMouseUp:
            mouseUp(at: point)
        case .mouseMoved:
            mouseMoved(to: point)
        case .keyDown:
            keyDown(keyCode: event.keyCode)
        default:
            break
        }
        return event
    }

    // MARK: Internal

    private func apply(_ event: CaptureInteractionEvent) {
        let next = CaptureInteractionReducer.reduce(state, event, shadowlessModifier: configuration.shadowlessModifier)
        guard next != state else { return }
        state = next
        switch next {
        case .captured(let command):
            onCaptured?(command)
            state = .idle
        case .cancelled:
            onCancelled?()
            state = .idle
        default:
            break
        }
    }

    /// Runs the raw drag rect through `SnapEngine` against screen-edge and
    /// window-edge candidates, then re-derives the moving drag point
    /// (`origin` stays the fixed corner) from the snapped rect so the
    /// reducer keeps seeing a simple two-point drag.
    private func snappedDragPoint(_ point: CapturePoint, origin: CapturePoint) -> CapturePoint {
        let rawRect = CaptureRect(
            x: min(origin.x, point.x),
            y: min(origin.y, point.y),
            width: abs(point.x - origin.x),
            height: abs(point.y - origin.y)
        )

        var candidates: [SnapLine] = []
        candidates.append(contentsOf: SnapEngine.lines(for: geometry.screenFrame(containing: origin), category: .edges))
        for frame in geometry.allWindowFrames() {
            candidates.append(contentsOf: SnapEngine.lines(for: frame, category: .edges))
        }

        let snapped = snapEngine.snap(moving: rawRect, candidates: candidates, settings: configuration.snapSettings).rect
        let x = point.x >= origin.x ? snapped.maxX : snapped.minX
        let y = point.y >= origin.y ? snapped.maxY : snapped.minY
        return CapturePoint(x: x, y: y)
    }
}
