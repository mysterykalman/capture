import AppKit

// Plain `main.swift` entry point (rather than a `@main`-annotated type) —
// the simplest, most explicit way to construct `NSApplication` for a
// SwiftPM `.executableTarget` with no storyboard/Info.plist at build time.
// See `AppDelegate`'s doc comment for why `.regular` (Dock icon + menu bar
// item) is set here explicitly.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
