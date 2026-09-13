import AppKit
import CaptureCore
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - Confidence note (read before trusting the ScreenCaptureKit calls
// below on a real Mac)
//
// This file is unverified: no Swift toolchain/Xcode is available in this
// sandbox (docs/ARCHITECTURE.md's "Critical environment constraint"), so
// none of the ScreenCaptureKit API usage below has been compiled, let alone
// run. Confidence by API surface, high to low:
//   - `SCShareableContent.excludingDesktopWindows(_:onScreenWindowsOnly:)`,
//     `SCContentFilter(display:excludingWindows:)`,
//     `SCContentFilter(desktopIndependentWindow:)`, `SCStreamConfiguration`
//     `width`/`height`/`showsCursor`, `SCDisplay.displayID`/`.width`/
//     `.height`/`.frame`, `SCWindow.windowID`/`.frame` — all long-standing
//     (macOS 12.3+) ScreenCaptureKit API, high confidence.
//   - `SCScreenshotManager.captureImage(contentFilter:configuration:)` —
//     the macOS 14+ one-shot-screenshot API the task brief itself named;
//     high confidence on the method existing and its throwing-async shape,
//     but not independently verified here.
//   - `SCStreamConfiguration.ignoreShadowsSingleWindow` — a macOS 14 SDK
//     addition for exactly the "window capture without shadow" case this
//     file needs. Medium confidence on this *exact* property name; it is
//     the name matching the corresponding WWDC23 ScreenCaptureKit session
//     material as best recalled. **Verify this symbol against the real
//     SDK header (`ScreenCaptureKit/SCStreamConfiguration.h`) before
//     relying on it** — if the name is wrong the file will fail to
//     compile at exactly this line, not silently misbehave.
// Area capture deliberately avoids `SCStreamConfiguration.sourceRect`
// (which the task brief flagged as an option) in favor of capturing the
// full display and cropping the resulting `CGImage` ourselves: `sourceRect`
// exists, but its exact origin convention (top-left vs. bottom-left) was
// not something this sandbox could verify against a live SCK build, while
// `CGImage` pixel space is unambiguously top-left/Y-down, so the crop path
// only depends on `SCDisplay.frame`'s well-documented coordinate space.

/// Which display(s) a full-screen or area capture targets.
public enum CaptureDisplaySelection: Sendable, Equatable {
    case main
    case display(CGDirectDisplayID)
    case all
}

/// Wraps `SCShareableContent`/`SCScreenshotManager` to implement Part I/
/// `01_capture_engine.md`'s still-capture modes: full-screen (one display /
/// all displays, cursor include/exclude), window (with/without shadow),
/// and area (crop of a full-display capture). Returns `CGImage`; callers
/// needing `NSImage` (e.g. for clipboard/preview) convert at the edge.
///
/// An `actor` rather than a plain class: `SCShareableContent`/
/// `SCScreenshotManager` calls are all `async`, and serializing engine
/// calls avoids two concurrent capture requests racing macOS's own
/// screen-capture daemon.
public actor ScreenCaptureEngine {
    public init() {}

    // MARK: Permission (docs/PERMISSIONS.md: "requested when first capture
    // action is invoked" — never at launch; never a silent no-op on denial)

    public static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompts the system Screen Recording consent dialog the first time;
    /// after an explicit decline macOS will not re-prompt and the caller
    /// must send the user to System Settings, per docs/PERMISSIONS.md.
    @discardableResult
    public static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: Full screen

    public func captureFullScreen(display selection: CaptureDisplaySelection = .main, includeCursor: Bool = false) async throws -> CGImage {
        try Self.ensurePermission()
        let content = try await Self.currentShareableContent()
        let target = try Self.resolveSingleDisplay(selection, in: content)
        return try await captureDisplayImage(target, includeCursor: includeCursor)
    }

    /// One image per connected display; Part I's "all displays" full-screen
    /// mode. Compositing these into one canvas (matching real display
    /// arrangement) is left to `CaptureEditor`'s assembly layer (Freeform
    /// Canvas/Grid layouts already cover that) rather than guessed at here
    /// — ScreenCaptureKit has no documented single-filter that spans
    /// multiple physical displays into one image.
    public func captureAllDisplays(includeCursor: Bool = false) async throws -> [(displayID: CGDirectDisplayID, image: CGImage)] {
        try Self.ensurePermission()
        let content = try await Self.currentShareableContent()
        guard !content.displays.isEmpty else { throw ScreenCaptureEngineError.displayNotFound }

        var results: [(displayID: CGDirectDisplayID, image: CGImage)] = []
        results.reserveCapacity(content.displays.count)
        for display in content.displays {
            let image = try await captureDisplayImage(display, includeCursor: includeCursor)
            results.append((display.displayID, image))
        }
        return results
    }

    // MARK: Window

    public func captureWindow(windowID: CaptureWindowToken, includeShadow: Bool = true) async throws -> CGImage {
        try Self.ensurePermission()
        let content = try await Self.currentShareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenCaptureEngineError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width.rounded()))
        configuration.height = max(1, Int(window.frame.height.rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = !includeShadow

        return try await Self.captureImage(filter: filter, configuration: configuration)
    }

    // MARK: Area

    /// `rect` is expected in AppKit screen-coordinate space (origin
    /// bottom-left of the primary display, Y up) — the space
    /// `AreaToWindowCaptureController`/`LiveWindowGeometryProvider` produce
    /// throughout this module.
    public func captureArea(rect: CaptureRect, display selection: CaptureDisplaySelection = .main, includeCursor: Bool = false) async throws -> CGImage {
        try Self.ensurePermission()
        guard rect.width > 0, rect.height > 0 else { throw ScreenCaptureEngineError.emptyCaptureRegion }

        let content = try await Self.currentShareableContent()
        let target = try Self.resolveSingleDisplay(selection, in: content)
        let fullImage = try await captureDisplayImage(target, includeCursor: includeCursor)

        // NSScreen.screens is read here on the actor's own executor, not
        // necessarily the main thread. Apple doesn't formally document
        // NSScreen property access as thread-safe, though reading (not
        // mutating) screen geometry off-main is common practice in
        // shipping apps. Flagged rather than silently assumed safe; a
        // more conservative version would hop to `@MainActor` for this
        // one read if problems surface in practice.
        guard let primaryScreenHeight = NSScreen.screens.first?.frame.height else {
            throw ScreenCaptureEngineError.emptyCaptureRegion
        }

        // `target.frame` (an `SCDisplay`'s frame) is documented in Quartz's
        // global display space (origin top-left of the primary display, Y
        // down) — the same space `LiveWindowGeometryProvider` converts
        // *out of* before returning frames to the rest of this module. We
        // convert `rect` back into that space here rather than change what
        // coordinate space the interaction layer works in, since AppKit/
        // NSEvent (and therefore the whole interactive selection UI) is
        // natively bottom-left/Y-up.
        let quartzRect = CGRect(
            x: rect.x,
            y: primaryScreenHeight - rect.y - rect.height,
            width: rect.width,
            height: rect.height
        )
        let displayLocalRect = CGRect(
            x: quartzRect.origin.x - target.frame.origin.x,
            y: quartzRect.origin.y - target.frame.origin.y,
            width: quartzRect.width,
            height: quartzRect.height
        )

        // `fullImage`'s pixel dimensions may exceed `target.frame`'s point
        // dimensions by the display's backing scale factor (Retina); scale
        // the crop rect from points to pixels accordingly.
        let scaleX = CGFloat(fullImage.width) / target.frame.width
        let scaleY = CGFloat(fullImage.height) / target.frame.height
        let pixelCropRect = CGRect(
            x: displayLocalRect.origin.x * scaleX,
            y: displayLocalRect.origin.y * scaleY,
            width: displayLocalRect.width * scaleX,
            height: displayLocalRect.height * scaleY
        ).integral

        let imageBounds = CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)
        let boundedCropRect = pixelCropRect.intersection(imageBounds)
        guard !boundedCropRect.isEmpty, let cropped = fullImage.cropping(to: boundedCropRect) else {
            throw ScreenCaptureEngineError.emptyCaptureRegion
        }
        return cropped
    }

    // MARK: Private

    private func captureDisplayImage(_ display: SCDisplay, includeCursor: Bool) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = includeCursor
        return try await Self.captureImage(filter: filter, configuration: configuration)
    }

    private static func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch let error as ScreenCaptureEngineError {
            throw error
        } catch {
            throw ScreenCaptureEngineError.underlying(error.localizedDescription)
        }
    }

    private static func currentShareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureEngineError.underlying(error.localizedDescription)
        }
    }

    private static func resolveSingleDisplay(_ selection: CaptureDisplaySelection, in content: SCShareableContent) throws -> SCDisplay {
        switch selection {
        case .main:
            if let main = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) {
                return main
            }
            guard let first = content.displays.first else { throw ScreenCaptureEngineError.displayNotFound }
            return first
        case .display(let id):
            guard let match = content.displays.first(where: { $0.displayID == id }) else {
                throw ScreenCaptureEngineError.displayNotFound
            }
            return match
        case .all:
            // Single-display call sites (captureFullScreen(display:.all),
            // captureArea) never reach here with `.all` in practice — area
            // capture on "all displays" isn't a meaningful single rect —
            // but resolve to the main display defensively rather than trap.
            return try resolveSingleDisplay(.main, in: content)
        }
    }

    private static func ensurePermission() throws {
        guard hasScreenRecordingPermission() else {
            throw CapturePermissionError.permissionDenied(.screenRecording)
        }
    }
}
