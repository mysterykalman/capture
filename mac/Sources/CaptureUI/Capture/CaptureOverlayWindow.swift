import AppKit
import CaptureCapture
import CaptureCore
import Foundation

/// The real AppKit view layer for `CaptureCapture.AreaToWindowCaptureController`
/// (a pure interaction/event-routing engine with "no visual overlay itself
/// — crosshair rendering, window highlight, etc. are `CaptureUI`'s job", per
/// that type's own doc comment). This file is the crosshair/selection
/// `NSWindow` overlay: one borderless, transparent, full-screen window per
/// connected display (so a drag can start on one display and the whole
/// desktop dims/arms consistently), all driven by one shared
/// `AreaToWindowCaptureController` + `CaptureInteractionState`.
///
/// Event routing uses exactly the convenience the controller documents for
/// this purpose: `NSEvent.addLocalMonitorForEvents` + `controller.handle(_:)`
/// (see that method's doc comment — "CaptureUI code that drives the overlay
/// via `NSEvent.addLocalMonitorForEvents`... Always returns `event`
/// unmodified; the caller's own monitor closure decides whether to swallow
/// it"). Every matched event is swallowed (returns `nil`) while the overlay
/// is active, so a click/drag/keypress never leaks through to whatever app
/// was frontmost before the shortcut fired.
@MainActor
public final class CaptureOverlayWindowController {
    private let interactionController: AreaToWindowCaptureController
    private let geometryProvider: WindowGeometryProviding
    private var overlayWindows: [OverlayWindow] = []
    private var localMonitor: Any?
    /// Recomputed on every `mouseMoved` purely for drawing the window-hover
    /// highlight — the controller's own internal hit-testing (inside
    /// `handle(_:)`) is a separate, side-effect-free call to the same
    /// `WindowGeometryProviding`, so duplicating the query here has no
    /// correctness impact, only a second (cheap) geometry lookup per move.
    private var hoveredWindowFrame: CaptureRect?

    /// Fired once a capture command is produced — the receiver
    /// (`CaptureFlowController`) is expected to hand `command` to
    /// `ScreenCaptureEngine`.
    public var onCaptured: ((CaptureCommand) -> Void)?
    public var onCancelled: (() -> Void)?

    public init(interactionController: AreaToWindowCaptureController, geometryProvider: WindowGeometryProviding) {
        self.interactionController = interactionController
        self.geometryProvider = geometryProvider
    }

    public var isPresenting: Bool { !overlayWindows.isEmpty }

    /// Arms the interaction controller and shows one overlay window per
    /// display. Safe to call again while already presenting (no-op).
    public func present(mode: InteractionMode) {
        guard overlayWindows.isEmpty else { return }

        interactionController.onStateChange = { [weak self] state in
            self?.render(state)
        }
        interactionController.onCaptured = { [weak self] command in
            self?.onCaptured?(command)
            self?.dismiss()
        }
        interactionController.onCancelled = { [weak self] in
            self?.onCancelled?()
            self?.dismiss()
        }

        overlayWindows = NSScreen.screens.map { screen in
            let window = OverlayWindow(screen: screen)
            window.orderFrontRegardless()
            return window
        }
        // Exactly one of the overlay windows needs to be key to receive
        // keyDown at all; the local monitor below then sees it regardless
        // of which overlay window is key, since local monitors fire for
        // every event delivered to any window this application owns.
        overlayWindows.first?.makeKey()

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .mouseMoved {
                let point = CapturePoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
                self.hoveredWindowFrame = self.geometryProvider.window(at: point)?.frame
            }
            self.interactionController.handle(event)
            return nil // swallow: nothing should reach any other window while armed
        }

        interactionController.begin(mode: mode)
        render(interactionController.state)
    }

    public func dismiss() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows = []
        hoveredWindowFrame = nil
    }

    private func render(_ state: CaptureInteractionState) {
        for window in overlayWindows {
            (window.contentView as? CaptureOverlayView)?.update(state: state, hoveredWindowFrame: hoveredWindowFrame)
        }
        updateCursor(for: state)
    }

    private func updateCursor(for state: CaptureInteractionState) {
        switch state {
        case .ready(.area), .areaDragging:
            NSCursor.crosshair.set()
        case .ready(.window), .windowHovering:
            NSCursor.pointingHand.set()
        default:
            NSCursor.arrow.set()
        }
    }
}

/// Borderless, transparent, click-through-disabled window spanning exactly
/// one `NSScreen`. `.screenSaver` level + `canJoinAllSpaces` matches how
/// native macOS Screenshot's own selection overlay behaves: above
/// everything, including full-screen apps' own Spaces.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hasShadow = false
        isReleasedWhenClosed = false
        contentView = CaptureOverlayView(frame: screen.frame)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws the dim scrim, crosshair guide lines, live selection rect (with a
/// dimension label), and window-hover highlight. All geometry it receives
/// is in AppKit global screen space; this view converts to its own local
/// (window-relative) coordinates by subtracting the window's screen origin,
/// since each `OverlayWindow`'s frame exactly matches one `NSScreen.frame`.
final class CaptureOverlayView: NSView {
    private var state: CaptureInteractionState = .idle
    private var hoveredWindowFrameGlobal: CaptureRect?

    override var isFlipped: Bool { false } // Matches AppKit's native bottom-left/y-up screen space throughout this module.

    func update(state: CaptureInteractionState, hoveredWindowFrame: CaptureRect?) {
        self.state = state
        self.hoveredWindowFrameGlobal = hoveredWindowFrame
        needsDisplay = true
    }

    private func toLocal(_ rect: CaptureRect) -> NSRect {
        guard let origin = window?.frame.origin else { return rect.cgRect }
        return NSRect(x: rect.x - origin.x, y: rect.y - origin.y, width: rect.width, height: rect.height)
    }

    private func toLocal(_ point: CapturePoint) -> NSPoint {
        guard let origin = window?.frame.origin else { return NSPoint(x: point.x, y: point.y) }
        return NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dim scrim across the whole display — the spec's discoverability
        // list promises "snap precisely" / a confident, purposeful capture
        // affordance rather than a plain empty crosshair.
        CapturePalette.ink.withAlphaComponent(0.28).setFill()
        bounds.fill()

        switch state {
        case .idle:
            break

        case .ready(.area):
            break // Scrim + system crosshair cursor is enough; no selection yet.

        case .areaDragging(let origin, let current):
            drawSelection(origin: origin, current: current)

        case .ready(.window), .windowHovering:
            if let frame = hoveredWindowFrameGlobal {
                drawWindowHighlight(frame)
            }

        case .cancelled, .captured:
            break
        }
    }

    private func drawSelection(origin: CapturePoint, current: CapturePoint) {
        let rect = NSRect(
            x: min(origin.x, current.x), y: min(origin.y, current.y),
            width: abs(current.x - origin.x), height: abs(current.y - origin.y)
        )
        let local = toLocal(CaptureRect(cgRect: rect))

        // Punch a clear (undimmed) hole for the live selection so the
        // region being captured previews at full brightness, matching
        // native macOS Screenshot's own selection behaviour.
        NSGraphicsContext.saveGraphicsState()
        NSColor.clear.setFill()
        local.fill(using: .destinationOut)
        NSGraphicsContext.restoreGraphicsState()

        let accent = CaptureTheme.accent
        accent.withAlphaComponent(0.12).setFill()
        local.fill()
        let border = NSBezierPath(rect: local)
        border.lineWidth = 1.5
        accent.setStroke()
        border.stroke()

        drawHandles(around: local, colour: accent)
        drawDimensionLabel(rect: local, size: CGSize(width: local.width, height: local.height))
    }

    private func drawWindowHighlight(_ frameGlobal: CaptureRect) {
        let local = toLocal(frameGlobal)
        NSGraphicsContext.saveGraphicsState()
        NSColor.clear.setFill()
        local.fill(using: .destinationOut)
        NSGraphicsContext.restoreGraphicsState()

        let accent = CaptureTheme.accent
        accent.withAlphaComponent(0.10).setFill()
        local.fill()
        let border = NSBezierPath(roundedRect: local.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        border.lineWidth = 3
        accent.setStroke()
        border.stroke()
    }

    private func drawHandles(around rect: NSRect, colour: NSColor) {
        let handleSize: CGFloat = 6
        let points = [
            NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.midX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.midY), NSPoint(x: rect.maxX, y: rect.midY),
            NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.midX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)
        ]
        for point in points {
            let handleRect = NSRect(x: point.x - handleSize / 2, y: point.y - handleSize / 2, width: handleSize, height: handleSize)
            let path = NSBezierPath(ovalIn: handleRect)
            NSColor.white.setFill()
            path.fill()
            colour.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private func drawDimensionLabel(rect: NSRect, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let text = "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let padding: CGFloat = 5
        var labelOrigin = NSPoint(x: rect.minX, y: rect.maxY + 6)
        if labelOrigin.y + textSize.height + padding * 2 > bounds.maxY {
            labelOrigin.y = rect.minY - textSize.height - padding * 2 - 6
        }
        let labelRect = NSRect(x: labelOrigin.x, y: labelOrigin.y, width: textSize.width + padding * 2, height: textSize.height + padding * 2)
        let bubble = NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4)
        CaptureTheme.accent.setFill()
        bubble.fill()
        attributed.draw(at: NSPoint(x: labelRect.minX + padding, y: labelRect.minY + padding))
    }
}
