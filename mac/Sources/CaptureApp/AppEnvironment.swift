import AppKit
import CaptureBrowserBridge
import CaptureCapture
import CaptureCore
import CaptureEditor
import CaptureHistory
import CaptureInspection
import CaptureUI
import CoreGraphics
import Foundation

/// Owns every long-lived object `CaptureApp` wires together and is the
/// concrete implementation of Part I §39's two acceptance milestones. See
/// this module's final report for the file-by-file map of what each piece
/// below actually does and which real APIs from the other six modules it
/// calls.
@MainActor
public final class AppEnvironment {
    // MARK: - Core services (real dependency graph, not mocked)

    public let historyStore: HistoryStore
    public let browserBridgeService: BrowserBridgeService
    public let blobStore: ContentAddressedBlobStore
    public let globalShortcutManager = GlobalShortcutManager()
    public let captureFlowController = CaptureFlowController()
    public let commandPaletteController = CommandPaletteController()
    public let quickAccessOverlay = QuickAccessOverlay()

    // MARK: - Settings models (CaptureUI-owned, persisted here)

    private let shortcutsSettingsModel: ShortcutsSettingsModel
    private let snapSettingsModel: SnapSettingsModel
    private let privacySettingsModel: PrivacySettingsModel

    // MARK: - Lazily-wired UI (IUO: assigned in `init` after every `let`
    // above is set, so these closures can freely capture `self` — see this
    // module's final report on why that ordering matters here)

    private var menuBarController: MenuBarController!
    private var browserElementCaptureFlow: BrowserElementCaptureFlow!
    private var settingsWindowController: SettingsWindowController?
    private var historyWindowController: HistoryWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var openEditors: [ObjectIdentifier: EditorWindowController] = [:]
    private var inputMonitoringRetryTimer: Timer?

    private let logger = CaptureLogger(category: "AppEnvironment")

    private static let onboardingCompletedKey = "com.capture.app.onboardingCompleted.v1"
    private static let snapSettingsKey = "com.capture.app.snapSettings.v1"
    private static let privacyEnabledKey = "com.capture.app.privacy.bookmarksBarEnabled.v1"
    private static let privacyStyleKey = "com.capture.app.privacy.redactionStyle.v1"

    public init() {
        let appSupport = Self.applicationSupportDirectory()

        // `docs/ARCHITECTURE.md`: "owns the shared `CaptureHistory.HistoryStore`
        // instance (opened at `~/Library/Application Support/Capture/history.sqlite`)".
        do {
            self.historyStore = try HistoryStore(applicationSupportDirectory: appSupport)
        } catch {
            // A broken/unreadable history index is not something the rest
            // of the app can degrade around silently (every capture would
            // either crash on insert or silently stop being indexed) —
            // fail loudly at launch rather than run in a half-working state.
            fatalError("Capture could not open history.sqlite at \(appSupport.path): \(error)")
        }

        self.browserBridgeService = BrowserBridgeService()
        self.blobStore = ContentAddressedBlobStore(applicationSupportDirectory: appSupport)

        self.snapSettingsModel = SnapSettingsModel(initial: Self.loadSnapSettings())
        self.privacySettingsModel = PrivacySettingsModel(
            bookmarksBarPrivacyEnabled: Self.loadPrivacyEnabled(),
            redactionStyle: Self.loadRedactionStyle()
        )
        self.shortcutsSettingsModel = ShortcutsSettingsModel(manager: globalShortcutManager)

        // Every `let` above is now set — `self` is fully initialized from
        // here on, so the rest of this initializer (and every closure it
        // builds) can freely capture/reference it.

        registerDefaultShortcutBindingsIfNeeded()

        captureFlowController.updateSnapSettings(snapSettingsModel.currentSettings)
        snapSettingsModel.onChange = { [weak self] settings in
            self?.captureFlowController.updateSnapSettings(settings)
            Self.saveSnapSettings(settings)
        }
        privacySettingsModel.onChange = { model in
            Self.savePrivacyEnabled(model.bookmarksBarPrivacyEnabled)
            Self.saveRedactionStyle(model.redactionStyle)
        }

        browserElementCaptureFlow = BrowserElementCaptureFlow(browserBridgeService: browserBridgeService) { [weak self] image, sourceApp in
            guard let self else { fatalError("AppEnvironment deallocated while an editor was still being opened") }
            return self.makeEditor(sourceImage: image, sourceApp: sourceApp, historyCaptureId: nil)
        }

        // Closes the session/evidence discovery gap `BrowserElementCaptureFlow`
        // documents: `BrowserBridgeService` now calls back into the app the
        // moment new evidence is stored, instead of the app having no way
        // to learn a tabSessionId exists at all. `browserWindowFrame` is
        // resolved best-effort at the moment evidence arrives (see
        // `Self.frontmostBrowserWindowFrame()` below) — the user has just
        // interacted with the browser tab to pin the element, so it is very
        // likely still frontmost, but this is a heuristic, not a guarantee,
        // and is the same "least-trusted" coordinate assumption
        // `BrowserElementCaptureFlow.resolveScreenRect` already flags.
        browserBridgeService.onEvidenceUpdated = { [weak self] tabSessionId, _ in
            guard let self, let frame = Self.frontmostBrowserWindowFrame() else { return }
            Task { @MainActor in
                await self.handleElementEvidenceAvailable(tabSessionId: tabSessionId, browserWindowFrame: frame)
            }
        }

        wireCaptureFlowController()
        wireGlobalShortcutHandlers()
        menuBarController = MenuBarController(actions: makeMenuBarActions())

        // `docs/ARCHITECTURE.md`'s process model: the Unix-socket bridge
        // must be listening for the native host to connect to, independent
        // of whether any browser is even open yet.
        do {
            try browserBridgeService.start()
        } catch {
            logger.error("BrowserBridgeService failed to start listening: \(String(describing: error))")
        }
    }

    /// Called once from `AppDelegate.applicationDidFinishLaunching(_:)`.
    public func applicationDidFinishLaunching() {
        if UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey) {
            startShortcutMonitoring()
        } else {
            presentOnboarding()
        }
    }

    public func applicationWillTerminate() {
        browserBridgeService.stop()
        globalShortcutManager.stopMonitoring()
        historyStore.close()
    }

    // MARK: - Onboarding (docs/PERMISSIONS.md's progressive-permission flow)

    private func presentOnboarding() {
        let controller = OnboardingWindowController { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
            self.onboardingWindowController?.close()
            self.onboardingWindowController = nil
            self.startShortcutMonitoring()
        }
        onboardingWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Input Monitoring is "requested once, at first launch after
    /// onboarding" (`docs/PERMISSIONS.md`'s correction note on
    /// `GlobalShortcutManager`). If declined, shortcuts stay unregistered
    /// and the menu bar surfaces a persistent, explicit warning — never a
    /// silent no-op — with a retry loop so granting it later (System
    /// Settings) picks shortcuts back up without a relaunch.
    private func startShortcutMonitoring() {
        if !GlobalShortcutManager.inputMonitoringGranted() {
            GlobalShortcutManager.requestInputMonitoringAccess()
        }
        do {
            try globalShortcutManager.startMonitoring()
            menuBarController.setInputMonitoringWarning(false)
            inputMonitoringRetryTimer?.invalidate()
            inputMonitoringRetryTimer = nil
        } catch {
            logger.warning("Input Monitoring not granted — global shortcuts are disabled until it is.")
            menuBarController.setInputMonitoringWarning(true)
            scheduleInputMonitoringRetry()
        }
    }

    private func scheduleInputMonitoringRetry() {
        inputMonitoringRetryTimer?.invalidate()
        inputMonitoringRetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, GlobalShortcutManager.inputMonitoringGranted() else { return }
                self.startShortcutMonitoring()
            }
        }
    }

    private func registerDefaultShortcutBindingsIfNeeded() {
        guard globalShortcutManager.currentBindings.isEmpty else { return }
        // Modest, non-conflicting defaults (Control+Option+<letter> —
        // deliberately not Shift+Command+3/4/5/6, which
        // `SystemShortcuts.macOSBuiltIns()` already flags as owned by
        // macOS). Every one of these remains fully user-remappable via
        // Settings > Shortcuts (`ShortcutsSettingsView`).
        let defaults: [(ShortcutAction, UInt16)] = [
            (.captureArea, 0),           // A
            (.captureWindow, 13),        // W
            (.captureFullScreen, 3),     // F
            (.captureRepeatArea, 15),    // R
            (.openHistory, 4),           // H
            (.openEditor, 14),           // E
            (.commandPalette, 40),       // K
            (.toggleInspectMode, 34)     // I
        ]
        for (action, keyCode) in defaults {
            globalShortcutManager.setBinding(ShortcutBinding(keyCode: keyCode, modifiers: [.control, .option]), for: action)
        }
    }

    private func wireGlobalShortcutHandlers() {
        globalShortcutManager.setHandler({ [weak self] in self?.captureFlowController.beginAreaCapture() }, for: .captureArea)
        globalShortcutManager.setHandler({ [weak self] in self?.captureFlowController.beginWindowCapture() }, for: .captureWindow)
        globalShortcutManager.setHandler({ [weak self] in self?.captureFlowController.captureFullScreen() }, for: .captureFullScreen)
        globalShortcutManager.setHandler({ [weak self] in self?.captureFlowController.captureRepeatArea() }, for: .captureRepeatArea)
        globalShortcutManager.setHandler({ [weak self] in self?.presentHistory() }, for: .openHistory)
        globalShortcutManager.setHandler({ [weak self] in self?.presentMostRecentEditorOrInform() }, for: .openEditor)
        globalShortcutManager.setHandler({ [weak self] in self?.presentCommandPalette() }, for: .commandPalette)
        globalShortcutManager.setHandler({ [weak self] in self?.presentInspectModeGapNotice() }, for: .toggleInspectMode)
    }

    // MARK: - Phase 1: capture -> editor -> history -> project (Part I §39)

    private func wireCaptureFlowController() {
        captureFlowController.onCaptureCompleted = { [weak self] result in self?.handleCaptureCompleted(result) }
        captureFlowController.onScreenRecordingPermissionDenied = { [weak self] in self?.presentScreenRecordingDeniedAlert() }
        captureFlowController.onCaptureFailed = { [weak self] error in self?.logger.error("Capture failed: \(String(describing: error))") }
    }

    private func handleCaptureCompleted(_ result: CapturedImageResult) {
        do {
            // Content-addressed blob write, per the design
            // `CaptureCore.Hashing`'s own doc comment names (Part I §10/§20)
            // but no module actually implements — see
            // `ContentAddressedBlobStore`'s doc comment.
            let (hash, _) = try blobStore.store(result.image)

            let sourceAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Capture"
            let metadata = CaptureMetadata(sourceApp: sourceAppName, os: "macOS")
            let captureId = try historyStore.insertCapture(
                metadata: metadata,
                mediaHash: hash,
                captureType: .screenshot,
                dimensions: result.pixelSize
            )

            let editor = makeEditor(sourceImage: result.image, sourceApp: sourceAppName, historyCaptureId: captureId)
            editor.onProjectSaved = { [weak self] url in self?.blobStore.recordProjectURL(url, forHash: hash) }
            editor.showWindow(nil)

            presentQuickAccess(for: result.image, editor: editor)
        } catch {
            logger.error("Failed to index/open a finished capture: \(String(describing: error))")
            presentAlert(message: "Capture couldn't be saved to history", informative: String(describing: error))
        }
    }

    private func makeEditor(sourceImage: CGImage, sourceApp: String?, historyCaptureId: UUID?) -> EditorWindowController {
        let editor = EditorWindowController(sourceImage: sourceImage, sourceApp: sourceApp, historyStore: historyStore, historyCaptureId: historyCaptureId)
        editor.pdfExporter = PDFExportAdapter()
        track(editor)
        return editor
    }

    private func track(_ editor: EditorWindowController) {
        let key = ObjectIdentifier(editor)
        openEditors[key] = editor
        if let window = editor.window {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.openEditors.removeValue(forKey: key)
            }
        }
    }

    private func presentQuickAccess(for image: CGImage, editor: EditorWindowController) {
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        quickAccessOverlay.present(
            thumbnail: thumbnail,
            actions: QuickAccessOverlay.Actions(
                copy: { [weak editor] in editor?.copyToClipboard() },
                save: { [weak editor] in editor?.promptSaveProject() },
                edit: { [weak editor] in editor?.showWindow(nil) },
                pin: { [weak self, weak editor] in
                    guard let captureId = editor?.historyCaptureId else { return }
                    self?.setFavourite(true, captureId: captureId)
                },
                ocr: { [weak self] in self?.presentNotImplementedAlert(feature: "OCR") }
            )
        )
    }

    private func setFavourite(_ favourite: Bool, captureId: UUID) {
        let historyStore = historyStore
        Task.detached { try? historyStore.setFavourite(favourite, forCapture: captureId) }
    }

    // MARK: - Phase 3: browser element evidence -> capture -> DOM-anchored annotation

    /// The real, working end of the Phase 3 pipeline (see
    /// `BrowserElementCaptureFlow`'s doc comment for the one missing link —
    /// discovering `tabSessionId` — that currently keeps this from firing
    /// automatically). Exposed publicly so a future `BrowserBridgeService`
    /// session/evidence callback (or, meanwhile, manual integration testing
    /// on a real Mac with a known session id) has a real entry point to
    /// call rather than needing to reassemble this wiring itself.
    public func handleElementEvidenceAvailable(tabSessionId: UUID, browserWindowFrame: CaptureRect) async {
        await browserElementCaptureFlow.handleElementEvidenceAvailable(tabSessionId: tabSessionId, browserWindowFrame: browserWindowFrame)
    }

    /// Part I §39 step 10: "attempt to resolve the anchor" on reopen.
    public func attemptAnchorResolution(for editor: EditorWindowController, tabSessionId: UUID) async {
        let results = await browserElementCaptureFlow.attemptAnchorResolution(for: editor, tabSessionId: tabSessionId)
        let untrustworthyCount = results.values.filter { !$0.isTrustworthy }.count
        if untrustworthyCount > 0 {
            presentAlert(message: "Anchor not found", informative: "\(untrustworthyCount) DOM-anchored annotation(s) could not be confidently re-resolved on this page and will stay at their last known position.")
        }
    }

    // MARK: - "Reopen it from history" (Part I §39 step 9) and "Reopen project" (step 12)

    private func openFromHistory(_ entry: HistoryEntry) {
        if let projectURL = blobStore.projectURL(forHash: entry.mediaContentHash) {
            do {
                let editor = try EditorWindowController(loadingProjectAt: projectURL, historyStore: historyStore)
                editor.pdfExporter = PDFExportAdapter()
                track(editor)
                editor.showWindow(nil)
            } catch {
                presentAlert(message: "Couldn't reopen this project", informative: String(describing: error))
            }
        } else if let image = blobStore.loadImage(forHash: entry.mediaContentHash) {
            let editor = makeEditor(sourceImage: image, sourceApp: entry.sourceApp, historyCaptureId: entry.id)
            editor.showWindow(nil)
        } else {
            presentAlert(message: "Capture unavailable", informative: "The original image for this history entry could not be found on disk.")
        }
    }

    // MARK: - Windows

    private func presentHistory() {
        if historyWindowController == nil {
            historyWindowController = HistoryWindowController(historyStore: historyStore, onOpen: { [weak self] entry in self?.openFromHistory(entry) })
        }
        historyWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                shortcutsModel: shortcutsSettingsModel,
                snapModel: snapSettingsModel,
                privacyModel: privacySettingsModel
            )
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentCommandPalette() {
        commandPaletteController.toggle(items: buildCommandPaletteItems())
    }

    private func presentMostRecentEditorOrInform() {
        if let editor = openEditors.values.first {
            editor.showWindow(nil)
        } else {
            presentAlert(message: "No editor is open", informative: "Take a capture first (Capture Area, Capture Window, or Capture Full Screen).")
        }
    }

    private func buildCommandPaletteItems() -> [CommandPaletteItem] {
        [
            CommandPaletteItem(title: "Capture Area", subtitle: "Drag to select a region", symbol: "viewfinder", family: .capture) { [weak self] in self?.captureFlowController.beginAreaCapture() },
            CommandPaletteItem(title: "Capture Window", symbol: "macwindow", family: .capture) { [weak self] in self?.captureFlowController.beginWindowCapture() },
            CommandPaletteItem(title: "Capture Full Screen", symbol: "display", family: .capture) { [weak self] in self?.captureFlowController.captureFullScreen() },
            CommandPaletteItem(title: "Capture Repeat Area", symbol: "arrow.clockwise", family: .capture) { [weak self] in self?.captureFlowController.captureRepeatArea() },
            CommandPaletteItem(title: "Open History", symbol: "clock.arrow.circlepath", family: .neutral) { [weak self] in self?.presentHistory() },
            CommandPaletteItem(title: "Open Editor", symbol: "square.and.pencil", family: .neutral) { [weak self] in self?.presentMostRecentEditorOrInform() },
            CommandPaletteItem(title: "Settings…", symbol: "gearshape", family: .neutral) { [weak self] in self?.presentSettings() },
            CommandPaletteItem(title: "Toggle Inspect Mode", subtitle: "Requires an active browser session — see notes", symbol: "eyedropper", family: .inspect) { [weak self] in self?.presentInspectModeGapNotice() }
        ]
    }

    // MARK: - Menu bar

    private func makeMenuBarActions() -> MenuBarController.Actions {
        MenuBarController.Actions(
            captureArea: { [weak self] in self?.captureFlowController.beginAreaCapture() },
            captureWindow: { [weak self] in self?.captureFlowController.beginWindowCapture() },
            captureFullScreen: { [weak self] in self?.captureFlowController.captureFullScreen() },
            captureRepeatArea: { [weak self] in self?.captureFlowController.captureRepeatArea() },
            openHistory: { [weak self] in self?.presentHistory() },
            openEditor: { [weak self] in self?.presentMostRecentEditorOrInform() },
            openCommandPalette: { [weak self] in self?.presentCommandPalette() },
            openSettings: { [weak self] in self?.presentSettings() },
            openSystemSettingsForInputMonitoring: { Self.openSystemSettings(pane: "Privacy_ListenEvent") },
            quit: { NSApp.terminate(nil) }
        )
    }

    // MARK: - Alerts

    private func presentScreenRecordingDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Capture needs Screen Recording permission to take screenshots. Enable Capture under System Settings > Privacy & Security > Screen Recording, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Self.openSystemSettings(pane: "Privacy_ScreenCapture")
        }
    }

    private func presentInspectModeGapNotice() {
        presentAlert(
            message: "Inspect Mode needs an active browser session",
            informative: "Open Chrome, run the Capture extension's Inspect Mode there, then pin an element — Capture will pick up its evidence once a browser tab session is active. (This build's native<->browser session hand-off has a known gap; see docs/IMPLEMENTATION_STATUS.md.)"
        )
    }

    private func presentNotImplementedAlert(feature: String) {
        presentAlert(message: "\(feature) isn't available yet", informative: "\(feature) is not implemented in this build.")
    }

    private func presentAlert(message: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Best-effort on-screen frame (AppKit space: bottom-left origin, Y up
    /// — same convention as `CaptureCapture.LiveWindowGeometryProvider`) of
    /// the frontmost window belonging to a known Chromium-family browser.
    /// Used only as the `browserWindowFrame` input to
    /// `BrowserElementCaptureFlow.handleElementEvidenceAvailable`, which
    /// already documents `resolveScreenRect` as its own least-trusted,
    /// unverified-on-a-real-browser piece — this resolver adds a second,
    /// separate assumption (that a known-browser window is actually
    /// frontmost/only one is on screen) on top of that, so treat the whole
    /// Phase 3 auto-fire path as a best-effort convenience, not a
    /// guaranteed-correct pipeline, until both are validated on a real Mac.
    /// `CaptureCapture.LiveWindowGeometryProvider` doesn't expose owning-app
    /// filtering in its public API, so this queries Quartz directly rather
    /// than adding a dependency edge onto a private implementation detail
    /// of another module.
    private static let knownBrowserBundleIDs: Set<String> = [
        "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser"
    ]

    private static func frontmostBrowserWindowFrame() -> CaptureRect? {
        let browserApps = NSWorkspace.shared.runningApplications.filter {
            guard let bundleID = $0.bundleIdentifier else { return false }
            return knownBrowserBundleIDs.contains(bundleID)
        }
        guard !browserApps.isEmpty else { return nil }
        let browserPIDs = Set(browserApps.map(\.processIdentifier))

        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] else {
            return nil
        }

        // Quartz's on-screen list is already frontmost-first, so the first
        // normal-layer window owned by a known browser is the best guess.
        for entry in rawList {
            guard let layer = entry[kCGWindowLayer as String] as? Int32, layer == 0 else { continue }
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t, browserPIDs.contains(ownerPID) else { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? CFDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let appKitRect = CGRect(
                x: cgBounds.origin.x,
                y: primaryHeight - cgBounds.origin.y - cgBounds.height,
                width: cgBounds.width,
                height: cgBounds.height
            )
            return CaptureRect(cgRect: appKitRect)
        }
        return nil
    }

    // MARK: - Paths

    private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Capture", isDirectory: true)
    }

    // MARK: - Settings persistence

    private static func loadSnapSettings() -> SnapSettings {
        guard let data = UserDefaults.standard.data(forKey: snapSettingsKey),
              let decoded = try? CaptureCoreJSON.decoder.decode(SnapSettings.self, from: data) else { return .default }
        return decoded
    }

    private static func saveSnapSettings(_ settings: SnapSettings) {
        guard let data = try? CaptureCoreJSON.encoder.encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: snapSettingsKey)
    }

    private static func loadPrivacyEnabled() -> Bool {
        // Default ON (hard requirement) when no value has ever been saved.
        UserDefaults.standard.object(forKey: privacyEnabledKey) == nil ? true : UserDefaults.standard.bool(forKey: privacyEnabledKey)
    }

    private static func savePrivacyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: privacyEnabledKey)
    }

    private static func loadRedactionStyle() -> BookmarksBarRedactionStyle {
        guard let raw = UserDefaults.standard.string(forKey: privacyStyleKey), let style = BookmarksBarRedactionStyle(rawValue: raw) else {
            return .default
        }
        return style
    }

    private static func saveRedactionStyle(_ style: BookmarksBarRedactionStyle) {
        UserDefaults.standard.set(style.rawValue, forKey: privacyStyleKey)
    }
}
