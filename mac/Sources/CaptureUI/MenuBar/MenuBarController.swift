import AppKit
import CaptureCapture
import Foundation

/// Owns the `NSStatusItem` (Part I §28 "Menu bar / compact launcher — quick
/// capture commands"). Capture ships as a regular Dock app *and* a menu bar
/// item (see `CaptureApp`'s activation-policy note) so the menu bar item is
/// always reachable even when every window is closed.
///
/// Deliberately holds no capture/editor/history logic of its own — every
/// menu command is a plain closure supplied by the caller (`CaptureApp`,
/// which owns the real `CaptureFlowController`/window controllers), so this
/// type's only job is presenting the menu and staying visually correct
/// (showing the "shortcuts disabled" state — see `setInputMonitoringWarning`
/// — per `docs/PERMISSIONS.md`'s requirement that a missing Input
/// Monitoring grant "must be surfaced explicitly, never leave the user
/// wondering why a shortcut does nothing").
@MainActor
public final class MenuBarController {
    public struct Actions {
        public var captureArea: () -> Void
        public var captureWindow: () -> Void
        public var captureFullScreen: () -> Void
        public var captureRepeatArea: () -> Void
        public var openHistory: () -> Void
        public var openEditor: () -> Void
        public var openCommandPalette: () -> Void
        public var openSettings: () -> Void
        public var openSystemSettingsForInputMonitoring: () -> Void
        public var quit: () -> Void

        public init(
            captureArea: @escaping () -> Void,
            captureWindow: @escaping () -> Void,
            captureFullScreen: @escaping () -> Void,
            captureRepeatArea: @escaping () -> Void,
            openHistory: @escaping () -> Void,
            openEditor: @escaping () -> Void,
            openCommandPalette: @escaping () -> Void,
            openSettings: @escaping () -> Void,
            openSystemSettingsForInputMonitoring: @escaping () -> Void,
            quit: @escaping () -> Void
        ) {
            self.captureArea = captureArea
            self.captureWindow = captureWindow
            self.captureFullScreen = captureFullScreen
            self.captureRepeatArea = captureRepeatArea
            self.openHistory = openHistory
            self.openEditor = openEditor
            self.openCommandPalette = openCommandPalette
            self.openSettings = openSettings
            self.openSystemSettingsForInputMonitoring = openSystemSettingsForInputMonitoring
            self.quit = quit
        }
    }

    private let statusItem: NSStatusItem
    private let actions: Actions
    private var inputMonitoringWarningItem: NSMenuItem?

    public init(actions: Actions) {
        self.actions = actions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureButton()
        statusItem.menu = buildMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // A simple, high-contrast glyph (the system "viewfinder" symbol
        // reads as "capture" at menu-bar size without needing a custom
        // asset) — tinted via `NSImage.isTemplate` so it follows the menu
        // bar's own light/dark rendering automatically.
        let image = NSImage(systemSymbolName: "viewfinder.rectangular", accessibilityDescription: "Capture")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Capture"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(withHandler("Capture Area", key: "") { [actions] in actions.captureArea() })
        menu.addItem(withHandler("Capture Window", key: "") { [actions] in actions.captureWindow() })
        menu.addItem(withHandler("Capture Full Screen", key: "") { [actions] in actions.captureFullScreen() })
        menu.addItem(withHandler("Capture Repeat Area", key: "") { [actions] in actions.captureRepeatArea() })
        menu.addItem(.separator())
        menu.addItem(withHandler("Open Editor", key: "") { [actions] in actions.openEditor() })
        menu.addItem(withHandler("Open History…", key: "") { [actions] in actions.openHistory() })
        menu.addItem(withHandler("Command Palette…", key: "k") { [actions] in actions.openCommandPalette() })
        menu.addItem(.separator())
        menu.addItem(withHandler("Settings…", key: ",") { [actions] in actions.openSettings() })
        menu.addItem(.separator())
        menu.addItem(withHandler("Quit Capture", key: "q") { [actions] in actions.quit() })
        return menu
    }

    /// Part I §"Global Custom Shortcut System" + `docs/PERMISSIONS.md`:
    /// "Global shortcuts silently fail to fire — `CaptureUI` must surface
    /// this state explicitly." Called by `CaptureApp` whenever
    /// `GlobalShortcutManager.inputMonitoringGranted()` is (or becomes)
    /// `false`; the menu-bar icon itself gets a warning badge and a menu
    /// item explaining why shortcuts aren't firing, with a one-click path
    /// to System Settings.
    public func setInputMonitoringWarning(_ isShowing: Bool) {
        if isShowing {
            let image = NSImage(systemSymbolName: "viewfinder.rectangular", accessibilityDescription: "Capture — shortcuts disabled")
            image?.isTemplate = false
            statusItem.button?.image = badgedImage()
            statusItem.button?.toolTip = "Capture — global shortcuts are disabled (Input Monitoring permission needed)"

            if inputMonitoringWarningItem == nil, let menu = statusItem.menu {
                let item = withHandler("⚠️ Global shortcuts disabled — Open System Settings…", key: "") { [actions] in
                    actions.openSystemSettingsForInputMonitoring()
                }
                menu.insertItem(.separator(), at: 0)
                menu.insertItem(item, at: 0)
                inputMonitoringWarningItem = item
            }
        } else {
            configureButton()
            statusItem.button?.toolTip = "Capture"
            if let item = inputMonitoringWarningItem, let menu = statusItem.menu {
                let separatorIndex = menu.index(of: item) + 1
                if separatorIndex < menu.numberOfItems, menu.item(at: separatorIndex)?.isSeparatorItem == true {
                    menu.removeItem(at: separatorIndex)
                }
                menu.removeItem(item)
                inputMonitoringWarningItem = nil
            }
        }
    }

    private func badgedImage() -> NSImage? {
        guard let base = NSImage(systemSymbolName: "viewfinder.rectangular", accessibilityDescription: nil) else { return nil }
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        base.isTemplate = true
        base.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        CapturePalette.amber.setFill()
        let dot = NSBezierPath(ovalIn: NSRect(x: 12, y: 8, width: 8, height: 8))
        dot.fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func withHandler(_ title: String, key: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuItemTarget.invoke), keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = [.command] }
        let target = MenuItemTarget(action: action)
        item.target = target
        item.representedObject = target // retains the target for the item's lifetime
        return item
    }
}

/// `NSMenuItem.action`/`.target` need an `@objc`-callable Objective-C
/// target; this tiny box adapts a Swift closure to that without every call
/// site needing its own `@objc` method.
private final class MenuItemTarget: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
