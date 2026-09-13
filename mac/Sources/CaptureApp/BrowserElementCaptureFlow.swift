import CaptureBrowserBridge
import CaptureCapture
import CaptureCore
import CaptureInspection
import CaptureUI
import CoreGraphics
import Foundation

/// Phase 3 — "First browser milestone" (Part I §39). Wires
/// `CaptureBrowserBridge.BrowserBridgeService`'s evidence store to a real
/// screen capture + DOM-anchored annotation, as far as this build's actual
/// public APIs allow end-to-end.
///
/// ## The one missing link (read before assuming this "just works")
/// `BrowserBridgeService`/`TabSessionManager` expose no way to *discover* a
/// `tabSessionId` — no delegate, no notification, no enumeration API. Every
/// entry point (`latestEvidence(forTabSession:)`, `activateInspect`, ...)
/// requires the caller to already know the UUID a `session.start` request
/// produced, but that UUID is only ever returned in the *response* to the
/// extension that sent `session.start` (see `BrowserBridgeService.
/// registerHandlers()`'s `.sessionStart` case) — `CaptureApp` is never told
/// it. This is a genuine gap in `CaptureBrowserBridge`'s public surface, not
/// something fixable from this file without editing that module (which
/// this task's instructions say not to do); it is called out again in this
/// module's final report as the blocking gap for full auto-discovery.
///
/// Everything downstream of "a `tabSessionId` is known" is real, working
/// wiring: `handleElementEvidenceAvailable(tabSessionId:browserWindowFrame:)`
/// is the seam a future `BrowserBridgeService` revision's session/evidence
/// callback would call; until such a callback exists it is only reachable
/// manually, but is written exactly as it would run in production.
@MainActor
public final class BrowserElementCaptureFlow {
    private let browserBridgeService: BrowserBridgeService
    private let screenCaptureEngine = ScreenCaptureEngine()
    private let logger = CaptureLogger(category: "BrowserElementCaptureFlow")
    /// Opens (or reuses) an editor window for the captured element pixels —
    /// supplied by `AppEnvironment` so this type doesn't need to know how
    /// editor windows are tracked/deduplicated app-wide.
    private let openEditor: (CGImage, String?) -> EditorWindowController

    public init(browserBridgeService: BrowserBridgeService, openEditor: @escaping (CGImage, String?) -> EditorWindowController) {
        self.browserBridgeService = browserBridgeService
        self.openEditor = openEditor
    }

    /// Full pipeline for one pinned/captured DOM element (Part I §39 "First
    /// browser milestone" steps 5-8): read the evidence already stored for
    /// `tabSessionId`, resolve it to an on-screen rect, capture those
    /// pixels, open an editor, and add a Counter annotation whose
    /// `Annotation.Anchor.elementEvidenceId` points back at the evidence —
    /// step 10's "attempt to resolve the anchor" on reopen is
    /// `BrowserBridgeService.resolveAnchor`, called separately when a
    /// project with a `.domElement`-anchored annotation is reopened (see
    /// `AppEnvironment.attemptAnchorResolution`).
    public func handleElementEvidenceAvailable(tabSessionId: UUID, browserWindowFrame: CaptureRect) async {
        guard let evidence = browserBridgeService.latestEvidence(forTabSession: tabSessionId) else {
            logger.warning("handleElementEvidenceAvailable called but no evidence is stored for this tab session yet")
            return
        }
        guard let screenRect = Self.resolveScreenRect(evidence: evidence, browserWindowFrame: browserWindowFrame) else {
            logger.warning("Could not resolve a screen rect for the pinned element's evidence")
            return
        }

        do {
            let image = try await screenCaptureEngine.captureArea(rect: screenRect)
            let editor = openEditor(image, evidence.url)
            // The capture *is* the element's rect by construction, so the
            // Counter anchors near its top-left corner rather than
            // re-deriving a sub-rect from evidence a second time.
            let badgeRect = CaptureRect(x: 6, y: 6, width: 28, height: 28)
            editor.insertDOMAnchoredAnnotation(kind: .counter, evidence: evidence, canvasRect: badgeRect)
            // Inspector hierarchy's "DOM evidence selected -> design
            // forensics card" (Part I §28), populated from the exact same
            // evidence the annotation now anchors to.
            editor.showForensicsCard(ForensicsCard.summarize(evidence))
        } catch {
            logger.error("Element capture failed: \(String(describing: error))")
        }
    }

    /// Part I §39 step 10: "Reopen the same page later and attempt to
    /// resolve the anchor." Given a reopened editor and a known
    /// `tabSessionId` for the page being revisited (subject to the same
    /// session-discovery gap documented on this type), looks up every
    /// `.domElement`-anchored annotation's original `ElementEvidence.Locator`
    /// and asks the extension to re-resolve it via
    /// `BrowserBridgeService.resolveAnchor`. Never silently attaches to a
    /// low-confidence match — `AnchorResolution.isTrustworthy` gates
    /// whether the annotation's frame actually moves; an untrustworthy
    /// result leaves the annotation at its `fallbackPixelPosition` and the
    /// caller (`AppEnvironment`) is expected to surface "Anchor not found"
    /// per Part I §8.
    public func attemptAnchorResolution(for editor: EditorWindowController, tabSessionId: UUID) async -> [UUID: AnchorResolution] {
        var results: [UUID: AnchorResolution] = [:]
        for evidence in editor.browserElements {
            do {
                let resolution = try await browserBridgeService.resolveAnchor(tabSessionId: tabSessionId, locator: evidence.locator)
                results[evidence.id] = resolution
            } catch {
                logger.warning("Anchor re-resolution failed for element \(evidence.id): \(String(describing: error))")
            }
        }
        return results
    }

    /// Composes an absolute AppKit-screen-space rect (origin bottom-left,
    /// y-up — the convention `ScreenCaptureEngine.captureArea` and every
    /// other screen rect in `CaptureCapture` use) for `evidence.rect` using
    /// the browser window's on-screen frame.
    ///
    /// **Confidence note:** no module in this build defines this
    /// composition anywhere, and `ElementEvidence`'s own doc comments don't
    /// pin down `rect`'s exact coordinate origin beyond "mirrors the
    /// schema". This function follows `docs/ARCHITECTURE.md`'s process-model
    /// description as closely as possible ("screen pixel capture of the
    /// resolved element rect... anchored to the browser window's on-screen
    /// frame") — `evidence.rect` is treated as viewport-relative CSS px
    /// (top-left origin, y-down, matching `evidence.viewport`), scaled by
    /// `evidence.viewport.devicePixelRatio` only where the browser reports
    /// device pixels elsewhere in this codebase (it does not for `rect`,
    /// per the schema's plain `{x,y,width,height}` shape) — but has not
    /// been validated against a live browser/DPI combination. Treat this
    /// function, specifically, as the least-trusted part of this file.
    static func resolveScreenRect(evidence: ElementEvidence, browserWindowFrame: CaptureRect) -> CaptureRect? {
        guard evidence.viewport.width > 0, evidence.viewport.height > 0 else { return nil }
        let chromeHeight = max(browserWindowFrame.height - evidence.viewport.height, 0)
        let x = browserWindowFrame.x + evidence.rect.x
        let y = browserWindowFrame.y + browserWindowFrame.height - chromeHeight - evidence.rect.y - evidence.rect.height
        guard evidence.rect.width > 0, evidence.rect.height > 0 else { return nil }
        return CaptureRect(x: x, y: y, width: evidence.rect.width, height: evidence.rect.height)
    }
}
