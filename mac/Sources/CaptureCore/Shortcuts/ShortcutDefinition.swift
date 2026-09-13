import Foundation

/// The Global Custom Shortcut System (Part I, "core requirement"). Every
/// action listed in the spec is remappable; `CaptureCapture`'s
/// `GlobalShortcutManager` registers the actual `CGEvent` global monitor per
/// binding using these pure-logic types for storage/conflict-detection so
/// that logic is unit-testable without AppKit/Carbon.
public enum ShortcutAction: String, Codable, Sendable, CaseIterable {
    case captureArea, captureWindow, captureFullScreen, captureRepeatArea, captureScrolling
    case captureBrowserElement, captureMultipleAddToTray, appendCaptureToCanvas
    case startStopRecording, recordWindow, recordArea
    case ocrRegion, inspectElement, pixelMeasure, colourPicker
    case openEditor, openHistory, openCaptureTray, pinLastCapture
    case delayedCapture, toggleInspectMode, commandPalette

    /// Human-readable label for Settings > Shortcuts.
    public var displayName: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureWindow: return "Capture Window"
        case .captureFullScreen: return "Capture Full Screen"
        case .captureRepeatArea: return "Capture Repeat Area"
        case .captureScrolling: return "Capture Scrolling"
        case .captureBrowserElement: return "Capture Browser Element"
        case .captureMultipleAddToTray: return "Capture Multiple / Add to Capture Tray"
        case .appendCaptureToCanvas: return "Append Capture to Current Canvas"
        case .startStopRecording: return "Start/Stop Recording"
        case .recordWindow: return "Record Window"
        case .recordArea: return "Record Area"
        case .ocrRegion: return "OCR Region"
        case .inspectElement: return "Inspect Element"
        case .pixelMeasure: return "Pixel Measure"
        case .colourPicker: return "Colour Picker"
        case .openEditor: return "Open Editor"
        case .openHistory: return "Open History"
        case .openCaptureTray: return "Open Capture Tray"
        case .pinLastCapture: return "Pin Last Capture"
        case .delayedCapture: return "Delayed Capture"
        case .toggleInspectMode: return "Toggle Inspect Mode"
        case .commandPalette: return "Command Palette"
        }
    }
}

/// Modifier flags stored as a plain `OptionSet` so this type has no Carbon/
/// AppKit dependency; `CaptureCapture` maps to/from `NSEvent.ModifierFlags`.
public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let control = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift = ShortcutModifiers(rawValue: 1 << 3)
}

/// A key binding: a virtual keycode (macOS `CGKeyCode` numeric space) plus
/// modifiers. Stored as a plain integer rather than importing Carbon's
/// keycode constants here.
public struct ShortcutBinding: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers
    /// Human-readable form for display, e.g. "⇧⌘4" — computed by the UI
    /// layer from `keyCode`/`modifiers`; stored redundantly here only for
    /// diagnostics/logging where AppKit's key-code-to-glyph tables aren't
    /// available.
    public var displayString: String?

    public init(keyCode: UInt16, modifiers: ShortcutModifiers, displayString: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayString = displayString
    }
}

/// macOS's own built-in screenshot shortcuts, keyed by the same
/// `(keyCode, modifiers)` the recorder captures, so we can warn a user who
/// assigns e.g. Shift-Command-4 without silently failing (Part I: "explain
/// macOS already owns it... Do not silently fail").
public struct SystemShortcutRegistry {
    public struct KnownShortcut: Sendable {
        public var binding: ShortcutBinding
        public var systemDescription: String
    }

    /// Populated by `CaptureUI` at app launch with the actual keycodes for
    /// digit keys 3/4/5/6 + Shift+Command(+Control), since keycodes are a
    /// Carbon/AppKit concern this layer avoids hardcoding.
    public var knownShortcuts: [KnownShortcut]

    public init(knownShortcuts: [KnownShortcut] = []) {
        self.knownShortcuts = knownShortcuts
    }

    public func conflict(for binding: ShortcutBinding) -> String? {
        knownShortcuts.first { $0.binding == binding }?.systemDescription
    }
}

public enum ShortcutConflict: Sendable {
    case anotherCaptureAction(ShortcutAction)
    case systemShortcut(description: String)
}

/// Pure conflict-detection logic (Part I: "Detect conflicts with: another
/// Capture shortcut; known common macOS shortcuts where feasible; built-in
/// screenshot shortcuts when the user assigns the same combination").
public struct ShortcutConflictDetector {
    public init() {}

    public func conflicts(
        assigning binding: ShortcutBinding,
        to action: ShortcutAction,
        existing bindings: [ShortcutAction: ShortcutBinding],
        systemShortcuts: SystemShortcutRegistry
    ) -> ShortcutConflict? {
        for (otherAction, otherBinding) in bindings where otherAction != action {
            if otherBinding == binding {
                return .anotherCaptureAction(otherAction)
            }
        }
        if let systemDescription = systemShortcuts.conflict(for: binding) {
            return .systemShortcut(description: systemDescription)
        }
        return nil
    }
}
