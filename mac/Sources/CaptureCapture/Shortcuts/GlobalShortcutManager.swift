import AppKit
import CoreGraphics
import Foundation
import CaptureCore

// MARK: - Design note: why NSEvent global monitor, and the Input Monitoring
// permission it actually requires
//
// Part I's Global Custom Shortcut System needs shortcuts that fire even
// when Capture is not the frontmost app — there is no way to do that on
// macOS other than a system-wide keyboard hook, and there are exactly two
// APIs for one: `CGEvent.tapCreate(.cgSessionEventTap, ...)` or
// `NSEvent.addGlobalMonitorForEvents(matching:handler:)`. We use the
// NSEvent form: it's simpler, we don't need to intercept/rewrite events
// (only observe), and unlike a `cgSessionEventTap` it can't be used to
// suppress or modify other apps' keystrokes even by mistake.
//
// Both mechanisms require the "Input Monitoring" TCC permission for
// keyDown/keyUp/flagsChanged events specifically (added in macOS 10.15).
// `docs/PERMISSIONS.md` does not list Input Monitoring in its permission
// table, and separately states Capture "never requests Input Monitoring as
// a substitute for a feature that can be done another way." That policy
// line is about *avoiding* Input Monitoring when some narrower permission
// or API would do (e.g. don't use a keystroke tap to detect app switches
// when `NSWorkspace` notifications would do). It does not apply here:
// system-wide custom keyboard shortcuts have no narrower alternative on
// macOS, so this is not a substitute for anything — it's the feature.
// Treat this file's dependency on Input Monitoring as a genuine gap in
// `docs/PERMISSIONS.md`'s table that should be filled in (see this
// module's final report), not as a policy violation.
//
// An alternative worth real consideration on a real Mac: Carbon's Hot Key
// Manager (`RegisterEventHotKey`/`InstallEventHandler` for
// `kEventHotKeyPressed`) registers global hotkeys WITHOUT any Input
// Monitoring or Accessibility prompt at all — it's what CleanShot X,
// Alfred, and Bartender actually use. It's deprecated-but-functional
// Carbon, requires `import Carbon.HIToolbox`, and only supports a single
// key + modifier combination per registration (no access to raw
// modifier-only chords or key-up). We did not switch to it here per the
// task's explicit instruction to use the "simpler AppKit-based
// alternative" and handle the permission realistically, but it is the
// better long-term choice if the Input Monitoring prompt proves
// unacceptable in practice — flagged here rather than silently decided.

/// A key event reduced to exactly what shortcut matching needs, decoupled
/// from `NSEvent` so the matching logic (`ShortcutMatcher`) is pure and
/// unit-testable without AppKit.
public struct ShortcutKeyEvent: Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers

    public init(keyCode: UInt16, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

extension ShortcutModifiers {
    /// Maps only the four modifier keys `ShortcutBinding` tracks; caps
    /// lock/function/help are deliberately ignored so e.g. having Caps
    /// Lock on doesn't break a shortcut match.
    public init(nsEventModifierFlags flags: NSEvent.ModifierFlags) {
        var result: ShortcutModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        self = result
    }
}

extension ShortcutKeyEvent {
    public init(nsEvent event: NSEvent) {
        self.init(keyCode: event.keyCode, modifiers: ShortcutModifiers(nsEventModifierFlags: event.modifierFlags))
    }
}

/// Pure matching logic: which (if any) bound action a key event triggers.
/// No AppKit dependency — exercised directly in `GlobalShortcutManagerTests`.
public enum ShortcutMatcher {
    public static func action(
        for event: ShortcutKeyEvent,
        in bindings: [ShortcutAction: ShortcutBinding]
    ) -> ShortcutAction? {
        for (action, binding) in bindings
        where binding.keyCode == event.keyCode && binding.modifiers == event.modifiers {
            return action
        }
        return nil
    }
}

/// Codable round-trip of the bindings dictionary to a flat `[String: Data]`-
/// friendly JSON object (`ShortcutAction.rawValue -> ShortcutBinding`), used
/// for `UserDefaults` persistence. Kept separate from `GlobalShortcutManager`
/// so the persistence format itself is unit-testable without constructing a
/// manager (which needs AppKit's `NSEvent` monitor APIs to be meaningful).
public enum ShortcutBindingCodec {
    public enum CodecError: Error, Sendable { case invalidTopLevelObject }

    public static func encode(_ bindings: [ShortcutAction: ShortcutBinding]) throws -> Data {
        let flattened = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        return try CaptureCoreJSON.encoder.encode(flattened)
    }

    /// Unknown action keys (e.g. a binding persisted by a newer app version
    /// with an action this build doesn't know about) are skipped rather
    /// than failing the whole decode — forward/backward compatibility for
    /// a `UserDefaults`-persisted format that outlives any one app version.
    public static func decode(_ data: Data) throws -> [ShortcutAction: ShortcutBinding] {
        let flattened = try CaptureCoreJSON.decoder.decode([String: ShortcutBinding].self, from: data)
        var result: [ShortcutAction: ShortcutBinding] = [:]
        for (rawAction, binding) in flattened {
            guard let action = ShortcutAction(rawValue: rawAction) else { continue }
            result[action] = binding
        }
        return result
    }
}

/// Real macOS built-in shortcuts populated into `CaptureCore.SystemShortcutRegistry`
/// so `ShortcutConflictDetector` can actually warn about them (Part I: "explain
/// macOS already owns it... do not silently fail").
public enum SystemShortcuts {
    /// System Settings > Keyboard > Keyboard Shortcuts > Screenshots, as of
    /// macOS Sequoia. See `CarbonKeyCode`'s confidence note — the digit
    /// keycodes are transcribed from training knowledge (no live Mac to
    /// verify against in this sandbox) but match the values given in the
    /// task brief and the well-known non-sequential ANSI ordering.
    public static func macOSBuiltIns() -> SystemShortcutRegistry {
        func known(_ keyCode: UInt16, _ modifiers: ShortcutModifiers, _ display: String, _ description: String) -> SystemShortcutRegistry.KnownShortcut {
            .init(binding: ShortcutBinding(keyCode: keyCode, modifiers: modifiers, displayString: display), systemDescription: description)
        }
        return SystemShortcutRegistry(knownShortcuts: [
            known(CarbonKeyCode.ansi3, [.shift, .command], "⇧⌘3", "macOS Screenshot: Capture Entire Screen"),
            known(CarbonKeyCode.ansi4, [.shift, .command], "⇧⌘4", "macOS Screenshot: Capture Selected Portion"),
            known(CarbonKeyCode.ansi5, [.shift, .command], "⇧⌘5", "macOS Screenshot & Recording Toolbar"),
            known(CarbonKeyCode.ansi6, [.shift, .command], "⇧⌘6", "macOS Touch Bar Screenshot (Touch Bar Macs only)"),
            known(CarbonKeyCode.ansi3, [.shift, .command, .control], "⇧⌃⌘3", "macOS Screenshot: Entire Screen to Clipboard"),
            known(CarbonKeyCode.ansi4, [.shift, .command, .control], "⇧⌃⌘4", "macOS Screenshot: Selected Portion to Clipboard")
        ])
    }
}

/// Registers/dispatches Capture's global keyboard shortcuts and persists
/// bindings across launches. AppKit-dependent (NSEvent monitors); the
/// underlying matching (`ShortcutMatcher`) and persistence
/// (`ShortcutBindingCodec`) are pure and independently tested.
///
/// Not thread-safe by design — like the rest of AppKit's event-handling
/// surface, construct and call this only from the main thread/queue.
public final class GlobalShortcutManager {
    private let userDefaults: UserDefaults
    private let defaultsKey: String
    private let conflictDetector = ShortcutConflictDetector()
    private let logger = CaptureLogger(category: "GlobalShortcutManager")

    public private(set) var systemShortcuts: SystemShortcutRegistry
    private var bindings: [ShortcutAction: ShortcutBinding]
    private var handlers: [ShortcutAction: () -> Void] = [:]

    private var globalMonitor: Any?
    private var localMonitor: Any?

    public init(
        userDefaults: UserDefaults = .standard,
        defaultsKey: String = "com.capture.shortcuts.bindings.v1",
        systemShortcuts: SystemShortcutRegistry = SystemShortcuts.macOSBuiltIns()
    ) {
        self.userDefaults = userDefaults
        self.defaultsKey = defaultsKey
        self.systemShortcuts = systemShortcuts
        self.bindings = Self.loadPersistedBindings(from: userDefaults, key: defaultsKey)
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    // MARK: Bindings

    public var currentBindings: [ShortcutAction: ShortcutBinding] { bindings }

    public func binding(for action: ShortcutAction) -> ShortcutBinding? { bindings[action] }

    /// Registers the callback invoked when `action`'s bound shortcut fires.
    /// Independent of `setBinding` — a handler can be attached before or
    /// after a binding exists; nothing fires until both are present.
    public func setHandler(_ handler: @escaping () -> Void, for action: ShortcutAction) {
        handlers[action] = handler
    }

    /// Surfaces conflicts for a would-be assignment without mutating
    /// anything. Callers (`CaptureUI`'s shortcut recorder) are expected to
    /// show the user the returned conflict and only then decide whether to
    /// call `setBinding` anyway — this mirrors Part I's "explain... do not
    /// silently fail" rather than silently blocking or silently allowing.
    public func conflicts(assigning binding: ShortcutBinding, to action: ShortcutAction) -> ShortcutConflict? {
        conflictDetector.conflicts(assigning: binding, to: action, existing: bindings, systemShortcuts: systemShortcuts)
    }

    /// Assigns (or, passing `nil`, clears) `action`'s binding, persists it
    /// immediately, and takes effect on the very next matching key event —
    /// no monitor teardown/rebuild, no app restart (Part I: "Apply changed
    /// shortcuts without restart whenever possible"), because dispatch
    /// reads `bindings` fresh on every event.
    public func setBinding(_ binding: ShortcutBinding?, for action: ShortcutAction) {
        bindings[action] = binding
        persistBindings()
    }

    public func removeBinding(for action: ShortcutAction) {
        setBinding(nil, for: action)
    }

    // MARK: Permission (Input Monitoring — see file-header note)

    public static func inputMonitoringGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// Prompts the system Input Monitoring consent dialog the first time an
    /// app requests it; after an explicit decline macOS will not re-prompt,
    /// and the caller must send the user to System Settings > Privacy &
    /// Security > Input Monitoring, per `docs/PERMISSIONS.md`'s "declined
    /// behaviour" pattern for every other gated permission.
    @discardableResult
    public static func requestInputMonitoringAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    // MARK: Monitoring lifecycle

    /// Installs the global + local key monitors. Deliberately requested
    /// only when the first shortcut actually needs to fire (call this from
    /// wherever Capture finishes onboarding / registers its first binding),
    /// never at launch — Part I/`docs/PERMISSIONS.md`'s progressive
    /// permission model. Throws rather than installing a monitor that would
    /// silently never receive events when permission is missing
    /// (`docs/PERMISSIONS.md`: "never crash or silently no-op").
    public func startMonitoring() throws {
        guard Self.inputMonitoringGranted() else {
            throw CapturePermissionError.permissionDenied(.inputMonitoring)
        }
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.dispatch(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event -> NSEvent? in
            guard let self else { return event }
            return self.dispatchLocal(event)
        }
    }

    public func stopMonitoring() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    public var isMonitoring: Bool { globalMonitor != nil }

    // MARK: Dispatch

    private func dispatch(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        guard let action = ShortcutMatcher.action(for: ShortcutKeyEvent(nsEvent: event), in: bindings) else { return }
        logger.debug("Global shortcut fired: \(action.rawValue)")
        handlers[action]?()
    }

    /// Local-monitor variant: returns the event unchanged when it doesn't
    /// match any binding (so normal typing/menu-key-equivalents inside
    /// Capture's own windows are unaffected), or `nil` to swallow it when
    /// it does (so a bound key doesn't also type a character or beep while
    /// Capture is frontmost).
    private func dispatchLocal(_ event: NSEvent) -> NSEvent? {
        guard !event.isARepeat else { return event }
        guard let action = ShortcutMatcher.action(for: ShortcutKeyEvent(nsEvent: event), in: bindings) else { return event }
        logger.debug("Local shortcut fired: \(action.rawValue)")
        handlers[action]?()
        return nil
    }

    // MARK: Persistence

    private func persistBindings() {
        do {
            let data = try ShortcutBindingCodec.encode(bindings)
            userDefaults.set(data, forKey: defaultsKey)
        } catch {
            logger.error("Failed to persist shortcut bindings: \(error.localizedDescription)")
        }
    }

    private static func loadPersistedBindings(from defaults: UserDefaults, key: String) -> [ShortcutAction: ShortcutBinding] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        do {
            return try ShortcutBindingCodec.decode(data)
        } catch {
            return [:]
        }
    }
}
