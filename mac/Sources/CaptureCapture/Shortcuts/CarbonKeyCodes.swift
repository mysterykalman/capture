import Foundation

/// Hand-transcribed subset of Carbon HIToolbox's `Events.h` virtual keycode
/// constants (`kVK_*`). We avoid `import Carbon` for just a handful of
/// integer constants so this module doesn't pull in the (deprecated, but
/// still the only source of these values) Carbon umbrella framework only
/// for named constants; the raw values below are the standard ANSI-US
/// physical-key-position keycodes, stable across all Mac keyboard layouts
/// (they identify a physical key, not the character it currently types).
///
/// CONFIDENCE NOTE: transcribed from training-data knowledge, not verified
/// against a live `HIToolbox.framework` header in this sandbox (no Xcode
/// available — see docs/ARCHITECTURE.md's "Critical environment
/// constraint"). The digit-key values are internally consistent with the
/// well-known non-sequential ANSI ordering (3/4/6/5 are NOT numerically
/// sequential because they encode physical key position, not the digit)
/// and match the values the task brief itself specified for 3/4/5/6.
/// `Escape` and `Space` are extremely well-established, low-risk values.
/// Before shipping, cross-check every value here against
/// `/System/Library/Frameworks/Carbon.framework/.../Events.h` on a real Mac.
enum CarbonKeyCode {
    static let ansi3: UInt16 = 0x14   // kVK_ANSI_3 = 20
    static let ansi4: UInt16 = 0x15   // kVK_ANSI_4 = 21
    static let ansi5: UInt16 = 0x17   // kVK_ANSI_5 = 23
    static let ansi6: UInt16 = 0x16   // kVK_ANSI_6 = 22

    static let escape: UInt16 = 0x35  // kVK_Escape = 53
    static let space: UInt16 = 0x31   // kVK_Space = 49
}
