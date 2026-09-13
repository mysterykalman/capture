import AppKit
import CaptureCapture
import CaptureCore
import SwiftUI

/// Settings > Shortcuts (Part I "Global Custom Shortcut System" — a core,
/// explicit requirement). Every `ShortcutAction` gets a real
/// shortcut-recording control bound through `CaptureCapture.GlobalShortcutManager`'s
/// actual API (`binding(for:)`, `setBinding(_:for:)`, `conflicts(assigning:to:)`),
/// with conflict warnings surfaced inline rather than silently blocked or
/// silently allowed — matching "explain... do not silently fail".
public struct ShortcutsSettingsView: View {
    @ObservedObject var model: ShortcutsSettingsModel

    public init(model: ShortcutsSettingsModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !model.inputMonitoringGranted {
                    inputMonitoringBanner
                }
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    ShortcutRow(action: action, model: model)
                    Divider().background(Color.captureSeparator)
                }
            }
        }
        .background(Color.captureCanvasBackground)
    }

    private var inputMonitoringBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.captureAmber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Global shortcuts are disabled").font(CaptureFont.headline())
                Text("Capture needs Input Monitoring permission for shortcuts to fire while another app is active. Grant it in System Settings, then reopen this app.")
                    .font(CaptureFont.secondary())
                    .foregroundStyle(Color.captureTextSecondary)
            }
            Spacer()
            Button("Open System Settings") { model.openInputMonitoringSettings() }
        }
        .padding(12)
        .background(CapturePalette.amber.swiftUIColor.opacity(0.12))
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject var model: ShortcutsSettingsModel

    var body: some View {
        HStack {
            Text(action.displayName)
                .font(CaptureFont.body())
                .foregroundStyle(Color.captureTextPrimary)
            Spacer()
            if let warning = model.conflictWarnings[action] {
                Text(warning)
                    .font(CaptureFont.secondary())
                    .foregroundStyle(Color.captureCoral)
                    .lineLimit(1)
            }
            ShortcutRecorderView(
                displayString: model.displayString(for: action),
                isRecording: model.recordingAction == action,
                onBeginRecording: { model.beginRecording(action) },
                onCommit: { keyCode, modifiers in model.commitRecording(keyCode: keyCode, modifiers: modifiers) },
                onCancel: { model.cancelRecording() },
                onClear: { model.clearBinding(action) }
            )
        }
        .padding(.horizontal, CaptureMetrics.contentPadding)
        .padding(.vertical, 8)
    }
}

private extension NSColor {
    var swiftUIColor: Color { Color(nsColor: self) }
}

/// Drives `GlobalShortcutManager` for the settings UI: reads current
/// bindings, records a new one via a real `NSEvent` key-capture (see
/// `ShortcutRecorderView`), and surfaces `conflicts(assigning:to:)` results
/// as a per-row warning string without ever blocking the assignment
/// outright (Part I: "do not silently fail" — silently *blocking* an
/// assignment the user explicitly chose would be its own kind of silent
/// failure).
@MainActor
public final class ShortcutsSettingsModel: ObservableObject {
    private let manager: GlobalShortcutManager
    @Published public private(set) var bindings: [ShortcutAction: ShortcutBinding] = [:]
    @Published public private(set) var conflictWarnings: [ShortcutAction: String] = [:]
    @Published public private(set) var recordingAction: ShortcutAction?
    @Published public var inputMonitoringGranted: Bool

    public var openInputMonitoringSettingsAction: () -> Void = {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    public init(manager: GlobalShortcutManager) {
        self.manager = manager
        self.bindings = manager.currentBindings
        self.inputMonitoringGranted = GlobalShortcutManager.inputMonitoringGranted()
        refreshConflicts()
    }

    public func refreshInputMonitoringStatus() {
        inputMonitoringGranted = GlobalShortcutManager.inputMonitoringGranted()
    }

    public func openInputMonitoringSettings() { openInputMonitoringSettingsAction() }

    public func displayString(for action: ShortcutAction) -> String {
        guard let binding = bindings[action] else { return "None" }
        return binding.displayString ?? Self.describe(binding)
    }

    public func beginRecording(_ action: ShortcutAction) {
        recordingAction = action
    }

    public func cancelRecording() {
        recordingAction = nil
    }

    /// Called by `ShortcutRecorderView` once a real key event was captured.
    public func commitRecording(keyCode: UInt16, modifiers: ShortcutModifiers) {
        guard let action = recordingAction else { return }
        let binding = ShortcutBinding(keyCode: keyCode, modifiers: modifiers, displayString: Self.describe(ShortcutBinding(keyCode: keyCode, modifiers: modifiers)))
        if let conflict = manager.conflicts(assigning: binding, to: action) {
            conflictWarnings[action] = Self.describe(conflict)
        } else {
            conflictWarnings[action] = nil
        }
        manager.setBinding(binding, for: action)
        bindings = manager.currentBindings
        recordingAction = nil
    }

    public func clearBinding(_ action: ShortcutAction) {
        manager.removeBinding(for: action)
        bindings = manager.currentBindings
        conflictWarnings[action] = nil
    }

    private func refreshConflicts() {
        var warnings: [ShortcutAction: String] = [:]
        for (action, binding) in bindings {
            if let conflict = manager.conflicts(assigning: binding, to: action) {
                warnings[action] = Self.describe(conflict)
            }
        }
        conflictWarnings = warnings
    }

    private static func describe(_ conflict: ShortcutConflict) -> String {
        switch conflict {
        case .anotherCaptureAction(let action): return "Conflicts with \(action.displayName)"
        case .systemShortcut(let description): return "macOS already uses this: \(description)"
        }
    }

    private static func describe(_ binding: ShortcutBinding) -> String {
        var parts: [String] = []
        if binding.modifiers.contains(.control) { parts.append("⌃") }
        if binding.modifiers.contains(.option) { parts.append("⌥") }
        if binding.modifiers.contains(.shift) { parts.append("⇧") }
        if binding.modifiers.contains(.command) { parts.append("⌘") }
        parts.append(CarbonKeyCodeNaming.symbol(for: binding.keyCode))
        return parts.joined()
    }
}

/// Best-effort keycode -> glyph mapping for display purposes only (never
/// used for matching — `GlobalShortcutManager`/`ShortcutMatcher` match on
/// the raw `keyCode`, not this label). Covers the common alphanumeric row
/// plus the digit keys the spec calls out (3/4/5/6) for parity with
/// `CaptureCapture.CarbonKeyCode`'s own transcription.
enum CarbonKeyCodeNaming {
    private static let labels: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        49: "Space", 53: "Escape"
    ]
    static func symbol(for keyCode: UInt16) -> String {
        labels[keyCode] ?? "Key \(keyCode)"
    }
}

/// A real shortcut-recording control: clicking it arms an `NSEvent` local
/// key monitor and captures the very next key-down as the new binding
/// (Escape cancels). AppKit-backed (`NSViewRepresentable`) because
/// `ShortcutBinding` needs the raw `CGKeyCode` `NSEvent.keyCode` gives,
/// which SwiftUI's own `onKeyPress` API does not expose.
private struct ShortcutRecorderView: NSViewRepresentable {
    let displayString: String
    let isRecording: Bool
    let onBeginRecording: () -> Void
    let onCommit: (UInt16, ShortcutModifiers) -> Void
    let onCancel: () -> Void
    let onClear: () -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton(frame: .zero)
        button.onBeginRecording = onBeginRecording
        button.onCommit = onCommit
        button.onCancel = onCancel
        button.onClear = onClear
        return button
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onBeginRecording = onBeginRecording
        nsView.onCommit = onCommit
        nsView.onCancel = onCancel
        nsView.onClear = onClear
        nsView.render(displayString: displayString, isRecording: isRecording)
    }

    final class RecorderButton: NSView {
        private let label = NSTextField(labelWithString: "")
        private let clearButton = NSButton(title: "×", target: nil, action: nil)
        var onBeginRecording: (() -> Void)?
        var onCommit: ((UInt16, ShortcutModifiers) -> Void)?
        var onCancel: (() -> Void)?
        var onClear: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
            wantsLayer = true
            layer?.cornerRadius = CaptureMetrics.controlCornerRadius
            layer?.borderWidth = 1
            addSubview(label)
            addSubview(clearButton)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            clearButton.translatesAutoresizingMaskIntoConstraints = false
            clearButton.isBordered = false
            clearButton.target = self
            clearButton.action = #selector(clearTapped)
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: 140),
                heightAnchor.constraint(equalToConstant: 24),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                clearButton.widthAnchor.constraint(equalToConstant: 16)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func render(displayString: String, isRecording: Bool) {
            label.stringValue = isRecording ? "Press a key…" : displayString
            layer?.backgroundColor = (isRecording ? CaptureTheme.accent.withAlphaComponent(0.15) : CaptureTheme.panelBackground).cgColor
            layer?.borderColor = (isRecording ? CaptureTheme.accent : CaptureTheme.separator).cgColor
            clearButton.isHidden = (displayString == "None") || isRecording
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onBeginRecording?()
        }

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // Escape cancels
                onCancel?()
                return
            }
            onCommit?(event.keyCode, ShortcutModifiers(nsEventModifierFlags: event.modifierFlags))
        }

        @objc private func clearTapped() { onClear?() }
    }
}
