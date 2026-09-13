import AppKit
import CoreGraphics
import CaptureCore
import Foundation

/// Real `WindowGeometryProviding` backed by Quartz Window Services
/// (`CGWindowListCopyWindowInfo`) for window enumeration/hit-testing and
/// `NSScreen` for display frames. Not unit-testable in this sandbox (no
/// live display/window server) — kept intentionally thin, with all actual
/// branching logic living in the pure `CaptureInteractionReducer` and the
/// (also-tested) coordinate conversion helper below.
///
/// COORDINATE SPACES — the one genuinely tricky part of this file:
/// `CGWindowListCopyWindowInfo`'s `kCGWindowBounds` is in Quartz's global
/// display coordinate space: origin at the top-left of the primary
/// display, Y increasing downward. `NSScreen.frame`/`NSEvent` locations are
/// in AppKit's space: origin at the bottom-left of the primary display, Y
/// increasing upward. Every frame this provider returns is converted to
/// AppKit's space (`flippedToAppKit`) so callers — ultimately fed by
/// `NSEvent`-derived points in `CaptureUI` — never have to think about the
/// distinction. Multi-display setups keep this simple because only the
/// *primary* display's height is needed for the flip (secondary displays'
/// origins are already relative to it in both spaces).
public final class LiveWindowGeometryProvider: WindowGeometryProviding {
    private let ownProcessID = pid_t(ProcessInfo.processInfo.processIdentifier)
    /// Quartz "normal" window layer; excludes the menu bar, Dock, and other
    /// system chrome layers that shouldn't be offered as capture targets.
    private let normalWindowLayer: Int32 = 0

    public init() {}

    public func window(at point: CapturePoint) -> (id: CaptureWindowToken, frame: CaptureRect)? {
        // Front-to-back order from CGWindowListCopyWindowInfo is already
        // on-screen-order (frontmost first) when no window-relative option
        // is supplied, so the first geometric hit is the topmost window.
        for entry in enumerateWindows() where entry.frame.cgRect.contains(CGPoint(x: point.x, y: point.y)) {
            return (entry.id, entry.frame)
        }
        return nil
    }

    public func allWindowFrames() -> [CaptureRect] {
        enumerateWindows().map(\.frame)
    }

    public func screenFrame(containing point: CapturePoint) -> CaptureRect {
        let cgPoint = CGPoint(x: point.x, y: point.y)
        let screen = NSScreen.screens.first { $0.frame.contains(cgPoint) } ?? NSScreen.main
        guard let frame = screen?.frame else { return .zero }
        return CaptureRect(cgRect: frame)
    }

    // MARK: Private

    private func enumerateWindows() -> [(id: CaptureWindowToken, frame: CaptureRect)] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] else {
            return []
        }

        var results: [(id: CaptureWindowToken, frame: CaptureRect)] = []
        results.reserveCapacity(rawList.count)

        for entry in rawList {
            guard let layer = entry[kCGWindowLayer as String] as? Int32, layer == normalWindowLayer else { continue }
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t, ownerPID != ownProcessID else { continue }
            guard let windowNumber = entry[kCGWindowNumber as String] as? UInt32 else { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? CFDictionary else { continue }
            guard let cgBounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }

            let appKitRect = Self.flippedToAppKit(cgBounds, primaryScreenHeight: primaryHeight)
            results.append((id: windowNumber, frame: CaptureRect(cgRect: appKitRect)))
        }
        return results
    }

    /// Converts a Quartz-space rect (origin top-left of the primary
    /// display, Y down) to AppKit space (origin bottom-left of the primary
    /// display, Y up).
    static func flippedToAppKit(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryScreenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
