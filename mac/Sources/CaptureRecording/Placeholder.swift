import Foundation

/// `CaptureRecording` is Phase 5 in the spec's own phase sequencing (Part I
/// §32) — screen/window/area video recording, structured cursor/click/
/// keystroke event tracks, auto/manual zoom, trim/cut, GIF export. This
/// build deliberately stopped at Phase 0-3 (see `docs/IMPLEMENTATION_STATUS.md`
/// for why) and this module is **not implemented**.
///
/// This file exists only so the `CaptureRecording` SwiftPM target (declared
/// in `mac/Package.swift`, matching the spec's repository layout) has at
/// least one source file — an empty target directory fails `swift build`
/// outright. Do not build UI or wiring against this module until real
/// recording capability is implemented here.
public enum CaptureRecordingModule {
    public static let isImplemented = false
}
