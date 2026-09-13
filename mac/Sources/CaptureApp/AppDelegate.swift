import AppKit

/// Standard `NSApplicationDelegate` lifecycle. Capture runs as a regular
/// app — Dock icon *and* menu bar item — per Part I §28's "Menu bar /
/// compact launcher" being one of several primary surfaces (History,
/// Editor, Command Palette are full windows a Dock-less/LSUIElement app
/// would make awkward to Cmd-Tab back to), matching how CleanShot X/Shottr
/// themselves ship. `.setActivationPolicy(.regular)` is set explicitly in
/// `main.swift` rather than only via an `LSUIElement` Info.plist key, since
/// this SwiftPM executable target has no bundled Info.plist at build time
/// (see `docs/decisions/0001-spm-instead-of-xcodeproj.md`) — `scripts/
/// package-app.sh` (referenced from `Package.swift`'s header comment) is
/// expected to assemble the final `.app` bundle and Info.plist around this
/// executable.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment()
        self.environment = environment
        environment.applicationDidFinishLaunching()
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.applicationWillTerminate()
    }

    /// A regular Dock-icon app with no open windows should not quit on its
    /// own just because the last window closed — the menu bar item and
    /// global shortcuts are still the primary way to use Capture.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
