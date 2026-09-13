import Foundation

/// Typed permission failures for `CaptureCapture` (docs/PERMISSIONS.md:
/// "returns a typed `.permissionDenied` error ... no capture is silently
/// skipped or faked"). Every entry point that touches a gated macOS
/// capability throws one of these rather than crashing or returning a
/// placeholder image.
public enum CapturePermissionKind: String, Sendable {
    case screenRecording
    case accessibility
    case microphone
    case camera
    /// TCC's "Input Monitoring" bucket. NOT listed in docs/PERMISSIONS.md's
    /// permission table — see `GlobalShortcutManager`'s file-header comment
    /// for why global keyboard shortcuts need it and why that isn't
    /// actually in tension with the "never request Input Monitoring as a
    /// substitute for a feature that can be done another way" policy.
    case inputMonitoring
}

public enum CapturePermissionError: Error, Sendable, Equatable {
    /// The permission has not been granted. `CaptureUI` is responsible for
    /// showing the "Open System Settings" prompt described in
    /// docs/PERMISSIONS.md — this module never shows UI itself.
    case permissionDenied(CapturePermissionKind)

    /// The permission's authorization state could not be determined (e.g.
    /// TCC query failed). Treated the same as denied by callers: never
    /// silently proceed as if granted.
    case permissionIndeterminate(CapturePermissionKind)
}

extension CapturePermissionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .permissionDenied(let kind):
            return "Capture: \(kind.rawValue) permission is not granted."
        case .permissionIndeterminate(let kind):
            return "Capture: \(kind.rawValue) permission state could not be determined."
        }
    }
}

/// Errors specific to the ScreenCaptureKit-backed capture engine, distinct
/// from permission failures so callers can branch on "ask for permission"
/// vs. "retry" vs. "give up and report".
public enum ScreenCaptureEngineError: Error, Sendable, Equatable {
    /// `SCShareableContent` did not include the requested display.
    case displayNotFound
    /// `SCShareableContent` did not include the requested window (it may
    /// have been closed between selection and capture).
    case windowNotFound
    /// The requested area rect did not intersect the source image after
    /// crop — e.g. a stale Repeat Area region from a display that has
    /// since been reconfigured.
    case emptyCaptureRegion
    /// `SCScreenshotManager`/`SCStream` returned no image data.
    case captureProducedNoImage
    /// Wraps an underlying `Error` from ScreenCaptureKit that doesn't fit
    /// the cases above; `localizedDescription` of the underlying error is
    /// captured as a plain string since `Error` itself is not `Equatable`.
    case underlying(String)
}
