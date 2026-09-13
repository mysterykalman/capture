import AppKit
import CaptureCapture
import CaptureCore
import CoreGraphics
import Foundation

/// The result of one finished still capture, handed from `CaptureFlowController`
/// to whatever opens the editor / Quick Access Overlay next
/// (`CaptureApp.CapturePipeline`). Deliberately carries only the raw pixel
/// content plus the geometry needed for Repeat Area / bookmarks-bar
/// detection — not yet an `EditorDocument` (that conversion, and deciding
/// what "source app"/URL metadata to attach, is the pipeline's job, since
/// `CaptureUI` alone doesn't know about the browser bridge).
public struct CapturedImageResult: Sendable {
    public let image: CGImage
    public let pixelSize: CaptureSize
    /// The captured region's own screen rect (AppKit space), when the
    /// capture mode had one (`.area`/`.window`) — `nil` for full-screen.
    public let screenRect: CaptureRect?
    public let displayID: CGDirectDisplayID?

    public init(image: CGImage, pixelSize: CaptureSize, screenRect: CaptureRect?, displayID: CGDirectDisplayID?) {
        self.image = image
        self.pixelSize = pixelSize
        self.screenRect = screenRect
        self.displayID = displayID
    }
}

/// Orchestrates the real, end-to-end "Mac-Like Area-to-Window Capture
/// Interaction" (spec digest): arms `CaptureOverlayWindowController`, waits
/// for `AreaToWindowCaptureController`'s `CaptureCommand` output, and drives
/// `CaptureCapture.ScreenCaptureEngine` to actually rasterize it — the
/// concrete glue between "global shortcut fired" and "a `CGImage` exists",
/// which is step 1-3 of Part I §39's first acceptance milestone.
///
/// One instance is owned by `CaptureApp` for the lifetime of the app; every
/// menu-bar command and every global shortcut handler calls into this same
/// controller so there is only ever one overlay/session in flight at a time.
@MainActor
public final class CaptureFlowController {
    private let engine = ScreenCaptureEngine()
    private let interactionController: AreaToWindowCaptureController
    private let overlayController: CaptureOverlayWindowController
    private let geometryProvider: WindowGeometryProviding
    public let repeatAreaStore: RepeatAreaStore
    private let logger = CaptureLogger(category: "CaptureFlowController")

    /// Fired once a still capture's pixels are ready.
    public var onCaptureCompleted: ((CapturedImageResult) -> Void)?
    /// Fired when capture couldn't complete for a reason other than
    /// permission (e.g. `ScreenCaptureEngineError`).
    public var onCaptureFailed: ((Error) -> Void)?
    /// Fired when Screen Recording permission is missing/declined —
    /// `docs/PERMISSIONS.md`: "`CaptureUI` shows the standard 'Open System
    /// Settings' prompt; no capture is silently skipped or faked."
    public var onScreenRecordingPermissionDenied: (() -> Void)?
    /// Fired when the user presses Escape / cancels the overlay with no
    /// capture taken.
    public var onCancelled: (() -> Void)?

    public init(
        geometryProvider: WindowGeometryProviding = LiveWindowGeometryProvider(),
        repeatAreaStore: RepeatAreaStore = RepeatAreaStore(),
        snapSettings: SnapSettings = .default
    ) {
        self.geometryProvider = geometryProvider
        self.repeatAreaStore = repeatAreaStore
        self.interactionController = AreaToWindowCaptureController(
            geometry: geometryProvider,
            configuration: .init(shadowlessModifier: .option, snapSettings: snapSettings)
        )
        self.overlayController = CaptureOverlayWindowController(interactionController: interactionController, geometryProvider: geometryProvider)

        overlayController.onCaptured = { [weak self] command in
            Task { @MainActor in await self?.handle(command) }
        }
        overlayController.onCancelled = { [weak self] in
            self?.onCancelled?()
        }
    }

    public func updateSnapSettings(_ settings: SnapSettings) {
        interactionController.updateConfiguration(.init(shadowlessModifier: .option, snapSettings: settings))
    }

    // MARK: - Entry points (Global Custom Shortcut System actions)

    /// `ShortcutAction.captureArea` — native crosshair-first flow.
    public func beginAreaCapture() {
        guard ensurePermission() else { return }
        overlayController.present(mode: .area)
    }

    /// `ShortcutAction.captureWindow` — skips straight to hover/click.
    public func beginWindowCapture() {
        guard ensurePermission() else { return }
        overlayController.present(mode: .window)
    }

    public func captureFullScreen(display selection: CaptureDisplaySelection = .main, includeCursor: Bool = false) {
        guard ensurePermission() else { return }
        Task { @MainActor in
            do {
                let image = try await engine.captureFullScreen(display: selection, includeCursor: includeCursor)
                complete(image: image, screenRect: nil, displayID: nil)
            } catch {
                fail(error)
            }
        }
    }

    /// `ShortcutAction.captureRepeatArea` — re-captures the last-used area
    /// region instantly with no redraw, falling back to a fresh area
    /// capture when nothing has been saved yet.
    public func captureRepeatArea() {
        guard ensurePermission() else { return }
        guard let region = repeatAreaStore.load() else {
            beginAreaCapture()
            return
        }
        Task { @MainActor in
            do {
                let display: CaptureDisplaySelection = region.displayID.map { .display($0) } ?? .main
                let image = try await engine.captureArea(rect: region.rect, display: display)
                complete(image: image, screenRect: region.rect, displayID: region.displayID)
            } catch {
                fail(error)
            }
        }
    }

    public var isPresentingOverlay: Bool { overlayController.isPresenting }

    // MARK: - Handling a finished interaction

    private func handle(_ command: CaptureCommand) async {
        switch command {
        case .area(let rect):
            do {
                let displayID = primaryDisplayID(containing: rect)
                let image = try await engine.captureArea(rect: rect, display: .main)
                repeatAreaStore.save(RepeatAreaRegion(rect: rect, displayID: displayID))
                complete(image: image, screenRect: rect, displayID: displayID)
            } catch {
                fail(error)
            }
        case .window(let windowID, let withoutShadow):
            do {
                let image = try await engine.captureWindow(windowID: windowID, includeShadow: !withoutShadow)
                let frame = geometryProvider.allWindowFrames().first // best-effort; exact frame isn't otherwise recoverable post-capture
                complete(image: image, screenRect: frame, displayID: nil)
            } catch {
                fail(error)
            }
        }
    }

    private func complete(image: CGImage, screenRect: CaptureRect?, displayID: CGDirectDisplayID?) {
        let result = CapturedImageResult(
            image: image,
            pixelSize: CaptureSize(width: CGFloat(image.width), height: CGFloat(image.height)),
            screenRect: screenRect,
            displayID: displayID
        )
        onCaptureCompleted?(result)
    }

    private func fail(_ error: Error) {
        if case CapturePermissionError.permissionDenied(.screenRecording) = error {
            onScreenRecordingPermissionDenied?()
            return
        }
        logger.error("Capture failed: \(String(describing: error))")
        onCaptureFailed?(error)
    }

    // MARK: - Permission

    /// Requests Screen Recording permission the first time a capture action
    /// is actually invoked (never at launch — `docs/PERMISSIONS.md`).
    /// Returns `false` (and fires `onScreenRecordingPermissionDenied`)
    /// without presenting the overlay if permission is missing after the
    /// request, so the overlay never arms over a capture that can't
    /// succeed.
    @discardableResult
    private func ensurePermission() -> Bool {
        if ScreenCaptureEngine.hasScreenRecordingPermission() { return true }
        ScreenCaptureEngine.requestScreenRecordingPermission()
        if ScreenCaptureEngine.hasScreenRecordingPermission() { return true }
        onScreenRecordingPermissionDenied?()
        return false
    }

    private func primaryDisplayID(containing rect: CaptureRect) -> CGDirectDisplayID? {
        NSScreen.screens.first { CaptureRect(cgRect: $0.frame).intersects(rect) }?.capture_displayID
    }
}

private extension NSScreen {
    var capture_displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
